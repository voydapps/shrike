//
//  Resize.swift
//  ShrikeEdit
//
//  Pure resize transform.
//
//  Interpolation → filter:
//    - .lanczos   → `CILanczosScaleTransform` (Core Image)
//    - .bicubic   → CGContext interpolation `.high`
//    - .bilinear  → CGContext interpolation `.default`
//    - .nearest   → CGContext interpolation `.none`
//
//  Lanczos is the default and the highest-quality option at downsample.
//  Nearest preserves hard edges (used intentionally for pixel art / UI
//  asset work).
//

import CoreGraphics
import CoreImage
import Foundation
import os
import ShrikeCore

/// Lifetime of the Lanczos processing context, separate from viewer uploads.
/// A batch scope keeps reuse between its photos; render users protect actual
/// synchronous Core Image work, including interactive edits on other tasks.
final class ResizeContextStore: Sendable {
    final class BatchScope: Sendable {
        private let store: ResizeContextStore
        private let finished = OSAllocatedUnfairLock(initialState: false)
        fileprivate init(_ store: ResizeContextStore) { self.store = store }
        func finish() {
            let first = finished.withLock { value in
                if value { return false }
                value = true
                return true
            }
            if first { store.finishBatch() }
        }
        deinit { finish() }
    }
    private struct State: Sendable {
        var context: CIContext?
        var creating: DispatchGroup?
        var renderUsers = 0
        var batchScopes = 0
        var cleanupRequested = false
    }
    private struct IdleCleanup: Sendable {
        let context: CIContext?
    }
    private enum Lookup: Sendable {
        case ready(CIContext)
        case create(DispatchGroup)
        case wait(DispatchGroup)
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let makeContext: @Sendable () -> CIContext
    private let clearContext: @Sendable (CIContext) -> Void
    private let relieveAllocator: @Sendable () -> Void

    init(makeContext: @escaping @Sendable () -> CIContext = {
        CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }, clearContext: @escaping @Sendable (CIContext) -> Void = { $0.clearCaches() },
         relieveAllocator: @escaping @Sendable () -> Void = { MemoryRelief.schedule() }) {
        self.makeContext = makeContext
        self.clearContext = clearContext
        self.relieveAllocator = relieveAllocator
    }

    func beginBatch() -> BatchScope {
        state.withLock { $0.batchScopes += 1 }
        return BatchScope(self)
    }

    func render(_ operation: (CIContext) -> CGImage?) -> CGImage? {
        let context = acquireContext()
        defer { finishRender() }
        return operation(context)
    }

    private func acquireContext() -> CIContext {
        let lookup = state.withLock { value -> Lookup in
            // Count the user before initialization, so batch completion cannot
            // retire a generation while its first render is being prepared.
            value.renderUsers += 1
            if let context = value.context { return .ready(context) }
            if let creating = value.creating { return .wait(creating) }
            let creating = DispatchGroup()
            creating.enter()
            value.creating = creating
            return .create(creating)
        }
        switch lookup {
        case .ready(let context): return context
        case .create(let creating):
            let context = makeContext()
            state.withLock { value in value.context = context; value.creating = nil }
            creating.leave()
            return context
        case .wait(let creating):
            // Only initial construction waits; established renders remain
            // concurrent. Factory/clear callbacks never execute under lock.
            creating.wait()
            return state.withLock { $0.context! }
        }
    }

    private func takeIdleCleanup(_ value: inout State) -> IdleCleanup? {
        guard value.cleanupRequested, value.batchScopes == 0, value.renderUsers == 0 else { return nil }
        value.cleanupRequested = false
        let retired = value.context
        value.context = nil
        return IdleCleanup(context: retired)
    }
    private func finishBatch() {
        let retired = state.withLock { value in
            precondition(value.batchScopes > 0)
            value.batchScopes -= 1
            value.cleanupRequested = true
            return takeIdleCleanup(&value)
        }
        clearRetired(retired)
    }
    private func finishRender() {
        let retired = state.withLock { value in
            precondition(value.renderUsers > 0)
            value.renderUsers -= 1
            return takeIdleCleanup(&value)
        }
        clearRetired(retired)
    }
    private func clearRetired(_ cleanup: IdleCleanup?) {
        guard let cleanup else { return }
        // New users can create a new generation while this retired, unused
        // context clears. Its image outputs remain independently owned.
        if let context = cleanup.context { clearContext(context) }
        // Batch decoding/encoding also leaves allocator buffers when no
        // Lanczos context was needed. One idle decision still requests the
        // existing debounced relief, without constructing a CIContext.
        relieveAllocator()
    }

    func stateForTesting() -> (batchScopes: Int, renderUsers: Int, hasContext: Bool) {
        state.withLock { ($0.batchScopes, $0.renderUsers, $0.context != nil) }
    }
}

public struct ResizeTool: Sendable {

    static let contexts = ResizeContextStore()

    static func beginBatchProcessing() -> ResizeContextStore.BatchScope { contexts.beginBatch() }

    /// Apply `spec` to `image`. Returns the input unchanged when the
    /// request is degenerate (nonpositive dims) or a no-op (target == source).
    public static func apply(_ spec: ResizeSpec, to image: CGImage) -> CGImage {
        apply(spec, to: image, contexts: contexts)
    }

    static func apply(_ spec: ResizeSpec, to image: CGImage, contexts: ResizeContextStore) -> CGImage {
        let (targetW, targetH) = targetDimensions(spec, width: image.width, height: image.height)

        // No-op fast path.
        if targetW == image.width && targetH == image.height {
            return image
        }

        switch spec.interpolation {
        case .lanczos:
            return resizeLanczos(image, toWidth: targetW, height: targetH, contexts: contexts) ?? resizeCG(
                image, toWidth: targetW, height: targetH, interpolation: .high
            ) ?? image
        case .bicubic:
            return resizeCG(image, toWidth: targetW, height: targetH, interpolation: .high) ?? image
        case .bilinear:
            return resizeCG(image, toWidth: targetW, height: targetH, interpolation: .default) ?? image
        case .nearest:
            return resizeCG(image, toWidth: targetW, height: targetH, interpolation: .none) ?? image
        }
    }

    // MARK: - Internal

    /// Shared validation and clamping for replay and metadata-only sizing.
    static func targetDimensions(_ spec: ResizeSpec, width: Int, height: Int) -> (Int, Int) {
        guard spec.width > 0, spec.height > 0 else { return (width, height) }
        return spec.preventUpscale ? (min(spec.width, width), min(spec.height, height)) : (spec.width, spec.height)
    }

    private static func resizeLanczos(_ image: CGImage, toWidth: Int, height: Int, contexts: ResizeContextStore) -> CGImage? {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else { return nil }
        let ci = CIImage(cgImage: image)
        let scale = CGFloat(height) / CGFloat(image.height)
        let aspect = (CGFloat(toWidth) / CGFloat(image.width)) / scale

        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)

        guard let outCI = filter.outputImage else { return nil }
        // The output extent may not be origin-(0,0); compute a target
        // rect of exactly toWidth × height starting at the extent origin.
        let extent = CGRect(
            x: outCI.extent.origin.x,
            y: outCI.extent.origin.y,
            width: CGFloat(toWidth),
            height: CGFloat(height)
        )
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return contexts.render { context in
            context.createCGImage(outCI, from: extent, format: .RGBA8, colorSpace: colorSpace)
        }
    }

    private static func resizeCG(
        _ image: CGImage,
        toWidth w: Int,
        height h: Int,
        interpolation: CGInterpolationQuality
    ) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = interpolation
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

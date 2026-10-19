//
//  Renderer.swift
//  ShrikeEdit
//
//  Recipe replay engine.
//  Every render replays the recipe's *effective* list
//  (`EditRecipe.effectiveOperations`: geometry in order, then the last
//  Color Adjust, then the last Levels) from the original `CGImage`; we
//  never accumulate floats across ops. Accumulation would drift on
//  repeated slider drags. Replay is O(opCount × pixelCount) which is fine
//  for ≤ 24 MP and the handful of ops a user stacks in one session.
//
//  Latest-wins buffer: slider drags emit hundreds of render requests per
//  second. A `generation: UInt64` counter is incremented on every call;
//  each invocation captures its own generation at entry and drops its
//  result if a newer request has arrived during a suspension point.
//  Same shape as `DecodeQueue.latestNavGen` — read that first for the
//  canonical pattern rationale.
//

import CoreGraphics
import Foundation

/// Quality hint for `EditRenderer.render`.
///
/// During a continuous slider drag the UI can request `.draft` to keep
/// frame rate up; on drag-end it switches to `.full`. The renderer uses
/// the hint to decide whether to downsample before running the Core
/// Image chain.
public enum RenderQualityHint: Sendable {
    case draft
    case full
}

/// Recipe replay engine.
///
/// Thread model: an actor, so only one render runs at a time per
/// instance. The generation guard means older renders that are still
/// mid-flight at a suspension point drop their output rather than
/// clobbering the presented image.
public actor EditRenderer {

    /// Monotonic counter bumped on every request; identical shape to
    /// `DecodeQueue.latestNavGen`. Wraps with `&+=` for total safety.
    private var latestGen: UInt64 = 0

    /// Longest edge (px) the draft path downsamples to before running
    /// the filter chain. 1280 keeps interactive live preview on 24 MP
    /// images snappy on M1; the final drag-end render is always at full
    /// resolution so committed ops carry full-res state.
    private let draftLongEdge: Int

    public init(draftLongEdge: Int = 1280) {
        self.draftLongEdge = draftLongEdge
    }

    /// Full-quality replay dimensions without decoding or rendering pixels.
    /// Uses the tools' same crop snapping, resize clamping and rotated CI
    /// extent, integerized after each operation. Nil means invalid or
    /// unrepresentable dimensions. Source dimensions must be integer pixels.
    /// Render allocation failures can return a tool's input instead; the
    /// actual rendered image remains authoritative in that fallback case.
    public nonisolated static func outputPixelSize(
        from sourceSize: CGSize, operations: [EditOperation]
    ) -> CGSize? {
        var size = sourceSize
        guard pixelDimensions(size) != nil else { return nil }
        for operation in EditRecipe.effectiveOperations(operations) {
            guard let (width, height) = pixelDimensions(size) else { return nil }
            switch operation {
            case .crop(let crop):
                // A valid normalized rect may exceed 1 by the existing
                // epsilon. Refuse overflow before the shared Int snapping.
                if crop.isValid {
                    let scalars = [crop.originX * Double(width), crop.originY * Double(height),
                                   crop.width * Double(width), crop.height * Double(height)]
                    guard scalars.allSatisfy({ Int(exactly: $0.rounded()) != nil }) else { return nil }
                }
                if let rect = CropTool.pixelRect(crop, width: width, height: height) { size = rect.size }
            case .resize(let spec):
                let (w, h) = ResizeTool.targetDimensions(spec, width: width, height: height)
                size = CGSize(width: w, height: h)
            case .rotate(let degrees):
                guard let rotated = RotateTool.outputPixelSize(from: size, degrees: degrees) else { return nil }
                size = rotated
            case .rotateAutoCrop(let degrees):
                guard let rotated = RotateTool.outputPixelSize(from: size, degrees: degrees, autocrop: true) else { return nil }
                size = rotated
            case .rotate90(let quarters):
                guard let rotated = RotateTool.outputPixelSize(from: size, quarters: quarters) else { return nil }
                size = rotated
            case .colorAdjust, .levels:
                break
            }
            guard pixelDimensions(size) != nil else { return nil }
        }
        return size
    }

    private nonisolated static func pixelDimensions(_ size: CGSize) -> (Int, Int)? {
        guard let width = Int(exactly: size.width), let height = Int(exactly: size.height),
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// Replay `recipe` against `original`. Returns the final `CGImage`
    /// or `nil` if a newer `render` / `renderLatest` call superseded this
    /// one at any `await` boundary.
    ///
    /// Callers that care about newer-wins semantics (slider drag) must
    /// treat `nil` as "dropped, don't present". Callers that just want
    /// the final image (export path) can fall back to `renderFinal` which
    /// never returns `nil`.
    public func render(
        recipe: EditRecipe,
        from original: CGImage,
        qualityHint: RenderQualityHint = .full
    ) async -> CGImage? {
        latestGen &+= 1
        let myGen = latestGen

        // Snapshot the ops list up front — the recipe is an actor, so
        // reading `operations` across `await` hops could otherwise see
        // mid-mutation state. One `await` to get the list, then pure
        // in-memory work.
        let ops = EditRecipe.effectiveOperations(await recipe.snapshot())

        // Yield once so any peer renders piling up behind us bump
        // latestGen first. This is what makes "queue
        // 10 renders in 16 ms, at most 2 execute" tractable: the
        // first renderer claimed gen=1 before yielding; the 10th bumps
        // it to gen=10, so gens 2–9 drop at the guard below.
        await Task.yield()
        guard myGen == latestGen else {
            return nil
        }

        // Downsample for draft renders. Full renders run against the
        // original. Draft path uses a nearest-neighbour resample of the
        // original up front — we don't care about quality for a draft,
        // we care about pixels-per-second.
        let source: CGImage
        switch qualityHint {
        case .draft:
            source = downsampleForDraft(original)
        case .full:
            source = original
        }

        var current = source
        for op in ops {
            current = apply(op, to: current)
            // Cheap guard — the ops are synchronous inside Core Image
            // but latestGen may have been bumped between ops by another
            // coroutine on this actor. If it has, bail. This makes a
            // 24 MP multi-op recipe drop on the same suspension point
            // an interactive drag might land on.
            guard myGen == latestGen else {
                return nil
            }
        }
        return current
    }

    /// Unconditional render — no drop semantics, always returns the
    /// final image. Used by `ImageExporter` on the save path where
    /// "newer render" doesn't mean anything.
    public func renderFinal(recipe: EditRecipe, from original: CGImage) async -> CGImage {
        let ops = EditRecipe.effectiveOperations(await recipe.snapshot())
        var current = original
        for op in ops {
            current = apply(op, to: current)
        }
        return current
    }

    /// The image as it enters Levels, for the Auto Contrast / Auto Color
    /// histogram: the effective replay of `recipe`
    /// *without* the levels op (geometry, then the last Color Adjust).
    ///
    /// The result is small: the source is first shrunk to the draft size
    /// (`max(maxEdge, draftLongEdge)`, the same pixels the live draft
    /// preview uses), then the result is shrunk so its long edge is at
    /// most `maxEdge`. `Histogram` samples at 512 px, so the default is
    /// enough. `maxEdge <= 0` renders at full size.
    ///
    /// Never dropped and never drops anything: it does not touch the
    /// newer-wins generation, and it runs off this actor, so a live
    /// `render` in flight is neither cancelled nor made to wait.
    @concurrent
    public nonisolated func renderLevelsInput(
        recipe: EditRecipe,
        from original: CGImage,
        maxEdge: Int = 512
    ) async -> CGImage {
        let ops = EditRecipe.levelsInputOperations(await recipe.snapshot())
        guard maxEdge > 0 else {
            return ops.reduce(original) { apply($1, to: $0) }
        }
        let source = Self.downsample(original, longEdge: max(maxEdge, draftLongEdge))
        let out = ops.reduce(source) { apply($1, to: $0) }
        return Self.downsample(out, longEdge: maxEdge)
    }

    // MARK: - Internal

    /// Dispatch one op to its tool. Pure function of `op` and `input` —
    /// no actor state, but kept here so `render` can call it without an
    /// extra indirection.
    nonisolated private func apply(_ op: EditOperation, to image: CGImage) -> CGImage {
        switch op {
        case .crop(let rect):
            return CropTool.apply(rect, to: image)
        case .rotate(let degrees):
            return RotateTool.apply(degrees: degrees, to: image, autocrop: false)
        case .rotateAutoCrop(let degrees):
            return RotateTool.apply(degrees: degrees, to: image, autocrop: true)
        case .rotate90(let quarters):
            return RotateTool.apply90(quarters: quarters, to: image)
        case .resize(let spec):
            return ResizeTool.apply(spec, to: image)
        case .colorAdjust(let params):
            return ColorAdjustTool.apply(params, to: image)
        case .levels(let params):
            return LevelsTool.apply(params, to: image)
        }
    }

    private func downsampleForDraft(_ image: CGImage) -> CGImage {
        Self.downsample(image, longEdge: draftLongEdge)
    }

    /// Bilinear shrink so the long edge is at most `limit`. Returns the
    /// input unchanged when it already fits.
    private static func downsample(_ image: CGImage, longEdge limit: Int) -> CGImage {
        let longEdge = max(image.width, image.height)
        if longEdge <= limit { return image }
        let scale = Double(limit) / Double(longEdge)
        let w = max(1, Int((Double(image.width)  * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        return ResizeTool.apply(
            ResizeSpec(width: w, height: h, interpolation: .bilinear, preventUpscale: false),
            to: image
        )
    }
}

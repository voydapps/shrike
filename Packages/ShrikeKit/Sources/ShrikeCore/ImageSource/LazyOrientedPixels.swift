//
//  LazyOrientedPixels.swift
//  ShrikeCore
//
//  The lazy CPU twin of a rotated photo. The
//  display texture is built from the file's stored pixels (rotated on the
//  GPU), so the CPU copy is only needed when something draws the photo on
//  the CPU (loupe, edit mode, copy). This CGImage decodes on its first
//  read and keeps the pixels until it is freed, like the upright twin
//  from `FileImageSource.lazyDisplayImage` (ImageIO `ShouldCache`).
//

import CoreGraphics
import Foundation
import os

/// Pixels of a lazy CPU twin: decoded on the first read, then kept until
/// the image is freed. `@unchecked Sendable`: the only mutable state
/// (`bytes`) is guarded by `lock`; the rest is immutable.
final class LazyOrientedPixels: @unchecked Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bitsPerPixel: Int
    let space: CGColorSpace
    let bitmapInfo: UInt32
    private let decode: @Sendable () -> CGImage?
    private let lock = NSLock()
    private var bytes: UnsafeMutableRawPointer?
    private var identity: ImageResourceIdentity?
    private var registryKey: ImageResourceIdentity?
    private struct Context: Sendable {
        let resources: ImageResourceBudget
        let owner: ImageResourceOwner
        let category: ImageResourceCategory
    }
    private var contexts: [ObjectIdentifier: Context] = [:]
    private var resourceLeases: [ObjectIdentifier: ImageResourceLease] = [:]
    private struct Registration: Sendable { weak var pixels: LazyOrientedPixels?; weak var image: CGImage? }
    private static let registry = OSAllocatedUnfairLock<[ImageResourceIdentity: Registration]>(initialState: [:])

    /// Test seam: true once the pixels were decoded.
    var isMaterialized: Bool { lock.withLock { bytes != nil } }

    private init(width: Int, height: Int, space: CGColorSpace,
                 decode: @escaping @Sendable () -> CGImage?) {
        self.width = width
        self.height = height
        self.space = space
        self.decode = decode
        if space.model == .monochrome {
            bitsPerPixel = 8
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        } else {
            bitsPerPixel = 32
            bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        }
        bytesPerRow = (width * bitsPerPixel / 8 + 63) / 64 * 64
    }

    deinit {
        if let registryKey {
            Self.registry.withLock { entries in
                if entries[registryKey]?.pixels === self { entries[registryKey] = nil }
            }
        }
        bytes?.deallocate()
    }

    static func attachAccounting(to image: CGImage, resources: ImageResourceBudget, owner: ImageResourceOwner,
                                 category: ImageResourceCategory) -> Bool {
        let identity = ImageResourceIdentity(object: image, kind: .cpuPixels)
        guard let box = registry.withLock({ entries -> LazyOrientedPixels? in
            guard entries[identity]?.image === image else { return nil }
            return entries[identity]?.pixels
        }) else { return false }
        box.lock.withLock {
            let key = ObjectIdentifier(resources)
            if box.contexts[key] == nil { box.contexts[key] = Context(resources: resources, owner: owner, category: category) }
        }
        box.chargeMaterializedPixels()
        return true
    }

    private func chargeMaterializedPixels() {
        let pending = lock.withLock { () -> (ImageResourceIdentity?, [Context]) in
            guard bytes != nil else { return (nil, []) }
            return (identity, contexts.filter { resourceLeases[$0.key] == nil }.map(\.value))
        }
        guard let identity = pending.0 else { return }
        for context in pending.1 {
            let lease = context.resources.retain([.init(identity: identity, bytes: byteCount)],
                                                 owner: context.owner, category: context.category)
            lock.withLock {
                let key = ObjectIdentifier(context.resources)
                if resourceLeases[key] == nil { resourceLeases[key] = lease }
            }
            // The local reference releases outside the provider lock.
            withExtendedLifetime(lease) {}
        }
    }

    var byteCount: Int { bytesPerRow * height }

    /// The pixels, decoded on the first call. The decoded image is drawn
    /// into this format (same colour space, so no colour conversion); a
    /// failed decode leaves black pixels.
    func pointer() -> UnsafeRawPointer {
        let pointer = lock.withLock {
            if let bytes { return UnsafeRawPointer(bytes) }
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            if let image = decode(),
               let ctx = CGContext(data: buffer, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo) {
                ctx.interpolationQuality = .high
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            bytes = buffer
            return UnsafeRawPointer(buffer)
        }
        chargeMaterializedPixels()
        return pointer
    }

    /// A CGImage whose pixels come from `decode` on first use. Nil when
    /// Core Graphics can't draw 8-bit pixels in `space`.
    static func makeImage(width: Int, height: Int, space: CGColorSpace,
                          decode: @escaping @Sendable () -> CGImage?) -> CGImage? {
        guard width > 0, height > 0, space.model == .rgb || space.model == .monochrome else { return nil }
        let box = LazyOrientedPixels(width: width, height: height, space: space, decode: decode)
        // Probe the format once (1 x 1, no pixels decoded).
        guard CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: box.bitmapInfo) != nil else { return nil }
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0,
            getBytePointer: { info in
                guard let info else { return nil }
                return Unmanaged<LazyOrientedPixels>.fromOpaque(info).takeUnretainedValue().pointer()
            },
            releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let box = Unmanaged<LazyOrientedPixels>.fromOpaque(info).takeUnretainedValue()
                let start = Int(position)
                let n = max(0, min(count, box.byteCount - start))
                guard n > 0 else { return 0 }
                buffer.copyMemory(from: box.pointer().advanced(by: start), byteCount: n)
                return n
            },
            releaseInfo: { info in
                guard let info else { return }
                Unmanaged<LazyOrientedPixels>.fromOpaque(info).release()
            }
        )
        let info = Unmanaged.passRetained(box).toOpaque()
        guard let provider = CGDataProvider(directInfo: info, size: off_t(box.byteCount),
                                            callbacks: &callbacks) else {
            Unmanaged<LazyOrientedPixels>.fromOpaque(info).release()
            return nil
        }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: box.bitsPerPixel, bytesPerRow: box.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: box.bitmapInfo), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        let identity = ImageResourceIdentity(object: image, kind: .cpuPixels)
        // The allocation belongs to the provider, which can outlive the
        // CGImage wrapper. Using the live provider's identity prevents an
        // old CGImage address being reused for an unrelated allocation.
        box.identity = ImageResourceIdentity(object: box, kind: .cpuPixels)
        box.registryKey = identity
        registry.withLock { $0[identity] = Registration(pixels: box, image: image) }
        return image
    }
}

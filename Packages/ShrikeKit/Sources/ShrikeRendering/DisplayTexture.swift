//
//  DisplayTexture.swift
//  ShrikeRendering
//
//  GPU texture for one decoded photo, built OFF the main thread by the
//  decode lane (next/prev under 50 ms, goal one frame).
//
//  Before: every image change rendered the CGImage into a new
//  `rgba16Float` texture on the main thread (10-11 ms of main-thread
//  CPU copy + ~20 ms GPU, 8 bytes per pixel). Now:
//
//  * SDR photos (8-bit, sRGB / Display P3 / other narrow-gamut spaces)
//    use an 8-bit `rgba8Unorm` texture holding the gamma-encoded values.
//    sRGB and Display P3 bytes are copied EXACTLY (colour management off).
//    The shader samples an `rgba8Unorm_srgb` view (the GPU applies the
//    sRGB transfer curve and filters in linear light) and, for sRGB,
//    multiplies by the sRGB → Display P3 primaries matrix. Other narrow spaces (grey,
//    untagged, ICC-only sRGB-likes) are converted by Core Image to
//    Display P3 8-bit first.
//  * Only images that really need it — more than 8 bits per channel,
//    float, HDR, or wide gamut other than Display P3 (Adobe RGB,
//    ProPhoto) — keep the old linear `rgba16Float` path.
//
//  The decode lane waits for the upload's command buffer to complete, so
//  a prepared texture is ready to sample from any command queue.
//

import CoreGraphics
import CoreImage
import ImageIO
import Metal
import simd
import ShrikeCore

/// How the texture's values must be read by the shader.
public enum DisplayTextureEncoding: Sendable, Equatable {
    /// 8-bit, sRGB transfer curve, sRGB primaries (exact copy of the file).
    case srgb8
    /// 8-bit, sRGB transfer curve, Display P3 primaries.
    case displayP3_8
    /// 16-bit float, linear Display P3 (extended range allowed).
    case linearP3Half

    public var isEightBit: Bool { self != .linearP3Half }
}

/// A GPU-ready photo. Immutable after creation.
///
/// `@unchecked Sendable`: `any MTLTexture` is not marked `Sendable` in the
/// SDK, but Metal resources may be referenced from any thread, and this
/// object never writes to the texture after the upload command buffer has
/// completed (the factory waits for it, or — on the main-thread path —
/// orders the upload before the draw on the same command queue).
public final class DisplayTexture: PreparedDisplayImage, @unchecked Sendable {
    /// Texture the shader samples. For 8-bit encodings this is an
    /// `rgba8Unorm_srgb` VIEW of `storage`, so the sampler returns linear
    /// values and filters in linear light.
    public let texture: any MTLTexture
    /// Texture the pixels were written into (`rgba8Unorm` / `rgba16Float`).
    public let storage: any MTLTexture
    public let resourceLease: ImageResourceLease?
    public let encoding: DisplayTextureEncoding
    /// Pixel size of the CGImage the texture was built from. The texture
    /// itself may be smaller (capped at the requested long edge).
    public let sourceWidth: Int
    public let sourceHeight: Int

    public init(
        storage: any MTLTexture, sampled: any MTLTexture, encoding: DisplayTextureEncoding,
        sourceWidth: Int? = nil, sourceHeight: Int? = nil,
        resources: ImageResourceBudget = .shared, owner: ImageResourceOwner = ImageResourceOwner(),
        resourceLease: ImageResourceLease? = nil
    ) {
        self.resourceLease = resourceLease ?? resources.retain([
            ImageResourceCost(identity: ImageResourceIdentity(object: storage, kind: .gpuTexture),
                              bytes: storage.width * storage.height * (encoding.isEightBit ? 4 : 8))
        ], owner: owner, category: .displayCache)
        self.storage = storage
        self.texture = sampled
        self.encoding = encoding
        self.sourceWidth = sourceWidth ?? storage.width
        self.sourceHeight = sourceHeight ?? storage.height
    }

    /// True when this texture was built from `image`'s pixels (by size).
    public func matches(_ image: CGImage) -> Bool {
        sourceWidth == image.width && sourceHeight == image.height
    }

    public var byteCount: Int {
        storage.width * storage.height * (encoding.isEightBit ? 4 : 8)
    }

    /// Row-major 3x3 matrix taking the sampled (linear) values to linear
    /// Display P3: sRGB primaries → P3 for `.srgb8`, identity otherwise.
    public var toLinearP3: simd_float3x3 {
        guard encoding == .srgb8 else { return matrix_identity_float3x3 }
        // Columns of the linear sRGB → linear Display P3 matrix (D65).
        return simd_float3x3(
            SIMD3<Float>(0.822462, 0.033194, 0.017083),
            SIMD3<Float>(0.177538, 0.966806, 0.072397),
            SIMD3<Float>(0.0, 0.0, 0.910520)
        )
    }
}

public enum DisplayTextureFactory {

    /// The system Metal device (a process-wide singleton, so textures made
    /// here are usable by every `MetalImageView`).
    static let device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()

    /// The factory's own queue for background uploads.
    private static let backgroundQueue: (any MTLCommandQueue)? = {
        let q = device?.makeCommandQueue()
        q?.label = "Shrike background texture upload"
        return q
    }()

    /// Preparer for `DecodeQueue`: builds the texture on the decode lane
    /// and waits for the GPU, so neighbours are ready before the key press.
    /// Rotated JPEG / HEIC files are built from their stored pixels and
    /// turned on the GPU (`prepareOriented`).
    public static let preparer = DisplayPreparer(
        oriented: { stored, orientation, sourceSize, maxLongEdge in
            make(from: stored, orientation: orientation, sourceSize: sourceSize,
                 commandQueue: nil, waitUntilCompleted: true, maxLongEdge: maxLongEdge)
        },
        { image, maxLongEdge in
            make(from: image, commandQueue: nil, waitUntilCompleted: true, maxLongEdge: maxLongEdge)
        }
    )

    /// The decode lane and visible slots charge the same budget/owner.
    public static func preparer(resources: ImageResourceBudget, owner: ImageResourceOwner) -> DisplayPreparer {
        DisplayPreparer(oriented: { stored, orientation, size, edge in
            make(from: stored, orientation: orientation, sourceSize: size, commandQueue: nil,
                 waitUntilCompleted: true, maxLongEdge: edge, resources: resources, owner: owner)
        }, { image, edge in
            make(from: image, commandQueue: nil, waitUntilCompleted: true, maxLongEdge: edge,
                 resources: resources, owner: owner)
        })
    }

    /// Creates the Metal device, upload queue and Core Image contexts on
    /// a background thread, so the first neighbour texture does not pay
    /// for them. Then it pushes three
    /// 16 x 16 images through `make` (upright scaled, upright 1:1, rotated
    /// scaled; 8-bit sRGB, the same Core Image graphs and pixel formats as
    /// a real photo), so Core Image loads its GPU programs before the
    /// first photo needs them.
    public static func warmUp() {
        DispatchQueue.global(qos: .userInitiated).async {
            let state = ShrikeSignposts.launch.begin("textureWarmUp")
            defer { ShrikeSignposts.launch.end("textureWarmUp", state) }
            _ = device
            _ = backgroundQueue
            _ = CIContext.shrikeUnmanaged
            guard let tiny = warmUpImage() else { return }
            _ = make(from: tiny, commandQueue: nil, waitUntilCompleted: true, maxLongEdge: 8)
            _ = make(from: tiny, commandQueue: nil, waitUntilCompleted: true, maxLongEdge: nil)
            _ = make(from: tiny, orientation: .left, sourceSize: (16, 16),
                     commandQueue: nil, waitUntilCompleted: true, maxLongEdge: 8)
            _ = CIContext.shrikeShared
        }
    }

    /// 16 x 16 opaque 8-bit sRGB image (what a JPEG decodes to).
    static func warmUpImage() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        return ctx.makeImage()
    }

    /// Frees Core Image's cached intermediates (called when a viewer
    /// window closes, so its uploads do not linger in the shared contexts).
    public static func releaseCaches() {
        CIContext.shrikeUnmanaged.clearCaches()
        CIContext.shrikeShared.clearCaches()
    }

    /// Texture size for `width` x `height` capped at `maxLongEdge`
    /// (aspect kept, never upscaled, at least 1 px).
    public static func cappedSize(width: Int, height: Int, maxLongEdge: Int?) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard let cap = maxLongEdge, cap > 0, longEdge > cap else { return (width, height) }
        let scale = Double(cap) / Double(longEdge)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// Pick the cheapest exact encoding for `image`.
    public static func encoding(for image: CGImage) -> DisplayTextureEncoding {
        guard image.bitsPerComponent <= 8,
              !image.bitmapInfo.contains(.floatComponents) else {
            return .linearP3Half
        }
        guard let space = image.colorSpace else { return .srgb8 }
        if let name = space.name {
            if name == CGColorSpace.sRGB { return .srgb8 }
            if name == CGColorSpace.displayP3 { return .displayP3_8 }
        }
        switch space.model {
        case .rgb, .monochrome:
            // Adobe RGB / ProPhoto etc. do not fit in Display P3.
            return space.isWideGamutRGB ? .linearP3Half : .displayP3_8
        default:
            // CMYK, Lab, indexed: let Core Image convert to linear P3.
            return .linearP3Half
        }
    }

    /// Build a texture for `image`. With `commandQueue == nil` the upload
    /// uses the factory's background queue. When `waitUntilCompleted` is
    /// false the caller must draw on the same queue (ordering).
    /// `maxLongEdge` caps the texture: the fast decode path can return up
    /// to 2x the display size, and a texture larger than the screen only
    /// costs memory. The downscale is a bilinear
    /// GPU resample, the same filter the view uses when it draws.
    ///
    /// `orientation` (EXIF) is applied on the GPU, as part of
    /// the same resample, so a rotated file's stored pixels can be uploaded
    /// as decoded. `sourceSize` is what the texture reports as its source
    /// (the oriented CPU twin's size); default: `image`'s oriented size.
    public static func make(
        from image: CGImage,
        orientation: CGImagePropertyOrientation = .up,
        sourceSize: (width: Int, height: Int)? = nil,
        commandQueue: (any MTLCommandQueue)?,
        waitUntilCompleted: Bool,
        maxLongEdge: Int? = nil,
        resources: ImageResourceBudget = .shared, owner: ImageResourceOwner = ImageResourceOwner()
    ) -> DisplayTexture? {
        guard let device,
              let queue = commandQueue ?? backgroundQueue,
              image.width > 0, image.height > 0 else { return nil }
        let encoding = encoding(for: image)
        let turns = orientation.rawValue >= 5   // EXIF 5-8 swap width and height
        let orientedWidth = turns ? image.height : image.width
        let orientedHeight = turns ? image.width : image.height
        let size = cappedSize(width: orientedWidth, height: orientedHeight, maxLongEdge: maxLongEdge)
        let (pixels, pixelOverflow) = size.width.multipliedReportingOverflow(by: size.height)
        let (textureBytes, byteOverflow) = pixels.multipliedReportingOverflow(by: encoding.isEightBit ? 4 : 8)
        guard !pixelOverflow, !byteOverflow, let reservation = resources.tryReserve(bytes: textureBytes,
            owner: owner, category: .displayCache, priority: .visible, policy: .requiredImage) else { return nil }
        defer { reservation.release() }
        let scaled = size.width != orientedWidth || size.height != orientedHeight
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: encoding.isEightBit ? .rgba8Unorm : .rgba16Float,
            width: size.width,
            height: size.height,
            mipmapped: false
        )
        desc.usage = encoding.isEightBit
            ? [.shaderRead, .shaderWrite, .pixelFormatView]
            : [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let storage = device.makeTexture(descriptor: desc),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Shrike image upload"

        let ci = uploadImage(image, orientation: orientation,
                             scaledTo: scaled ? (size.width, size.height) : nil)
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let sampled: any MTLTexture
        if encoding.isEightBit {
            if isExactCopy(image) {
                // Colour management off: the file's bytes land unchanged.
                CIContext.shrikeUnmanaged.render(
                    ci, to: storage, commandBuffer: commandBuffer,
                    bounds: bounds, colorSpace: image.colorSpace ?? ColorPipeline.srgbSpace
                )
            } else {
                // Narrow-gamut space that is not sRGB/P3 by name: Core
                // Image converts to gamma-encoded Display P3 (8-bit).
                CIContext.shrikeShared.render(
                    ci, to: storage, commandBuffer: commandBuffer,
                    bounds: bounds, colorSpace: ColorPipeline.displayP3Space
                )
            }
            guard let view = storage.makeTextureView(pixelFormat: .rgba8Unorm_srgb) else { return nil }
            sampled = view
        } else {
            ColorPipeline.renderToWorkingSpace(
                image, into: storage, commandBuffer: commandBuffer,
                size: scaled ? CGSize(width: size.width, height: size.height) : nil,
                orientation: orientation
            )
            sampled = storage
        }
        commandBuffer.commit()
        if waitUntilCompleted { commandBuffer.waitUntilCompleted() }
        return DisplayTexture(
            storage: storage, sampled: sampled, encoding: encoding,
            sourceWidth: sourceSize?.width ?? orientedWidth,
            sourceHeight: sourceSize?.height ?? orientedHeight,
            resources: resources, owner: owner
        )
    }

    /// The Core Image graph every upload renders: EXIF `orientation`, then
    /// the flip to texture rows (CIImage origin is bottom-left; the quad
    /// samples top-left first), then an optional bilinear resample to
    /// `size`. All three are affine, so Core Image folds them into one
    /// sampling transform (one GPU pass).
    static func uploadImage(
        _ image: CGImage, orientation: CGImagePropertyOrientation,
        scaledTo size: (width: Int, height: Int)?
    ) -> CIImage {
        var ci = CIImage(cgImage: image)
        if orientation != .up {
            ci = ci.oriented(orientation)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        }
        ci = ci.oriented(.downMirrored)
        if let size {
            ci = ci.clampedToExtent().transformed(by: CGAffineTransform(
                scaleX: CGFloat(size.width) / ci.extent.width,
                y: CGFloat(size.height) / ci.extent.height
            ))
        }
        return ci
    }

    /// True when the encoding's bytes can be copied as-is: tagged exactly
    /// sRGB or Display P3 (or untagged, treated as sRGB).
    static func isExactCopy(_ image: CGImage) -> Bool {
        guard let space = image.colorSpace else { return true }
        guard let name = space.name else { return false }
        return name == CGColorSpace.sRGB || name == CGColorSpace.displayP3
    }
}

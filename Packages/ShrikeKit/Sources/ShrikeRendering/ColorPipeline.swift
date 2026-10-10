//
//  ColorPipeline.swift
//  ShrikeRendering
//
//  ICC → display color management helper.
//
//  Scope: the Metal layer is configured with `rgba16Float` pixel format and
//  `extendedLinearDisplayP3` colorspace (a wide-gamut *linear* working space).
//  The compositor interprets the drawable's float16 samples as linear P3
//  values, so every texture sample the shader returns must already be linear
//  P3. `normalized(_:)` moves any incoming `CGImage` — sRGB JPEG, tagged
//  Display P3, Adobe RGB, monochrome — into that canonical space via
//  CoreImage, producing a 16-bit float CGImage ready for direct upload.
//
//  WHY this matters: an earlier pipeline skipped
//  normalisation entirely and uploaded sRGB JPEG bytes with `.SRGB: false`.
//  The texture contents were gamma-encoded sRGB but the layer declared them
//  linear P3, so the compositor passed them through without applying the
//  sRGB → linear transfer function. Result: every image picked up a strong
//  blue/purple tint — highlights and skin tones shifted toward blue while
//  blacks stayed black (since 0 maps to 0 regardless of transfer function).
//
//  HDR gain maps (kCGImageSourceAuxiliaryDataTypeHDRGainMap) are detected
//  and reported, but *not* applied — we render the SDR base layer.
//

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import Metal

public enum ColorPipeline {

    /// Target working space for the Metal layer (matches `MetalImageView`).
    /// Cached so we don't rebuild it per-image — `CGColorSpace(name:)` is
    /// cheap but this is called on the navigation hot path.
    /// sRGB and (gamma-encoded) Display P3, for the 8-bit texture path.
    public static let srgbSpace: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    public static let displayP3Space: CGColorSpace =
        CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()

    public static let workingColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpaceCreateDeviceRGB()
    }()

    /// Convert `image` into the working color space used by the Metal layer
    /// (`extendedLinearDisplayP3`, 16-bit float). Returns the same image when
    /// conversion is unnecessary or fails (fail-open: wrong-looking colours
    /// beat a black screen).
    ///
    /// The output is a 16-bit-float CGImage tagged with the working color
    /// space. `MTKTextureLoader` will upload it as `rgba16Float` directly,
    /// skipping any gamma trickery, and the values sampled in the shader
    /// match what the layer expects.
    public static func normalized(_ image: CGImage) -> CGImage {
        let workingSpace = workingColorSpace

        // Already tagged with the working space AND at 16-bit depth? No-op.
        // (An 8-bit image tagged as linear-P3 is unusual but we still need
        // to promote to float to avoid quantisation through the shader.)
        if let existing = image.colorSpace,
           existing.name == workingSpace.name,
           image.bitsPerComponent >= 16 {
            return image
        }

        let ci = CIImage(cgImage: image)
        let context = CIContext.shrikeShared
        guard let converted = context.createCGImage(
            ci,
            from: ci.extent,
            format: .RGBAh,              // half-float → matches layer
            colorSpace: workingSpace
        ) else {
            return image
        }
        return converted
    }

    /// Render `image` directly into `texture` (which must be `rgba16Float`),
    /// applying the source-ICC → linear Display-P3 colour conversion in the
    /// same GPU pass. Used by `MetalImageView` to bypass the
    /// `MTKTextureLoader.newTexture(cgImage:)` path, which can't decode the
    /// 16-bit-float CGImage that `normalized(_:)` would otherwise produce
    /// for any source carrying an alpha channel (PNG, TIFF, transparent
    /// HEIC) — the failure was "Image decoding failed", which the viewer's
    /// catch block swallowed, leaving the previous texture (or nil) on
    /// screen and the user staring at solid black.
    ///
    /// The caller owns `commandBuffer` and is responsible for committing
    /// it. The caller also owns `texture` lifetime — we only encode work.
    public static func renderToWorkingSpace(
        _ image: CGImage,
        into texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer,
        size: CGSize? = nil,
        orientation: CGImagePropertyOrientation = .up
    ) {
        // CIImage's coordinate origin is bottom-left; CGImage's is top-left.
        // The shader's UV mapping treats the texture as top-left origin
        // (UV (0,0) maps to vertex (-1, 1) in `MetalImageView.quadBuffer`),
        // so the upload graph flips the CIImage vertically (after the EXIF
        // `orientation`). Without the flip the image renders
        // upside down on screen.
        let turns = orientation.rawValue >= 5
        let oriented = turns
            ? CGSize(width: image.height, height: image.width)
            : CGSize(width: image.width, height: image.height)
        let target = size ?? oriented
        let scaled = target != oriented
        let ci = DisplayTextureFactory.uploadImage(
            image, orientation: orientation,
            scaledTo: scaled ? (Int(target.width), Int(target.height)) : nil
        )
        CIContext.shrikeShared.render(
            ci,
            to: texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: workingColorSpace
        )
    }

    /// Probe the Metal-view's current `NSScreen` for EDR headroom (>1.0 means HDR).
    @MainActor
    public static func edrHeadroom(for screen: NSScreen?) -> CGFloat {
        guard let screen else { return 1.0 }
        return screen.maximumExtendedDynamicRangeColorComponentValue
    }

    /// Detect the presence of a HDR gain map aux image. Returns whether one
    /// exists so the UI can badge the image as HDR.
    public static func hasHDRGainMap(at url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            src, 0, kCGImageAuxiliaryDataTypeHDRGainMap
        )
        return aux != nil
    }

    // MARK: - Test surface (pure functions)

    /// Apply the sRGB → linear transfer function (piecewise). Used by
    /// `ColorPipelineTests` to verify the normalisation math without
    /// instantiating a Metal device.
    public static func srgbToLinear(_ v: Double) -> Double {
        if v <= 0.04045 { return v / 12.92 }
        return pow((v + 0.055) / 1.055, 2.4)
    }

    /// Convert a tagged-sRGB `(r, g, b)` triplet in 0…1 to the working
    /// color space used by the Metal layer. Pure function: runs a sample
    /// through CoreImage with the same context used by `normalized(_:)`
    /// so tests can assert the blue-tint bug stays fixed.
    ///
    /// Returns `nil` if CoreImage can't satisfy the conversion (e.g. on
    /// CI machines without GPU — in that case the bug is untestable here).
    public static func convertSRGBToWorking(
        r: Double, g: Double, b: Double
    ) -> (r: Double, g: Double, b: Double)? {
        // Build a 1x1 sRGB CGImage with the requested colour.
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bytes: [UInt8] = [
            UInt8(max(0, min(255, (r * 255).rounded()))),
            UInt8(max(0, min(255, (g * 255).rounded()))),
            UInt8(max(0, min(255, (b * 255).rounded()))),
            255,
        ]
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        guard let image = CGImage(
            width: 1, height: 1,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 4, space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        ) else { return nil }

        let converted = normalized(image)
        guard
            let dataProvider = converted.dataProvider,
            let data = dataProvider.data,
            let ptr = CFDataGetBytePtr(data)
        else { return nil }

        // `.RGBAh` packs 4 half-floats (8 bytes). Decode the first pixel.
        let half0 = ptr.withMemoryRebound(to: UInt16.self, capacity: 4) { $0 }
        let r16 = halfAsDouble(half0[0])
        let g16 = halfAsDouble(half0[1])
        let b16 = halfAsDouble(half0[2])
        return (r16, g16, b16)
    }

    /// Decode an IEEE 754 binary16 value to Double. No Float16 dependency so
    /// the helper compiles on the oldest supported toolchain.
    private static func halfAsDouble(_ h: UInt16) -> Double {
        let sign = Double((h >> 15) & 0x1) == 0 ? 1.0 : -1.0
        let exp = Int((h >> 10) & 0x1F)
        let frac = Int(h & 0x3FF)
        switch exp {
        case 0:
            if frac == 0 { return sign * 0.0 }
            return sign * Double(frac) * pow(2.0, -24)
        case 0x1F:
            return frac == 0 ? sign * .infinity : .nan
        default:
            return sign * (1.0 + Double(frac) / 1024.0) * pow(2.0, Double(exp - 15))
        }
    }
}

// CIContext is expensive; share one (Metal-backed if possible).
//
// WHY these specific color spaces: working space must be *linear* to avoid
// compound-gamma errors during scaling / filtering, and output must match
// the Metal layer (extendedLinearDisplayP3). Using `DeviceRGB` for either
// (the old default) bypasses Core Image's colour conversion entirely —
// which is the bug that left sRGB-tagged JPEGs rendering with a blue cast
// on Display-P3 screens.
extension CIContext {
    static let shrikeShared: CIContext = {
        let linearSRGB = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? linearSRGB

        let options: [CIContextOption: Any] = [
            .workingColorSpace: linearSRGB,
            .outputColorSpace: linearP3,
            .workingFormat: CIFormat.RGBAh,
            // Every render here is a one-shot
            // upload. Cached intermediates only kept a CPU copy of each
            // photo (42 MB per 18 MP photo, 600 MB with four windows).
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    /// Colour management OFF (working + output space = none). Used to copy
    /// 8-bit sRGB / Display P3 pixels into an 8-bit texture unchanged; the
    /// fragment shader does the transfer curve and primaries conversion.
    static let shrikeUnmanaged: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()
}

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

public struct ResizeTool: Sendable {

    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    /// Apply `spec` to `image`. Returns the input unchanged when the
    /// request is degenerate (nonpositive dims) or a no-op (target == source).
    public static func apply(_ spec: ResizeSpec, to image: CGImage) -> CGImage {
        guard spec.width > 0, spec.height > 0 else { return image }

        var targetW = spec.width
        var targetH = spec.height

        if spec.preventUpscale {
            targetW = min(targetW, image.width)
            targetH = min(targetH, image.height)
        }

        // No-op fast path.
        if targetW == image.width && targetH == image.height {
            return image
        }

        switch spec.interpolation {
        case .lanczos:
            return resizeLanczos(image, toWidth: targetW, height: targetH) ?? resizeCG(
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

    private static func resizeLanczos(_ image: CGImage, toWidth: Int, height: Int) -> CGImage? {
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
        return ciContext.createCGImage(outCI, from: extent, format: .RGBA8, colorSpace: colorSpace)
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

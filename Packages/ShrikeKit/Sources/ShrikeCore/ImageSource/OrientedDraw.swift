//
//  OrientedDraw.swift
//  ShrikeCore
//
//  Draws stored pixels as display pixels: EXIF orientation (all 8 values)
//  and an optional scale in one `CGContext` draw. Used by the thumbnail
//  fast path (`FileImageSource`) and by `OutputDecoder` (print / copy).
//
//  ShrikeEdit's `ExifOrientation.apply` does the same at scale 1; ShrikeCore
//  can't import ShrikeEdit, so the transform lives here too. The two are
//  pinned to ImageIO's own `WithTransform` output by tests.
//

import Foundation
import CoreGraphics
import ImageIO

enum OrientedDraw {

    /// True for EXIF 5–8: display width = stored height.
    static func swapsDimensions(_ orientation: UInt32) -> Bool {
        orientation >= 5 && orientation <= 8
    }

    /// Display size of a stored `width × height` image.
    static func displaySize(width: Int, height: Int, orientation: UInt32) -> (width: Int, height: Int) {
        swapsDimensions(orientation) ? (height, width) : (width, height)
    }

    /// Draws `image` into a new bitmap of `outWidth × outHeight` display
    /// pixels, applying `orientation`. The stored image is scaled to fill
    /// the output (for 5–8 its width maps onto `outHeight`).
    ///
    /// - Parameters:
    ///   - keepDepth: keep 16-bit / float sources at their depth (output
    ///     decodes); false renders 8-bit (thumbnails).
    ///   - quality: interpolation used when scaling.
    static func render(_ image: CGImage, orientation: UInt32, outWidth: Int, outHeight: Int,
                       keepDepth: Bool, quality: CGInterpolationQuality) -> CGImage? {
        let o = (1...8).contains(orientation) ? orientation : 1
        guard outWidth > 0, outHeight > 0,
              let ctx = makeContext(like: image, width: outWidth, height: outHeight, keepDepth: keepDepth)
        else { return nil }
        ctx.interpolationQuality = quality
        // Stored image drawn at this size (pre-orientation).
        let W = CGFloat(swapsDimensions(o) ? outHeight : outWidth)
        let H = CGFloat(swapsDimensions(o) ? outWidth : outHeight)
        ctx.concatenate(transform(orientation: o, storedWidth: W, storedHeight: H,
                                  outHeight: CGFloat(outHeight)))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage()
    }

    /// CG-space (y-up) transform from the stored frame `W × H` to the
    /// display frame. Built in a y-down frame (row 0 = top, as EXIF
    /// describes it) and flipped at both ends.
    static func transform(orientation: UInt32, storedWidth W: CGFloat, storedHeight H: CGFloat,
                          outHeight: CGFloat) -> CGAffineTransform {
        let m: CGAffineTransform
        switch orientation {
        case 2: m = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case 3: m = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case 4: m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case 5: m = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)      // (x,y)→(y,x)
        case 6: m = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)     // (x,y)→(H−y,x)
        case 7: m = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: H, ty: W)    // (x,y)→(H−y,W−x)
        case 8: m = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)     // (x,y)→(y,W−x)
        default: m = .identity
        }
        let srcFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let dstFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outHeight)
        return srcFlip.concatenating(m).concatenating(dstFlip)
    }

    /// A bitmap context in the image's own colour space when CoreGraphics
    /// can render into it (RGB, gray without alpha, CMYK), else sRGB.
    static func makeContext(like image: CGImage, width: Int, height: Int, keepDepth: Bool) -> CGContext? {
        let isFloat = keepDepth && image.bitmapInfo.contains(.floatComponents)
        let bpc = isFloat ? 32 : (keepDepth && image.bitsPerComponent > 8 ? 16 : 8)
        let depthBits: UInt32 = isFloat
            ? CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            : (bpc == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let hasAlpha: Bool = {
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }()
        if let cs = image.colorSpace {
            var info: UInt32?
            switch cs.model {
            case .rgb:
                info = (hasAlpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                 : CGImageAlphaInfo.noneSkipLast.rawValue) | depthBits
            case .monochrome where !hasAlpha:
                info = CGImageAlphaInfo.none.rawValue | depthBits
            case .cmyk where !hasAlpha && !isFloat:
                info = CGImageAlphaInfo.none.rawValue | depthBits
            default:
                info = nil
            }
            if let info, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                                             bytesPerRow: 0, space: cs, bitmapInfo: info) {
                return ctx
            }
        }
        // Colour space a bitmap context rejects (indexed, Lab, gray+alpha).
        let fallback = CGColorSpace(name: isFloat ? CGColorSpace.extendedSRGB : CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                         bytesPerRow: 0, space: fallback,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | depthBits)
    }
}

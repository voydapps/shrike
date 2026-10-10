//
//  OrientedImageFixtures.swift
//  ShrikeCoreTests
//
//  Generated images with an EXIF orientation tag, and pixel sampling.
//  The stored pattern has four coloured quadrants (y-down: top-left red,
//  top-right green, bottom-left blue, bottom-right white) so every one of
//  the 8 orientations lands them in a different place.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum OrientedImageFixtures {

    struct RGB: Equatable, CustomStringConvertible {
        var r: Int, g: Int, b: Int
        var description: String { "(\(r),\(g),\(b))" }
        func distance(to o: RGB) -> Int { max(abs(r - o.r), abs(g - o.g), abs(b - o.b)) }
    }

    /// Stored-frame quadrant image, `width × height`.
    static func quadrants(width: Int, height: Int,
                          space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitsPerComponent: Int = 8) -> CGImage {
        let info = bitsPerComponent == 16
            ? CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bitsPerComponent,
                            bytesPerRow: 0, space: space, bitmapInfo: info)!
        let w = CGFloat(width), h = CGFloat(height)
        // CG is y-up: the top half is y ∈ [h/2, h].
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) {
            ctx.setFillColor(CGColor(colorSpace: space, components: [r, g, b, 1])!)
            ctx.fill(rect)
        }
        fill(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))      // top-left
        fill(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))  // top-right
        fill(0, 0, 1, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))          // bottom-left
        fill(1, 1, 1, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))      // bottom-right
        return ctx.makeImage()!
    }

    /// Writes `image` to `url` as `type` with an EXIF orientation tag.
    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, orientation: UInt32 = 1) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// ImageIO's own oriented rendering (`WithTransform`), the reference.
    static func imageIOOriented(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    /// sRGB 8-bit pixels of `image`, y-down (row 0 = top).
    static func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (data, w, h)
    }

    /// Colour at fractional position (fx, fy) in [0, 1], y-down.
    static func sample(_ image: CGImage, _ fx: Double, _ fy: Double) -> RGB {
        let p = pixels(image)
        let x = min(p.width - 1, Int(fx * Double(p.width)))
        let y = min(p.height - 1, Int(fy * Double(p.height)))
        let i = (y * p.width + x) * 4
        return RGB(r: Int(p.data[i]), g: Int(p.data[i + 1]), b: Int(p.data[i + 2]))
    }

    /// Mean absolute difference per channel (0…255) between two images of
    /// the same size.
    static func meanAbsDiff(_ a: CGImage, _ b: CGImage) -> Double {
        let pa = pixels(a), pb = pixels(b)
        precondition(pa.width == pb.width && pa.height == pb.height)
        var sum = 0
        for i in 0..<pa.data.count where i % 4 != 3 {
            sum += abs(Int(pa.data[i]) - Int(pb.data[i]))
        }
        return Double(sum) / Double(pa.width * pa.height * 3)
    }
}

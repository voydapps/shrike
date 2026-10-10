//
//  Orientation.swift
//  ShrikeEdit
//
//  EXIF orientation as an element of the dihedral group D4, plus the
//  pixel transform that turns stored pixels into display pixels.
//
//  Two users:
//    * `ImageExporter` decodes the stored pixels, then calls
//      `ExifOrientation.apply(_:to:)` so the recipe replays in the same
//      (display) coordinate space the viewer and edit mode show. The
//      viewer decodes with `kCGImageSourceCreateThumbnailWithTransform`,
//      which is the same mapping.
//    * `LosslessRotator` composes the file's current orientation with
//      a user op (rotate ±90/180, flip H/V) and rewrites only the tag.
//
//  Model: every orientation is `R^r · F^f` — first an optional horizontal
//  mirror `F` of the stored pixels, then `r` clockwise quarter turns `R`.
//  The group relation `F·R = R⁻¹·F` gives the composition table below.
//
//      EXIF  (f, r)   meaning (stored → display)
//      1     (0, 0)   identity
//      2     (1, 0)   mirror horizontal
//      3     (0, 2)   rotate 180
//      4     (1, 2)   mirror vertical      (= mirror H, then 180)
//      5     (1, 3)   transpose            (= mirror H, then 270 CW)
//      6     (0, 1)   rotate 90 CW
//      7     (1, 1)   transverse           (= mirror H, then 90 CW)
//      8     (0, 3)   rotate 270 CW
//
//  A user op `U` applied to the *displayed* image gives `T' = U · T`:
//      rotate q CW : (f, r) → (f, r + q)
//      flip H      : (f, r) → (¬f, −r)
//      flip V      : (f, r) → (¬f, 2 − r)
//

import CoreGraphics
import Foundation
import ImageIO

/// EXIF / TIFF orientation tag value (1…8).
public enum ExifOrientation: UInt32, Sendable, CaseIterable, Codable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    /// Reads the orientation from an ImageIO property dictionary (top-level
    /// `kCGImagePropertyOrientation`, falling back to the TIFF dictionary).
    /// Missing or out-of-range values mean `.up` (what ImageIO displays).
    public init(properties: [CFString: Any]?) {
        let raw: UInt32? =
            (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
            ?? ((properties?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[
                kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value
        self = raw.flatMap(ExifOrientation.init(rawValue:)) ?? .up
    }

    /// Mirror flag and clockwise quarter turns — see file header.
    public var components: (mirrored: Bool, quarters: Int) {
        switch self {
        case .up:            return (false, 0)
        case .upMirrored:    return (true, 0)
        case .down:          return (false, 2)
        case .downMirrored:  return (true, 2)
        case .leftMirrored:  return (true, 3)
        case .right:         return (false, 1)
        case .rightMirrored: return (true, 1)
        case .left:          return (false, 3)
        }
    }

    public init(mirrored: Bool, quarters: Int) {
        let q = ((quarters % 4) + 4) % 4
        switch (mirrored, q) {
        case (false, 0): self = .up
        case (true, 0):  self = .upMirrored
        case (false, 2): self = .down
        case (true, 2):  self = .downMirrored
        case (true, 3):  self = .leftMirrored
        case (false, 1): self = .right
        case (true, 1):  self = .rightMirrored
        default:         self = .left      // (false, 3)
        }
    }

    /// True when display width/height are the stored height/width.
    public var swapsDimensions: Bool { components.quarters % 2 == 1 }

    /// Orientation after the user rotates the displayed image `quarters`
    /// clockwise quarter turns (negative = counter-clockwise).
    public func rotated(quarters: Int) -> ExifOrientation {
        let c = components
        return ExifOrientation(mirrored: c.mirrored, quarters: c.quarters + quarters)
    }

    /// Orientation after the user mirrors the displayed image left↔right.
    public func flippedHorizontally() -> ExifOrientation {
        let c = components
        return ExifOrientation(mirrored: !c.mirrored, quarters: -c.quarters)
    }

    /// Orientation after the user mirrors the displayed image top↔bottom.
    public func flippedVertically() -> ExifOrientation {
        let c = components
        return ExifOrientation(mirrored: !c.mirrored, quarters: 2 - c.quarters)
    }

    /// Apply a user-level op to this orientation.
    public func applying(_ op: OrientationOp) -> ExifOrientation {
        switch op {
        case .rotate(let q):   return rotated(quarters: q)
        case .flipHorizontal:  return flippedHorizontally()
        case .flipVertical:    return flippedVertically()
        }
    }

    // MARK: - Pixels

    /// Turn stored pixels into display pixels. Returns `image` unchanged
    /// for `.up`. The result keeps the source colour space; 16-bit and
    /// float sources keep their depth so HDR/wide-gamut TIFFs survive.
    public static func apply(_ orientation: ExifOrientation, to image: CGImage) -> CGImage {
        guard orientation != .up else { return image }
        let w = image.width
        let h = image.height
        let outW = orientation.swapsDimensions ? h : w
        let outH = orientation.swapsDimensions ? w : h

        guard let ctx = makeContext(like: image, width: outW, height: outH) else {
            return image
        }
        ctx.interpolationQuality = .none

        // CGContext is y-up. Build the transform in a y-down pixel frame
        // (row 0 = top, same as EXIF), then flip into CG space.
        //   display(x', y') = M · stored(x, y), both y-down.
        let W = CGFloat(w), H = CGFloat(h)
        var m: CGAffineTransform
        switch orientation {
        case .up:            m = .identity
        case .upMirrored:    m = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0)
        case .down:          m = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        case .downMirrored:  m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        case .leftMirrored:  m = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)      // (x,y)→(y,x)
        case .right:         m = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)     // (x,y)→(H−y,x)
        case .rightMirrored: m = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: H, ty: W)    // (x,y)→(H−y,W−x)
        case .left:          m = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)     // (x,y)→(y,W−x)
        }
        // y-down ↔ y-up conversions for the source and destination frames.
        let srcFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let dstFlip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(outH))
        // CG-space stored → y-down stored → y-down display → CG-space display.
        let full = srcFlip.concatenating(m).concatenating(dstFlip)
        ctx.concatenate(full)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
        return ctx.makeImage() ?? image
    }

    private static func makeContext(like image: CGImage, width: Int, height: Int) -> CGContext? {
        let space: CGColorSpace
        if let cs = image.colorSpace, cs.model == .rgb || cs.model == .monochrome {
            space = cs
        } else {
            space = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        let bpc: Int
        var info: UInt32
        if isFloat {
            bpc = 32
            info = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        } else if image.bitsPerComponent > 8 {
            bpc = 16
            info = CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue
        } else {
            bpc = 8
            info = CGImageAlphaInfo.premultipliedLast.rawValue
        }
        if space.model == .monochrome {
            info = isFloat
                ? (CGImageAlphaInfo.none.rawValue | CGBitmapInfo.floatComponents.rawValue
                   | CGBitmapInfo.byteOrder32Little.rawValue)
                : (bpc == 16
                   ? (CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
                   : CGImageAlphaInfo.none.rawValue)
        }
        if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc,
                               bytesPerRow: 0, space: space, bitmapInfo: info) {
            return ctx
        }
        // Colour space the bitmap context rejects — fall back to sRGB 8-bit.
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// A user-level orientation change on the displayed image.
public enum OrientationOp: Sendable, Equatable, Hashable {
    /// Clockwise quarter turns; negative = counter-clockwise.
    case rotate(quarters: Int)
    case flipHorizontal
    case flipVertical
}

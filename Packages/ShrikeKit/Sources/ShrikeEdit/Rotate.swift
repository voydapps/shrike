//
//  Rotate.swift
//  ShrikeEdit
//
//  Recipe-path rotation: `.rotate(degrees:)` (free rotate, ±45°) and
//  `.rotate90(quarters:)` (snapped).
//
//  The *lossless* file rotate (it rewrites only the orientation tag, so
//  there is no decode/re-encode quality loss) is separate and lives in
//  `LosslessRotator.swift`. This file implements only the
//  recipe-applicable pixel transform.
//

import CoreGraphics
import CoreImage
import Foundation

/// Stateless rotation helpers.
public struct RotateTool: Sendable {

    /// Cached `CIContext` keyed off a shared accessor. `CIContext` is
    /// expensive to construct; sharing one per process is cheap and
    /// thread-safe (Apple docs). `CIContext` is `Sendable` under Swift 6
    /// so no isolation annotation is needed.
    private static let ciContext: CIContext = {
        // Software context — no GPU wake-up for the single in-memory
        // rotate. The edit pipeline uses CIContext elsewhere too
        // (ColorAdjust); keep one instance.
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    // MARK: 90° quarter turns

    /// Apply a quarter-turn rotation.
    /// `quarters` is normalised mod 4: `+1` = CW 90°, `+2` = 180°,
    /// `-1` / `+3` = CCW 90°. `0` returns the input unchanged.
    public static func apply90(quarters: Int, to image: CGImage) -> CGImage {
        let q = ((quarters % 4) + 4) % 4
        switch q {
        case 0:
            return image
        case 1:
            return rotated(image, radians: -.pi / 2)
        case 2:
            return rotated(image, radians: .pi)
        case 3:
            return rotated(image, radians: .pi / 2)
        default:
            return image
        }
    }

    // MARK: Free rotate

    /// Apply a free-rotate by `degrees`. When `autocrop` is true, the
    /// rotated image is trimmed to the largest axis-aligned rectangle
    /// fully inside the rotated bounds — this is the default because
    /// the blank corners otherwise look broken.
    ///
    /// The UI slider is limited to ±45°, but this function
    /// accepts any angle. It normalises into `-180…180` first so a
    /// drag-around slider can't produce degenerate rotations.
    public static func apply(degrees: Double, to image: CGImage, autocrop: Bool) -> CGImage {
        let normalised = degrees.truncatingRemainder(dividingBy: 360)
        let wrapped: Double
        if normalised > 180 {
            wrapped = normalised - 360
        } else if normalised < -180 {
            wrapped = normalised + 360
        } else {
            wrapped = normalised
        }

        // Zero-degree fast path — preserves byte identity for the no-op
        // case that the recipe's coalescer can produce at slider origin.
        if abs(wrapped) < 1e-6 {
            return image
        }

        let radians = -wrapped * .pi / 180.0   // CG coordinate system
        let rotated = rotated(image, radians: radians)
        guard autocrop else { return rotated }
        return autocropLargestInscribed(
            rotated,
            originalWidth: Double(image.width),
            originalHeight: Double(image.height),
            degrees: wrapped
        )
    }

    // MARK: - Internal

    /// Produce a new `CGImage` of the source rotated by `radians`,
    /// expanded to the rotated bounding box (corners exposed). Uses
    /// `CoreImage.CIAffineTransform` via the shared `CIContext`.
    private static func rotated(_ image: CGImage, radians: Double) -> CGImage {
        let ci = CIImage(cgImage: image)
        let transform = CGAffineTransform(rotationAngle: CGFloat(radians))
        let rotatedCI = ci.transformed(by: transform)
        let extent = rotatedCI.extent
        guard extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite
        else {
            return image
        }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        if let out = ciContext.createCGImage(rotatedCI, from: extent, format: .RGBA8, colorSpace: colorSpace) {
            return out
        }
        // Fallback: bitmap context rotate. Used only when CIContext
        // fails (unusual but possible with exotic colour spaces).
        return cgRotateFallback(image, radians: radians) ?? image
    }

    private static func cgRotateFallback(_ image: CGImage, radians: Double) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let rotatedBounds = CGRect(x: 0, y: 0, width: w, height: h)
            .applying(CGAffineTransform(rotationAngle: CGFloat(radians)))
        let bw = Int(ceil(abs(rotatedBounds.width)))
        let bh = Int(ceil(abs(rotatedBounds.height)))
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: bw,
            height: bh,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(bw) / 2, y: CGFloat(bh) / 2)
        ctx.rotate(by: CGFloat(radians))
        ctx.translateBy(x: -w / 2, y: -h / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Crop a rotated bitmap down to the largest axis-aligned rectangle
    /// that's entirely inside the original (pre-rotation) image's
    /// rotated footprint. Standard formula from the image-processing
    /// literature; see e.g. stackoverflow.com/a/16778797.
    private static func autocropLargestInscribed(
        _ rotated: CGImage,
        originalWidth w: Double,
        originalHeight h: Double,
        degrees: Double
    ) -> CGImage {
        let theta = abs(degrees) * .pi / 180.0
        guard theta > 1e-6 else { return rotated }

        let cosA = abs(cos(theta))
        let sinA = abs(sin(theta))

        let longer  = max(w, h)
        let shorter = min(w, h)

        // The "largest rectangle inscribed in a rotated rectangle"
        // formula has two regimes depending on aspect ratio & angle.
        let bboxW: Double
        let bboxH: Double

        if shorter <= 2 * sinA * cosA * longer || abs(cosA - sinA) < 1e-9 {
            // Half-diagonal case.
            let x = 0.5 * shorter
            if w >= h {
                bboxW = x / sinA
                bboxH = x / cosA
            } else {
                bboxW = x / cosA
                bboxH = x / sinA
            }
        } else {
            let cos2 = cosA * cosA - sinA * sinA
            bboxW = (w * cosA - h * sinA) / cos2
            bboxH = (h * cosA - w * sinA) / cos2
        }

        guard bboxW > 1, bboxH > 1 else { return rotated }

        let rw = Double(rotated.width)
        let rh = Double(rotated.height)
        let cx = rw / 2
        let cy = rh / 2
        let x = max(0.0, cx - bboxW / 2)
        let y = max(0.0, cy - bboxH / 2)
        let cw = min(rw - x, bboxW)
        let ch = min(rh - y, bboxH)

        let rect = CGRect(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: max(1, Int(cw.rounded())),
            height: max(1, Int(ch.rounded()))
        )
        return rotated.cropping(to: rect) ?? rotated
    }
}

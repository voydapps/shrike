//
//  Crop.swift
//  ShrikeEdit
//
//  Pure crop transform.
//  The tool operates on `CGImage` in-memory. On-canvas overlay / aspect
//  presets live in ShrikeUI — this file is the recipe-applicable piece:
//  given a `CropRect` (normalised 0…1), produce the cropped `CGImage`.
//

import CoreGraphics

/// Stateless crop helpers.
public struct CropTool: Sendable {

    /// Convert a pixel-space rect into a normalised `CropRect`.
    ///
    /// `imageSize` is the pixel size of the image the rect refers to.
    /// Returned `CropRect` uses the same top-left convention as UI code
    /// (`rect.origin.y` is the distance from the top edge).
    public static func normalise(rect: CGRect, in imageSize: CGSize) -> CropRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return .full
        }
        let normalised = CropRect(
            originX: Double(rect.origin.x) / Double(imageSize.width),
            originY: Double(rect.origin.y) / Double(imageSize.height),
            width:   Double(rect.size.width)  / Double(imageSize.width),
            height:  Double(rect.size.height) / Double(imageSize.height)
        )
        return normalised.isValid ? normalised : .full
    }

    /// Apply `crop` to `image`. Returns the input unchanged when the
    /// crop is identity, degenerate, or invalid — the renderer treats
    /// an invalid crop as a no-op rather than throwing.
    public static func apply(_ crop: CropRect, to image: CGImage) -> CGImage {
        guard crop.isValid else { return image }

        // Treat rects that round to "full image" as identity — avoids a
        // needless allocation for the common "no crop applied" case.
        if crop.originX <= 1e-9,
           crop.originY <= 1e-9,
           crop.width >= 1 - 1e-9,
           crop.height >= 1 - 1e-9
        {
            return image
        }

        let w = Double(image.width)
        let h = Double(image.height)

        // Round to integer pixel bounds after clamping into the image.
        // `CGImage.cropping(to:)` tolerates floating rects but integer
        // snapping matches what the UI overlay displays.
        var x = Int((crop.originX * w).rounded())
        var y = Int((crop.originY * h).rounded())
        var cw = Int((crop.width  * w).rounded())
        var ch = Int((crop.height * h).rounded())

        x = max(0, min(x, image.width - 1))
        y = max(0, min(y, image.height - 1))
        cw = max(1, min(cw, image.width - x))
        ch = max(1, min(ch, image.height - y))

        let pixelRect = CGRect(x: x, y: y, width: cw, height: ch)
        return image.cropping(to: pixelRect) ?? image
    }
}

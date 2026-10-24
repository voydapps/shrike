//
//  ColorAdjust.swift
//  ShrikeEdit
//
//  Brightness / contrast / saturation / hue transform.
//
//  Filter chain: `CIColorControls` (brightness, contrast, saturation), then
//  `CIHueAdjust` (hue). Each filter is skipped when its own inputs are at
//  identity, so a hue-only edit never passes through CIColorControls. The
//  seven other reserved sliders on `ColorAdjustParams` (exposure,
//  temperature, tint, shadows, highlights, whites, blacks) are not built
//  and read as identity.
//
//  Every render path uses this one function through `EditRenderer`: the
//  live preview (`.draft`), Save / Save As / Export, batch and the recipe
//  replay.
//
//  Parameter ranges (spec):
//    brightness  -1.0 … +1.0    0 = identity
//    contrast    -1.0 … +1.0    0 = identity
//    saturation  -1.0 … +1.0    0 = identity
//    hue         -180 … +180    degrees, 0 (or nil) = identity
//
//  Mapping to CIColorControls (whose natural range is
//  brightness -1…1 [identity 0], contrast 0…2 [identity 1], saturation
//  0…2 [identity 1]): pass brightness through as-is; map `contrast` and
//  `saturation` as `1 + value` so the user-facing 0 is identity. Hue maps
//  to `CIHueAdjust.inputAngle` in radians.
//

import CoreGraphics
import CoreImage
import Foundation

public struct ColorAdjustTool: Sendable {

    /// Hue slider range, in degrees.
    public static let hueRange: ClosedRange<Double> = -180...180

    private static let ciContext: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }()

    /// Apply `params` to `image`. Returns the input unchanged when
    /// `params.isIdentity`.
    public static func apply(_ params: ColorAdjustParams, to input: CGImage) -> CGImage {
        if params.isIdentity { return input }
        // CMYK and grayscale can't be rendered RGBA8 (the tool used to hand
        // the input back unchanged): work in sRGB.
        let image = EditColorSpace.workingRGB(input, keepGray: false)
        var ci = CIImage(cgImage: image)

        if params.brightness != 0 || params.contrast != 0 || params.saturation != 0 {
            guard let filter = CIFilter(name: "CIColorControls") else { return input }
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(params.brightness,           forKey: kCIInputBrightnessKey)
            filter.setValue(1.0 + params.contrast,       forKey: kCIInputContrastKey)
            filter.setValue(1.0 + params.saturation,     forKey: kCIInputSaturationKey)
            guard let out = filter.outputImage else { return input }
            ci = out
        }

        let hue = min(max(params.hue ?? 0, hueRange.lowerBound), hueRange.upperBound)
        if hue != 0 {
            guard let filter = CIFilter(name: "CIHueAdjust") else { return input }
            filter.setValue(ci, forKey: kCIInputImageKey)
            filter.setValue(hue * .pi / 180, forKey: kCIInputAngleKey)
            guard let out = filter.outputImage else { return input }
            ci = out
        }

        let extent = ci.extent.isInfinite
            ? CGRect(x: 0, y: 0, width: image.width, height: image.height)
            : ci.extent

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(ci, from: extent, format: .RGBA8, colorSpace: colorSpace)
            ?? input
    }
}

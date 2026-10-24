//
//  EditColorSpace.swift
//  ShrikeEdit
//
//  The edit tools render 8-bit RGBA. CMYK (and other non-RGB) photos can't
//  be rendered that way, and grayscale can't go through Core Image's colour
//  filters, so each tool used to hand back its input unchanged while the
//  save said "Saved" (audit COR-1 / COR-2). Tools call `workingRGB` first,
//  as `LevelsTool` always did, so the edit really happens. Converting is a
//  change of file format, so `ImageExporter.capability` tells the user.
//

import CoreGraphics
import Foundation

enum EditColorSpace {

    /// `image` itself when it is RGB (or grayscale and `keepGray`), else an
    /// 8-bit sRGB copy. Returns `image` when the copy can't be made; the
    /// caller's output check then reports the failure.
    static func workingRGB(_ image: CGImage, keepGray: Bool) -> CGImage {
        guard let model = image.colorSpace?.model else { return image }
        if model == .rgb { return image }
        if model == .monochrome && keepGray { return image }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return image }
        let alpha: CGImageAlphaInfo
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = .noneSkipLast
        default: alpha = .premultipliedLast
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: alpha.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }
}

//
//  WindowTitles.swift
//  ShrikeUI
//
//  Window titles and subtitles.
//
//  * Viewer: title = file name of the displayed primary, subtitle
//    "43 of 180 · 6000 × 4000".
//  * Browser: title = folder name, subtitle "252 images", or
//    "47 of 252 images" when a filter hides some.
//

import Foundation
import ImageIO

public enum WindowTitles {

    /// "43 of 180 · 6000 × 4000". `index` is zero-based. The size part is
    /// left out until the header has been read.
    public static func viewerSubtitle(index: Int, total: Int, pixelSize: CGSize?) -> String {
        // "43 of 180 · 6000 × 4000"; one item shows
        // only the size; an unknown size shows only the position.
        guard total > 0 else { return "No images" }
        let position = "\(index + 1) of \(total)"
        guard let size = pixelSize, size.width > 0, size.height > 0 else { return position }
        let pixels = "\(Int(size.width)) × \(Int(size.height))"
        return total == 1 ? pixels : "\(position) · \(pixels)"
    }

    /// "252 images", "1 image", or "47 of 252 images" when filtered.
    public static func browserSubtitle(visible: Int, total: Int) -> String {
        let noun = total == 1 ? "image" : "images"
        if visible == total { return "\(total) \(noun)" }
        return "\(visible) of \(total) \(noun)"
    }

    /// Pixel size from the file header, orientation applied (no decode).
    /// Call off the main actor.
    public static func headerPixelSize(of url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        // Orientations 5–8 swap width and height.
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }
}

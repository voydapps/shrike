//
//  EditSourceLoader.swift
//  ShrikeUI
//
//  The full-resolution, upright image edit mode works on.
//  The viewer's texture may be a preview or a subsampled display
//  decode; edit mode needs every pixel, in oriented display space.
//

import Foundation
import ImageIO
import CoreGraphics

enum EditSourceLoader {

    /// Decodes `url` at full size with EXIF orientation applied. Runs
    /// off the main actor. nil when the file can't be decoded.
    static func fullImage(at url: URL) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

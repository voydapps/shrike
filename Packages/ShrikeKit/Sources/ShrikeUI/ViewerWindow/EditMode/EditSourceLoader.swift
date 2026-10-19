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

import ShrikeCore

struct LoadedEditImage: Sendable {
    let image: CGImage
    let lease: ImageResourceLease
}

extension EditSourceLoader {
    /// Admission happens before a full-size edit decode; the lease follows
    /// the returned pixels into the session rather than ending at await.
    static func loadForEditing(at url: URL, resources: ImageResourceBudget, owner: ImageResourceOwner) async throws -> LoadedEditImage? {
        let estimate = try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { throw ImageResourceError.invalidByteCount }
            return try ImageWorkingSetEstimate(width: w, height: h, bitsPerComponent: props[kCGImagePropertyDepth] as? Int ?? 8).totalBytes
        }.value
        let reservation = try await resources.reserve(bytes: estimate, owner: owner, category: .editOriginal, priority: .visible, policy: .oneOversizedOperation)
        defer { reservation.release() }
        try Task.checkCancellation()
        let decode = Task.detached(priority: .userInitiated) { fullImage(at: url) }
        let image = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
        try Task.checkCancellation()
        return image.map { LoadedEditImage(image: $0, lease: resources.retain(image: $0, owner: owner, category: .editOriginal)) }
    }
}

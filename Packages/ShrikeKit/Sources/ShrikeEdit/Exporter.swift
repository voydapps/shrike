//
//  Exporter.swift
//  ShrikeEdit
//
//  Save / Save As pipeline.
//  Three responsibilities:
//    1. Bake the recipe against the original source into a `CGImage`.
//    2. Encode to the requested `ExportFormat` with EXIF + ICC preserved
//       (orientation forcibly rewritten to 1 because rotations are baked
//       into the pixel data).
//    3. Write atomically: temp file in the same directory + `replaceItemAt`,
//       so a crash / IO failure leaves the original intact.
//
//  RAW redirect: if the destination URL points at a RAW format we can't
//  write, the caller should have already redirected to `<stem>-edited.jpg`;
//  the exporter refuses RAW writes (ImageDestinationError.unwritableFormat).
//  The `-edited` suffix itself is exposed as
//  `ImageExporter.rawRedirectSuffix` so it can become a preference
//  without touching callers.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeIO

public struct ImageExportResourceContext: Sendable {
    public let resources: ImageResourceBudget
    public let owner: ImageResourceOwner
    public let reservation: ImageWorkReservation
    public init(resources: ImageResourceBudget, owner: ImageResourceOwner, reservation: ImageWorkReservation) {
        self.resources = resources; self.owner = owner; self.reservation = reservation
    }
}

public enum ExportFormat: String, Sendable, Codable, CaseIterable {
    case jpeg, png, tiff, heic
    /// WebP / AVIF: only usable when the running OS ships an encoder —
    /// check `isEncodable` (ImageIO had no WebP encoder as of macOS 26).
    case webp, avif

    /// UTType for the CGImageDestination.
    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png:  return .png
        case .tiff: return .tiff
        case .heic: return .heic
        case .webp: return .webP
        case .avif: return UTType("public.avif") ?? UTType(filenameExtension: "avif") ?? .image
        }
    }

    /// File extension (no dot) for the format.
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png:  return "png"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .webp: return "webp"
        case .avif: return "avif"
        }
    }

    /// True when the format carries a user-visible quality slider.
    public var usesQuality: Bool {
        switch self {
        case .jpeg, .heic, .webp, .avif: return true
        case .png, .tiff:                return false
        }
    }

}

public enum ExportError: Error, Sendable, Equatable {
    case sourceMissing
    case sourceUnreadable
    case recipeApplyFailed
    case destinationCreateFailed
    case destinationFinalizeFailed
    case unwritableFormat
    /// Refused to overwrite `source` in place: its format can't be written
    /// back safely (RAW, GIF, PSD, multi-frame, format/extension mismatch…).
    /// See `ExportFormat.inPlaceFormat(for:)`. The UI must use Save As.
    case inPlaceWriteNotAllowed
    /// The destination's extension doesn't match the bytes we'd write
    /// (e.g. JPEG bytes into `photo.gif`).
    case extensionMismatch
    /// The pre-overwrite backup failed, so the overwrite was not attempted.
    case backupFailed(underlying: String)
    case atomicReplaceFailed(underlying: String)
    case ioFailure(underlying: String)
}

extension ExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceMissing: return "The source file is no longer available."
        case .sourceUnreadable: return "Shrike could not decode the source image."
        case .recipeApplyFailed: return "The requested edits could not be rendered."
        case .destinationCreateFailed, .destinationFinalizeFailed: return "The output image could not be fully encoded and validated. The previous destination was kept."
        case .unwritableFormat: return "This image format cannot be written on this Mac."
        case .inPlaceWriteNotAllowed: return "Save an edited copy to keep the original format, frames and precision safe."
        case .extensionMismatch: return "The output filename extension does not match the selected image format."
        case .backupFailed(let reason): return "The previous destination could not be backed up; nothing was overwritten. \(reason)"
        case .atomicReplaceFailed(let reason), .ioFailure(let reason): return "The output could not be committed. \(reason)"
        }
    }
}

/// Baking + encoding pipeline for the edit save path.
public actor ImageExporter {
    public enum Checkpoint: Sendable, Equatable { case decoded, rendered, encoded, beforeBackup, beforeCommit }

    /// Suffix appended to the stem when the save path redirects a RAW
    /// source to a sibling JPEG. Exposed as a `public
    /// static let` so it can become a preference without breaking
    /// call sites.
    public static let rawRedirectSuffix: String = "-edited"

    /// Default JPEG + HEIC quality when the caller doesn't pass one.
    /// Matches `Prefs.editJPEGQualityDefault` / `editHEICQualityDefault`.
    public static let defaultQuality: Double = 0.92

    /// Where originals go before an overwrite. `nil` disables backups —
    /// tests only; app code must keep the default.
    private let backupStore: BackupStore?
    /// When set, ratings / flags / tags follow the save: re-stamped on an
    /// in-place overwrite, copied onto a Save-As file.
    private let metadataStore: MetadataStore?
    private let checkpoint: (@Sendable (Checkpoint) async throws -> Void)?
    private let resources: ImageResourceBudget
    private let resourceOwner: ImageResourceOwner

    public init(backupStore: BackupStore? = BackupStore.shared,
                metadataStore: MetadataStore? = nil,
                checkpoint: (@Sendable (Checkpoint) async throws -> Void)? = nil,
                resources: ImageResourceBudget = .shared, resourceOwner: ImageResourceOwner = .init()) {
        self.backupStore = backupStore
        self.metadataStore = metadataStore
        self.checkpoint = checkpoint
        self.resources = resources; self.resourceOwner = resourceOwner
    }

    /// Bake `recipe` against the `CGImage` read from `from` and write
    /// the result to `to` in `format`. EXIF, ICC, and (optionally) GPS
    /// are preserved; orientation is rewritten to 1 because any recipe
    /// rotation has been baked into pixels.
    ///
    /// Writes are atomic: the bytes land in a temp file in the same
    /// directory, then `FileManager.replaceItemAt` swaps them over the
    /// destination. A crash or I/O failure mid-write leaves the original
    /// (if any) intact.
    ///
    /// Before an existing file at `destination` is replaced, it is copied
    /// into the `BackupStore` (reason `.save`). If that copy fails nothing
    /// is overwritten (`ExportError.backupFailed`). Returns the backup
    /// record, or `nil` when no file was replaced.
    @discardableResult
    public func export(
        recipe: EditRecipe,
        from source: URL,
        to destination: URL,
        format: ExportFormat,
        quality: Double = ImageExporter.defaultQuality,
        preserveEXIF: Bool = true,
        stripGPS: Bool = false,
        backupReason: BackupReason = .save,
        resourceContext: ImageExportResourceContext? = nil,
        resourceCategory: ImageResourceCategory = .exportWork
    ) async throws -> BackupRecord? {
        try Task.checkCancellation()
        // 1. Read the source.
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.sourceMissing
        }

        // 0. Refuse writes that would damage or mislabel a file.
        //    Defence in depth: the UI is supposed to route these to
        //    Save As already, via `ExportFormat.inPlaceFormat(for:)`.
        try Self.validateDestination(source: source, destination: destination, format: format)
        let operations = await recipe.snapshot()
        if FileIdentity.sameFile(source, destination),
           Self.capability(for: source, operations: operations, format: format).requiresCopy {
            throw ExportError.inPlaceWriteNotAllowed
        }
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ExportError.sourceUnreadable
        }
        let sourceProperties =
            CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
        guard let width = sourceProperties?[kCGImagePropertyPixelWidth] as? Int,
              let height = sourceProperties?[kCGImagePropertyPixelHeight] as? Int else { throw ExportError.sourceUnreadable }
        let outputSize = try Self.outputBounds(width: width, height: height, operations: operations)
        let estimate = try ImageWorkingSetEstimate(width: width, height: height,
            bitsPerComponent: sourceProperties?[kCGImagePropertyDepth] as? Int ?? 8,
            floatingPoint: sourceProperties?[kCGImagePropertyIsFloat] as? Bool ?? false,
            outputWidth: outputSize.0, outputHeight: outputSize.1)
        let reservation: ImageWorkReservation
        if let resourceContext { reservation = resourceContext.reservation }
        else {
            reservation = try await resources.reserve(bytes: estimate.totalBytes, owner: resourceOwner,
                category: resourceCategory, priority: resourceCategory == .batchWork ? .batch : .visible,
                policy: .oneOversizedOperation)
        }
        // Non-interruptible work owns this token until the real lane
        // closure ends, even if its async caller has been cancelled.
        defer { withExtendedLifetime(reservation) {} }
        let storedImage = try await DecodeLane.shared.run {
            try withExtendedLifetime(reservation) {
                guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(src, 0,
                        [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else { throw ExportError.sourceUnreadable }
                return image
            }
        }
        try await check(.decoded)

        // The recipe (crop rect, rotations) was built on screen against
        // the *displayed* image, which the viewer decodes with the EXIF
        // transform applied. `CGImageSourceCreateImageAtIndex` returns the
        // stored (unrotated) pixels, so turn them into display pixels
        // before replaying. Orientation 1 is written on the way out.
        let originalImage = Self.displayOrientedImage(
            storedImage, properties: sourceProperties
        )

        // 2. Replay the recipe. `renderFinal` is the non-dropping variant
        // — we want a result, not a "maybe dropped" CGImage.
        let renderer = EditRenderer()
        let finalImage = await renderer.renderFinal(recipe: recipe, from: originalImage)
        try await check(.rendered)
        if FileIdentity.sameFile(source, destination), storedImage.bitsPerComponent > finalImage.bitsPerComponent {
            throw ExportError.inPlaceWriteNotAllowed
        }

        // 3. Encode to a temp file.
        let tmpURL = temporaryURL(sameDirectoryAs: destination, format: format)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try writeEncoded(
            image: finalImage,
            to: tmpURL,
            format: format,
            quality: quality,
            sourceProperties: sourceProperties,
            preserveEXIF: preserveEXIF,
            stripGPS: stripGPS
        )
        guard let validated = CGImageSourceCreateWithURL(tmpURL as CFURL, nil),
              CGImageSourceGetCount(validated) == 1,
              let dimensions = CGImageSourceCopyPropertiesAtIndex(validated, 0, nil) as? [CFString: Any],
              dimensions[kCGImagePropertyPixelWidth] as? Int == finalImage.width,
              dimensions[kCGImagePropertyPixelHeight] as? Int == finalImage.height
        else { throw ExportError.destinationFinalizeFailed }
        try await check(.encoded)

        // 4. Back up whatever we are about to replace. No backup, no
        // overwrite.
        let replacing = FileManager.default.fileExists(atPath: destination.path)
        var record: BackupRecord?
        if replacing, let backupStore {
            try await check(.beforeBackup)
            do {
                record = try await backupStore.backup(destination, reason: backupReason)
            } catch {
                throw ExportError.backupFailed(underlying: "\(error)")
            }
        }
        try await check(.beforeCommit)

        // 5. Atomic replace. Same-directory guarantee keeps the rename
        // on one filesystem, which is what `replaceItemAt` requires for
        // the atomic path.
        do {
            if replacing {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: tmpURL)
            } else {
                try FileManager.default.moveItem(at: tmpURL, to: destination)
            }
        } catch {
            throw ExportError.atomicReplaceFailed(underlying: "\(error)")
        }

        // 6. Keep the user's rating / flag / tags with the file. The file
        // is already written, so a metadata hiccup must not fail the save.
        if let metadataStore {
            if FileIdentity.sameFile(source, destination) {
                try? await metadataStore.rekey(from: destination, to: destination)
            } else {
                try? await metadataStore.copyMetadata(from: source, to: destination)
            }
        }
        return record
    }

    private func check(_ point: Checkpoint) async throws {
        try Task.checkCancellation()
        try await checkpoint?(point)
        try Task.checkCancellation()
    }

    private static func outputBounds(width: Int, height: Int, operations: [EditOperation]) throws -> (Int, Int) {
        // Use the renderer's rounded geometry, including the frozen Auto Crop
        // choice, for the allocation guard as well as the eventual pixels.
        guard let size = EditRenderer.outputPixelSize(
            from: CGSize(width: width, height: height), operations: operations
        ), let outputWidth = Int(exactly: size.width), let outputHeight = Int(exactly: size.height) else {
            throw ImageResourceError.dimensionOverflow
        }
        return (outputWidth, outputHeight)
    }

    /// Throws when writing `format` to `destination` would damage or
    /// mislabel a user file. Pure check, no side effects.
    static func validateDestination(
        source: URL, destination: URL, format: ExportFormat
    ) throws {
        let ext = destination.pathExtension
        if !ext.isEmpty {
            if ImageFormat.isCameraRAW(destination) {
                throw ExportError.unwritableFormat
            }
            guard format.accepts(extension: ext) else {
                throw ExportError.extensionMismatch
            }
        }
        guard format.isEncodable else { throw ExportError.unwritableFormat }
        if FileIdentity.sameFile(source, destination) {
            guard ExportFormat.inPlaceFormat(for: source) == format else {
                throw ExportError.inPlaceWriteNotAllowed
            }
        }
    }

    /// Stored pixels → display pixels, using the source's orientation tag.
    /// Same coordinate space as the viewer (and therefore edit mode).
    static func displayOrientedImage(
        _ stored: CGImage, properties: [CFString: Any]?
    ) -> CGImage {
        ExifOrientation.apply(ExifOrientation(properties: properties), to: stored)
    }

    // MARK: - Internal

    /// Construct a temp URL in the same directory as `destination`.
    /// Same-directory is load-bearing — `replaceItemAt` is only atomic
    /// within a filesystem.
    private func temporaryURL(sameDirectoryAs destination: URL, format: ExportFormat) -> URL {
        let dir = destination.deletingLastPathComponent()
        let stem = destination.deletingPathExtension().lastPathComponent
        let uuid = UUID().uuidString
        return dir.appendingPathComponent(
            "\(stem).shrikeedit.\(uuid).\(format.fileExtension).tmp"
        )
    }

    /// Write `image` to `url` in `format`. Throws the appropriate
    /// `ExportError` case on failure.
    private func writeEncoded(
        image: CGImage,
        to url: URL,
        format: ExportFormat,
        quality: Double,
        sourceProperties: [CFString: Any]?,
        preserveEXIF: Bool,
        stripGPS: Bool
    ) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.destinationCreateFailed
        }

        // Build the per-frame properties dictionary.
        var frameProps: [CFString: Any] = [:]

        // Orientation: always 1 because the recipe has baked in any rotation.
        frameProps[kCGImagePropertyOrientation] = 1

        if format.usesQuality {
            frameProps[kCGImageDestinationLossyCompressionQuality] =
                max(0, min(1, quality))
        }

        if preserveEXIF, let sourceProperties {
            // EXIF sub-dictionary: copy as-is, minus orientation-adjacent
            // fields the destination will fight us on.
            if var exif = sourceProperties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif.removeValue(forKey: kCGImagePropertyOrientation)
                frameProps[kCGImagePropertyExifDictionary] = exif
            }
            // TIFF sub-dictionary: carries Make/Model/Software among others.
            // Drop Orientation; keep everything else.
            if var tiff = sourceProperties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                tiff.removeValue(forKey: kCGImagePropertyOrientation)
                frameProps[kCGImagePropertyTIFFDictionary] = tiff
            }
            // GPS sub-dictionary: opt-out via stripGPS.
            if !stripGPS,
               let gps = sourceProperties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
                frameProps[kCGImagePropertyGPSDictionary] = gps
            }
            // IPTC is typically small and wholly copyable.
            if let iptc = sourceProperties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
                frameProps[kCGImagePropertyIPTCDictionary] = iptc
            }
        }

        CGImageDestinationAddImage(dest, image, frameProps as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportError.destinationFinalizeFailed
        }
    }
}

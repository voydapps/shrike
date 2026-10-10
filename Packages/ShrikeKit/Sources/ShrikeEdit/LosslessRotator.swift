//
//  LosslessRotator.swift
//  ShrikeEdit
//
//  Lossless rotate / flip by rewriting ONLY the orientation metadata.
//  The compressed image data is copied through untouched by
//  `CGImageDestinationCopyImageSource`, so there is no generation loss —
//  this is what Preview and Photos do for JPEG/HEIC.
//
//  Flow per call:
//    1. Check the file is a single-frame JPEG / HEIC / HEIF / TIFF / PNG
//       (by content, not extension) and not a camera RAW.
//    2. New orientation = current ∘ op (D4 table in Orientation.swift).
//    3. Copy the image source to a temp file in the same folder with the
//       new orientation (EXIF, TIFF and XMP orientation all updated).
//    4. Back up the original (BackupStore, reason .rotate). No backup →
//       no overwrite.
//    5. Atomic replace over the original.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeIO

/// Errors surfaced from `LosslessRotator`.
public enum LosslessRotateError: Error, Sendable, Equatable {
    /// Not a single-frame JPEG / HEIC / TIFF / PNG (RAW, GIF, multi-page…).
    /// The UI must not fall back to a lossy re-encode for these silently.
    case unsupportedFormat
    /// Source file vanished between enumeration and rotate.
    case sourceMissing
    /// The pre-rotate backup failed; the file was not touched.
    case backupFailed(underlying: String)
    /// Atomic rename over the original failed.
    case atomicReplaceFailed(underlying: String)
    /// ImageIO couldn't copy the source with the new orientation.
    case transformFailed(underlying: String)
}

/// What a lossless rotate did — enough for an Undo button.
public struct LosslessRotateResult: Sendable, Equatable {
    public let url: URL
    public let oldOrientation: ExifOrientation
    public let newOrientation: ExifOrientation
    /// Copy of the file as it was before the rotate.
    public let backup: BackupRecord
}

/// Lossless (metadata-only) rotator for JPEG, HEIC/HEIF, TIFF and PNG.
public actor LosslessRotator {

    private let backupStore: BackupStore

    public init(backupStore: BackupStore = BackupStore.shared) {
        self.backupStore = backupStore
    }

    // MARK: - Capability

    /// True when `url` can be rotated losslessly: a single-frame JPEG,
    /// HEIC/HEIF, TIFF or PNG by content, and not a camera RAW (DNG is
    /// TIFF-based, so the RAW check matters). Reads the file header.
    public static func isSupported(_ url: URL) -> Bool {
        guard !ImageFormat.isCameraRAW(url),
              let src = CGImageSourceCreateWithURL(url as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) == 1,
              let typeID = CGImageSourceGetType(src) as String?,
              let type = UTType(typeID),
              !type.conforms(to: .rawImage)
        else { return false }
        if let heics = UTType("public.heics"), type.conforms(to: heics) { return false }
        return type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
            || type.conforms(to: .tiff) || type.conforms(to: .png)
    }

    // MARK: - Operations

    /// Rotate `url` in place by `quarters` clockwise quarter turns (`+1` =
    /// 90° CW, `-1` = 90° CCW, `2` = 180°).
    @discardableResult
    public func rotate(url: URL, quarters: Int) async throws -> LosslessRotateResult {
        try await apply(.rotate(quarters: quarters), to: url)
    }

    /// Mirror `url` in place, left↔right (`horizontal: true`) or top↔bottom.
    @discardableResult
    public func flip(url: URL, horizontal: Bool) async throws -> LosslessRotateResult {
        try await apply(horizontal ? .flipHorizontal : .flipVertical, to: url)
    }

    /// Apply `op` to the displayed image by rewriting the orientation tag.
    @discardableResult
    public func apply(_ op: OrientationOp, to url: URL) async throws -> LosslessRotateResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw LosslessRotateError.sourceMissing }
        guard Self.isSupported(url),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let type = CGImageSourceGetType(src)
        else { throw LosslessRotateError.unsupportedFormat }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let old = ExifOrientation(properties: props)
        let new = old.applying(op)

        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).shrikerotate.\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, type, 1, nil) else {
            throw LosslessRotateError.transformFailed(underlying: "destination create failed")
        }
        let options: [CFString: Any] = [
            kCGImageDestinationOrientation: new.rawValue,
            kCGImageDestinationMergeMetadata: true,
        ]
        var cfError: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, options as CFDictionary, &cfError) else {
            let msg = cfError.map { "\($0.takeRetainedValue())" } ?? "unknown"
            throw LosslessRotateError.transformFailed(underlying: msg)
        }
        // Belt and braces: the written file must carry the new tag.
        guard let check = CGImageSourceCreateWithURL(tmp as CFURL, nil),
              ExifOrientation(properties: CGImageSourceCopyPropertiesAtIndex(check, 0, nil)
                              as? [CFString: Any]) == new
        else {
            throw LosslessRotateError.transformFailed(underlying: "orientation not written")
        }

        let record: BackupRecord
        do {
            record = try await backupStore.backup(url, reason: .rotate)
        } catch {
            throw LosslessRotateError.backupFailed(underlying: "\(error)")
        }

        do {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } catch {
            throw LosslessRotateError.atomicReplaceFailed(underlying: "\(error)")
        }
        return LosslessRotateResult(url: url, oldOrientation: old, newOrientation: new, backup: record)
    }

    /// Undo a rotate by restoring the pre-rotate backup (byte-exact).
    public func undo(_ result: LosslessRotateResult) async throws {
        try await backupStore.restore(result.backup)
    }
}

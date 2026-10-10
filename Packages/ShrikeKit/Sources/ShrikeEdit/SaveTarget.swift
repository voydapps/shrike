//
//  SaveTarget.swift
//  ShrikeEdit
//
//  Single source of truth for "can Shrike overwrite this file in place,
//  and in which format?". Everything else — the UI's Save
//  routing and the exporter's own refusal — asks here.
//
//  Rules (nil = not safe, the UI must force Save As):
//    * RAW (any `public.camera-raw-image`)                 → nil
//    * GIF, BMP, PSD, PDF, unknown / dynamic types         → nil
//    * WebP / AVIF                                          → only if the
//      running OS can encode them (`CGImageDestinationCopyTypeIdentifiers`)
//    * multi-frame sources (animated GIF/PNG, HEICS, multi-page TIFF)
//                                                           → nil
//    * bytes on disk don't match the extension (PNG named .jpg) → nil
//    * JPEG family (.jpg .jpeg .jpe .jfif) → .jpeg; .png; .tif/.tiff;
//      .heic/.heif → .heic
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore

extension ExportFormat {

    /// Type identifiers ImageIO can encode on this machine. Read once.
    private static let encodableTypeIdentifiers: Set<String> = {
        Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    }()

    /// True when the running OS ships an ImageIO encoder for this format.
    public var isEncodable: Bool {
        Self.encodableTypeIdentifiers.contains(utType.identifier)
    }

    /// Lower-case extensions whose bytes this format produces.
    public var acceptedExtensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg", "jpe", "jfif", "jif"]
        case .png:  return ["png"]
        case .tiff: return ["tif", "tiff"]
        case .heic: return ["heic", "heif", "hif"]
        case .webp: return ["webp"]
        case .avif: return ["avif"]
        }
    }

    /// True when writing this format under `ext` wouldn't mislabel it.
    public func accepts(extension ext: String) -> Bool {
        acceptedExtensions.contains(ext.lowercased())
    }

    /// Map a UTType to the export format that writes the same kind of
    /// bytes. `nil` for anything we won't write back (RAW, GIF, BMP, PSD,
    /// sequences, …) and for WebP/AVIF when the OS can't encode them.
    public static func writableFormat(for type: UTType) -> ExportFormat? {
        if type.conforms(to: .rawImage) { return nil }
        // Sequences / animations are never single-frame safe.
        if let heics = UTType("public.heics"), type.conforms(to: heics) { return nil }
        let candidate: ExportFormat?
        if type.conforms(to: .jpeg) {
            candidate = .jpeg
        } else if type.conforms(to: .png) {
            candidate = .png
        } else if type.conforms(to: .tiff) {
            candidate = .tiff
        } else if type.conforms(to: .heic) || type.conforms(to: .heif) {
            candidate = .heic
        } else if type.conforms(to: .webP) {
            candidate = .webp
        } else if type.identifier == ExportFormat.avif.utType.identifier {
            candidate = .avif
        } else {
            candidate = nil
        }
        guard let candidate, candidate.isEncodable else { return nil }
        return candidate
    }

    /// The format Shrike may use to overwrite `url` in place, or `nil`
    /// when an in-place write would damage the file (see file header).
    ///
    /// Reads the file header when the file exists (content type + frame
    /// count). For a path that doesn't exist yet, answers from the
    /// extension alone — there is nothing to damage.
    public static func inPlaceFormat(for url: URL) -> ExportFormat? {
        guard url.isFileURL,
              let extType = ImageFormat.utType(for: url),
              !ImageFormat.isCameraRAW(url),
              let byExtension = writableFormat(for: extType)
        else { return nil }

        guard FileManager.default.fileExists(atPath: url.path) else {
            return byExtension
        }
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts),
              let typeID = CGImageSourceGetType(src) as String?,
              let contentType = UTType(typeID)
        else { return nil }
        // Bytes must be what the name says (a PNG called .jpg → nil).
        guard writableFormat(for: contentType) == byExtension else { return nil }
        // Animated GIF/PNG, HEIC sequences, multi-page TIFF: writing frame
        // 0 back would silently drop the rest.
        guard CGImageSourceGetCount(src) == 1 else { return nil }
        return byExtension
    }

    /// Where a non-in-place Save lands by default: `<stem>-edited.<ext>`
    /// next to the original. Doesn't check for an existing file.
    public static func editedSiblingURL(for url: URL, format: ExportFormat = .jpeg) -> URL {
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        return dir
            .appendingPathComponent(stem + ImageExporter.rawRedirectSuffix)
            .appendingPathExtension(format.fileExtension)
    }
}

// MARK: - Save routing decision

/// Why ⌘S can't write a file in place. Maps to the Save-panel messages
/// for RAW (`raw`), multi-frame (`multiFrame`) and the other two.
public enum SaveAsReason: Sendable, Hashable {
    /// Camera RAW. Shrike never changes RAW files.
    case raw
    /// Animated GIF/PNG, HEIC sequence, multi-page TIFF. Writing back would
    /// keep only the first frame.
    case multiFrame(count: Int)
    /// A format Shrike can't write back without loss (GIF still, BMP, PSD,
    /// PDF, WebP/AVIF without an encoder, unknown). `typeName` is the
    /// system's name for the type, e.g. "GIF image".
    case notWritable(typeName: String)
    /// The bytes don't match the extension (a PNG named ".jpg").
    case extensionMismatch

    /// The Save-panel message for `url`.
    public func message(for url: URL) -> String {
        let name = url.lastPathComponent
        switch self {
        case .raw:
            return "RAW files are never changed. Save an edited copy instead."
        case .multiFrame(let count):
            let unit = SaveTarget.isPaged(url) ? "pages" : "frames"
            return "“\(name)” has \(count) \(unit). Saving in place would keep only the first one. "
                + "Save an edited copy instead."
        case .notWritable, .extensionMismatch:
            return "“\(name)” can't be saved in place without losing data. Save an edited copy instead."
        }
    }
}

/// What ⌘S does for a file.
public enum SaveTargetDecision: Sendable, Hashable {
    /// Back up, then overwrite in this format.
    case inPlace(ExportFormat)
    /// Show the Save panel with `reason`'s message; `suggested` is the
    /// default format for the edited copy.
    case saveAsRequired(SaveAsReason, suggested: ExportFormat)

    /// The in-place format, or `nil` when Save As is required.
    public var inPlaceFormat: ExportFormat? {
        if case .inPlace(let format) = self { return format }
        return nil
    }

    /// Why Save As is required, or `nil` for an in-place save.
    public var reason: SaveAsReason? {
        if case .saveAsRequired(let reason, _) = self { return reason }
        return nil
    }

    /// The format a Save As panel should start with: the file's own format
    /// when it's writable, else `suggested`.
    public var format: ExportFormat {
        switch self {
        case .inPlace(let format): return format
        case .saveAsRequired(_, let suggested): return suggested
        }
    }
}

/// Save routing. A thin layer over
/// `ExportFormat.inPlaceFormat(for:)` that also says *why* a file can't be
/// written in place, so the UI can show the right message. The in-place answer is
/// always exactly `inPlaceFormat(for:)`.
public enum SaveTarget {

    /// Decide what ⌘S does for `url`. Reads the file header (type, frame
    /// count, alpha) only when an in-place save is refused.
    public static func evaluate(_ url: URL) -> SaveTargetDecision {
        if let format = ExportFormat.inPlaceFormat(for: url) {
            return .inPlace(format)
        }
        let extType = ImageFormat.utType(for: url)
        if ImageFormat.isCameraRAW(url) || extType?.conforms(to: .rawImage) == true {
            return .saveAsRequired(.raw, suggested: .jpeg)
        }

        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        let source: CGImageSource? = url.isFileURL
            && FileManager.default.fileExists(atPath: url.path)
            ? CGImageSourceCreateWithURL(url as CFURL, opts) : nil
        let contentType = source.flatMap { CGImageSourceGetType($0) as String? }.flatMap { UTType($0) }
        let suggested: ExportFormat = source.map(hasAlpha) == true ? .png : .jpeg

        if let contentType, contentType.conforms(to: .rawImage) {
            return .saveAsRequired(.raw, suggested: .jpeg)   // RAW bytes behind another name
        }
        if let source {
            let count = CGImageSourceGetCount(source)
            if count > 1 {
                return .saveAsRequired(.multiFrame(count: count), suggested: suggested)
            }
        }
        // Bytes and name map to different writable formats (at least one
        // of them non-nil): the mismatch, not the format, blocks us.
        if let contentType, let extType,
           ExportFormat.writableFormat(for: extType) != ExportFormat.writableFormat(for: contentType) {
            return .saveAsRequired(.extensionMismatch, suggested: suggested)
        }
        return .saveAsRequired(.notWritable(typeName: typeName(contentType ?? extType, url: url)),
                               suggested: suggested)
    }

    /// Default Save As location: `<stem>-edited.<ext>` next to `url`, in
    /// the decision's format.
    public static func saveAsURL(for url: URL, decision: SaveTargetDecision) -> URL {
        ExportFormat.editedSiblingURL(for: url, format: decision.format)
    }

    /// TIFF and PDF count pages; everything else counts frames.
    static func isPaged(_ url: URL) -> Bool {
        guard let type = ImageFormat.utType(for: url) else { return false }
        return type.conforms(to: .tiff) || type.conforms(to: .pdf)
    }

    private static func hasAlpha(_ source: CGImageSource) -> Bool {
        guard CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return false }
        return (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
    }

    private static func typeName(_ type: UTType?, url: URL) -> String {
        if let type, !type.isDynamic, let name = type.localizedDescription { return name }
        let ext = url.pathExtension
        return ext.isEmpty ? "Unknown file" : ext.uppercased()
    }
}

// MARK: - Same-file detection

enum FileIdentity {
    /// True when `a` and `b` name the same file on disk. Uses the file
    /// system's resource identifier when both exist (handles symlinks,
    /// `/var` vs `/private/var`, and case-insensitive volumes); otherwise
    /// compares standardized paths.
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path) {
            let ka = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
            let kb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey])
                .fileResourceIdentifier
            if let ka, let kb {
                return ka.isEqual(kb)
            }
        }
        return a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

//
//  ImageFormat.swift
//  ShrikeCore
//
//  Cheap, extension-based classification of image files. Deliberately
//  does NOT read file headers — the whole point is to be fast enough
//  to call on the hot path right before a decode is dispatched, so the
//  caller can pick a cold-start predicted duration (see
//  `DecodeTimePredictor`) and decide whether the hairline progress
//  indicator should skip its 100 ms grace.
//
//  Keep this enum stable. `DecodeStatsStore` keys rolling per-format
//  stats off the raw value space below, and adding a new case is fine
//  but renaming/removing one invalidates accumulated samples in
//  memory. (Stats are in-memory only, so a new launch starts
//  fresh — but avoid churn anyway.)
//

import Foundation
import ImageIO
import os
import UniformTypeIdentifiers

/// Classification of an image file by filename extension only. Use
/// `init?(url:)` for the classification entry point; returns `.other`
/// for unknown-but-supportable extensions and `nil` only if the URL
/// has no extension at all. (Callers typically want to treat both
/// `nil` and `.other` as "unknown, use the generic cold-start
/// prediction" — see `DecodeTimePredictor`.)
public enum ImageFormat: String, Sendable, Hashable, CaseIterable {
    case jpeg
    case heic
    case png
    case gif
    case tiff
    case webp
    case avif
    case bmp
    case raw
    case psd
    case pdf
    case other

    /// Classify a file URL by its path extension. Lowercase-compares
    /// the extension, so `.JPG`, `.jpg`, `.Jpeg` all map to `.jpeg`.
    ///
    /// Returns `nil` only when the URL has no extension at all.
    /// Unknown extensions map to `.other` — the caller can still get
    /// a useful generic prediction from `DecodeTimePredictor`.
    public init?(url: URL) {
        let ext = url.pathExtension
        guard !ext.isEmpty else { return nil }
        self.init(extension: ext)
    }

    /// Classify by raw extension string (no leading dot). Used
    /// directly by tests; `init?(url:)` is the usual entry point.
    public init?(extension ext: String) {
        let lowered = ext.lowercased()
        guard !lowered.isEmpty else { return nil }
        if let format = Self.extensionMap[lowered] {
            self = format
        } else if let type = Self.utType(forExtension: lowered), type.conforms(to: .rawImage) {
            self = .raw
        } else {
            self = .other
        }
    }

    // MARK: - Extension table
    //
    // The common RAW formats are listed by name so classification needs no
    // UTType lookup: Canon CR2/CR3, Nikon NEF/NRW, Sony ARW/SR2, Adobe
    // DNG, Olympus ORF, Panasonic RW2, Fujifilm RAF, Pentax PEF, Samsung
    // SRW, Minolta MRW. Any other extension whose UTType conforms to
    // `public.camera-raw-image` (3FR, IIQ, ERF, …) also maps to `.raw`
    // through the fallback in `init?(extension:)`.
    //
    // Sigma X3F and Kodak KDC are deliberately absent: ImageIO cannot
    // decode them, so Shrike does not list them (see `isSupported`).
    private static let extensionMap: [String: ImageFormat] = [
        // JPEG family
        "jpg": .jpeg,
        "jpeg": .jpeg,
        "jpe": .jpeg,
        "jfif": .jpeg,

        // HEIF family
        "heic": .heic,
        "heif": .heic,

        // PNG
        "png": .png,

        // GIF
        "gif": .gif,

        // TIFF family
        "tif": .tiff,
        "tiff": .tiff,

        // WebP
        "webp": .webp,

        // AVIF
        "avif": .avif,

        // BMP
        "bmp": .bmp,

        // RAW — camera manufacturer formats. See comment above.
        "cr2": .raw,
        "cr3": .raw,
        "nef": .raw,
        "nrw": .raw,
        "arw": .raw,
        "sr2": .raw,
        "dng": .raw,
        "orf": .raw,
        "rw2": .raw,
        "raf": .raw,
        "pef": .raw,
        "srw": .raw,
        "mrw": .raw,

        // Photoshop
        "psd": .psd,

        // PDF (we render first page as an image).
        "pdf": .pdf,
    ]

    // MARK: - Capability hints

    /// Whether containers in this format are likely to carry an embedded
    /// preview image (EXIF IFD1 thumbnail, HEIF auxiliary preview, RAW
    /// vendor preview chunk, etc.).
    ///
    /// Used by `FileImageSource.loadEmbeddedPreview()` as a pre-gate so
    /// the embedded-preview path is never invoked on formats that
    /// definitely cannot satisfy it. Without the gate, ImageIO logs a
    /// noisy `CGImageSourceCreateThumbnailAtIndex … failed to create
    /// thumbnail [-50]` for every PNG/GIF/BMP nav even though the
    /// caller correctly treats the `nil` return as "no preview, fall
    /// through to thumb-cache bridge".
    ///
    /// Truth table:
    ///   * `.jpeg` — almost every camera-out JPEG has an EXIF IFD1
    ///     thumbnail, and even hand-saved JPEGs frequently carry one.
    ///   * `.heic` — HEIF containers ship an embedded preview image
    ///     by spec.
    ///   * `.raw` — every RAW format Shrike knows about (CR2/CR3,
    ///     NEF/NRW, ARW/SR2, DNG, ORF, RW2, RAF, PEF, SRW, MRW, …)
    ///     carries an embedded JPEG preview — that's what cameras and
    ///     RAW viewers paint while the demosaic runs.
    ///   * `.tiff` — kept on the "yes" list deliberately. Some RAW
    ///     formats use a TIFF container (DNG is TIFF-based, some camera
    ///     vendors emit `.tif` from in-camera RAW), and missing a
    ///     preview on those is a worse failure mode than the cost of
    ///     one ImageIO log entry on a plain non-preview TIFF.
    ///   * Everything else (`.png`, `.gif`, `.bmp`, `.webp`, `.avif`,
    ///     `.psd`, `.pdf`, `.other`) — no embedded preview convention.
    ///     Skip the call.
    public var hasEmbeddedPreview: Bool {
        switch self {
        case .jpeg, .heic, .raw, .tiff:
            return true
        case .png, .gif, .bmp, .webp, .avif, .psd, .pdf, .other:
            return false
        }
    }
}

// MARK: - UTType-based classification

extension ImageFormat {

    /// Extensions macOS doesn't map to a real image UTType (it returns a
    /// `dyn.*` type) but which are the same bytes as a known type.
    private static let extensionAliases: [String: String] = [
        "jfif": "public.jpeg",
        "jpe": "public.jpeg",
        "jif": "public.jpeg",
    ]

    /// The UTType for a filename extension, case-insensitive, with the
    /// alias table above. `nil` for empty or dynamic (unknown) types.
    public static func utType(forExtension ext: String) -> UTType? {
        let lowered = ext.lowercased()
        guard !lowered.isEmpty else { return nil }
        if let alias = extensionAliases[lowered], let t = UTType(alias) { return t }
        guard let t = UTType(filenameExtension: lowered), !t.isDynamic else { return nil }
        return t
    }

    /// The UTType for a file URL, from its extension (no disk access).
    public static func utType(for url: URL) -> UTType? {
        utType(forExtension: url.pathExtension)
    }

    /// True for every camera RAW format the OS knows (conformance to
    /// `public.camera-raw-image`), plus RAW extensions from the table above.
    /// Extension-only.
    public static func isCameraRAW(_ url: URL) -> Bool {
        if let t = utType(for: url), t.conforms(to: .rawImage) { return true }
        return ImageFormat(url: url) == .raw
    }
}

// MARK: - Supported formats (the one list)
//
// "Can Shrike open this file?" has exactly one answer, built at run time
// from what this Mac's ImageIO can decode (`CGImageSourceCopyTypeIdentifiers`)
// intersected with UTType conformance to `public.image`. Every folder scan,
// open panel and "is this an image?" check should ask here instead of
// keeping its own extension list. Formats ImageIO can't decode (Sigma X3F,
// Kodak KDC, PDF) are therefore never listed; formats a newer macOS adds
// (JPEG XL on macOS 14+) show up without a code change.

extension ImageFormat {

    /// Image UTTypes ImageIO can decode on this Mac. Read once.
    public static let decodableImageTypes: [UTType] = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return ids.compactMap { UTType($0) }.filter { $0.conforms(to: .image) }
    }()

    private static let decodableImageIdentifiers: Set<String> =
        Set(decodableImageTypes.map(\.identifier))

    /// Lower-cased filename extensions (no dot) of every supported type,
    /// plus the JPEG aliases macOS has no UTType for (`jfif`, `jif`). This
    /// is the shared extension set: use it (or `isSupported(_:)`) for
    /// folder scans, drag-and-drop filters and open panels.
    public static let supportedExtensions: Set<String> = {
        var set = Set<String>()
        for type in decodableImageTypes {
            for ext in type.tags[.filenameExtension] ?? [] {
                let lowered = ext.lowercased()
                // An extension counts only if the OS resolves it to a
                // supported type (guards against tags shared with other
                // types, e.g. `pic`).
                if let resolved = utType(forExtension: lowered), isSupported(resolved) {
                    set.insert(lowered)
                }
            }
        }
        for (alias, target) in extensionAliases {
            if let t = UTType(target), isSupported(t) { set.insert(alias) }
        }
        return set
    }()

    /// Subset of `supportedExtensions` whose type is a camera RAW
    /// (`public.camera-raw-image`). Note `tif` is not in it even though a
    /// Canon RAW type also claims `.tif`: the OS resolves `.tif` to TIFF.
    public static let supportedRAWExtensions: Set<String> = {
        supportedExtensions.filter { utType(forExtension: $0)?.conforms(to: .rawImage) == true }
    }()

    /// RAW formats this Mac's ImageIO can't decode but that still belong to
    /// a shot: Sigma X3F and Kodak KDC. They are never
    /// listed or opened as images; `ImageGrouping` attaches them to a
    /// display file with the same name so trash / move / copy / rename
    /// carry them along. A lone one is not listed. If a future macOS
    /// decodes one of them, it moves to `supportedRAWExtensions` and drops
    /// out of this set.
    public static let companionOnlyRAWExtensions: Set<String> =
        Set(["x3f", "kdc"]).subtracting(supportedExtensions)

    /// Non-image files that travel with an image and must be listed so
    /// `ImageGrouping` can attach them: XMP / Apple AAE sidecars, the Live
    /// Photo `.mov`, and `companionOnlyRAWExtensions`.
    public static let companionExtensions: Set<String> =
        Set(["xmp", "aae", "mov"]).union(companionOnlyRAWExtensions)

    /// Extensions a folder scan should pick up before grouping:
    /// `supportedExtensions` ∪ `companionExtensions`.
    public static let folderScanExtensions: Set<String> =
        supportedExtensions.union(companionExtensions)

    /// True when ImageIO on this Mac can decode files of `type`: the type
    /// is an image and is (or conforms to) one ImageIO lists.
    public static func isSupported(_ type: UTType) -> Bool {
        guard type.conforms(to: .image) else { return false }
        if decodableImageIdentifiers.contains(type.identifier) { return true }
        return decodableImageTypes.contains { type.conforms(to: $0) }
    }

    /// True when the file's extension names a supported type. No disk
    /// access; case-insensitive. Unknown extensions are resolved through
    /// UTType once and remembered.
    public static func isSupported(_ url: URL) -> Bool {
        isSupported(extension: url.pathExtension)
    }

    /// Extension form of `isSupported(_ url:)` (no leading dot).
    public static func isSupported(extension ext: String) -> Bool {
        let lowered = ext.lowercased()
        guard !lowered.isEmpty else { return false }
        if supportedExtensions.contains(lowered) { return true }
        if let cached = unknownExtensionCache.withLock({ $0[lowered] }) { return cached }
        let answer = utType(forExtension: lowered).map(isSupported) ?? false
        unknownExtensionCache.withLock { $0[lowered] = answer }
        return answer
    }

    /// True for an image or a companion file (see `folderScanExtensions`).
    public static func isFolderScanCandidate(_ url: URL) -> Bool {
        let lowered = url.pathExtension.lowercased()
        return companionExtensions.contains(lowered) || isSupported(extension: lowered)
    }

    /// Memo for extensions outside `supportedExtensions` (`txt`, `mov`, …)
    /// so a 20,000-file folder costs one UTType lookup per distinct
    /// extension, not per file.
    private static let unknownExtensionCache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
}

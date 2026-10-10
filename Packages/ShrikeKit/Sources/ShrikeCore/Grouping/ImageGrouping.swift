//
//  ImageGrouping.swift
//  ShrikeCore
//
//  Collapses files that belong to one shot into a single list entry.
//  Cameras set to
//  RAW+JPEG (`P1250298.JPG` + `P1250298.ORF`) showed every photo twice.
//
//  One `ImageGroup` = one thing the viewer shows:
//    * `primary` — the file to display. A display format (JPEG > HEIC >
//      PNG > other raster) wins over RAW. A RAW with no display sibling
//      is its own primary.
//    * `companions` — files that travel with the primary for trash /
//      move / rating: the RAW sibling(s), `.xmp` / `.aae` sidecars, and
//      the Live Photo `.mov` of a HEIC/JPEG.
//    * RAW types ImageIO can't decode (X3F, KDC —
//      `ImageFormat.companionOnlyRAWExtensions`) are companions only: they
//      join a display file with the same name as a `.raw` companion, and
//      are dropped when alone or when RAW pairing is off. They are never
//      a primary.
//
//  Matching is by directory + basename, case-insensitive
//  (`IMG_1.JPG` pairs with `img_1.cr3`). Only files in the same folder
//  pair. Darktable-style sidecars (`IMG_1.CR3.xmp`) match too.
//
//  "Show both files" (`ImageGroupingPreference` off):
//  RAW pairing is off, so the display file and the RAW are separate
//  entries, but sidecars and the Live Photo movie still travel with an
//  image. Each companion stays with the SAME file in both modes:
//    * `.mov` → the HEIC / JPEG (it is that photo's Live Photo video).
//    * `.aae` → the display file (Apple's edit file for the HEIC / JPEG).
//    * plain `.xmp` → the RAW (RAW editors write XMP sidecars; JPEG and
//      HEIC carry their XMP inside the file). With pairing on, the RAW is
//      in the display file's group, so the `.xmp` is with the RAW there too.
//    * `IMG_1.CR3.xmp` / `IMG_1.JPG.xmp` → the file its name extends.
//  When only one image has the stem, every companion goes to it.
//
//  Pure string work — no disk access. Input order is preserved: groups
//  come out in the order their primaries appear, so the caller sorts
//  first (natural sort) and groups second. 20,000 URLs group in a few
//  milliseconds (see ImageGroupingTests.testPerformance20k).
//

import Foundation

// MARK: - Model

public struct ImageGroup: Sendable, Hashable {

    public enum CompanionKind: Sendable, Hashable {
        /// Camera RAW sibling of a display file (`.ORF` next to `.JPG`).
        case raw
        /// Metadata sidecar (`.xmp`, Apple `.aae`).
        case sidecar
        /// Live Photo video (`.mov`) of a HEIC / JPEG.
        case livePhotoMovie
    }

    public struct Companion: Sendable, Hashable {
        public let url: URL
        public let kind: CompanionKind
        public init(url: URL, kind: CompanionKind) {
            self.url = url
            self.kind = kind
        }
    }

    /// The file to display.
    public let primary: URL
    /// Files that belong to the same shot, in input order.
    public let companions: [Companion]
    /// True when `primary` itself is a RAW file (no display sibling).
    public let primaryIsRAW: Bool

    public init(primary: URL, companions: [Companion] = [], primaryIsRAW: Bool = false) {
        self.primary = primary
        self.companions = companions
        self.primaryIsRAW = primaryIsRAW
    }

    /// A RAW file is part of this shot — either a companion or the primary.
    /// Drives the "RAW" badge.
    public var hasRAW: Bool {
        primaryIsRAW || companions.contains { $0.kind == .raw }
    }

    /// RAW companions (normally zero or one).
    public var rawURLs: [URL] {
        companions.lazy.filter { $0.kind == .raw }.map(\.url)
    }

    /// First RAW companion, if any.
    public var rawURL: URL? {
        companions.first { $0.kind == .raw }?.url
    }

    /// Live Photo movie, if any.
    public var livePhotoMovie: URL? {
        companions.first { $0.kind == .livePhotoMovie }?.url
    }

    /// Sidecar files (`.xmp`, `.aae`).
    public var sidecarURLs: [URL] {
        companions.lazy.filter { $0.kind == .sidecar }.map(\.url)
    }

    /// Primary first, then every companion. Use for trash / move / copy
    /// so culling removes the whole shot.
    public var allURLs: [URL] {
        [primary] + companions.map(\.url)
    }
}

// MARK: - Grouping

public enum ImageGrouping {

    public struct Options: Sendable, Hashable {
        /// Fold a RAW into the display file with the same basename.
        public var pairRAW: Bool
        /// Attach `.xmp` / `.aae` sidecars to their image.
        public var attachSidecars: Bool
        /// Attach a Live Photo `.mov` to its HEIC / JPEG.
        public var attachLivePhotoMovies: Bool
        /// Emit sidecars / movies that found no image as their own groups.
        /// Off by default: they are not images, so the viewer skips them.
        public var keepOrphanCompanions: Bool

        public init(
            pairRAW: Bool = true,
            attachSidecars: Bool = true,
            attachLivePhotoMovies: Bool = true,
            keepOrphanCompanions: Bool = false
        ) {
            self.pairRAW = pairRAW
            self.attachSidecars = attachSidecars
            self.attachLivePhotoMovies = attachLivePhotoMovies
            self.keepOrphanCompanions = keepOrphanCompanions
        }

        /// Pair everything (the default).
        public static let `default` = Options()

        /// "Show both files": every image is its own entry
        /// (no RAW pairing), but `.xmp` / `.aae` sidecars and Live Photo
        /// movies still travel with their image. What the preference
        /// `shrike.grouping.pairRAW = false` maps to.
        public static let showBothFiles = Options(pairRAW: false)

        /// No grouping at all: every image is its own entry; sidecars and
        /// movies are dropped (they are not images). Not what the
        /// preference uses — see `showBothFiles`.
        public static let disabled = Options(
            pairRAW: false, attachSidecars: false, attachLivePhotoMovies: false,
            keepOrphanCompanions: false
        )
    }

    /// Groups `urls` into shots. See the file header for the rules.
    /// Output order follows the input order of each group's primary.
    public static func group(_ urls: [URL], options: Options = .default) -> [ImageGroup] {
        let count = urls.count
        guard count > 0 else { return [] }

        // Pass 1 — classify each URL and build the lookup tables.
        var kinds = [FileKind](repeating: .other, count: count)
        var keys = [String?](repeating: nil, count: count)
        /// Sidecars only: follow the RAW (not the display file) when RAW
        /// pairing is off and both exist.
        var sidecarPrefersRAW = [Bool](repeating: false, count: count)
        /// key → (index, priority) of the best display file.
        var bestDisplay: [String: (index: Int, priority: UInt8)] = [:]
        /// key → first RAW (used when no display file exists).
        var firstRAW: [String: Int] = [:]
        bestDisplay.reserveCapacity(count)

        for i in 0..<count {
            let parsed = parse(urls[i])
            kinds[i] = parsed.kind
            keys[i] = parsed.key
            sidecarPrefersRAW[i] = parsed.prefersRAW
            guard let key = parsed.key else { continue }
            switch parsed.kind {
            case .display(let priority):
                if let existing = bestDisplay[key] {
                    if priority < existing.priority { bestDisplay[key] = (i, priority) }
                } else {
                    bestDisplay[key] = (i, priority)
                }
            case .raw:
                if firstRAW[key] == nil { firstRAW[key] = i }
            case .companionRAW, .sidecar, .movie, .other:
                break
            }
        }

        // Pass 2 — decide each URL's owner (the input index of its
        // group's primary). -1 = dropped.
        var owner = [Int](repeating: -1, count: count)
        var ownerKind = [ImageGroup.CompanionKind?](repeating: nil, count: count)
        var primaries: [Int] = []
        primaries.reserveCapacity(count)

        for i in 0..<count {
            let key = keys[i]
            switch kinds[i] {
            case .display, .other:
                owner[i] = i
                primaries.append(i)

            case .raw:
                if options.pairRAW, let key, let display = bestDisplay[key] {
                    owner[i] = display.index
                    ownerKind[i] = .raw
                } else {
                    owner[i] = i
                    primaries.append(i)
                }

            case .companionRAW:
                // Undecodable RAW: only ever a companion (never listed alone).
                if options.pairRAW, let key, let display = bestDisplay[key] {
                    owner[i] = display.index
                    ownerKind[i] = .raw
                }

            case .sidecar:
                var target: Int?
                if options.attachSidecars, let key {
                    // With pairing on, the RAW lives in the display file's
                    // group. With it off, the sidecar picks its own image
                    // (file header): `.xmp` → RAW, `.aae` → display file.
                    if options.pairRAW {
                        target = bestDisplay[key]?.index ?? firstRAW[key]
                    } else if sidecarPrefersRAW[i] {
                        target = firstRAW[key] ?? bestDisplay[key]?.index
                    } else {
                        target = bestDisplay[key]?.index ?? firstRAW[key]
                    }
                }
                if let target {
                    owner[i] = target
                    ownerKind[i] = .sidecar
                } else if options.keepOrphanCompanions {
                    owner[i] = i
                    primaries.append(i)
                }

            case .movie:
                var target: Int?
                if options.attachLivePhotoMovies, let key, let display = bestDisplay[key],
                   display.priority <= FileKind.livePhotoMaxPriority {
                    target = display.index
                }
                if let target {
                    owner[i] = target
                    ownerKind[i] = .livePhotoMovie
                } else if options.keepOrphanCompanions {
                    owner[i] = i
                    primaries.append(i)
                }
            }
        }

        // Pass 3 — collect companions per primary, in input order.
        // Indexed by the primary's input index; empty arrays don't allocate.
        var companionsByPrimary = [[ImageGroup.Companion]](repeating: [], count: count)
        for i in 0..<count {
            guard let kind = ownerKind[i] else { continue }
            companionsByPrimary[owner[i]].append(ImageGroup.Companion(url: urls[i], kind: kind))
        }

        var groups: [ImageGroup] = []
        groups.reserveCapacity(primaries.count)
        for p in primaries {
            var isRAW = false
            if case .raw = kinds[p] { isRAW = true }
            groups.append(ImageGroup(
                primary: urls[p],
                companions: companionsByPrimary[p],
                primaryIsRAW: isRAW
            ))
        }
        return groups
    }

    // MARK: - Classification

    enum FileKind: Equatable {
        /// Displayable raster; lower priority wins as primary.
        case display(priority: UInt8)
        case raw
        /// RAW that ImageIO can't decode (X3F, KDC): companion only.
        case companionRAW
        case sidecar
        case movie
        /// Unknown extension — passes through as its own group.
        case other

        /// JPEG (0) and HEIC (1) can own a Live Photo movie.
        static let livePhotoMaxPriority: UInt8 = 1
    }

    /// Lowercased extension → kind, keyed by `packedExtension` so the
    /// hot path never allocates a String for the extension.
    static let kindByExtension: [UInt64: FileKind] = {
        var map: [UInt64: FileKind] = [:]
        func add<S: Sequence>(_ exts: S, _ kind: FileKind) where S.Element == String {
            for ext in exts {
                guard let packed = packedExtension(Substring(ext)), map[packed] == nil else { continue }
                map[packed] = kind
            }
        }
        add(["jpg", "jpeg", "jpe", "jfif"], .display(priority: 0))
        add(["heic", "heif", "hif"], .display(priority: 1))
        add(["png"], .display(priority: 2))
        add(["tif", "tiff", "webp", "avif", "jxl", "gif", "bmp", "psd", "tga", "exr", "hdr"],
            .display(priority: 3))
        // RAW = the RAW types this Mac's ImageIO can decode (the one list in
        // ImageFormat). X3F and KDC can't be decoded: they only travel with
        // a display file of the same name.
        add(ImageFormat.supportedRAWExtensions.sorted(), .raw)
        add(ImageFormat.companionOnlyRAWExtensions.sorted(), .companionRAW)
        add(["xmp", "aae"], .sidecar)
        add(["mov"], .movie)
        // Every other supported image type is a display file too, so a
        // `.jp2` + `.CR2` shot still pairs.
        add(ImageFormat.supportedExtensions.sorted(), .display(priority: 3))
        return map
    }()

    /// Packs a 1–8 byte ASCII extension, lowercased, into a UInt64.
    /// Nil for longer or non-ASCII extensions (none of ours are).
    static func packedExtension(_ ext: Substring) -> UInt64? {
        var packed: UInt64 = 0
        var length = 0
        for byte in ext.utf8 {
            guard byte < 0x80, length < 8 else { return nil }
            let lower = (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
            packed = (packed << 8) | UInt64(lower)
            length += 1
        }
        return length == 0 ? nil : packed
    }

    static func fileKind(ofExtension ext: Substring) -> FileKind? {
        guard let packed = packedExtension(ext) else { return nil }
        return kindByExtension[packed]
    }

    /// Splits a URL into its kind and a grouping key
    /// (`lowercased(directory + "/" + basename)`). The key is nil for
    /// files without an extension; those never pair. `prefersRAW` (sidecars
    /// only) says which image a sidecar belongs to when RAW pairing is off:
    /// `IMG_1.CR3.xmp` → RAW, `IMG_1.JPG.xmp` → display file, a plain
    /// `.xmp` → RAW, a plain `.aae` → display file.
    static func parse(_ url: URL) -> (kind: FileKind, key: String?, prefersRAW: Bool) {
        // `path(percentEncoded:)` is about 2x faster than `.path`.
        let path = url.path(percentEncoded: false)
        let utf8 = path.utf8
        guard let dot = utf8.lastIndex(of: UInt8(ascii: ".")) else { return (.other, nil, false) }
        if let slash = utf8.lastIndex(of: UInt8(ascii: "/")), slash > dot {
            return (.other, nil, false)   // dot is in a directory name
        }
        let ext = path[path.index(after: dot)...]
        guard let kind = fileKind(ofExtension: ext) else {
            return (.other, nil, false)
        }

        var stemEnd = dot
        var prefersRAW = false
        if kind == .sidecar {
            prefersRAW = packedExtension(ext) == packedXMP
            // `IMG_1.CR3.xmp` → strip the inner image extension too.
            let stem = path[..<dot]
            if let innerDot = stem.utf8.lastIndex(of: UInt8(ascii: ".")),
               stem.utf8.lastIndex(of: UInt8(ascii: "/")).map({ $0 < innerDot }) ?? true {
                if let innerKind = fileKind(ofExtension: stem[stem.index(after: innerDot)...]) {
                    switch innerKind {
                    case .display: stemEnd = innerDot; prefersRAW = false
                    case .raw, .companionRAW: stemEnd = innerDot; prefersRAW = true
                    default: break
                    }
                }
            }
        }
        return (kind, path[..<stemEnd].lowercased(), prefersRAW)
    }

    static let packedXMP = packedExtension("xmp")
}

// MARK: - Preference

/// On/off switch for RAW+JPEG / Live Photo grouping in the browser and
/// viewer (`shrike.grouping.pairRAW`; false = "Show both
/// files"). Listed in `Prefs.Key.allKeys` so "Reset all" clears it.
public enum ImageGroupingPreference {
    public static let key = "shrike.grouping.pairRAW"

    /// Default `true`.
    public static var isEnabled: Bool {
        get {
            let defaults = ShrikeDefaults.store
            return defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
        }
        set { ShrikeDefaults.store.set(newValue, forKey: key) }
    }

    /// Options matching the current preference. Off ("Show both files")
    /// still attaches sidecars and Live Photo movies.
    public static var options: ImageGrouping.Options {
        isEnabled ? .default : .showBothFiles
    }
}

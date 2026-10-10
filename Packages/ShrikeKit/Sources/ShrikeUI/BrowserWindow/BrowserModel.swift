//
//  BrowserModel.swift
//  ShrikeUI
//
//  Data-model types shared by the browser window subsystem. Kept separate
//  from the AppKit view controllers so they can be unit-tested without a
//  running event loop.
//

import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeIO

// MARK: - BrowserItem

/// One row / cell in the browser. Backed by a `FileImageSource` for decode
/// but carries enough resource data to power sort, filter, list-mode columns,
/// and the inspector without another disk round-trip.
public struct BrowserItem: Sendable, Hashable, Identifiable {
    public let url: URL
    public let displayName: String
    public let fileSize: Int64
    public let modificationDate: Date
    public let creationDate: Date?
    /// EXIF capture date — populated lazily by the content controller after
    /// the item first becomes visible. `nil` means "not yet read".
    public var captureDate: Date?
    public let utType: UTType
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// Rating 0-5 (0 = unrated). Populated lazily from `MetadataStore`.
    public var rating: Int
    public var isFlagged: Bool
    public var tags: [String]
    /// Finder tags with colours (shown as dots).
    public var finderTags: [FinderTag] = []
    /// Shrike edited the file and kept the original (pencil).
    public var edited = false
    /// Primary + companions (RAW, sidecars, Live Photo movie).
    public var group: ImageGroup

    public var id: URL { url }

    public init(
        url: URL,
        displayName: String,
        fileSize: Int64,
        modificationDate: Date,
        creationDate: Date? = nil,
        captureDate: Date? = nil,
        utType: UTType,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        rating: Int = 0,
        isFlagged: Bool = false,
        tags: [String] = []
    ) {
        self.url = url
        self.displayName = displayName
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.captureDate = captureDate
        self.utType = utType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.rating = rating
        self.isFlagged = isFlagged
        self.tags = tags
        self.group = ImageGroup(primary: url)
    }

    /// What the cell draws.
    public var badges: ItemBadges {
        ItemBadges(rating: rating, flagged: isFlagged, tags: finderTags,
                   hasRAW: group.hasRAW, isLivePhoto: group.livePhotoMovie != nil, edited: edited)
    }

    /// Backing image source for decode + hashing (via ThumbnailCache).
    public var imageSource: FileImageSource {
        FileImageSource(url: url)
    }

    /// Best-effort construction from a URL — reads file size / mtime / ctime
    /// from `URLResourceValues`. Caller handles thrown errors if needed.
    public static func make(from url: URL) throws -> BrowserItem {
        let vals = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey,
            .typeIdentifierKey,
            .nameKey,
        ])
        let size = Int64(vals.fileSize ?? 0)
        let mtime = vals.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let ctime = vals.creationDate
        let typeID = vals.typeIdentifier
        let ut = typeID.flatMap { UTType($0) }
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data
        return BrowserItem(
            url: url,
            displayName: vals.name ?? url.lastPathComponent,
            fileSize: size,
            modificationDate: mtime,
            creationDate: ctime,
            captureDate: nil,
            utType: ut,
            pixelWidth: nil,
            pixelHeight: nil
        )
    }
}

// MARK: - View modes

public enum BrowserViewMode: Int, Sendable, CaseIterable, Hashable {
    case grid = 0
    case filmstrip = 1
    case list = 2
}

// MARK: - Sort

/// View ▸ Sort By keys, in menu order. Raw values are
/// the `shrike.browser.sortKey` pref values.
public enum BrowserSortKey: String, Sendable, Hashable, CaseIterable {
    case name
    case dateCaptured
    case dateModified
    case size
    case rating
    case kind
    case dimensions

    /// Keys whose values come from the files' headers (`SortKeyReader`),
    /// read off the main thread before the grid re-sorts.
    public var needsReading: Bool { self == .dateCaptured || self == .dimensions }
}

public enum BrowserSortDirection: String, Sendable, Hashable {
    case ascending
    case descending
}

public struct BrowserSort: Sendable, Hashable {
    public var key: BrowserSortKey
    public var direction: BrowserSortDirection

    public init(key: BrowserSortKey = .name, direction: BrowserSortDirection = .ascending) {
        self.key = key
        self.direction = direction
    }

    public static let defaultValue = BrowserSort()

    /// The saved choice (`shrike.browser.sortKey` / `sortAscending`).
    public static var saved: BrowserSort {
        BrowserSort(key: BrowserSortKey(rawValue: Prefs.browserSortKey) ?? .name,
                    direction: Prefs.browserSortAscending ? .ascending : .descending)
    }

    public func save() {
        Prefs.browserSortKey = key.rawValue
        Prefs.browserSortAscending = direction == .ascending
    }
}

// MARK: - Filter

/// Aggregate filter state. `matches(_:)` is the single source of truth for
/// inclusion in the visible item list. Composes with AND semantics.
public struct BrowserFilter: Sendable, Hashable {
    /// Rating floor. 0 disables the rating clause.
    public var minimumRating: Int
    /// If true, only flagged items pass.
    public var flaggedOnly: Bool
    /// If non-empty, items must match at least one of the UTTypes or one
    /// of the extensions. Empty set disables the format clause.
    public var formats: Set<BrowserFormatBucket>
    /// Inclusive date range applied to `modificationDate`. `nil` bounds mean
    /// "open-ended on that side".
    public var modifiedFrom: Date?
    public var modifiedTo: Date?
    /// Search term matched (case-insensitive, diacritic-insensitive) against
    /// the file name. Empty string disables.
    public var searchTerm: String
    /// Only photos with no rating (the "Unrated" rating choice).
    public var unratedOnly: Bool = false
    /// Kinds unticked in the filter popover. Empty: every kind.
    public var excludedKinds: Set<BrowserFilterKind> = []
    /// Tag match — item must contain at least one of these (if non-empty).
    public var tags: Set<String>

    public init(
        minimumRating: Int = 0,
        flaggedOnly: Bool = false,
        formats: Set<BrowserFormatBucket> = [],
        modifiedFrom: Date? = nil,
        modifiedTo: Date? = nil,
        searchTerm: String = "",
        tags: Set<String> = []
    ) {
        self.minimumRating = minimumRating
        self.flaggedOnly = flaggedOnly
        self.formats = formats
        self.modifiedFrom = modifiedFrom
        self.modifiedTo = modifiedTo
        self.searchTerm = searchTerm
        self.tags = tags
    }

    public static let none = BrowserFilter()

    /// True when no filter is actually narrowing the visible set.
    public var isEmpty: Bool {
        popoverPartIsEmpty
            && searchTerm.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// True when nothing the filter popover sets is on (its Clear button
    /// is disabled then).
    public var popoverPartIsEmpty: Bool {
        minimumRating == 0
            && !unratedOnly
            && excludedKinds.isEmpty
            && !flaggedOnly
            && formats.isEmpty
            && modifiedFrom == nil
            && modifiedTo == nil
            && tags.isEmpty
    }

    /// The popover's rating choice.
    public var ratingChoice: BrowserRatingChoice {
        get {
            if unratedOnly { return .unrated }
            return minimumRating > 0 ? .atLeast(min(minimumRating, 5)) : .any
        }
        set {
            switch newValue {
            case .any: minimumRating = 0; unratedOnly = false
            case .atLeast(let n): minimumRating = max(1, min(5, n)); unratedOnly = false
            case .unrated: minimumRating = 0; unratedOnly = true
            }
        }
    }

    public func matches(_ item: BrowserItem) -> Bool {
        if minimumRating > 0 && item.rating < minimumRating { return false }
        if unratedOnly && item.rating > 0 { return false }
        if flaggedOnly && !item.isFlagged { return false }
        // A pair matches every kind it holds (a RAW+JPEG pair is RAW and
        // JPEG), so it passes while any of its kinds is still ticked.
        if !formats.isEmpty {
            var buckets: Set<BrowserFormatBucket> = [BrowserFormatBucket.bucket(for: item.utType)]
            if item.group.hasRAW { buckets.insert(.raw) }
            if buckets.isDisjoint(with: formats) { return false }
        }
        if !excludedKinds.isEmpty, BrowserFilterKind.kinds(of: item).isSubset(of: excludedKinds) {
            return false
        }
        if let from = modifiedFrom, item.modificationDate < from { return false }
        if let to = modifiedTo, item.modificationDate > to { return false }
        let trimmed = searchTerm.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !Self.fuzzyContains(item.displayName, needle: trimmed) {
            return false
        }
        if !tags.isEmpty {
            let intersect = tags.intersection(Set(item.tags))
            if intersect.isEmpty { return false }
        }
        return true
    }

    // Case + diacritic insensitive substring search.
    private static func fuzzyContains(_ haystack: String, needle: String) -> Bool {
        haystack.range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
    }
}

// MARK: - Filter popover choices

/// The Rating popup: Any, 1 star or more … 4 stars or more, 5 stars, Unrated.
public enum BrowserRatingChoice: Sendable, Hashable {
    case any
    case atLeast(Int)
    case unrated

    public static let menuOrder: [BrowserRatingChoice] =
        [.any, .atLeast(1), .atLeast(2), .atLeast(3), .atLeast(4), .atLeast(5), .unrated]

    public var title: String {
        switch self {
        case .any: return "Any"
        case .atLeast(5): return "5 stars"
        case .atLeast(1): return "1 star or more"
        case .atLeast(let n): return "\(n) stars or more"
        case .unrated: return "Unrated"
        }
    }
}

/// The popover's Kind boxes.
public enum BrowserFilterKind: String, Sendable, Hashable, CaseIterable {
    case jpeg, heic, png, raw, other

    public var title: String {
        switch self {
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .png: return "PNG"
        case .raw: return "RAW"
        case .other: return "Other"
        }
    }

    /// Every kind the shot holds: its display file's, plus RAW for a pair.
    public static func kinds(of item: BrowserItem) -> Set<BrowserFilterKind> {
        let own: BrowserFilterKind
        switch BrowserFormatBucket.bucket(for: item.utType) {
        case .jpeg: own = .jpeg
        case .heic: own = .heic
        case .png: own = .png
        case .raw: own = .raw
        default: own = .other
        }
        return item.group.hasRAW ? [own, .raw] : [own]
    }
}

// MARK: - Format buckets

/// Coarse file-format buckets we expose in the filter UI. The UT hierarchy
/// is noisy; users think in these terms.
public enum BrowserFormatBucket: String, Sendable, Hashable, CaseIterable, Codable {
    case jpeg
    case heic
    case png
    case tiff
    case gif
    case webp
    case raw
    case psd
    case pdf
    case other

    public static func bucket(for ut: UTType) -> BrowserFormatBucket {
        if ut.conforms(to: .jpeg)  { return .jpeg }
        if ut.conforms(to: .heic)  { return .heic }
        if ut.conforms(to: .heif)  { return .heic }
        if ut.conforms(to: .png)   { return .png }
        if ut.conforms(to: .tiff)  { return .tiff }
        if ut.conforms(to: .gif)   { return .gif }
        if ut.conforms(to: .webP)  { return .webp }
        if ut.conforms(to: .rawImage) { return .raw }
        if ut.conforms(to: .pdf)   { return .pdf }
        // PSD has no canonical UTI constant; check the identifier directly.
        if ut.identifier == "com.adobe.photoshop-image" { return .psd }
        return .other
    }

    public var displayName: String {
        switch self {
        case .jpeg:  return "JPEG"
        case .heic:  return "HEIC"
        case .png:   return "PNG"
        case .tiff:  return "TIFF"
        case .gif:   return "GIF"
        case .webp:  return "WebP"
        case .raw:   return "RAW"
        case .psd:   return "PSD"
        case .pdf:   return "PDF"
        case .other: return "Other"
        }
    }
}

// MARK: - Natural sort

/// Public so the grid data source and list sort comparator share it.
public enum BrowserNaturalSort {

    /// `.numeric + .caseInsensitive + .diacriticInsensitive` comparison.
    /// `"image2.jpg" < "image10.jpg"` — matches Finder / NSNumericSearch.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [.numeric, .caseInsensitive, .diacriticInsensitive])
    }
}

// MARK: - Pipeline

/// Pure function: apply `filter`, then `sort`, to a slice of items.
///
/// Stateless by design — unit tests supply synthetic `BrowserItem` arrays
/// and assert on ordering. The view controller calls this whenever the user
/// tweaks filters / sort keys.
public enum BrowserPipeline {

    public static func filterAndSort(
        _ items: [BrowserItem],
        filter: BrowserFilter,
        sort: BrowserSort,
        values: [URL: SortValue]? = nil
    ) -> [BrowserItem] {
        let filtered = filter.isEmpty
            ? items
            : items.filter(filter.matches)
        return apply(sort: sort, to: filtered, values: values)
    }

    /// `items` in Finder name order (`localizedStandardCompare`). A list
    /// already in that order (the usual case: folder listings are ordered
    /// off the main thread) costs one pass of comparisons.
    public static func nameOrdered(_ items: [BrowserItem]) -> [BrowserItem] {
        var ordered = true
        var index = items.startIndex + 1
        while index < items.endIndex {
            if items[index - 1].displayName.localizedStandardCompare(items[index].displayName) == .orderedDescending {
                ordered = false
                break
            }
            index += 1
        }
        if ordered { return items }
        return items.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Sorts by `sort`. Ties break by name, ascending, in
    /// both directions; a missing value goes last. `values` are the values
    /// read for Date Captured / Dimensions, by primary URL.
    ///
    /// Each item gets one number up front and the sort compares numbers
    /// and name ranks only: 5,000 items sort in a few milliseconds.
    public static func apply(sort: BrowserSort, to items: [BrowserItem],
                             values: [URL: SortValue]? = nil) -> [BrowserItem] {
        let ordered = nameOrdered(items)
        let asc = sort.direction == .ascending
        if sort.key == .name { return asc ? ordered : ordered.reversed() }
        let keys = sortNumbers(sort.key, for: ordered, values: values)
        let indices = ordered.indices.sorted { a, b in
            switch (keys[a], keys[b]) {
            case let (x?, y?) where x != y: return asc ? x < y : x > y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a < b
            }
        }
        return indices.map { ordered[$0] }
    }

    /// One comparable number per item; nil = missing.
    static func sortNumbers(_ key: BrowserSortKey, for items: [BrowserItem],
                            values: [URL: SortValue]?) -> [Double?] {
        func read(_ item: BrowserItem) -> SortValue? { values?[item.group.primary] }
        switch key {
        case .name:
            return items.indices.map { Double($0) }
        case .dateModified:
            return items.map { $0.modificationDate.timeIntervalSinceReferenceDate }
        case .dateCaptured:
            // EXIF capture date; the file's creation date when it has none.
            return items.map { item in
                switch read(item) {
                case .date(let d)?: return d.timeIntervalSinceReferenceDate
                case .missing?: return nil
                default: return (item.captureDate ?? item.creationDate)?.timeIntervalSinceReferenceDate
                }
            }
        case .size:
            return items.map { Double($0.fileSize) }
        case .rating:
            return items.map { Double($0.rating) }
        case .kind:
            // `localizedDescription` once per type, ranked in Finder order.
            var names: [String: String] = [:]
            let kinds = items.map { item -> String in
                if let known = names[item.utType.identifier] { return known }
                let name = item.utType.localizedDescription ?? item.utType.identifier
                names[item.utType.identifier] = name
                return name
            }
            let ranks = Dictionary(uniqueKeysWithValues: Set(kinds)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .enumerated().map { ($1, Double($0)) })
            return kinds.map { ranks[$0] }
        case .dimensions:
            // Pixel count; 0 when unknown.
            return items.map { item in
                if case .number(let n)? = read(item) { return Double(n) }
                return Double((item.pixelWidth ?? 0) * (item.pixelHeight ?? 0))
            }
        }
    }
}

// MARK: - Folder selection

/// Lightweight snapshot passed from `FolderTreeViewController` to the content
/// pane. Not strictly necessary today but keeps the API forward-compatible
/// for search scopes / smart folders / multi-root bookmarks.
public struct FolderSelection: Sendable, Hashable {
    public let url: URL
    public let displayName: String

    public init(url: URL) {
        self.url = url.standardizedFileURL
        self.displayName = url.lastPathComponent
    }
}

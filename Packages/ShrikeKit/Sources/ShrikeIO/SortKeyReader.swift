//
//  SortKeyReader.swift
//  ShrikeIO
//
//  Values for View ▸ Sort By, read
//  off the main thread in batches of 500 groups, keyed by primary URL.
//
//    name          primary's file name (Finder-like comparison)
//    dateCaptured  EXIF DateTimeOriginal (with offset); else file creation date
//    dateModified  contentModificationDate
//    size          file size of the primary
//    rating        MetadataStore rating; 0 when unrated
//    kind          UTType.localizedDescription
//    dimensions    pixel count (w × h)
//
//  Capture date and pixel size come from the header only (no decode) and
//  are cached in `MetadataStore` by canonical path + modification date, so
//  sorting the same folder again does not open the files.
//
//  Cancellation: cancelling the consuming task (or dropping the stream)
//  stops at the next batch boundary.
//

import Foundation
import UniformTypeIdentifiers
import ShrikeCore

public enum SortKey: String, Sendable, CaseIterable, Codable {
    case name, dateCaptured, dateModified, size, rating, kind, dimensions

    /// Keys whose values need a file read (header or database).
    public var needsReading: Bool {
        switch self {
        case .dateCaptured, .dimensions, .rating: return true
        default: return false
        }
    }
}

/// A sortable value. `<` is the ascending order: text by
/// `localizedStandardCompare` (Finder order: "IMG_2" < "IMG_10"), numbers
/// and dates numerically, and `.missing` after everything else.
public enum SortValue: Sendable, Hashable, Comparable {
    case text(String)
    case date(Date)
    case number(Int64)
    case missing

    public static func < (a: SortValue, b: SortValue) -> Bool {
        switch (a, b) {
        case let (.text(x), .text(y)): return x.localizedStandardCompare(y) == .orderedAscending
        case let (.date(x), .date(y)): return x < y
        case let (.number(x), .number(y)): return x < y
        case (.missing, _): return false
        case (_, .missing): return true
        default: return a.rank < b.rank
        }
    }

    public var isMissing: Bool { self == .missing }

    private var rank: Int {
        switch self {
        case .text: return 0
        case .date: return 1
        case .number: return 2
        case .missing: return 3
        }
    }
}

public actor SortKeyReader {

    public static let batchSize = 500
    /// Header reads in flight at once (they are I/O-bound, ~1–4 ms each).
    static let headerReadWidth = 8

    private let metadata: MetadataStore?

    /// - Parameter metadata: rating source and header cache. Nil reads
    ///   ratings from the files' extended attributes and caches nothing.
    public init(metadata: MetadataStore?) {
        self.metadata = metadata
    }

    /// Values of `key` for every group's primary, in batches of up to 500.
    public func values(for groups: [ImageGroup], key: SortKey) -> AsyncStream<[URL: SortValue]> {
        let urls = groups.map(\.primary)
        let metadata = self.metadata
        return AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                var start = 0
                while start < urls.count {
                    if Task.isCancelled { break }
                    let batch = Array(urls[start..<min(start + Self.batchSize, urls.count)])
                    start += Self.batchSize
                    let values = await Self.read(batch, key: key, metadata: metadata)
                    if Task.isCancelled { break }
                    continuation.yield(values)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sorts `groups` by `values` (keyed by primary URL). Missing values go
    /// last in both directions; ties break by name, ascending.
    public nonisolated static func sorted(_ groups: [ImageGroup], by values: [URL: SortValue],
                                          ascending: Bool) -> [ImageGroup] {
        let keyed = groups.map { ($0, values[$0.primary] ?? .missing, $0.primary.lastPathComponent) }
        return keyed.sorted { a, b in
            if a.1 != b.1 {
                if a.1.isMissing != b.1.isMissing { return b.1.isMissing }
                if ascending ? a.1 < b.1 : b.1 < a.1 { return true }
                if ascending ? b.1 < a.1 : a.1 < b.1 { return false }
            }
            return a.2.localizedStandardCompare(b.2) == .orderedAscending
        }.map(\.0)
    }

    // MARK: - Reading

    private static func read(_ urls: [URL], key: SortKey, metadata: MetadataStore?) async -> [URL: SortValue] {
        var out: [URL: SortValue] = [:]
        out.reserveCapacity(urls.count)
        switch key {
        case .name:
            for url in urls { out[url] = .text(url.lastPathComponent) }
        case .dateModified:
            for url in urls {
                let d = try? Self.fresh(url).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                out[url] = d.map(SortValue.date) ?? .missing
            }
        case .size:
            for url in urls {
                let s = try? Self.fresh(url).resourceValues(forKeys: [.fileSizeKey]).fileSize
                out[url] = s.map { .number(Int64($0)) } ?? .missing
            }
        case .kind:
            for url in urls {
                let type = try? Self.fresh(url).resourceValues(forKeys: [.contentTypeKey]).contentType
                out[url] = type?.localizedDescription.map(SortValue.text) ?? .missing
            }
        case .rating:
            if let metadata {
                let records = await metadata.records(for: urls)
                for url in urls { out[url] = .number(Int64(records[url]?.rating ?? 0)) }
            } else {
                for url in urls { out[url] = .number(Int64(FileAttributes.rating(at: url) ?? 0)) }
            }
        case .dateCaptured, .dimensions:
            let headers = await headers(for: urls, metadata: metadata)
            for url in urls {
                let h = headers[url]
                if key == .dimensions {
                    if let w = h?.info.pixelWidth, let hh = h?.info.pixelHeight, w > 0, hh > 0 {
                        out[url] = .number(Int64(w) * Int64(hh))
                    } else {
                        out[url] = .missing
                    }
                } else if let date = h?.info.dateCaptured {
                    out[url] = .date(date)
                } else if let created = h?.created {
                    out[url] = .date(created)
                } else {
                    out[url] = .missing
                }
            }
        }
        return out
    }

    /// A new URL object for `url`. Resource values are cached per URL
    /// object (and only dropped when a run loop turns), so the grid's
    /// long-lived URLs can report an old modification date or size.
    private static func fresh(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path, isDirectory: false)
    }

    private struct Header: Sendable {
        var info: ImageHeaderInfo
        var created: Date?
    }

    /// Header values from the cache, reading (and caching) the rest.
    private static func headers(for urls: [URL], metadata: MetadataStore?) async -> [URL: Header] {
        var dates: [URL: (modified: Date, created: Date?)] = [:]
        for url in urls {
            guard let v = try? Self.fresh(url).resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]),
                  let modified = v.contentModificationDate else { continue }
            dates[url] = (modified, v.creationDate)
        }
        var result: [URL: Header] = [:]
        let cached = await metadata?.cachedHeaders(for: dates.mapValues(\.modified)) ?? [:]
        for (url, info) in cached { result[url] = Header(info: info, created: dates[url]?.created) }

        let toRead = urls.filter { dates[$0] != nil && cached[$0] == nil }
        guard !toRead.isEmpty else { return result }
        let fresh = await withTaskGroup(of: (URL, ImageHeaderInfo).self) { group in
            var out: [URL: ImageHeaderInfo] = [:]
            var next = 0
            func add() {
                let url = toRead[next]
                next += 1
                group.addTask { (url, ImageHeaderInfo.read(url) ?? ImageHeaderInfo()) }
            }
            while next < min(headerReadWidth, toRead.count) { add() }
            for await (url, info) in group {
                out[url] = info
                if next < toRead.count, !Task.isCancelled { add() }
            }
            return out
        }
        for (url, info) in fresh { result[url] = Header(info: info, created: dates[url]?.created) }
        // Unreadable files are cached too (all nil), so they aren't retried.
        if let metadata, !Task.isCancelled {
            var store: [URL: (modified: Date, info: ImageHeaderInfo)] = [:]
            for (url, info) in fresh { if let m = dates[url]?.modified { store[url] = (m, info) } }
            await metadata.storeHeaders(store)
        }
        return result
    }
}

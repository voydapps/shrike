//
//  PhotoInfoCache.swift
//  ShrikeUI
//
//  Header reads (`PhotoInfo`) of the files selected lately in the Browser.
// A photo seen before fills the inspector's
//  Capture rows and the status bar's size in the click's own turn, with
//  no file read and no second publish. A failed read is kept too (as nil),
//  so a file with no header never waits again.
//
//  An entry is only used while the listing still shows the same file: the
//  modification date and the size must match the item. The Browser also
//  drops entries for files the watcher saw change.
//

import Foundation
import ShrikeCore

@MainActor
final class PhotoInfoCache {

    /// About one screen of recent clicks.
    static let defaultCapacity = 64

    enum Lookup: Equatable {
        /// Read before: the info (nil = the file has no readable header).
        case hit(PhotoInfo?)
        case miss
    }

    private struct Entry {
        let modified: Date
        let size: Int64
        let info: PhotoInfo?
    }

    private let capacity: Int
    private var entries: [URL: Entry] = [:]
    /// Oldest first.
    private var order: [URL] = []

    init(capacity: Int = PhotoInfoCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    var count: Int { entries.count }

    func lookup(_ item: BrowserItem) -> Lookup {
        guard let entry = entries[item.url] else { return .miss }
        guard entry.modified == item.modificationDate, entry.size == item.fileSize else {
            remove(item.url)
            return .miss
        }
        touch(item.url)
        return .hit(entry.info)
    }

    func store(_ info: PhotoInfo?, for item: BrowserItem) {
        entries[item.url] = Entry(modified: item.modificationDate, size: item.fileSize, info: info)
        touch(item.url)
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries[oldest] = nil
        }
    }

    /// The watcher saw these files change (or go away).
    func invalidate<S: Sequence>(_ urls: S) where S.Element == URL {
        for url in urls {
            remove(url)
            let std = url.standardizedFileURL
            if std != url { remove(std) }
        }
    }

    func removeAll() {
        entries.removeAll()
        order.removeAll()
    }

    private func remove(_ url: URL) {
        guard entries.removeValue(forKey: url) != nil else { return }
        order.removeAll { $0 == url }
    }

    private func touch(_ url: URL) {
        if let i = order.firstIndex(of: url) { order.remove(at: i) }
        order.append(url)
    }
}

extension PhotoInfo {
    /// The pixel size the header gave, when it gave both sides.
    var headerSize: (width: Int, height: Int)? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return (pixelWidth, pixelHeight)
    }
}

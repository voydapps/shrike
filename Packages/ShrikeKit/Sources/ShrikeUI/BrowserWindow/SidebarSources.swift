//
//  SidebarSources.swift
//  ShrikeUI
//
//  Where the Browser sidebar's Favorites and Locations come from.
//
//  - `FavoritesStore` keeps `shrike.browser.favorites`: a JSON array of
//    `{ "path": String, "bookmark": Data }`. The first launch seeds
//    Pictures, Desktop and Downloads by PATH ONLY: nothing lists or reads
//    those folders (a read of Desktop / Downloads fires the "Shrike would
//    like to access…" privacy prompt). A bookmark is made when the user
//    adds a folder, and only resolved when the saved path is gone.
//  - `VolumeSource` lists mounted volumes and ejects them. Tests inject a
//    fixed list and a fake ejector, so they never eject a real disk.
//

import AppKit
import ShrikeCore

// MARK: - Favorites

/// One saved favorite, as stored in `shrike.browser.favorites`.
public struct SidebarFavorite: Codable, Equatable, Sendable {
    public var path: String
    public var bookmark: Data

    public init(path: String, bookmark: Data = Data()) {
        self.path = path
        self.bookmark = bookmark
    }

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// A favorite as the sidebar shows it: where it is now, and whether it is
/// there at all (a disconnected disk → 50 % row, "Not available").
public struct SidebarFavoriteRow: Equatable, Sendable {
    public var url: URL
    public var isMissing: Bool
}

@MainActor
public final class FavoritesStore {

    private let load: () -> Data?
    private let save: (Data?) -> Void
    private let seed: () -> [URL]
    private let exists: (URL) -> Bool

    public init(
        load: @escaping () -> Data?,
        save: @escaping (Data?) -> Void,
        seed: @escaping () -> [URL],
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.load = load
        self.save = save
        self.seed = seed
        self.exists = exists
    }

    /// The app's store (`Prefs.browserFavoritesData`). Under XCTest it is an
    /// empty in-memory store with no seed, so tests never see or touch the
    /// user's Pictures / Desktop / Downloads.
    public static func standard() -> FavoritesStore {
        if ShrikeDataPaths.isRunningTests { return inMemory() }
        return FavoritesStore(
            load: { Prefs.browserFavoritesData },
            save: { Prefs.browserFavoritesData = $0 },
            seed: {
                let fm = FileManager.default
                let dirs: [FileManager.SearchPathDirectory] = [.picturesDirectory, .desktopDirectory, .downloadsDirectory]
                return dirs.compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            }
        )
    }

    /// A store kept in memory (tests).
    public static func inMemory(_ initial: [SidebarFavorite]? = nil, seed: [URL] = []) -> FavoritesStore {
        final class Box { var data: Data? }
        let box = Box()
        if let initial { box.data = try? JSONEncoder().encode(initial) }
        return FavoritesStore(load: { box.data }, save: { box.data = $0 }, seed: { seed })
    }

    /// The saved list. The first call on a fresh install seeds it with the
    /// seed folders that exist (a `stat`, never a listing).
    public func favorites() -> [SidebarFavorite] {
        if let data = load() {
            return (try? JSONDecoder().decode([SidebarFavorite].self, from: data)) ?? []
        }
        let seeded = seed().filter(exists).map { SidebarFavorite(path: $0.standardizedFileURL.path) }
        write(seeded)
        return seeded
    }

    /// Rows for the sidebar: the saved path when it exists; otherwise the
    /// bookmark's new place (a moved folder), else a missing row.
    public func rows() -> [SidebarFavoriteRow] {
        var list = favorites()
        var changed = false
        let rows = list.indices.map { i -> SidebarFavoriteRow in
            let url = list[i].url
            if exists(url) { return SidebarFavoriteRow(url: url, isMissing: false) }
            if let moved = Self.resolve(list[i].bookmark), exists(moved) {
                list[i].path = moved.standardizedFileURL.path
                changed = true
                return SidebarFavoriteRow(url: moved, isMissing: false)
            }
            return SidebarFavoriteRow(url: url, isMissing: true)
        }
        if changed { write(list) }
        return rows
    }

    /// Adds `url` at `index` (the end by default). A folder already in the
    /// list is not added twice. Returns false when it was already there.
    @discardableResult
    public func add(_ url: URL, at index: Int? = nil) -> Bool {
        var list = favorites()
        let path = url.standardizedFileURL.path
        guard !list.contains(where: { $0.path == path }) else { return false }
        let bookmark = (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        let at = min(max(index ?? list.count, 0), list.count)
        list.insert(SidebarFavorite(path: path, bookmark: bookmark), at: at)
        write(list)
        return true
    }

    public func remove(at index: Int) {
        var list = favorites()
        guard list.indices.contains(index) else { return }
        list.remove(at: index)
        write(list)
    }

    /// Moves the favorite at `from` so it lands before the row that was at
    /// `to` (outline-view drop index semantics).
    public func move(from: Int, to: Int) {
        var list = favorites()
        guard list.indices.contains(from) else { return }
        let item = list.remove(at: from)
        let target = to > from ? to - 1 : to
        list.insert(item, at: min(max(target, 0), list.count))
        write(list)
    }

    private func write(_ list: [SidebarFavorite]) {
        save(try? JSONEncoder().encode(list))
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

// MARK: - Volumes

/// One mounted volume under Locations.
public struct SidebarVolume: Equatable, Sendable {
    public enum Kind: Sendable, Equatable { case removable, external, `internal` }
    public var url: URL
    public var name: String
    public var kind: Kind
    public var isEjectable: Bool

    public init(url: URL, name: String, kind: Kind, isEjectable: Bool) {
        self.url = url
        self.name = name
        self.kind = kind
        self.isEjectable = isEjectable
    }

    /// Row symbols.
    public var symbolName: String {
        switch kind {
        case .removable: return "sdcard"
        case .external: return "externaldrive"
        case .internal: return "internaldrive"
        }
    }

    /// Removable volumes first, the rest in the system's order.
    public static func ordered(_ volumes: [SidebarVolume]) -> [SidebarVolume] {
        volumes.filter { $0.kind == .removable } + volumes.filter { $0.kind != .removable }
    }
}

/// Lists and ejects volumes. `eject` runs OFF the main thread (an eject can
/// block for seconds while the disk flushes).
public struct VolumeSource: Sendable {
    public var list: @Sendable () -> [SidebarVolume]
    public var eject: @Sendable (URL) throws -> Void

    public init(list: @escaping @Sendable () -> [SidebarVolume],
                eject: @escaping @Sendable (URL) throws -> Void) {
        self.list = list
        self.eject = eject
    }

    /// The Mac's mounted, visible volumes (a volume list and `statfs`, no
    /// folder reads).
    public static let system = VolumeSource(
        list: {
            let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsRemovableKey,
                                          .volumeIsInternalKey, .volumeIsEjectableKey]
            let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                             options: [.skipHiddenVolumes]) ?? []
            let volumes = urls.compactMap { url -> SidebarVolume? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let kind: SidebarVolume.Kind = values.volumeIsRemovable == true
                    ? .removable
                    : (values.volumeIsInternal == true ? .internal : .external)
                return SidebarVolume(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                                     kind: kind, isEjectable: values.volumeIsEjectable == true || values.volumeIsRemovable == true)
            }
            return SidebarVolume.ordered(volumes)
        },
        eject: { url in try NSWorkspace.shared.unmountAndEjectDevice(at: url) }
    )

    /// No volumes, eject never called (tests of other features).
    public static let none = VolumeSource(list: { [] }, eject: { _ in })
}

/// Sidebar copy.
enum SidebarCopy {
    static let notAvailableTooltip = "Not available"
    static func notAvailable(_ name: String) -> String {
        "“\(name)” is not available. The disk may be disconnected."
    }
    static func ejectFailed(_ name: String) -> String {
        "Couldn't eject “\(name)”. A file on it may be in use."
    }
    static func ejectLabel(_ name: String) -> String { "Eject \(name)" }
    static func ejectMenu(_ name: String) -> String { "Eject “\(name)”" }
    static let openInNewWindow = "Open in New Window"
    static let copyPath = "Copy Path"
    static let newFolder = "New Folder…"
    static let cantReadTooltip = "Shrike can't read this folder."
    static func cantRead(_ name: String) -> String { "Shrike can't read “\(name)”." }
    // VoiceOver
    static let voiceOverName = "Sidebar"
    static let currentFolderValue = "current folder"
    static let hiddenValue = "hidden"
    static let cantReadValue = "can't read"
}

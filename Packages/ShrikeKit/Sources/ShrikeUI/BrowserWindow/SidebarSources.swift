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
    private let exists: @Sendable (URL) -> Bool

    public init(
        load: @escaping () -> Data?,
        save: @escaping (Data?) -> Void,
        seed: @escaping () -> [URL],
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
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
    /// bookmark's new place (a moved folder), else a missing row. Checks the
    /// disk on the calling thread: UI code uses `uncheckedRows()` and
    /// `checkedRows()` instead.
    public func rows() -> [SidebarFavoriteRow] {
        let list = favorites()
        let result = Self.check(list, exists: exists)
        if let updated = result.updated { write(updated) }
        return result.rows
    }

    /// The saved list as rows, every folder shown as present. Reads stored
    /// data only: no disk access. `isMissing` can be carried over from
    /// what the sidebar showed before, so a rebuild does not flash.
    public func uncheckedRows(knownMissing: Set<String> = []) -> [SidebarFavoriteRow] {
        favorites().map { SidebarFavoriteRow(url: $0.url, isMissing: knownMissing.contains($0.url.standardizedFileURL.path)) }
    }

    /// What `checkedRows()` found: the rows, and the list to save when a
    /// moved folder was found through its bookmark (with the list that was
    /// checked, so a later change of the saved list is not overwritten).
    public struct Checked: Sendable {
        public var rows: [SidebarFavoriteRow]
        var checked: [SidebarFavorite]
        var updated: [SidebarFavorite]?
    }

    /// The same rows as `rows()`, with every `stat` and bookmark lookup off
    /// the main thread (a sleeping network share can block for seconds).
    public func checkedRows() async -> Checked {
        let list = favorites()
        let exists = self.exists
        return await Task.detached(priority: .userInitiated) { Self.check(list, exists: exists) }.value
    }

    /// Saves the moved paths of a check, when the saved list is still the one
    /// that was checked (a favorite added meanwhile is never lost).
    /// Returns false when the list changed: the caller checks again.
    @discardableResult
    func commit(_ result: Checked) -> Bool {
        guard favorites() == result.checked else { return false }
        if let updated = result.updated { write(updated) }
        return true
    }

    nonisolated static func check(_ saved: [SidebarFavorite], exists: @Sendable (URL) -> Bool) -> Checked {
        var list = saved
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
        return Checked(rows: rows, checked: saved, updated: changed ? list : nil)
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

    nonisolated static func resolve(_ bookmark: Data) -> URL? {
        guard !bookmark.isEmpty else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}

// MARK: - Workspace

extension Notification.Name {
    /// The Workspace was set or cleared; every open sidebar rebuilds.
    static let shrikeWorkspaceDidChange = Notification.Name("app.shrike.workspaceDidChange")
}

/// The Workspace as the sidebar shows it: where it is now and whether it
/// is there at all.
public struct SidebarWorkspaceRow: Equatable, Sendable {
    public var url: URL
    public var isMissing: Bool
    public var title: String { url.lastPathComponent }
}

/// The one pinned folder. Stored as one JSON object
/// `{ "path", "bookmark" }` in `shrike.browser.workspace`; the bookmark only
/// finds a moved folder (Shrike is not sandboxed, so no security scope).
@MainActor
public final class WorkspaceStore {

    private let load: () -> Data?
    private let save: (Data?) -> Void
    private let exists: @Sendable (URL) -> Bool

    public init(
        load: @escaping () -> Data?,
        save: @escaping (Data?) -> Void,
        exists: @escaping @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) {
        self.load = load
        self.save = save
        self.exists = exists
    }

    /// Backed by `Prefs.browserWorkspaceData` (so `ShrikeDefaults.store`).
    public static func prefsBacked() -> WorkspaceStore {
        WorkspaceStore(load: { Prefs.browserWorkspaceData }, save: { Prefs.browserWorkspaceData = $0 })
    }

    /// The app's store. Under XCTest it is an empty in-memory store.
    public static func standard() -> WorkspaceStore {
        ShrikeDataPaths.isRunningTests ? inMemory() : prefsBacked()
    }

    /// A store kept in memory (tests).
    public static func inMemory(_ initial: SidebarFavorite? = nil) -> WorkspaceStore {
        final class Box { var data: Data? }
        let box = Box()
        if let initial { box.data = try? JSONEncoder().encode(initial) }
        return WorkspaceStore(load: { box.data }, save: { box.data = $0 })
    }

    /// True when a Workspace is saved. One defaults read: nothing is
    /// resolved or touched on disk (the launch path calls this).
    public var isSet: Bool { load() != nil }

    public func saved() -> SidebarFavorite? {
        guard let data = load() else { return nil }
        return try? JSONDecoder().decode(SidebarFavorite.self, from: data)
    }

    /// The Workspace as the sidebar shows it: the saved path when it is
    /// there; otherwise the bookmark's new place (renamed or moved; saved,
    /// no message), else a missing row. A bookmark that now points into the
    /// Trash counts as missing. Nil when none is set. Checks the disk on the
    /// calling thread: the sidebar uses `uncheckedRow()` / `checkedRow()`.
    public func row() -> SidebarWorkspaceRow? {
        guard let saved = saved() else { return nil }
        let result = Self.check(saved, exists: exists)
        if let updated = result.updated { write(updated) }
        return result.row
    }

    /// The saved Workspace as a present row: stored data only, no disk.
    public func uncheckedRow(knownMissing: Bool = false) -> SidebarWorkspaceRow? {
        saved().map { SidebarWorkspaceRow(url: $0.url, isMissing: knownMissing) }
    }

    public struct Checked: Sendable {
        public var row: SidebarWorkspaceRow?
        var checked: SidebarFavorite?
        var updated: SidebarFavorite?
    }

    /// The same row as `row()`, checked off the main thread.
    public func checkedRow() async -> Checked {
        let saved = saved()
        let exists = self.exists
        return await Task.detached(priority: .userInitiated) { Self.check(saved, exists: exists) }.value
    }

    /// Saves a moved path when the saved Workspace is still the checked one.
    /// False when it changed meanwhile: the caller checks again.
    @discardableResult
    func commit(_ result: Checked) -> Bool {
        guard saved() == result.checked else { return false }
        if let updated = result.updated { write(updated) }
        return true
    }

    nonisolated static func check(_ saved: SidebarFavorite?, exists: @Sendable (URL) -> Bool) -> Checked {
        guard var value = saved else { return Checked(row: nil, checked: nil, updated: nil) }
        let url = value.url
        if exists(url) { return Checked(row: SidebarWorkspaceRow(url: url, isMissing: false), checked: saved, updated: nil) }
        if let moved = FavoritesStore.resolve(value.bookmark), exists(moved),
           !moved.standardizedFileURL.pathComponents.contains(".Trash") {
            value.path = moved.standardizedFileURL.path
            return Checked(row: SidebarWorkspaceRow(url: moved, isMissing: false), checked: saved, updated: value)
        }
        return Checked(row: SidebarWorkspaceRow(url: url, isMissing: true), checked: saved, updated: nil)
    }

    /// Makes `url` the Workspace (replacing any other). False for "/".
    @discardableResult
    public func set(_ url: URL) -> Bool {
        let std = url.standardizedFileURL
        guard std.path != "/" else { return false }
        let bookmark = (try? std.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)) ?? Data()
        write(SidebarFavorite(path: std.path, bookmark: bookmark))
        return true
    }

    public func clear() {
        save(nil)
        NotificationCenter.default.post(name: .shrikeWorkspaceDidChange, object: nil)
    }

    private func write(_ value: SidebarFavorite) {
        save(try? JSONEncoder().encode(value))
        NotificationCenter.default.post(name: .shrikeWorkspaceDidChange, object: nil)
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
    /// What the sidebar shows before `list` has run off the main thread.
    /// Must not touch the disk. The system source has nothing to show yet;
    /// an injected list (tests) is plain data, so it is used as is.
    public var initial: @Sendable () -> [SidebarVolume]
    /// True while `initial` is only a placeholder for `list`.
    public var initialIsPlaceholder: Bool

    public init(list: @escaping @Sendable () -> [SidebarVolume],
                eject: @escaping @Sendable (URL) throws -> Void,
                initial: (@Sendable () -> [SidebarVolume])? = nil) {
        self.list = list
        self.eject = eject
        self.initial = initial ?? list
        self.initialIsPlaceholder = initial != nil
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
        eject: { url in try NSWorkspace.shared.unmountAndEjectDevice(at: url) },
        initial: { [] }
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
    static let setAsWorkspace = "Set as Workspace"
    static let clearWorkspace = "Clear Workspace"
    static let workspaceHeader = "Workspace"
    static let workspaceValue = "Workspace"
    static func workspaceIs(_ name: String) -> String { "Workspace is now “\(name)”." }
    static let workspaceCleared = "Workspace cleared."
    static let workspaceUnavailable = "The Workspace isn't available."
    static func workspaceFolderUnavailable(_ name: String) -> String { "“\(name)” isn't available." }
    static func workspaceNamedUnavailable(_ name: String) -> String { "Workspace “\(name)” isn't available." }
    static let chooseSmallerFolder = "Choose a smaller folder."
    static let cantReadTooltip = "Shrike can't read this folder."
    static func cantRead(_ name: String) -> String { "Shrike can't read “\(name)”." }
    // VoiceOver
    static let voiceOverName = "Sidebar"
    static let currentFolderValue = "current folder"
    static let hiddenValue = "hidden"
    static let cantReadValue = "can't read"
}

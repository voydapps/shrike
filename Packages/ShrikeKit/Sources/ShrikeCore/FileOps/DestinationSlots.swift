//
//  DestinationSlots.swift
//  ShrikeCore
//
//  The nine Copy/Move destination folders
//  (keys 1–9 in the Copy/Move HUD, File ▸ Copy to Folder ▸, the sidebar's
//  "Set as Destination ▸") and the last folder used per verb ("C C",
//  "M M").
//
//  Storage:
//    * `shrike.fileops.destinations` — JSON array of 9 entries
//      `{ "path": String?, "bookmark": Data?, "name": String? }`. `name` is
//      an extra: the Finder display name captured when the
//      slot is set, so menus never touch the disk.
//    * `shrike.fileops.lastCopy` / `shrike.fileops.lastMove` — plain
//      bookmark data.
//  Bookmarks are not security-scoped (the app is not sandboxed). They follow
//  a folder that was renamed or moved on the same volume.
//
//  Resolving never shows UI and never mounts a volume
//  (`.withoutUI`, `.withoutMounting`): an unplugged disk is reported as
//  `.unavailable`, and the UI shows the missing-destination alert.
//

import Foundation

/// Copy or Move — the two verbs that remember a last destination.
public enum FileVerb: String, Sendable, Hashable, CaseIterable, Codable {
    case copy
    case move
}

/// One set slot, as shown in menus ("1  Selects").
public struct DestinationSlot: Sendable, Hashable {
    /// 1–9, the key that runs it.
    public let number: Int
    /// The folder as last stored. Call `DestinationSlots.resolve(_:)` before
    /// using it: the folder may have moved or its disk may be unplugged.
    public let url: URL
    /// Finder display name of the folder.
    public let name: String

    public init(number: Int, url: URL, name: String) {
        self.number = number
        self.url = url
        self.name = name
    }
}

public enum DestinationSlotError: Error, Sendable, Hashable {
    /// Slot `number` has no folder (or `number` is not 1–9).
    case empty(Int)
    /// The folder can't be found — usually a disconnected disk. `name` fills
    /// the missing-destination alert: "“Client” is not available."
    case unavailable(name: String)
}

/// The nine destination slots plus the last folder used for Copy and Move.
/// Cheap value type; every call reads `UserDefaults` (thread-safe), so it can
/// be used from any thread.
public struct DestinationSlots: Sendable {

    /// Number of slots (keys 1–9).
    public static let count = 9
    public static let numbers = 1...count

    public enum Key {
        public static let destinations = "shrike.fileops.destinations"
        public static let lastCopy = "shrike.fileops.lastCopy"
        public static let lastMove = "shrike.fileops.lastMove"
        public static let all = [destinations, lastCopy, lastMove]

        public static func last(_ verb: FileVerb) -> String {
            switch verb {
            case .copy: return lastCopy
            case .move: return lastMove
            }
        }
    }

    /// Posted (object `nil`) after `set`, `clear` or `setLast`, so menus
    /// can rebuild.
    public static let didChangeNotification = Notification.Name("ShrikeDestinationSlotsDidChange")

    /// Slots in `ShrikeDefaults.store`.
    public static let standard = DestinationSlots()

    // UserDefaults isn't Sendable in the SDK; Foundation locks internally.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = ShrikeDefaults.store) {
        self.defaults = defaults
    }

    // MARK: Slots

    /// Always 9 entries; entry `i` is slot `i + 1`. `nil` = empty slot.
    /// Doesn't touch the disk.
    public func slots() -> [DestinationSlot?] {
        load().enumerated().map { index, entry in
            guard let path = entry.path, !path.isEmpty else { return nil }
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return DestinationSlot(number: index + 1, url: url,
                                   name: entry.name ?? url.lastPathComponent)
        }
    }

    /// The slot for key `number` (1–9), or `nil` when empty.
    public func slot(_ number: Int) -> DestinationSlot? {
        guard Self.numbers.contains(number) else { return nil }
        return slots()[number - 1]
    }

    /// Store `folder` in slot `number` (1–9). Ignored for other numbers.
    public func set(_ number: Int, folder: URL) {
        guard Self.numbers.contains(number) else { return }
        var entries = load()
        entries[number - 1] = Self.entry(for: folder)
        save(entries)
    }

    /// Empty slot `number` (1–9).
    public func clear(_ number: Int) {
        guard Self.numbers.contains(number) else { return }
        var entries = load()
        entries[number - 1] = Entry()
        save(entries)
    }

    /// The folder for slot `number`, checked on disk. Follows a folder that
    /// was renamed or moved (and updates the stored path). Throws `.empty`
    /// or `.unavailable(name:)` (the missing-destination alert).
    public func resolve(_ number: Int) throws(DestinationSlotError) -> URL {
        guard Self.numbers.contains(number) else { throw .empty(number) }
        var entries = load()
        let entry = entries[number - 1]
        guard let path = entry.path, !path.isEmpty else { throw .empty(number) }

        guard let (url, refreshed) = Self.resolve(bookmark: entry.bookmark, path: path) else {
            throw .unavailable(name: entry.name ?? (path as NSString).lastPathComponent)
        }
        if refreshed || url.path != path {
            entries[number - 1] = Self.entry(for: url)
            save(entries, notify: false)
        }
        return url
    }

    // MARK: Last destination per verb

    /// The last folder used for `verb`, or `nil` when there is none or it
    /// can't be found now.
    public func last(_ verb: FileVerb) -> URL? {
        guard let data = defaults.data(forKey: Key.last(verb)) else { return nil }
        guard let (url, refreshed) = Self.resolve(bookmark: data, path: nil) else { return nil }
        if refreshed, let fresh = Self.bookmark(for: url) {
            defaults.set(fresh, forKey: Key.last(verb))
        }
        return url
    }

    /// Remember `folder` as the last destination for `verb`.
    public func setLast(_ folder: URL, for verb: FileVerb) {
        guard let data = Self.bookmark(for: folder) else { return }
        defaults.set(data, forKey: Key.last(verb))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: Storage

    struct Entry: Codable, Hashable {
        var path: String?
        var bookmark: Data?
        var name: String?
    }

    func load() -> [Entry] {
        var entries: [Entry] = []
        if let data = defaults.data(forKey: Key.destinations),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(decoded.prefix(Self.count))
        }
        entries += Array(repeating: Entry(), count: Self.count - entries.count)
        return entries
    }

    private func save(_ entries: [Entry], notify: Bool = true) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Key.destinations)
        if notify {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    private static func entry(for folder: URL) -> Entry {
        let url = folder.standardizedFileURL
        let name = FileManager.default.fileExists(atPath: url.path)
            ? FileManager.default.displayName(atPath: url.path)
            : url.lastPathComponent
        return Entry(path: url.path, bookmark: bookmark(for: url), name: name)
    }

    /// Plain (not security-scoped) bookmark, or `nil` when the folder
    /// doesn't exist.
    static func bookmark(for folder: URL) -> Data? {
        try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve without UI or mounting; the result must be an existing
    /// folder. Falls back to `path` when the bookmark can't be resolved.
    /// `refreshed` = the stored bookmark should be rewritten.
    static func resolve(bookmark: Data?, path: String?) -> (URL, refreshed: Bool)? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               isDirectory(url) {
                return (url.standardizedFileURL, stale)
            }
        }
        if let path {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if isDirectory(url) { return (url, true) }
        }
        return nil
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
}

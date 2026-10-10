//
//  FinderTags.swift
//  ShrikeIO
//
//  Read/write macOS Finder tags. "macOS has native
//  tags — integrate instead of rolling our own." The file's tags are the
//  source of truth; Finder, Spotlight
//  and other apps see what Shrike writes.
//
//  * Names go through `NSURLTagNamesKey` (the supported API; writable on
//    macOS 10.9+). When a written name matches a tag the user already
//    has (e.g. "Red"), the system stores that tag's colour with it.
//  * Colours are read from the `com.apple.metadata:_kMDItemUserTags`
//    xattr, whose entries look like "Name\n6" (6 = red).
//  * Tag names compare case-insensitively, like Finder.
//

import Foundation
import AppKit
import Darwin

// MARK: - Model

/// Finder's label colours. Raw values are the colour indices Finder
/// stores in `_kMDItemUserTags` ("Red\n6").
public enum FinderTagColor: Int, Sendable, CaseIterable, Codable {
    case none = 0
    case gray = 1
    case green = 2
    case purple = 3
    case blue = 4
    case yellow = 5
    case red = 6
    case orange = 7

    /// The order Finder shows the colours in its menus and sidebar.
    public static let finderMenuOrder: [FinderTagColor] = [.red, .orange, .yellow, .green, .blue, .purple, .gray]

    /// The system's colour for this label (nil for `.none`).
    @MainActor
    public var nsColor: NSColor? {
        guard self != .none else { return nil }
        let colors = NSWorkspace.shared.fileLabelColors
        return colors.indices.contains(rawValue) ? colors[rawValue] : nil
    }
}

public struct FinderTag: Sendable, Hashable, Codable {
    public let name: String
    public let color: FinderTagColor

    public init(name: String, color: FinderTagColor = .none) {
        self.name = name
        self.color = color
    }
}

public enum FinderTagsError: Error, Equatable, Sendable {
    case fileNotFound(URL)
    case writeFailed(URL, String)

    /// The file the error is about (for the "Couldn't change the tags of
    /// “name”." toast).
    public var url: URL {
        switch self {
        case .fileNotFound(let url), .writeFailed(let url, _): return url
        }
    }
}

// MARK: - API

public enum FinderTags {

    static let xattrName = "com.apple.metadata:_kMDItemUserTags"

    /// Tag names on `url`, in Finder's order. Empty when the file has no
    /// tags or cannot be read.
    public static func read(_ url: URL) -> [String] {
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return (try? fresh.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// Tags on `url` with their colours. Falls back to names only (colour
    /// `.none`) when the xattr cannot be parsed.
    public static func readWithColors(_ url: URL) -> [FinderTag] {
        if let entries = readXattrEntries(url) {
            return entries.map(parseEntry)
        }
        return read(url).map { FinderTag(name: $0) }
    }

    /// Replaces all tags on `url`. Duplicate names (case-insensitive) are
    /// dropped; order is kept. An empty list removes every tag.
    public static func write(_ url: URL, tags: [String]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FinderTagsError.fileNotFound(url)
        }
        let cleaned = clean(tags)
        do {
            try (url as NSURL).setResourceValue(cleaned as NSArray, forKey: .tagNamesKey)
        } catch {
            throw FinderTagsError.writeFailed(url, error.localizedDescription)
        }
    }

    /// Adds tags that are not already present. Returns the resulting list.
    @discardableResult
    public static func add(_ tags: [String], to url: URL) throws -> [String] {
        let current = read(url)
        let merged = dedupe(current + tags)
        if merged != current { try write(url, tags: merged) }
        return merged
    }

    /// Removes tags (case-insensitive). Returns the resulting list.
    @discardableResult
    public static func remove(_ tags: [String], from url: URL) throws -> [String] {
        let current = read(url)
        let drop = Set(tags.map { $0.lowercased() })
        let kept = current.filter { !drop.contains($0.lowercased()) }
        if kept != current { try write(url, tags: kept) }
        return kept
    }

    /// Adds the tag if missing, removes it if present. Returns true when
    /// the tag is set afterwards.
    @discardableResult
    public static func toggle(_ tag: String, on url: URL) throws -> Bool {
        if read(url).contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            try remove([tag], from: url)
            return false
        }
        try add([tag], to: url)
        return true
    }

    /// The seven standard colour tags with the user's (localised) names,
    /// in Finder's menu order (Red, Orange, … Gray).
    @MainActor
    public static func knownTags() -> [FinderTag] {
        let labels = NSWorkspace.shared.fileLabels   // index = colour index; 0 = "None"
        return FinderTagColor.finderMenuOrder.compactMap { color in
            guard labels.indices.contains(color.rawValue) else { return nil }
            return FinderTag(name: labels[color.rawValue], color: color)
        }
    }

    /// Every tag the user has defined in Finder (Settings ▸ Tags), for
    /// autocompletion. Standard colour tags come first; custom tags follow
    /// in Finder's order. Best effort: returns just the standard tags when
    /// Finder's tag list cannot be read.
    @MainActor
    public static func allUserTags(finderPreferences: URL? = nil) -> [FinderTag] {
        var result = knownTags()
        var seen = Set(result.map { $0.name.lowercased() })
        for tag in userDefinedTags(finderPreferences: finderPreferences ?? defaultFinderTagPlist)
        where seen.insert(tag.name.lowercased()).inserted {
            result.append(tag)
        }
        return result
    }

    // MARK: - Internals

    /// Finder keeps the user's tag list in its synced preferences.
    static var defaultFinderTagPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/SyncedPreferences/com.apple.finder.plist")
    }

    /// Parses `values.FinderTagDict.value.FinderTags` = [{n: name, l: colour}].
    static func userDefinedTags(finderPreferences url: URL) -> [FinderTag] {
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let values = root["values"] as? [String: Any],
              let dict = values["FinderTagDict"] as? [String: Any],
              let value = dict["value"] as? [String: Any],
              let tags = value["FinderTags"] as? [[String: Any]]
        else { return [] }
        return tags.compactMap { entry in
            guard let name = entry["n"] as? String, !name.isEmpty else { return nil }
            let index = (entry["l"] as? Int) ?? 0
            return FinderTag(name: name, color: FinderTagColor(rawValue: index) ?? .none)
        }
    }

    static func readXattrEntries(_ url: URL) -> [String]? {
        url.withUnsafeFileSystemRepresentation { path -> [String]? in
            guard let path else { return nil }
            let size = getxattr(path, xattrName, nil, 0, 0, 0)
            guard size > 0 else { return size == 0 ? [] : (errno == ENOATTR ? [] : nil) }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, xattrName, $0.baseAddress, size, 0, 0) }
            guard read == size,
                  let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
            else { return nil }
            return list
        }
    }

    /// "Name\n6" → (Name, red). Missing / bad index → `.none`.
    static func parseEntry(_ entry: String) -> FinderTag {
        guard let newline = entry.lastIndex(of: "\n") else { return FinderTag(name: entry) }
        let name = String(entry[..<newline])
        let index = Int(entry[entry.index(after: newline)...]) ?? 0
        return FinderTag(name: name, color: FinderTagColor(rawValue: index) ?? .none)
    }

    /// Trimmed, non-empty, deduplicated (case-insensitive), order kept —
    /// exactly what `write` stores.
    static func clean(_ tags: [String]) -> [String] {
        dedupe(tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    static func dedupe(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.filter { seen.insert($0.lowercased()).inserted }
    }
}

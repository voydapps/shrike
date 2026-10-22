//
//  FileContentStamp.swift
//  ShrikeCore
//
//  Size and content modification date of a file. A rating, flag or tag is
//  written as an extended attribute: the folder watcher reports the file as
//  "modified", but neither value changes. Code that reacts to "modified" by
//  dropping pictures compares stamps first.
//

import Foundation

public struct FileContentStamp: Equatable, Sendable {
    public let size: Int64
    public let modified: Date?

    public init(size: Int64, modified: Date?) {
        self.size = size
        self.modified = modified
    }

    /// The file's stamp now, or nil when it cannot be read. Reads through a
    /// fresh URL: Foundation caches resource values on the instance.
    public static func read(_ url: URL) -> FileContentStamp? {
        guard let v = try? URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return FileContentStamp(size: Int64(v.fileSize ?? -1), modified: v.contentModificationDate)
    }

    /// True when `url` no longer has this stamp. An unreadable file counts as
    /// changed (it may be gone or replaced).
    public func differs(from url: URL) -> Bool {
        guard let now = Self.read(url) else { return true }
        return now != self
    }
}

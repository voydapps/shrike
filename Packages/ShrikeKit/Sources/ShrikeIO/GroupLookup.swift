//
//  GroupLookup.swift
//  ShrikeIO
//
//  Finds the group that holds a URL without scanning the list. A list of
//  n groups answers a lookup with hash probes: first the standardized
//  path (string work only, no file-system calls), then, on a miss, only
//  the files that share the target's name. Before this, every lookup
//  resolved the symlinks of every URL in the list (about 17 µs each), so
//  a watcher batch that added files to a big folder took minutes on the
//  main thread (audit MP-01 / MP-02).
//

import Foundation
import ShrikeCore

public struct GroupLookup: Sendable {

    /// `standardizedFileURL.path` of every URL in the list → its group.
    private var exact: [String: Int] = [:]
    /// Lower-cased file name → groups holding a file with that name.
    private var byName: [String: [Int]] = [:]

    public init(_ groups: [ImageGroup]) {
        exact.reserveCapacity(groups.count)
        byName.reserveCapacity(groups.count)
        for (i, group) in groups.enumerated() { add(group, at: i) }
    }

    private mutating func add(_ group: ImageGroup, at i: Int) {
        for url in group.allURLs {
            let path = url.standardizedFileURL.path
            if exact[path] == nil { exact[path] = i }
            let name = url.lastPathComponent.lowercased()
            if byName[name]?.last != i { byName[name, default: []].append(i) }
        }
    }

    private mutating func remove(_ group: ImageGroup, at i: Int) {
        for url in group.allURLs {
            let path = url.standardizedFileURL.path
            if exact[path] == i { exact[path] = nil }
            let name = url.lastPathComponent.lowercased()
            if var bucket = byName[name] {
                bucket.removeAll { $0 == i }
                byName[name] = bucket.isEmpty ? nil : bucket
            }
        }
    }

    /// The group at `index` was swapped for another one in place.
    public mutating func replace(at index: Int, old: ImageGroup, new: ImageGroup) {
        remove(old, at: index)
        add(new, at: index)
    }

    /// Index of the group holding `url` (primary or companion), compared by
    /// `standardizedFileURL.resolvingSymlinksInPath()`. With
    /// `caseInsensitiveFallback`, a file whose path differs only in case
    /// matches when nothing matches exactly (case-insensitive volumes).
    public func index(of url: URL, in groups: [ImageGroup], caseInsensitiveFallback: Bool = false) -> Int? {
        if let hit = exact[url.standardizedFileURL.path], groups.indices.contains(hit) { return hit }
        let targetName = url.lastPathComponent.lowercased()
        guard let bucket = byName[targetName] else { return nil }
        let target = FolderScanner.canonicalPath(url)
        let targetLowered = target.lowercased()
        var caseOnlyMatch: Int?
        for i in bucket.sorted() where groups.indices.contains(i) {
            for candidate in groups[i].allURLs where candidate.lastPathComponent.lowercased() == targetName {
                let path = FolderScanner.canonicalPath(candidate)
                if path == target { return i }
                if caseInsensitiveFallback, caseOnlyMatch == nil, path.lowercased() == targetLowered {
                    caseOnlyMatch = i
                }
            }
        }
        return caseOnlyMatch
    }
}

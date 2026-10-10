//
//  CanonicalPath.swift
//  ShrikeCore
//
//  One way to turn a file URL into the string Shrike uses as its identity
//  (MetadataStore rows, BackupStore chains). Must give the same answer
//  before and after the file itself is moved away, so only the *parent*
//  directory is symlink-resolved (it normally still exists) — resolving
//  the leaf of a vanished file would give a different result.
//
//  `of(_:)` keeps the spelling (display, restore targets). `key(_:)` is
//  the lookup key: on a case-insensitive volume (the macOS default) it is
//  case-folded and NFC-normalised, so `IMG.JPG` and `img.jpg` — one file
//  on that volume — share one key. On a case-sensitive volume it equals
//  `of(_:)`.
//

import Foundation
import os

public enum CanonicalPath {

    /// `/var/…` and `/private/var/…` map to the same string; `..` and `.`
    /// are removed; the leaf name is kept as spelled.
    public static func of(_ url: URL) -> String {
        let std = url.standardizedFileURL
        let parent = std.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(std.lastPathComponent).standardizedFileURL.path
    }

    /// Lookup key: `of(url)`, case-folded when the file's volume ignores
    /// case (`URLResourceKey.volumeSupportsCaseSensitiveNamesKey`).
    public static func key(_ url: URL) -> String {
        let path = of(url)
        let parent = (path as NSString).deletingLastPathComponent
        return isCaseInsensitive(directory: parent) ? fold(path) : path
    }

    /// `urls.map(key)`, but each parent folder is resolved and probed once
    /// (the grid asks for a page of siblings at a time).
    public static func keys(_ urls: [URL]) -> [String] {
        var parents: [String: (resolved: String, folds: Bool)] = [:]
        return urls.map { url in
            let std = url.standardizedFileURL
            let rawParent = std.deletingLastPathComponent()
            let entry: (resolved: String, folds: Bool)
            if let hit = parents[rawParent.path] {
                entry = hit
            } else {
                let resolved = rawParent.resolvingSymlinksInPath().standardizedFileURL.path
                entry = (resolved, isCaseInsensitive(directory: resolved))
                parents[rawParent.path] = entry
            }
            let leaf = std.lastPathComponent
            let path = entry.resolved == "/" ? "/" + leaf : entry.resolved + "/" + leaf
            return entry.folds ? fold(path) : path
        }
    }

    /// Case- and normalisation-insensitive spelling of `path`.
    public static func fold(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: nil)
    }

    /// Whether the volume holding `directory` (or its nearest existing
    /// ancestor) ignores case. Cached per directory for the process.
    public static func isCaseInsensitive(directory: String) -> Bool {
        if let hit = cache.withLock({ $0[directory] }) { return hit }
        var probe = URL(fileURLWithPath: directory, isDirectory: true)
        var answer = false
        while true {
            if let v = try? probe.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]),
               let sensitive = v.volumeSupportsCaseSensitiveNames {
                answer = !sensitive
                break
            }
            let up = probe.deletingLastPathComponent()
            if up.path == probe.path { break }
            probe = up
        }
        let result = answer
        cache.withLock { dict in
            if dict.count > 4096 { dict.removeAll(keepingCapacity: true) }
            dict[directory] = result
        }
        return result
    }

    private static let cache = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])
}

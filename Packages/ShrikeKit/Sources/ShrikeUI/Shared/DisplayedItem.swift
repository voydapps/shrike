//
//  DisplayedItem.swift
//  ShrikeUI
//
//  The item a window actually shows. Every file
//  action reads this — never an index that may have moved on since the
//  pixels were painted.
//

import Foundation
import ShrikeCore

public struct DisplayedItem: Equatable, Sendable {
    /// Primary URL + companions (RAW, sidecars, Live Photo movie).
    public let group: ImageGroup
    /// Index in the window's list at paint time.
    public let listIndex: Int
    /// List generation at paint time (bumps on every list mutation).
    public let generation: UInt64

    public init(group: ImageGroup, listIndex: Int, generation: UInt64) {
        self.group = group
        self.listIndex = listIndex
        self.generation = generation
    }
}

/// A window's list of groups plus a generation counter that bumps on
/// every mutation, so a stale index can be told apart from a fresh one.
public struct GroupList: Sendable, Equatable {
    public private(set) var groups: [ImageGroup]
    public private(set) var generation: UInt64 = 0

    public init(_ groups: [ImageGroup] = []) {
        self.groups = groups
    }

    public var count: Int { groups.count }
    public var isEmpty: Bool { groups.isEmpty }

    public subscript(index: Int) -> ImageGroup? {
        groups.indices.contains(index) ? groups[index] : nil
    }

    public mutating func replace(with groups: [ImageGroup]) {
        self.groups = groups
        generation &+= 1
    }

    /// Swaps the group at `index` (rename: the item keeps its place).
    public mutating func replace(at index: Int, with group: ImageGroup) {
        guard groups.indices.contains(index) else { return }
        groups[index] = group
        generation &+= 1
    }

    /// Removes the groups whose primary is in `primaries`; returns the
    /// removed groups with their old indices (ascending).
    @discardableResult
    public mutating func remove(primaries: Set<URL>) -> [RemovedGroup] {
        var removed: [RemovedGroup] = []
        var kept: [ImageGroup] = []
        kept.reserveCapacity(groups.count)
        for (i, g) in groups.enumerated() {
            if primaries.contains(g.primary) {
                removed.append(RemovedGroup(index: i, group: g))
            } else {
                kept.append(g)
            }
        }
        guard !removed.isEmpty else { return [] }
        groups = kept
        generation &+= 1
        return removed
    }

    /// Re-inserts groups at their old indices (clamped), lowest first.
    public mutating func insert(_ entries: [RemovedGroup]) {
        guard !entries.isEmpty else { return }
        for entry in entries.sorted(by: { $0.index < $1.index }) {
            groups.insert(entry.group, at: min(max(0, entry.index), groups.count))
        }
        generation &+= 1
    }

    /// Index of the group holding `url` (primary or companion), compared
    /// by `standardizedFileURL.resolvingSymlinksInPath()`.
    public func index(of url: URL) -> Int? {
        let target = Self.canonical(url)
        for (i, g) in groups.enumerated()
        where g.allURLs.contains(where: { Self.canonical($0) == target }) {
            return i
        }
        return nil
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// A group taken out of a list, with the index it had.
public struct RemovedGroup: Sendable, Equatable {
    public let index: Int
    public let group: ImageGroup
    public init(index: Int, group: ImageGroup) {
        self.index = index
        self.group = group
    }
}

public extension ImageGroup {
    /// "DSC_0042.jpg" — the primary's file name (a RAW companion is not named).
    var displayName: String { primary.lastPathComponent }
}

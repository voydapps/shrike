//
//  FolderWatcherRegistry.swift
//  ShrikeIO
//
//  Weak set of every live `FolderWatcher`; `ignore(paths:for:)` fans out to
//  ALL of them. Windows do not use it for their own writes: that would hide
//  the change from every other window too. They use `WindowWatcherScope`.
//  A watcher skips URLs outside its own folder, so broadcasting is safe.
//

import Foundation
import os

/// Something that can be told to ignore changes to a set of files for a
/// short time. `FolderWatcher` and `FolderWatcherRegistry` conform; tests
/// use a recording fake.
public protocol FolderChangeSuppressing: Sendable {
    func ignore(paths: [URL], for duration: Duration)
}

extension FolderWatcher: FolderChangeSuppressing {}

/// Weak set of live `FolderWatcher`s. Thread-safe.
public final class FolderWatcherRegistry: FolderChangeSuppressing {

    /// Every `FolderWatcher` registers here on init.
    public static let shared = FolderWatcherRegistry()

    private struct WeakWatcher: Sendable {
        weak var watcher: FolderWatcher?
    }

    private let watchers = OSAllocatedUnfairLock<[ObjectIdentifier: WeakWatcher]>(initialState: [:])

    public init() {}

    /// Adds `watcher` (held weakly; it drops out when deallocated).
    public func register(_ watcher: FolderWatcher) {
        let id = ObjectIdentifier(watcher)
        watchers.withLock { map in
            map = map.filter { $0.value.watcher != nil }
            map[id] = WeakWatcher(watcher: watcher)
        }
    }

    public func unregister(_ watcher: FolderWatcher) {
        let id = ObjectIdentifier(watcher)
        _ = watchers.withLock { $0.removeValue(forKey: id) }
    }

    /// Live watchers right now.
    public var registered: [FolderWatcher] {
        watchers.withLock { $0.values.compactMap(\.watcher) }
    }

    /// Forwards to every live watcher. Each one keeps only the paths
    /// directly inside its folder.
    public func ignore(paths: [URL], for duration: Duration) {
        guard !paths.isEmpty else { return }
        for watcher in registered where watcher.isRunning {
            watcher.ignore(paths: paths, for: duration)
        }
    }
}

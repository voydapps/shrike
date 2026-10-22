//
//  WindowWatcherScope.swift
//  ShrikeIO
//
//  The watchers ONE window must not hear its own writes in.
//
//  `FolderWatcherRegistry.ignore` silences every watcher in the app. That is
//  wrong for a write that other windows only learn about through their
//  watcher: a second Browser on the same folder would never refresh the
//  thumbnail, size or badge. A window therefore ignores its own write in
//  its own watcher, and in its paired partner's watcher (the window it
//  updates explicitly after the write). Every other watcher still reports
//  the change.
//

import Foundation
import os

/// A window's own watcher plus the watcher of its paired partner window.
/// Thread-safe; `FileOps` calls `ignore` off the main actor.
public final class WindowWatcherScope: FolderChangeSuppressing, Sendable {

    private struct Weak: Sendable { weak var watcher: FolderWatcher? }
    private struct PartnerRef: Sendable { weak var scope: WindowWatcherScope? }
    private struct State: Sendable {
        var own: Weak = Weak()
        var partner: PartnerRef = PartnerRef()
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    /// The window's own watcher (nil when it watches nothing).
    public func setWatcher(_ watcher: FolderWatcher?) {
        state.withLock { $0.own = Weak(watcher: watcher) }
    }

    /// The paired window's scope (nil when unpaired).
    public func setPartner(_ partner: WindowWatcherScope?) {
        state.withLock { $0.partner = PartnerRef(scope: partner) }
    }

    /// Watchers that ignore the paths: the window's own and its partner's own.
    public var watchers: [FolderWatcher] {
        let (own, partner) = state.withLock { ($0.own.watcher, $0.partner.scope) }
        var result: [FolderWatcher] = []
        if let own { result.append(own) }
        if let other = partner?.state.withLock({ $0.own.watcher }), other !== own { result.append(other) }
        return result
    }

    public func ignore(paths: [URL], for duration: Duration) {
        guard !paths.isEmpty else { return }
        for watcher in watchers where watcher.isRunning {
            watcher.ignore(paths: paths, for: duration)
        }
    }
}

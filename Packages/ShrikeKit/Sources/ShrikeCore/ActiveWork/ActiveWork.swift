//
//  ActiveWork.swift
//  ShrikeCore
//
//  Info.plist turns on sudden and automatic
//  termination, so macOS may kill the app at logout in the middle of a write.
//  Every piece of work that must not be cut off (a copy, a Batch run, a save, a
//  rotate write, a restore) opens a token here. While at least one token is
//  open, both kinds of termination are switched off. When the last token ends
//  they are switched on again. Unsaved edits use their own registry
//  (`unsavedEdits`): they also switch termination off, but they are not
//  running work, so the quit flow, which reads `shared`, never sees them.
//
//  The system calls are counted, so they are made once per 0 -> 1 and 1 -> 0
//  change, never once per token. The UI reads `snapshot()` for the quit question.
//

import Foundation
import os

public final class ActiveWork: Sendable {

    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case batchRun, transfer, save, rotateWrite, restore, unsavedEdit
    }

    public struct Token: Sendable, Hashable {
        fileprivate let id: UUID
    }

    /// What is running right now.
    public struct Snapshot: Sendable, Equatable {
        public let counts: [Kind: Int]
        /// Details of every open token (file name, "12 photos", ...), oldest first.
        public let details: [String]
        public var total: Int { counts.values.reduce(0, +) }
        public var isIdle: Bool { total == 0 }
        public func count(of kind: Kind) -> Int { counts[kind] ?? 0 }
        public func contains(_ kind: Kind) -> Bool { count(of: kind) > 0 }
    }

    /// The system calls, made as a pair. Tests pass counting closures.
    public struct Hooks: Sendable {
        public var disable: @Sendable () -> Void
        public var enable: @Sendable () -> Void
        public init(disable: @escaping @Sendable () -> Void, enable: @escaping @Sendable () -> Void) {
            self.disable = disable
            self.enable = enable
        }

        static func system(reason: String) -> Hooks {
            Hooks(
                disable: {
                    ProcessInfo.processInfo.disableSuddenTermination()
                    ProcessInfo.processInfo.disableAutomaticTermination(reason)
                },
                enable: {
                    ProcessInfo.processInfo.enableAutomaticTermination(reason)
                    ProcessInfo.processInfo.enableSuddenTermination()
                })
        }
    }

    static let reason = "Shrike is writing files"

    /// Process-wide registry used by the app.
    public static let shared = ActiveWork()

    /// Viewers with unsaved edits. Only keeps the system from ending the app
    /// (logout, restart) before the quit question; not counted as work.
    public static let unsavedEdits = ActiveWork(hooks: .system(reason: "Shrike has unsaved edits"))

    private struct Entry: Sendable {
        let kind: Kind
        let detail: String
        let order: UInt64
    }
    private struct State: Sendable {
        var open: [UUID: Entry] = [:]
        var next: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let hooks: Hooks

    public init() { hooks = .system(reason: ActiveWork.reason) }

    public init(hooks: Hooks) { self.hooks = hooks }

    /// Opens a token. Pair every call with `end(_:)` (use `defer`).
    @discardableResult
    public func begin(kind: Kind, detail: String = "") -> Token {
        let id = UUID()
        let hooks = self.hooks
        state.withLock { s in
            let wasIdle = s.open.isEmpty
            s.open[id] = Entry(kind: kind, detail: detail, order: s.next)
            s.next += 1
            if wasIdle { hooks.disable() }
        }
        return Token(id: id)
    }

    /// Closes a token. Closing the same token twice does nothing.
    public func end(_ token: Token) {
        let hooks = self.hooks
        state.withLock { s in
            guard s.open.removeValue(forKey: token.id) != nil else { return }
            if s.open.isEmpty { hooks.enable() }
        }
    }

    /// Runs `body` with a token open.
    public func withWork<T>(kind: Kind, detail: String = "", _ body: () throws -> T) rethrows -> T {
        let token = begin(kind: kind, detail: detail)
        defer { end(token) }
        return try body()
    }

    public func snapshot() -> Snapshot {
        state.withLock { s in
            var counts: [Kind: Int] = [:]
            for entry in s.open.values { counts[entry.kind, default: 0] += 1 }
            let details = s.open.values.sorted { $0.order < $1.order }.map(\.detail).filter { !$0.isEmpty }
            return Snapshot(counts: counts, details: details)
        }
    }
}

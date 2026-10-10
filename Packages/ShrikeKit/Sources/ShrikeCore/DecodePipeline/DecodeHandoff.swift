//
//  DecodeHandoff.swift
//  ShrikeCore
//
//  Cold open: the photo a Finder double-click
//  names starts decoding (and its GPU texture is built) the moment the
//  request arrives, before the app has finished launching, the folder is
//  scanned or the viewer window exists. The viewer's `DecodeQueue` then
//  takes the finished (or still running) decode instead of starting its
//  own, so the decode is no longer on the first-photo path.
//
//  Also: `DecodeMemoryLedger`, the process-wide byte count that lets all
//  viewer windows share one budget for far neighbours.
//

import Foundation
import os

/// Hands a decode started before any `DecodeQueue` existed to the first
/// queue that asks for the same file. Each start is claimed at most once;
/// an unclaimed decode is dropped after `lifetime`.
public final class DecodeHandoff: Sendable {

    public static let shared = DecodeHandoff()

    /// How long an unclaimed decode is kept (the open found no viewer).
    public static let lifetime: Duration = .seconds(15)

    /// How long a finished early decode stays waitable
    /// (`waitForFinished`) after it ends. The new viewer asks within a
    /// few ms; later it finds the photo in its own queue.
    public static let finishedKeep: Duration = .milliseconds(500)

    private struct Entry: Sendable {
        let target: Int
        /// Tells this start apart from a later start of the same file.
        let serial: UInt64
        let task: Task<DecodedImage, any Error>
    }

    /// The end of one start's decode, so the
    /// new viewer can wait for it (bounded, `waitForFinished`) before it
    /// orders its window front, instead of showing an empty canvas first.
    /// Holds the result only until the viewer takes it or the start
    /// expires; a viewer that stops waiting drops its box, and the
    /// finished decode then only lives in the queue that claimed it.
    private final class Finish: Sendable {
        let target: Int
        let serial: UInt64
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<DecodedImage?>(initialState: nil)
        init(target: Int, serial: UInt64) {
            self.target = target
            self.serial = serial
        }
    }

    private struct State {
        var map: [String: Entry] = [:]
        var finishes: [String: Finish] = [:]
        var nextSerial: UInt64 = 0
    }

    private let entries = OSAllocatedUnfairLock<State>(initialState: State())

    public init() {}

    static func key(for url: URL) -> String { url.standardizedFileURL.path }

    /// Starts decoding `url` for a display of `targetLongEdge` on `lane`,
    /// building the texture with `preparer`. No-op when a decode for this
    /// file is already waiting.
    public func start(
        url: URL,
        targetLongEdge: Int,
        preparer: DisplayPreparer?,
        lane: DecodeLane = .shared
    ) {
        let key = Self.key(for: url)
        let source = FileImageSource(url: url)
        let serial = entries.withLockUnchecked { state -> UInt64? in
            guard state.map[key] == nil else { return nil }
            state.nextSerial &+= 1
            let finish = Finish(target: targetLongEdge, serial: state.nextSerial)
            let task = Task.detached(priority: .userInitiated) { () throws -> DecodedImage in
                let signpost = ShrikeSignposts.decode.begin("handoffDecode")
                defer {
                    ShrikeSignposts.decode.end("handoffDecode", signpost)
                    finish.done.signal()
                }
                let entry = try await lane.run {
                    try DecodeQueue.makeEntry(file: source, id: source.id,
                                              target: targetLongEdge, preparer: preparer)
                }
                finish.result.withLockUnchecked { $0 = entry }
                // The box only serves a viewer that is being built right
                // now: it lets go of the photo shortly after, whether or
                // not anyone took it (the claiming queue keeps its own).
                Task.detached(priority: .utility) {
                    try? await Task.sleep(for: DecodeHandoff.finishedKeep)
                    finish.result.withLockUnchecked { $0 = nil }
                }
                return entry
            }
            state.map[key] = Entry(target: targetLongEdge, serial: state.nextSerial, task: task)
            state.finishes[key] = finish
            return state.nextSerial
        }
        guard let serial else { return }
        // Drop it if nobody claims it (the open made no viewer).
        // Memory: the timer holds only the key
        // and the serial, never the task. A task keeps its finished
        // result, so holding it here kept every opened photo's texture
        // (about 45 MB for an 18 MP photo) alive for 15 s, even after
        // its window had closed.
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: Self.lifetime)
            self?.expire(key: key, serial: serial)
        }
    }

    private func expire(key: String, serial: UInt64) {
        let expired = entries.withLockUnchecked { state -> Task<DecodedImage, any Error>? in
            if state.finishes[key]?.serial == serial { state.finishes.removeValue(forKey: key) }
            guard let entry = state.map[key], entry.serial == serial else { return nil }
            state.map.removeValue(forKey: key)
            return entry.task
        }
        expired?.cancel()
    }

    /// The waiting decode for `url` when it was made for at least
    /// `target` pixels; removes it (one claim per start).
    public func claim(url: URL, target: Int) -> Task<DecodedImage, any Error>? {
        let key = Self.key(for: url)
        return entries.withLockUnchecked { state in
            guard let entry = state.map[key], entry.target >= target else { return nil }
            state.map.removeValue(forKey: key)
            return entry.task
        }
    }

    /// Blocks the caller until the early
    /// decode of `url` has finished, at most until `deadline`, and
    /// returns it when it was made for at least `target` pixels. Takes
    /// the waiting box (one take per start, whatever the outcome), so
    /// nothing here keeps the photo alive afterwards. Returns nil at
    /// once when no early decode was started for `url`. Meant for the
    /// launch path only: the new viewer waits a few ms so that the photo
    /// and its window reach the screen together.
    public func waitForFinished(url: URL, target: Int, deadline: DispatchTime) -> DecodedImage? {
        let key = Self.key(for: url)
        let finish = entries.withLockUnchecked { state in
            state.finishes.removeValue(forKey: key)
        }
        guard let finish, finish.target >= target else { return nil }
        guard finish.done.wait(timeout: deadline) == .success else { return nil }
        // Let a later waiter on the same box (none today) see it too.
        finish.done.signal()
        return finish.result.withLockUnchecked { $0 }
    }

    /// True while an early decode of `url` can still be waited for.
    public func hasWaitableDecode(url: URL) -> Bool {
        let key = Self.key(for: url)
        return entries.withLockUnchecked { $0.finishes[key] != nil }
    }

    /// Drops the waiting box of `url` (the viewer painted its first
    /// photo another way), so its result is not kept here.
    public func forgetFinished(url: URL) {
        let key = Self.key(for: url)
        _ = entries.withLockUnchecked { $0.finishes.removeValue(forKey: key) }
    }

    /// Test seam: number of unclaimed decodes.
    public var pendingCount: Int { entries.withLockUnchecked { $0.map.count } }

    /// Test seam: number of boxes still waiting to be taken.
    public var waitableCount: Int { entries.withLockUnchecked { $0.finishes.count } }
}

/// Process-wide bytes held by every `DecodeQueue` cache. Four windows
/// used to hold four full prefetch windows
/// (1.7 GB); far neighbours now come out of one shared budget.
public final class DecodeMemoryLedger: Sendable {

    public static let shared = DecodeMemoryLedger()

    /// Shared budget for all windows' caches: 640 MB, or 1/8 of RAM on
    /// small machines (never under 192 MB). The current photo and its two
    /// direct neighbours are always kept, whatever this says.
    public static let defaultSharedBudget: Int = {
        let eighth = Int(clamping: ProcessInfo.processInfo.physicalMemory / 8)
        return min(640 * 1_048_576, max(192 * 1_048_576, eighth))
    }()

    private let bytes = OSAllocatedUnfairLock<[ObjectIdentifier: Int]>(initialState: [:])

    public init() {}

    func set(_ owner: ObjectIdentifier, bytes value: Int) {
        bytes.withLockUnchecked { map in
            if value > 0 { map[owner] = value } else { map.removeValue(forKey: owner) }
        }
    }

    /// Bytes held by every queue except `owner`.
    func others(than owner: ObjectIdentifier) -> Int {
        bytes.withLockUnchecked { map in
            map.reduce(0) { $0 + ($1.key == owner ? 0 : $1.value) }
        }
    }

    /// Total bytes across all queues (diagnostics, tests).
    public var total: Int { bytes.withLockUnchecked { $0.values.reduce(0, +) } }
}

//
//  FinderTagWriter.swift
//  ShrikeIO
//
//  Finder-tag writes off the main thread, in call order (file I/O never
//  runs on the main thread). Each tag write is
//  a `setxattr`, which is quick on a local disk but can stall for seconds
//  on a network volume.
//
//  * One serial queue. A change is queued the moment it is called
//    (`enqueue` is synchronous), so writes always land in the order of
//    the clicks — even from plain synchronous UI code, with no `Task`.
//  * `add` / `remove` read the file when their turn comes, so they build
//    on every write queued before them, never on a stale copy.
//  * One file failing never stops the others. Every failure comes back
//    as a `FinderTagsError`, which carries its file's URL.
//  * The async methods are `nonisolated(nonsending)`: called from the
//    main actor they queue the change before the first suspension, so
//    `Task { await writer.add(…) }` from two clicks keeps click order.
//
//  The synchronous `FinderTags` API is unchanged; this sits on top of it.
//

import Foundation

// MARK: - Model

/// What to do to a file's tags.
public enum FinderTagChange: Sendable, Hashable {
    /// Replace all tags (an empty list removes every tag).
    case set([String])
    /// Add names that are not there yet (case-insensitive).
    case add([String])
    /// Remove names (case-insensitive).
    case remove([String])
}

/// One file and the change to apply to it.
public struct FinderTagEdit: Sendable, Hashable {
    public let url: URL
    public let change: FinderTagChange

    public init(url: URL, change: FinderTagChange) {
        self.url = url
        self.change = change
    }
}

/// Outcome of one queued batch.
public struct FinderTagWriteResult: Sendable, Equatable {
    /// Tag names on each file that succeeded, after the change. Files the
    /// change left as they were are included too.
    public var tags: [URL: [String]]
    /// One error per failed file, in the batch's order. Empty = all fine.
    public var failures: [FinderTagsError]

    public init(tags: [URL: [String]] = [:], failures: [FinderTagsError] = []) {
        self.tags = tags
        self.failures = failures
    }

    public var succeeded: Bool { failures.isEmpty }
    /// The files that failed (for the toast).
    public var failedURLs: [URL] { failures.map(\.url) }
}

// MARK: - Writer

public final class FinderTagWriter: Sendable {

    /// The app-wide writer: one queue, so every window's writes stay in order.
    public static let shared = FinderTagWriter()

    private let queue: DispatchQueue

    public init(label: String = "app.shrike.finder-tags") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    // MARK: Queue now (synchronous)

    /// Queues `edits` behind everything queued before and returns at once.
    /// The edits run in array order. `completion` runs on the writer's
    /// queue, not the main thread — hop to the main actor yourself.
    public func enqueue(
        _ edits: [FinderTagEdit],
        completion: (@Sendable (FinderTagWriteResult) -> Void)? = nil
    ) {
        queue.async {
            let result = Self.apply(edits)
            completion?(result)
        }
    }

    /// Queues the same change for every file in `urls`.
    public func enqueue(
        _ change: FinderTagChange, on urls: [URL],
        completion: (@Sendable (FinderTagWriteResult) -> Void)? = nil
    ) {
        enqueue(urls.map { FinderTagEdit(url: $0, change: change) }, completion: completion)
    }

    // MARK: Async

    /// Applies `edits` in order after everything queued before; returns
    /// when they are written.
    nonisolated(nonsending)
    public func write(_ edits: [FinderTagEdit]) async -> FinderTagWriteResult {
        await withCheckedContinuation { continuation in
            enqueue(edits) { continuation.resume(returning: $0) }
        }
    }

    /// Replaces the tags of every file in `urls` with `tags`.
    nonisolated(nonsending)
    public func set(_ tags: [String], on urls: [URL]) async -> FinderTagWriteResult {
        await write(urls.map { FinderTagEdit(url: $0, change: .set(tags)) })
    }

    /// Adds `tags` to every file in `urls`.
    nonisolated(nonsending)
    public func add(_ tags: [String], to urls: [URL]) async -> FinderTagWriteResult {
        await write(urls.map { FinderTagEdit(url: $0, change: .add(tags)) })
    }

    /// Removes `tags` from every file in `urls`.
    nonisolated(nonsending)
    public func remove(_ tags: [String], from urls: [URL]) async -> FinderTagWriteResult {
        await write(urls.map { FinderTagEdit(url: $0, change: .remove(tags)) })
    }

    /// Returns once everything queued before this call is written.
    nonisolated(nonsending)
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: Work (on the queue)

    static func apply(_ edits: [FinderTagEdit]) -> FinderTagWriteResult {
        var result = FinderTagWriteResult()
        for edit in edits {
            do {
                result.tags[edit.url] = try apply(edit.change, to: edit.url)
            } catch let error as FinderTagsError {
                result.failures.append(error)
            } catch {
                result.failures.append(.writeFailed(edit.url, error.localizedDescription))
            }
        }
        return result
    }

    /// Returns the tags on `url` after the change.
    private static func apply(_ change: FinderTagChange, to url: URL) throws -> [String] {
        // A missing file is an error even when the change would be a no-op
        // (removing a tag from a file that is gone).
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FinderTagsError.fileNotFound(url)
        }
        switch change {
        case .set(let tags):
            let cleaned = FinderTags.clean(tags)
            try FinderTags.write(url, tags: cleaned)
            return cleaned
        case .add(let tags):
            return try FinderTags.add(FinderTags.clean(tags), to: url)
        case .remove(let tags):
            return try FinderTags.remove(FinderTags.clean(tags), from: url)
        }
    }
}

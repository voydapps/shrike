//
//  FolderWatcherTests.swift
//  ShrikeIOTests
//
//  Real FSEvents against a temp directory. Every test works in its own
//  unique folder under NSTemporaryDirectory(); nothing else is touched.
//

import XCTest
import Foundation
@testable import ShrikeIO

/// Collects every element of a watcher's stream so tests can poll it.
private actor ChangeCollector {
    private(set) var changes: [FolderChange] = []
    private(set) var finished = false

    func append(_ change: FolderChange) { changes.append(change) }
    func finish() { finished = true }

    var added: [String] { changes.flatMap(\.added).map(\.lastPathComponent) }
    var removed: [String] { changes.flatMap(\.removed).map(\.lastPathComponent) }
    var modified: [String] { changes.flatMap(\.modified).map(\.lastPathComponent) }
    var renamed: [[String]] {
        changes.flatMap(\.renamed).map { [$0.from.lastPathComponent, $0.to.lastPathComponent] }
    }
    var allNames: [String] {
        changes.flatMap { $0.added + $0.removed + $0.modified + $0.renamed.flatMap { [$0.from, $0.to] } }
            .map(\.path)
    }
}

final class FolderWatcherTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeFolderWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: Helpers

    private func touch(_ name: String, in dir: URL? = nil, bytes: Int = 16) throws {
        let url = (dir ?? root).appendingPathComponent(name)
        try Data(repeating: 0xAB, count: bytes).write(to: url)
    }

    private func startCollecting(_ watcher: FolderWatcher) -> (ChangeCollector, Task<Void, Never>) {
        let collector = ChangeCollector()
        let task = Task {
            for await change in watcher.changes { await collector.append(change) }
            await collector.finish()
        }
        return (collector, task)
    }

    /// Polls until `predicate` is true or the timeout expires.
    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(5),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return await predicate()
    }

    /// FSEvents may still flush fixture writes made just before the stream
    /// started; give the fixtures time to settle first.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
    }

    private func fastOptions() -> FolderWatcher.Options {
        FolderWatcher.Options(debounce: .milliseconds(150), maxLatency: .seconds(1),
                              fsEventsLatency: .milliseconds(50))
    }

    // MARK: Tests

    func testRejectsNonDirectory() throws {
        try touch("file.jpg")
        XCTAssertThrowsError(try FolderWatcher(folder: root.appendingPathComponent("file.jpg"))) { error in
            XCTAssertEqual(error as? FolderWatcherError,
                           .notADirectory(root.appendingPathComponent("file.jpg")))
        }
        XCTAssertThrowsError(try FolderWatcher(folder: root.appendingPathComponent("missing")))
    }

    func testAddRemoveRenameModify() async throws {
        try touch("a.jpg")
        try touch("b.jpg")
        try touch("c.jpg")
        await settle()

        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }
        XCTAssertTrue(watcher.isRunning)

        // Added
        try touch("new.jpg")
        let sawAdd = await waitUntil { await collector.added.contains("new.jpg") }
        XCTAssertTrue(sawAdd, "expected new.jpg in added")

        // Removed
        try FileManager.default.removeItem(at: root.appendingPathComponent("a.jpg"))
        let sawRemove = await waitUntil { await collector.removed.contains("a.jpg") }
        XCTAssertTrue(sawRemove, "expected a.jpg in removed")

        // Renamed (paired, not added + removed)
        try FileManager.default.moveItem(at: root.appendingPathComponent("b.jpg"),
                                         to: root.appendingPathComponent("b-renamed.jpg"))
        let sawRename = await waitUntil { await collector.renamed.contains(["b.jpg", "b-renamed.jpg"]) }
        XCTAssertTrue(sawRename, "expected paired rename b.jpg → b-renamed.jpg")
        let addedAfterRename = await collector.added
        let removedAfterRename = await collector.removed
        XCTAssertFalse(addedAfterRename.contains("b-renamed.jpg"))
        XCTAssertFalse(removedAfterRename.contains("b.jpg"))

        // Modified in place
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent("c.jpg"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 2, 3]))
        try handle.close()
        let sawModify = await waitUntil { await collector.modified.contains("c.jpg") }
        XCTAssertTrue(sawModify, "expected c.jpg in modified")

        // URLs use the caller's folder form, not /private/var/...
        let changes = await collector.changes
        for url in changes.flatMap({ $0.added + $0.removed + $0.modified }) {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path,
                           root.standardizedFileURL.path)
        }
    }

    func testAtomicSaveReportsModifiedNotAddedOrRemoved() async throws {
        try touch("photo.jpg")
        await settle()

        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        // Our own save path writes a temp file and renames it over the
        // original.
        try Data(repeating: 0xCD, count: 4096)
            .write(to: root.appendingPathComponent("photo.jpg"), options: .atomic)

        let sawModify = await waitUntil { await collector.modified.contains("photo.jpg") }
        XCTAssertTrue(sawModify, "atomic save should surface as modified")
        try? await Task.sleep(for: .milliseconds(400))
        let added = await collector.added
        let removed = await collector.removed
        XCTAssertFalse(added.contains("photo.jpg"))
        XCTAssertFalse(removed.contains("photo.jpg"))
    }

    func testIgnoredPathsAreNotReported() async throws {
        try touch("own.jpg")
        try touch("other.jpg")
        await settle()

        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        // Shrike saves own.jpg and creates own-copy.jpg; someone else edits
        // other.jpg at the same time.
        watcher.ignore(paths: [root.appendingPathComponent("own.jpg"),
                               root.appendingPathComponent("own-copy.jpg"),
                               FileManager.default.temporaryDirectory.appendingPathComponent("x.jpg")])
        try Data(repeating: 0xCD, count: 4096)
            .write(to: root.appendingPathComponent("own.jpg"), options: .atomic)
        try touch("own-copy.jpg")
        try touch("other.jpg", bytes: 64)

        let sawOther = await waitUntil { await collector.modified.contains("other.jpg") }
        XCTAssertTrue(sawOther)
        try? await Task.sleep(for: .milliseconds(400))
        let all = await collector.added + collector.removed + collector.modified
        XCTAssertFalse(all.contains("own.jpg"), "own save must be suppressed: \(all)")
        XCTAssertFalse(all.contains("own-copy.jpg"), "own copy must be suppressed: \(all)")

        // Once the window is over, the file is reported again, and the
        // suppressed add was still recorded (a delete is "removed").
        try? await Task.sleep(for: .milliseconds(700))
        try FileManager.default.removeItem(at: root.appendingPathComponent("own-copy.jpg"))
        let sawRemove = await waitUntil { await collector.removed.contains("own-copy.jpg") }
        XCTAssertTrue(sawRemove, "changes after the window are reported")
    }

    func testDefaultDebounceIs200ms() {
        XCTAssertEqual(FolderWatcher.Options().debounce, .milliseconds(200))
    }

    func testBurstOfThousandFilesCoalesces() async throws {
        await settle()
        let watcher = try FolderWatcher(folder: root) // default options
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        let start = ContinuousClock.now
        for i in 0..<1_000 {
            try touch(String(format: "IMG_%04d.JPG", i), bytes: 64)
        }
        let writeTime = ContinuousClock.now - start

        let sawAll = await waitUntil(timeout: .seconds(10)) { await Set(collector.added).count == 1_000 }
        XCTAssertTrue(sawAll, "expected all 1,000 adds")
        try? await Task.sleep(for: .milliseconds(400))
        let changes = await collector.changes
        let added = await collector.added
        XCTAssertEqual(added.count, 1_000, "each file reported once")
        // One batch expected; allow a second if the writes straddled the
        // max-latency deadline on a slow machine.
        XCTAssertLessThanOrEqual(changes.count, 2, "burst must coalesce, got \(changes.count) batches")
        print("[FolderWatcher] 1,000 files written in \(writeTime); delivered in \(changes.count) batch(es)")
    }

    func testNestedAndHiddenChangesAreIgnored() async throws {
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        await settle()

        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        try touch("deep.jpg", in: sub)
        try touch(".DS_Store")
        try touch("sentinel.jpg")
        let sawSentinel = await waitUntil { await collector.added.contains("sentinel.jpg") }
        XCTAssertTrue(sawSentinel)
        try? await Task.sleep(for: .milliseconds(300))

        let names = await collector.allNames
        XCTAssertFalse(names.contains { $0.contains("/sub/") }, "nested file leaked: \(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix(".DS_Store") }, "hidden file leaked: \(names)")
    }

    func testWatchedFolderDeletedFinishesStream() async throws {
        let watched = root.appendingPathComponent("watched", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        try touch("one.jpg", in: watched)
        await settle()

        let watcher = try FolderWatcher(folder: watched, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        try FileManager.default.removeItem(at: watched)

        let finished = await waitUntil { await collector.finished }
        XCTAssertTrue(finished, "stream should finish after the folder is deleted")
        let last = await collector.changes.last
        XCTAssertEqual(last?.folderEvent, .deleted)
        XCTAssertFalse(watcher.isRunning)
    }

    func testWatchedFolderRenamedReportsMove() async throws {
        let watched = root.appendingPathComponent("before", isDirectory: true)
        let moved = root.appendingPathComponent("after", isDirectory: true)
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        await settle()

        let watcher = try FolderWatcher(folder: watched, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }

        try FileManager.default.moveItem(at: watched, to: moved)

        let finished = await waitUntil { await collector.finished }
        XCTAssertTrue(finished)
        guard case .moved(let to)? = await collector.changes.last?.folderEvent else {
            return XCTFail("expected .moved, got \(String(describing: await collector.changes.last))")
        }
        XCTAssertEqual(to.resolvingSymlinksInPath().path, moved.resolvingSymlinksInPath().path)
    }

    func testStopFinishesStreamAndIsIdempotent() async throws {
        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let (collector, task) = startCollecting(watcher)
        defer { task.cancel() }
        watcher.stop()
        watcher.stop()
        let finished = await waitUntil { await collector.finished }
        XCTAssertTrue(finished)
        XCTAssertFalse(watcher.isRunning)
    }

    func testDeinitStopsWatching() async throws {
        var watcher: FolderWatcher? = try FolderWatcher(folder: root, options: fastOptions())
        let stream = watcher!.changes
        let collector = ChangeCollector()
        let task = Task {
            for await change in stream { await collector.append(change) }
            await collector.finish()
        }
        defer { task.cancel() }
        watcher = nil
        let finished = await waitUntil { await collector.finished }
        XCTAssertTrue(finished, "releasing the watcher must finish the stream")
    }

    func testCancellingConsumerStopsWatcher() async throws {
        let watcher = try FolderWatcher(folder: root, options: fastOptions())
        let task = Task { for await _ in watcher.changes {} }
        task.cancel()
        let stopped = await waitUntil { !watcher.isRunning }
        XCTAssertTrue(stopped)
    }
}

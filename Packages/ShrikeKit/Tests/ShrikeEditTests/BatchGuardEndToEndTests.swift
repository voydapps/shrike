//
//  BatchGuardEndToEndTests.swift
//  ShrikeEditTests
//
//  Review (round 5): a Batch rename with a swap (staging through temp names) and its Undo keep every
//  put-aside chain on the right photo. Confirmation test, green on arrival.
//

import XCTest
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchGuardEndToEndTests: XCTestCase {

    private var root: URL!
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("BatchGuard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws {
        try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
    }
    private func putAside(_ f: URL, _ s: BackupStore, _ tag: String) async throws -> BackupRecord {
        try await save(f, s, "\(tag) two")
        let chain = await s.records(for: f)
        let original = try XCTUnwrap(chain.last)
        try Data("\(tag) two plus a keyword from another app".utf8).write(to: f)
        try await save(f, s, "\(tag) shrike edit afterwards, again different")
        return original
    }
    private func guardPath(_ r: BackupRecord, _ s: BackupStore) async -> String? {
        await s.allRecords().first { $0.id == r.id }?.detachedFrom
    }

    func testASwapAndItsUndoKeepEveryGuardOnItsOwnPhoto() async throws {
        let src = root.appendingPathComponent("src")
        let a = src.appendingPathComponent("002.jpg"), b = src.appendingPathComponent("001.jpg")
        try Data("photo A".utf8).write(to: a)
        try Data("photo B".utf8).write(to: b)
        let s = store()
        let originalA = try await putAside(a, s, "A")
        let originalB = try await putAside(b, s, "B")
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: s, watchers: nil), backups: s)
        // Items [002, 001] numbered 001, 002: a true swap through the staging names.
        let plan = BatchPlan(items: [ImageGroup(primary: a), ImageGroup(primary: b)],
                             rename: try RenameTemplate(parsing: "{counter:000}", counterStart: 1), output: .inPlace)
        var final: BatchResult?
        for try await p in runner.run(plan) { if let r = p.result { final = r } }
        let result = try XCTUnwrap(final)
        XCTAssertEqual(result.doneCount, 2)
        let one = CanonicalPath.of(src.appendingPathComponent("001.jpg")), two = CanonicalPath.of(src.appendingPathComponent("002.jpg"))
        let guardA = await guardPath(originalA, s), guardB = await guardPath(originalB, s)
        XCTAssertEqual(guardA, one, "photo A was 002 and is 001 now")
        XCTAssertEqual(guardB, two, "photo B was 001 and is 002 now")

        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await s.purge(olderThan: 30)
        await s.reap()
        let ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(originalA.id) && ids.contains(originalB.id), "both originals survive the clean-up")

        _ = try await runner.undo(result)
        let backA = await guardPath(originalA, s), backB = await guardPath(originalB, s)
        XCTAssertEqual(backA, two, "Undo: photo A is 002 again")
        XCTAssertEqual(backB, one, "Undo: photo B is 001 again")
    }
}

//
//  ReplaceRetentionTests.swift
//  ShrikeIOTests
//
//  Review T2: a Replace victim is kept by the retention clock only, not by the file that now sits
//  at its path. Undo inside retention still brings it back with its Revert.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class ReplaceRetentionTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("ReplaceRetention") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }
    private func noTrashOps(_ s: BackupStore) -> FileOps {
        let trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash"))
        trash.noTrash = true
        return FileOps(metadata: nil, backups: s, watchers: nil, trashItem: { try trash.trash($0) })
    }
    private func replaced(_ ops: FileOps, incoming: URL, into dest: URL) async throws -> FileOpReceipt {
        var last: FileOpProgress?
        for try await p in ops.copy([ImageGroup(primary: incoming)], to: dest, conflicts: .always(.replace)) { last = p }
        return try XCTUnwrap(last).receipt
    }

    func testCleanUpInsideRetentionKeepsTheVictimAndUndoBringsItBackWithRevert() async throws {
        let s = store()
        let dest = try tmp.dir("dest")
        let victim = try tmp.file("x.jpg", "old victim", in: "dest")
        let incoming = try tmp.file("x.jpg", "incoming", in: "src")
        try await s.backup(victim, reason: .save)                             // the victim has history of its own
        await s.noteWritten(victim)
        let ops = noTrashOps(s)
        let receipt = try await replaced(ops, incoming: incoming, into: dest)
        let before = Set(await s.allRecords().map(\.id))
        advance(days: 1)
        await s.purge(olderThan: 30)
        await s.reap()
        let after = Set(await s.allRecords().map(\.id))
        XCTAssertEqual(after, before, "inside retention nothing is reaped")
        _ = try await ops.undo(receipt)
        let chain = await s.records(for: victim)
        XCTAssertFalse(chain.isEmpty, "the victim is back with its chain")
        XCTAssertNil(chain.first?.detachedAt)
        let availability = await s.availability(for: victim)
        XCTAssertTrue(availability.canRevert)
    }

    func testAfterRetentionTheVictimsCopiesAreReapedEvenWhileTheIncomingPhotoSitsThere() async throws {
        let s = store()
        let dest = try tmp.dir("dest")
        _ = try tmp.file("x.jpg", "old victim", in: "dest")
        let incoming = try tmp.file("x.jpg", "incoming", in: "src")
        let ops = noTrashOps(s)
        _ = try await replaced(ops, incoming: incoming, into: dest)
        let held = await s.allRecords().count
        XCTAssertGreaterThan(held, 0)
        advance(days: 40)
        await s.purge(olderThan: 30)
        let left = await s.allRecords().count
        XCTAssertEqual(left, 0, "kept by retention only: 0.2.32 dropped these after retention too")
    }

    /// A parked chain of 10 levels: reaching the depth cap must never delete earlier than the clock allows.
    func testDeepParkingNeverDeletesEarlierThanTheClockAllows() async throws {
        let root = tmp.url.appendingPathComponent("Backups")
        let now = clock.withLock { $0 }
        var records: [BackupRecord] = []
        let paths = (0..<10).map { tmp.url.appendingPathComponent("_aside/.shrike-stale-\($0)-x.jpg").path }
        for i in 0..<10 {
            let folder = root.appendingPathComponent("2026-01-01/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("x.jpg")
            try Data("copy \(i)".utf8).write(to: copy)
            let rec = BackupRecord(id: UUID(), originalPath: paths[i], backupPath: copy.path,
                                   createdAt: now.addingTimeInterval(-100 * 86_400), reason: .replace,
                                   byteSize: 6, sequence: 0, detachedAt: now,
                                   detachedFrom: i < 9 ? paths[i + 1] : nil)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            try enc.encode(rec).write(to: folder.appendingPathComponent(".shrike-backup.json"))
            records.append(rec)
        }
        let s = store()
        await s.purge(olderThan: 30)
        await s.reap()
        var ids = Set(await s.allRecords().map(\.id))
        XCTAssertEqual(ids, Set(records.map(\.id)), "none is expired: all 10 stay, even past the depth cap")
        advance(days: 40)
        await s.purge(olderThan: 30)
        ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.isEmpty, "all expire with the clock")
    }
}

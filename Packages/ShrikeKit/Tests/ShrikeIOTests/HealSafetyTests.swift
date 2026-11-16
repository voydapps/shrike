//
//  HealSafetyTests.swift
//  ShrikeIOTests
//
//  Review W4 (a guard branch moves the other guards too) and W5 (a failed restore moves no chain; since round 10 the heal runs only after the bytes).
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class HealSafetyTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("HealSafety") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws -> BackupRecord {
        let r = try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
        return r
    }

    /// W4: chain T has an older put-aside chain that guards T. Recovery guards T's chain by the path A
    /// where the photo lives; the older chain must follow, not fall to the clock.
    func testGuardingAChainByAnotherPathMovesTheOlderGuardsToo() async throws {
        let t = try tmp.file("b shrike-tmp-X.jpg", "photo B")
        let a = try tmp.file("a.jpg", "photo B at its final name")
        let s = store()
        let older = try await save(t, s, "B two")                                   // older chain ...
        try Data("B two plus a keyword from another app".utf8).write(to: t)
        let newer = try await save(t, s, "B edited again, different")              // ... guarded by t; newer chain at t
        let result = await s.detach(chainAt: t, guarding: a)
        XCTAssertEqual(result.failed, 0)
        let all = await s.allRecords()
        XCTAssertEqual(all.first { $0.id == newer.id }?.detachedFrom, CanonicalPath.of(a))
        XCTAssertEqual(all.first { $0.id == older.id }?.detachedFrom, CanonicalPath.of(a), "the older guard follows the anchor")
        try FileManager.default.removeItem(at: t)                                  // the temp name is gone for good
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        let kept = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(kept.contains(older.id) && kept.contains(newer.id), "both originals live while the photo lives at a")
    }

    /// W5: the bytes cannot be restored (the backup copy is gone). Both chains stay where they were.
    func testAFailedRestoreLeavesBothChainsWhereTheyWere() async throws {
        let p = try tmp.file("P.jpg", "victim original")
        let s = store()
        let rv = try await save(p, s, "victim edited")
        await s.detachForReplace(chainAt: p)                                       // the victim is replaced ...
        try Data("photo X".utf8).write(to: p)                                      // ... by another photo X
        let rx = try await save(p, s, "photo X edited")                            // X has its own live chain at p
        try FileManager.default.removeItem(at: rv.backupURL)                       // the restore cannot succeed

        do { try await s.restore(rv); XCTFail("the backup copy is gone") } catch {}
        let live = await s.records(for: p)
        XCTAssertTrue(live.contains { $0.id == rx.id }, "X's own chain is live at its path again")
        XCTAssertFalse(live.contains { $0.id == rv.id }, "the victim's chain is parked again")
        let record = await s.allRecords().first { $0.id == rv.id }
        XCTAssertNotNil(record?.detachedAt)
        XCTAssertNil(record?.detachedFrom, "on the clock, as before the attempt")
        let x = await s.allRecords().first { $0.id == rx.id }
        XCTAssertNil(x?.detachedAt, "X's chain is not left parked")
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8), "photo X edited", "X's file is untouched")
    }
}

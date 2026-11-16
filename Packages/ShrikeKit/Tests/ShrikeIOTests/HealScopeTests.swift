//
//  HealScopeTests.swift
//  ShrikeIOTests
//
//  Review V2: `restore(_:)` brings a parked chain back only for chains parked on the clock (Replace
//  victims, unproven histories). A chain put aside because the file was changed OUTSIDE Shrike stays
//  guarded by its path; restoring one of its records does not shuffle chains.
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class HealScopeTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("HealScope") }
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

    /// An outside change (size) puts chain C1 aside, guarded by the path; a Shrike save starts C2.
    /// Restoring a C1 record brings C1's bytes back, so C1 is the live chain again (Revert gives r1, as the
    /// single chain of 0.2.32 did) and C2, with the safety copy, is put aside under the path guard. Round 10
    /// reverses review V2: V2's churn came from healing BEFORE the bytes, which no longer happens.
    func testRestoringARecordOfAnOutsideChangeChainMakesItLiveAndGuardsTheOther() async throws {
        let f = try tmp.file("IMG.jpg", "original")
        let s = store()
        let r1 = try await save(f, s, "version two")                           // C1 = [r1]
        try Data("version two plus a keyword from another app".utf8).write(to: f)
        let r2 = try await save(f, s, "shrike edit afterwards, again different")   // C1 guarded, C2 = [r2]
        let c1 = await s.allRecords().first { $0.id == r1.id }
        XCTAssertEqual(c1?.detachedFrom, CanonicalPath.of(f))

        let safetyGot = try await s.restore(r1)
        let safety = try XCTUnwrap(safetyGot)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "original", "the old version's bytes are back")
        let live = await s.records(for: f)
        XCTAssertTrue(live.contains { $0.id == r1.id }, "C1 is the live chain again")
        XCTAssertFalse(live.contains { $0.id == r2.id || $0.id == safety.id })
        let availability = await s.availability(for: f)
        XCTAssertEqual(availability.originalRecord?.id, r1.id, "Revert gives C1's original")
        let c2Key = await s.chainKey(ofRecord: r2.id), safetyKey = await s.chainKey(ofRecord: safety.id)
        XCTAssertEqual(c2Key, safetyKey, "the safety copy is in C2")
        let c2 = await s.allRecords().first { $0.id == r2.id }
        XCTAssertEqual(c2?.detachedFrom, CanonicalPath.of(f), "C2 is guarded by the path")
        let r3 = try await save(f, s, "a Shrike save afterwards")
        let r3Key = await s.chainKey(ofRecord: r3.id), r1Key = await s.chainKey(ofRecord: r1.id)
        XCTAssertEqual(r3Key, r1Key, "the next save joins C1: no third chain")
        let keys = Set(await s.allRecords().compactMap { BackupStore.key(for: $0.originalURL) })
        XCTAssertEqual(keys.count, 2)
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        let remaining = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(remaining.contains(r1.id) && remaining.contains(r2.id), "both originals live while the file exists")
    }

    /// A Replace victim's clock-parked chain comes back, and the live chain of the photo now at the path
    /// is put aside under a guard, never merged.
    func testHealingAReplaceVictimParksTheLiveChainOfTheOtherPhotoUnderAGuard() async throws {
        let p = try tmp.file("P.jpg", "victim original")
        let s = store()
        let rv = try await save(p, s, "victim edited")
        await s.detachForReplace(chainAt: p)                                    // the victim is replaced ...
        try Data("photo X".utf8).write(to: p)                                   // ... by another photo X
        let rx = try await save(p, s, "photo X edited")                         // X has its own live chain

        try await s.restore(rv)
        // The safety copy of X's file (taken after the heal) makes the victim's stamp mismatch, so the victim's
        // chain may be put aside again, by its path. That is churn, not loss: the invariant is that X's chain
        // is never merged into it and stays under a guard.
        let atP = await s.records(for: p)
        XCTAssertFalse(atP.contains { $0.id == rx.id }, "X's chain is not merged into another photo's")
        let x = await s.allRecords().first { $0.id == rx.id }
        XCTAssertEqual(x?.detachedFrom, CanonicalPath.of(p), "X's chain is parked under a path guard")
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        let kept = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(kept.contains(rv.id) && kept.contains(rx.id), "nothing is lost")
    }

    /// V3 (a refactor, so no red run): the id -> chain map follows insert, rekey, delete and a relaunch.
    func testTheRecordKeyMapFollowsEveryChainMove() async throws {
        let f = try tmp.file("IMG.jpg", "original")
        let g = tmp.url.appendingPathComponent("IMG2.jpg")
        let s = store()
        let r = try await s.backup(f, reason: .save)
        let atF = await s.chainKey(ofRecord: r.id)
        XCTAssertEqual(atF, BackupStore.key(for: f))
        try FileManager.default.moveItem(at: f, to: g)
        await s.rekey(from: f, to: g)
        let atG = await s.chainKey(ofRecord: r.id)
        XCTAssertEqual(atG, BackupStore.key(for: g))
        let fresh = store()                                           // a relaunch builds the map from disk
        let afterRelaunch = await fresh.chainKey(ofRecord: r.id)
        XCTAssertEqual(afterRelaunch, BackupStore.key(for: g))
        let unknown = await s.chainKey(ofRecord: UUID())
        XCTAssertNil(unknown)
        advance(days: 40)
        try FileManager.default.removeItem(at: g)
        await s.purge(olderThan: 30)
        let gone = await s.chainKey(ofRecord: r.id)
        XCTAssertNil(gone, "a deleted record leaves the map")
    }
}

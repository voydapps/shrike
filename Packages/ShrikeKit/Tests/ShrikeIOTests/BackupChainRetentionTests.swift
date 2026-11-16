//
//  BackupChainRetentionTests.swift
//  ShrikeIOTests
//
//  Review F1: the fingerprint belongs to the chain, and a chain put aside is never deletable at once.
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class BackupChainRetentionTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("BackupChainRetention") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store(retention: Int = 30) -> BackupStore {
        let clock = self.clock
        return BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { retention },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }

    /// A save: back up, change the file, note the write.
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws {
        try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
    }

    func testRetentionOfTheNewestRecordKeepsRevertAndTheOriginal() async throws {
        let f = try tmp.file("IMG_1.jpg", "original")
        let s = store()
        try await save(f, s, "version two")
        try await save(f, s, "version three is longer")
        advance(days: 1)
        await s.purge(olderThan: 0)            // the newest record goes, the original stays (file exists)
        let remaining = await s.allRecords()
        XCTAssertEqual(remaining.count, 1)
        let availability = await s.availability(for: f)
        XCTAssertTrue(availability.canRevert, "the fingerprint survived the deletion of the newest record")
        let state = await s.state(for: f)
        XCTAssertEqual(state, .edited)

        // The next save puts nothing aside and the next purge still keeps the original.
        try await save(f, s, "version four, again different")
        advance(days: 1)
        await s.purge(olderThan: 0)
        let originals = await s.records(for: f)
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(originals.first?.sequence, 0, "the first backup, the original, is still there")
    }

    func testAChainPutAsideIsKeptUntilRetentionRunsOutFromThatMoment() async throws {
        let f = try tmp.file("IMG_0001.JPG", "old photo")
        let s = store()
        try await save(f, s, "old photo edited")
        // A different photo takes the path, a month and a bit later.
        advance(days: 31)
        try Data("a new photo from the card".utf8).write(to: f)
        try await save(f, s, "new photo edited")           // the old chain is put aside here
        let all = await s.allRecords()
        let oldOriginal = try XCTUnwrap(all.first { $0.reason == .save && $0.sequence == 0 && $0.detachedAt != nil })

        await s.purge(olderThan: 30)            // the old original is 31 days old, but was put aside just now
        var ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(oldOriginal.id), "not deletable at once")
        await s.reap()
        ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(oldOriginal.id))

        advance(days: 31)
        await s.purge(olderThan: 30)
        ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(oldOriginal.id), "a file still sits at the real path (round 3, N2): kept")
        try FileManager.default.removeItem(at: f)
        await s.purge(olderThan: 30)
        ids = Set(await s.allRecords().map(\.id))
        XCTAssertFalse(ids.contains(oldOriginal.id), "gone once no file is there and retention ran out from the aside date")
    }

    /// Review F9f: re-keying onto a path that already has a chain must not merge two photos' chains.
    func testRekeyOntoAPathWithAChainPutsThatChainAside() async throws {
        let p = try tmp.file("P.jpg", "photo one")
        let q = tmp.url.appendingPathComponent("Q.jpg")
        let s = store()
        let a = try await s.backup(p, reason: .save)
        await s.rekey(from: p, to: q)                       // chain A follows its photo to Q
        let b = try await s.backup(p, reason: .save)        // a different photo now sits at P: chain B
        await s.rekey(from: q, to: p)                       // photo one comes back to P
        let atP = await s.records(for: p)
        XCTAssertEqual(atP.map(\.id), [a.id], "P has photo one's chain only")
        let all = Set(await s.allRecords().map(\.id))
        XCTAssertEqual(all, [a.id, b.id], "the other photo's chain is still in the store")
    }
}

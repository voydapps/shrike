//
//  BackupDetachedFollowTests.swift
//  ShrikeIOTests
//
//  Review R1: a put-aside chain follows Shrike's own renames, moves, Trash and Undo of them,
//  so its original is not deleted just because the photo changed place.
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class BackupDetachedFollowTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("BackupDetachedFollow") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store(cap: Int64 = 0) -> BackupStore {
        let clock = self.clock
        return BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { cap }, now: { clock.withLock { $0 } })
    }
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws {
        try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
    }
    /// An outside change (size) and a Shrike save put the chain aside. Returns record 0 of that chain.
    private func putAside(_ f: URL, _ s: BackupStore) async throws -> BackupRecord {
        try await save(f, s, "version two")
        let chain = await s.records(for: f)
        let original = try XCTUnwrap(chain.last)
        try Data("version two plus a keyword from another app".utf8).write(to: f)
        try await save(f, s, "shrike edit afterwards, again different")
        return original
    }
    private func survives(_ r: BackupRecord, _ s: BackupStore) async -> Bool {
        Set(await s.allRecords().map(\.id)).contains(r.id)
    }

    func testARenameKeepsThePutAsideOriginalAlive() async throws {
        let f = try tmp.file("IMG_1.jpg", "original")
        let s = store()
        let original = try await putAside(f, s)
        let g = tmp.url.appendingPathComponent("IMG_renamed.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        await s.rekey(from: f, to: g)
        advance(days: 40)
        await s.purge(olderThan: 30)
        let kept = await survives(original, s)
        XCTAssertTrue(kept, "the photo is at its new name: the original stays")
        // After the photo is really deleted the clock applies again.
        try FileManager.default.removeItem(at: g)
        await s.purge(olderThan: 30)
        let gone = await survives(original, s)
        XCTAssertFalse(gone)
    }

    func testTheCapPassKeepsItToo() async throws {
        let f = try tmp.file("IMG_2.jpg", String(repeating: "x", count: 500))
        let s = store(cap: 1)
        let original = try await putAside(f, s)
        let g = tmp.url.appendingPathComponent("IMG_moved.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        await s.rekey(from: f, to: g)
        advance(days: 40)
        await s.reap()
        let kept = await survives(original, s)
        XCTAssertTrue(kept)
    }

    func testTrashAndPutBackKeepIt() async throws {
        let f = try tmp.file("IMG_3.jpg", "original")
        let s = store()
        let original = try await putAside(f, s)
        let trashed = try tmp.dir("_trash").appendingPathComponent("IMG_3.jpg")
        try FileManager.default.moveItem(at: f, to: trashed)
        await s.rekey(from: f, to: trashed)
        advance(days: 40)
        await s.purge(olderThan: 30)
        var kept = await survives(original, s)
        XCTAssertTrue(kept, "in the Trash the file still exists")
        try FileManager.default.moveItem(at: trashed, to: f)
        await s.rekey(from: trashed, to: f)
        await s.purge(olderThan: 30)
        kept = await survives(original, s)
        XCTAssertTrue(kept, "put back")
        let availability = await s.availability(for: f)
        XCTAssertTrue(availability.canRevert)
    }

    func testAMoveFollowedByUndoKeepsIt() async throws {
        let f = try tmp.file("IMG_4.jpg", "original", in: "src")
        let s = store()
        let original = try await putAside(f, s)
        let g = try tmp.dir("dest").appendingPathComponent("IMG_4.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        await s.rekey(from: f, to: g)
        advance(days: 40)
        await s.purge(olderThan: 30)
        var kept = await survives(original, s)
        XCTAssertTrue(kept, "moved")
        try FileManager.default.moveItem(at: g, to: f)
        await s.rekey(from: g, to: f)
        await s.purge(olderThan: 30)
        kept = await survives(original, s)
        XCTAssertTrue(kept, "Undo of the move")
    }

    func testTheRewrittenPathIsSavedOnDiskAndSurvivesARelaunch() async throws {
        let f = try tmp.file("IMG_5.jpg", "original")
        let s = store()
        let original = try await putAside(f, s)
        let g = tmp.url.appendingPathComponent("IMG_5b.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        await s.rekey(from: f, to: g)
        advance(days: 40)
        let fresh = store()
        await fresh.purge(olderThan: 30)
        let kept = await survives(original, fresh)
        XCTAssertTrue(kept)
    }

    func testAFailedWriteOfTheRewrittenPathIsCounted() async throws {
        let f = try tmp.file("IMG_6.jpg", "original")
        let s = store()
        let original = try await putAside(f, s)
        let folder = original.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let g = tmp.url.appendingPathComponent("IMG_6b.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        let failed = await s.rekey(from: f, to: g)
        XCTAssertGreaterThan(failed, 0, "the put-aside record could not be saved")
    }

    /// R3: `detach` reports a record it could not save.
    func testDetachReportsAFailedWrite() async throws {
        let f = try tmp.file("IMG_7.jpg", "original")
        let s = store()
        let rec = try await s.backup(f, reason: .save)
        let folder = rec.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let result = await s.detach(chainAt: f)
        XCTAssertGreaterThan(result.failed, 0)
    }

    /// The private core must not rewrite other chains' real path when a chain is put aside.
    func testPuttingAnotherChainAsideDoesNotRedirectTheFirstOnesRealPath() async throws {
        let f = try tmp.file("IMG_8.jpg", "original")
        let s = store()
        let first = try await putAside(f, s)               // first chain guards f
        // The file at f changes again outside; a Shrike write puts the second chain aside too.
        try Data("yet another outside change, a longer text than before".utf8).write(to: f)
        try await save(f, s, "second shrike edit")
        let all = await s.allRecords()
        let guarded = all.compactMap(\.detachedFrom)
        XCTAssertTrue(guarded.allSatisfy { $0 == CanonicalPath.of(f) }, "every put-aside chain still guards the real path: \(guarded)")
        advance(days: 40)
        await s.purge(olderThan: 30)
        let kept = await survives(first, s)
        XCTAssertTrue(kept, "a file still sits at the real path")
    }
}

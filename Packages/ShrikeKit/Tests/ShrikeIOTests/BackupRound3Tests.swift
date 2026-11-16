//
//  BackupRound3Tests.swift
//  ShrikeIOTests
//
//  Review round 3: N1 (crash between backup and noteWritten), N2 (a put-aside chain keeps its
//  original while a file sits at the real path), N3 (journal pid reuse), F2 tightening.
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class BackupRound3Tests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("BackupRound3") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private var root: URL { tmp.url.appendingPathComponent("Backups") }
    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store(retention: Int = 30, cap: Int64 = 0) -> BackupStore {
        let clock = self.clock
        return BackupStore(root: root, retentionDays: { retention }, maxBytes: { cap }, now: { clock.withLock { $0 } })
    }
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws {
        try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
    }
    private func touch(_ url: URL, secondsFromNow: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsFromNow)],
                                              ofItemAtPath: url.path)
    }

    // MARK: N1

    func testACrashBetweenBackupAndNoteWrittenKeepsRevertAndDoesNotDetach() async throws {
        let f = try tmp.file("IMG_1.jpg", "original")
        let s = store()
        try await save(f, s, "version two")
        try await s.backup(f, reason: .save)                      // a new save begins ...
        try Data("version three, longer".utf8).write(to: f)       // ... the file is replaced ...
        // ... and the app dies before noteWritten.
        let fresh = store()                                       // the relaunch
        let availability = await fresh.availability(for: f)
        XCTAssertTrue(availability.canRevert, "the newest record has no stamp: unknown, so it matches")
        try await fresh.backup(f, reason: .save)
        let all = await fresh.allRecords()
        XCTAssertTrue(all.allSatisfy { $0.detachedAt == nil }, "nothing was put aside")
        XCTAssertEqual(all.count, 3)
    }

    /// N5: a write failure on an older record must not change the match (the newest is written first).
    func testAFailedWriteOnAnOlderRecordLeavesTheNewestStampedAndTheMatchUnchanged() async throws {
        let f = try tmp.file("IMG_2.jpg", "original")
        let s = store()
        let first = try await s.backup(f, reason: .save)
        try Data("version two".utf8).write(to: f)
        await s.noteWritten(f)
        let second = try await s.backup(f, reason: .save)
        try Data("version three, longer".utf8).write(to: f)
        let oldFolder = first.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: oldFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oldFolder.path) }
        let ok = await s.noteWritten(f)
        XCTAssertFalse(ok, "the older record could not be written")
        let newest = await s.records(for: f).first
        XCTAssertEqual(newest?.id, second.id)
        XCTAssertNotNil(newest?.writtenSize, "the newest record carries the stamp")
        let relaunched = store()
        let availability = await relaunched.availability(for: f)
        XCTAssertTrue(availability.canRevert)
    }

    // MARK: N2

    /// Another app (Bridge, Lightroom) writes a keyword into the file: the size changes.
    private func putAsideByAnOutsideChange(_ f: URL, _ s: BackupStore) async throws -> BackupRecord {
        try await save(f, s, "version two")
        let chain = await s.records(for: f)
        let original = try XCTUnwrap(chain.last)
        try Data("version two plus a keyword from another app".utf8).write(to: f)
        try await save(f, s, "shrike edit afterwards, again different")      // detaches the chain here
        return original
    }

    func testAnOutsideChangeThenAShrikeWriteDoesNotLetPurgeDeleteTheOriginal() async throws {
        let f = try tmp.file("IMG_3.jpg", "original")
        let s = store()
        let original = try await putAsideByAnOutsideChange(f, s)
        advance(days: 40)
        await s.purge(olderThan: 0)
        let ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(original.id), "a file still sits at the real path: the original is kept (0.2.32 rule)")
    }

    func testTheCapPassAlsoKeepsThatOriginalAndTheStoreReportsBeingOverTheCap() async throws {
        let f = try tmp.file("IMG_4.jpg", String(repeating: "x", count: 500))
        let s = store(cap: 1)
        let original = try await putAsideByAnOutsideChange(f, s)
        advance(days: 40)
        let report = await s.reap()
        let ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(original.id))
        XCTAssertTrue(report.overCap)
        let usage = await s.usage()
        XCTAssertTrue(usage.isOverCap)
    }

    func testWhenNoFileSitsAtTheRealPathRetentionFromThePutAsideDateApplies() async throws {
        let f = try tmp.file("IMG_5.jpg", "original")
        let s = store()
        let original = try await putAsideByAnOutsideChange(f, s)
        try FileManager.default.removeItem(at: f)
        await s.purge(olderThan: 30)
        var ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(original.id), "retention has not run out from the put-aside moment")
        advance(days: 40)
        await s.purge(olderThan: 30)
        ids = Set(await s.allRecords().map(\.id))
        XCTAssertFalse(ids.contains(original.id), "no file at the path and retention is over: reaped")
    }

    // MARK: F2 tightening

    func testSameSizeDifferentBytesAndADateOneSecondAwayIsNotTheSameFile() async throws {
        let f = try tmp.file("a.jpg", "original")
        let s = store()
        try await save(f, s, "edited!!")
        try Data("EDITED??".utf8).write(to: f)             // same size, other bytes
        try touch(f, secondsFromNow: 1)                    // within the old 2 s tolerance, not exactly equal
        let availability = await s.availability(for: f)
        XCTAssertFalse(availability.canRevert, "with a stored hash only an exactly equal date skips the hash")
    }

    func testAHashedChainWithAOneSecondDateDriftIsConfirmedByHashAndRestamped() async throws {
        let f = try tmp.file("a.jpg", "original")
        let s = store()
        try await save(f, s, "edited!!")
        let before = await s.records(for: f).first?.writtenModified
        try touch(f, secondsFromNow: 1)
        let availability = await s.availability(for: f)
        XCTAssertTrue(availability.canRevert)
        let after = await s.records(for: f).first?.writtenModified
        XCTAssertNotEqual(before, after, "same bytes: the new date is remembered")
    }

    func testAnOldHashFromBeforeTheMiddleSampleStillComparesTheOldWay() async throws {
        let f = try tmp.file("big.bin", String(repeating: "a", count: 3_500_000))
        let s = store()
        let rec = try await s.backup(f, reason: .save)
        let legacySum = try BackupStore.fingerprint(f).sum          // v1: size, first and last MiB
        let stamp = try XCTUnwrap(BackupStore.writeStamp(of: f))
        let legacy = BackupRecord(id: rec.id, originalPath: rec.originalPath, backupPath: rec.backupPath,
                                  createdAt: rec.createdAt, reason: rec.reason, byteSize: rec.byteSize,
                                  checksum: rec.checksum, sequence: rec.sequence, writtenSize: stamp.size,
                                  writtenModified: stamp.modified, writtenChecksum: legacySum)   // no version prefix
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacy).write(to: rec.backupURL.deletingLastPathComponent().appendingPathComponent(".shrike-backup.json"))
        try touch(f, secondsFromNow: 600)                         // other date, same bytes
        let fresh = store()
        let availability = await fresh.availability(for: f)
        XCTAssertTrue(availability.canRevert, "an unversioned hash is compared the v1 way")
    }

    func testANewHashSeesAChangeInTheMiddleOfALargeFile() async throws {
        var bytes = [UInt8](repeating: 7, count: 3_500_000)
        let f = tmp.url.appendingPathComponent("big2.bin")
        try Data(bytes).write(to: f)
        let s = store()
        try await s.backup(f, reason: .save)
        await s.noteWritten(f)
        bytes[1_750_000] = 8                                       // only the middle changes, same size
        try Data(bytes).write(to: f)
        try touch(f, secondsFromNow: 600)
        let availability = await s.availability(for: f)
        XCTAssertFalse(availability.canRevert, "the middle MiB is part of the hash now")
    }

    // MARK: N3 (journal pid reuse)

    func testAnEntryWhoseWriterPidNowBelongsToAnOlderRunningProcessIsLeftAlone() async throws {
        let j = RenameJournal(directory: try tmp.dir("_journal"))
        let original = tmp.url.appendingPathComponent("IMG.jpg")
        let temp = try tmp.file(".shrike-rename-X-IMG.jpg", "photo")
        // pid 1 (launchd) started at boot, before this entry was written: it may be the writer.
        j.write(RenameJournalEntry(id: UUID(), created: Date(),
                                   moves: [.init(original: original.path, temporary: temp.path)], pid: 1))
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(report.restored.isEmpty)
    }

    func testAnEntryWhosePidWasReusedByALaterProcessIsHandled() async throws {
        let j = RenameJournal(directory: try tmp.dir("_journal"))
        let original = tmp.url.appendingPathComponent("IMG.jpg")
        let temp = try tmp.file(".shrike-rename-X-IMG.jpg", "photo")
        // After a reboot pid 1 belongs to a process that started AFTER the entry was written.
        j.write(RenameJournalEntry(id: UUID(), created: .distantPast,
                                   moves: [.init(original: original.path, temporary: temp.path)], pid: 1))
        let report = await FileOps(metadata: nil, backups: nil, watchers: nil).recoverRenames(journal: j, startedBefore: Date())
        XCTAssertEqual(report.restored, [original])
    }
}

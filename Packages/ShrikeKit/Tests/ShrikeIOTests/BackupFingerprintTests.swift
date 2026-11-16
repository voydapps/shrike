//
//  BackupFingerprintTests.swift
//  ShrikeIOTests
//
//  Audit B-3: a backup chain applies only while the file on disk is still the one Shrike
//  last wrote (size + modification time). No sleeps: the time is set with setAttributes.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class BackupFingerprintTests: XCTestCase {

    var tmp: IOTempDir!
    var root: URL { tmp.url.appendingPathComponent("Backups", isDirectory: true) }

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("BackupFingerprint")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func touch(_ url: URL, secondsFromNow: TimeInterval) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(secondsFromNow)],
                                              ofItemAtPath: url.path)
    }

    /// A save: back up, change the file, note the write.
    private func save(_ url: URL, _ store: BackupStore, newBytes: String, reason: BackupReason = .save) async throws {
        try await store.backup(url, reason: reason)
        try Data(newBytes.utf8).write(to: url)
        await store.noteWritten(url)
    }

    func testChainAppliesWhileTheFileIsTheOneShrikeWrote() async throws {
        let f = try tmp.file("IMG_1.jpg", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited")
        let state = await store.state(for: f)
        XCTAssertEqual(state, .edited)
        let availability = await store.availability(for: f)
        XCTAssertTrue(availability.canRevert)
        let record = try await store.revertToOriginal(f)
        XCTAssertEqual(record.reason, .revert)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "original")
    }

    func testADifferentFileAtTheSamePathHidesTheChainButKeepsItInTheStore() async throws {
        let f = try tmp.file("IMG_0001.JPG", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited")
        // The card is formatted; a new photo takes the same name (other bytes, other date).
        try Data("a completely different photo".utf8).write(to: f)
        try touch(f, secondsFromNow: 3600)

        let state = await store.state(for: f)
        XCTAssertEqual(state, .none, "no edited badge")
        let states = await store.states(for: [f])
        XCTAssertEqual(states[f], BackupState.none)
        let availability = await store.availability(for: f)
        XCTAssertFalse(availability.canRevert, "Revert to Original is not offered")
        do {
            _ = try await store.revertToOriginal(f)
            XCTFail("must not revert")
        } catch {
            XCTAssertEqual(error as? BackupError, .backupMissing)
        }
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "a completely different photo")
        let all = await store.allRecords()
        XCTAssertEqual(all.count, 1, "the record stays until the normal clean-up")
    }

    /// Review F2: another app, a sync tool or a FAT volume changes only the date.
    func testChangedDateAloneKeepsTheChainAndTheNewDateIsRemembered() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited")
        let beforeraw = await store.records(for: f).first?.writtenModified
        let before = try XCTUnwrap(beforeraw)
        try touch(f, secondsFromNow: 7200)   // same size, same bytes, new date
        let state = await store.state(for: f)
        XCTAssertEqual(state, .edited)
        let availability = await store.availability(for: f)
        XCTAssertTrue(availability.canRevert)
        let afterraw = await store.records(for: f).first?.writtenModified
        let after = try XCTUnwrap(afterraw)
        XCTAssertGreaterThan(after, before + 3_600_000_000_000, "the new date was stored: the hash is paid once")
    }

    /// With a stored hash only an exactly equal date skips it (round 3); the 2 s tolerance is for old chains.
    func testAHashedChainWithAnExactDateNeedsNoHash() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited")
        let state = await store.state(for: f)
        XCTAssertEqual(state, .edited)
        let storedRaw = await store.records(for: f).first?.writtenModified
        XCTAssertEqual(try XCTUnwrap(storedRaw), try XCTUnwrap(BackupStore.writeStamp(of: f)).modified)
    }

    func testSameSizeButDifferentBytesAndADifferentDateHidesTheChain() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited!!")
        try Data("EDITED??".utf8).write(to: f)          // same size, other bytes
        try touch(f, secondsFromNow: 7200)
        let state = await store.state(for: f)
        XCTAssertEqual(state, .none, "Revert must never apply an original to a file with other content")
        let availability = await store.availability(for: f)
        XCTAssertFalse(availability.canRevert)
    }

    /// A chain written by the first version of the fingerprint has no hash: the date tolerance is all it has.
    func testAChainWithoutAHashFallsBackToTheDateTolerance() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .save)
        try Data("edited".utf8).write(to: f)
        let stamp = try XCTUnwrap(BackupStore.writeStamp(of: f))
        let legacy = BackupRecord(id: rec.id, originalPath: rec.originalPath, backupPath: rec.backupPath,
                                  createdAt: rec.createdAt, reason: rec.reason, byteSize: rec.byteSize,
                                  checksum: rec.checksum, sequence: rec.sequence,
                                  writtenSize: stamp.size, writtenModified: stamp.modified)
        try JSONEncoder.iso.encode(legacy).write(to: rec.backupURL.deletingLastPathComponent()
            .appendingPathComponent(".shrike-backup.json"))
        let fresh = BackupStore(root: root)
        let kept = await fresh.state(for: f)
        XCTAssertEqual(kept, .edited)
        try touch(f, secondsFromNow: 1)                    // inside the 2 s tolerance
        let drifted = await fresh.state(for: f)
        XCTAssertEqual(drifted, .edited, "a chain without a hash keeps the date tolerance")
        try touch(f, secondsFromNow: 7200)
        let hidden = await fresh.state(for: f)
        XCTAssertEqual(hidden, .none)
    }

    func testRecordsWithoutAFingerprintKeepWorkingAsBefore() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await store.backup(f, reason: .save)      // no noteWritten: an old-style record
        try Data("edited".utf8).write(to: f)
        try touch(f, secondsFromNow: 7200)
        let state = await store.state(for: f)
        XCTAssertEqual(state, .edited)
        let availability = await store.availability(for: f)
        XCTAssertTrue(availability.canRevert)
    }

    func testOldJSONWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {"backupPath":"/b/x.jpg","createdAt":"2026-01-01T00:00:00Z","id":"\(UUID().uuidString)",\
        "originalPath":"/p/x.jpg","reason":"save"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let rec = try decoder.decode(BackupRecord.self, from: Data(json.utf8))
        XCTAssertNil(rec.writtenSize)
        XCTAssertNil(rec.writtenModified)
    }

    func testTheFingerprintSurvivesARelaunch() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "edited")
        let fresh = BackupStore(root: root)
        let before = await fresh.state(for: f)
        XCTAssertEqual(before, .edited)
        try Data("another photo entirely".utf8).write(to: f)   // other size and bytes
        try touch(f, secondsFromNow: 7200)
        let after = await fresh.state(for: f)
        XCTAssertEqual(after, .none)
    }

    func testANewSaveOverADifferentPhotoStartsItsOwnChain() async throws {
        let f = try tmp.file("IMG_0001.JPG", "old photo")
        let store = BackupStore(root: root)
        try await save(f, store, newBytes: "old photo edited")
        try Data("new photo".utf8).write(to: f)
        try touch(f, secondsFromNow: 3600)
        // The user edits the new photo.
        try await save(f, store, newBytes: "new photo edited")

        let chain = await store.records(for: f)
        XCTAssertEqual(chain.count, 1, "only the new photo's own backup")
        _ = try await store.revertToOriginal(f)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "new photo",
                       "Revert gives back the new photo, never the old one")
        let all = await store.allRecords()
        XCTAssertEqual(all.count, 3, "the old photo's backups (original + the revert safety) are not deleted")
    }

    // MARK: B-8

    func testRekeyReportsARecordThatCouldNotBeWritten() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        let record = try await store.backup(f, reason: .save)
        let folder = record.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

        let failed = await store.rekey(from: f, to: tmp.url.appendingPathComponent("b.jpg"))
        XCTAssertEqual(failed, 1)
        let moved = await store.records(for: tmp.url.appendingPathComponent("b.jpg"))
        XCTAssertEqual(moved.count, 1, "the chain still follows the file in memory")
    }

    func testRekeyReportsZeroWhenEverythingIsSaved() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await store.backup(f, reason: .save)
        let failed = await store.rekey(from: f, to: tmp.url.appendingPathComponent("b.jpg"))
        XCTAssertEqual(failed, 0)
        let fresh = BackupStore(root: root)
        let after = await fresh.records(for: tmp.url.appendingPathComponent("b.jpg"))
        XCTAssertEqual(after.count, 1, "saved on disk, so it survives a relaunch")
    }

    // MARK: B-11

    func testUsageSaysWhetherTheStoreIsOverItsCap() async throws {
        let f = try tmp.file("a.jpg", String(repeating: "x", count: 1000))
        let capped = BackupStore(root: root, retentionDays: { 30 }, maxBytes: { 500 }, now: { Date() })
        try await capped.backup(f, reason: .save)
        let over = await capped.usage()
        XCTAssertEqual(over.usedBytes, 1000)
        XCTAssertEqual(over.capBytes, 500)
        XCTAssertTrue(over.isOverCap)

        let roomy = BackupStore(root: root, retentionDays: { 30 }, maxBytes: { 10_000 }, now: { Date() })
        let fine = await roomy.usage()
        XCTAssertFalse(fine.isOverCap)
        let uncapped = BackupStore(root: root, retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() })
        let none = await uncapped.usage()
        XCTAssertFalse(none.isOverCap, "a cap of 0 means no cap")
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

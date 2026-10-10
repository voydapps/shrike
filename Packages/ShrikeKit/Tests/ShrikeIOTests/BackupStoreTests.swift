//
//  BackupStoreTests.swift
//  ShrikeIOTests
//
//  Every store here lives under a temp root — never the real
//  Application Support folder.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class BackupStoreTests: XCTestCase {

    var tmp: IOTempDir!
    var root: URL { tmp.url.appendingPathComponent("Backups", isDirectory: true) }

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("Backup")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    func test_defaultRoot_isBundleIDFolderInApplicationSupport() {
        XCTAssertTrue(BackupStore.defaultRoot.path.hasSuffix(
            "Application Support/app.shrike/Backups"))
    }

    func test_backup_layoutAndRecord() async throws {
        let f = try tmp.file("IMG_1.jpg", "original")
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .rotate)

        XCTAssertEqual(readString(rec.backupURL), "original")
        XCTAssertEqual(rec.backupURL.lastPathComponent, "IMG_1.jpg")
        let uuidDir = rec.backupURL.deletingLastPathComponent()
        XCTAssertEqual(uuidDir.lastPathComponent, rec.id.uuidString)
        let dayDir = uuidDir.deletingLastPathComponent()
        XCTAssertEqual(dayDir.lastPathComponent, BackupStore.dayFolderName(for: rec.createdAt))
        XCTAssertEqual(dayDir.deletingLastPathComponent().path, root.path)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: uuidDir.appendingPathComponent(".shrike-backup.json").path))
        XCTAssertEqual(rec.reason, .rotate)
        XCTAssertEqual(rec.originalPath, f.path)
        XCTAssertEqual(rec.byteSize, 8)
    }

    func test_everyRotateTakesABackup() async throws {
        let f = try tmp.file("a.jpg", "v0")
        let store = BackupStore(root: root)
        try await store.backup(f, reason: .rotate)
        try await store.backup(f, reason: .rotate)
        let n = await store.records(for: f).count
        XCTAssertEqual(n, 2)
    }

    func test_latest_returnsNewest() async throws {
        let f = try tmp.file("a.jpg", "v1")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let box = ClockBox(clock)
        let store = BackupStore(root: root, now: { box.value })
        let r1 = try await store.backup(f, reason: .save)
        try Data("v2".utf8).write(to: f)
        clock.addTimeInterval(60); box.value = clock
        let r2 = try await store.backup(f, reason: .save)
        let latest = await store.latest(for: f)
        XCTAssertEqual(latest?.id, r2.id)
        let all = await store.records(for: f)
        XCTAssertEqual(all.map(\.id), [r2.id, r1.id])
        let other = await store.latest(for: tmp.url.appendingPathComponent("other.jpg"))
        XCTAssertNil(other)
    }

    func test_restore_putsOriginalBack_andBacksUpCurrent() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .save)
        try Data("edited".utf8).write(to: f)

        let safety = try await store.restore(rec)
        XCTAssertEqual(readString(f), "original")
        let s = try XCTUnwrap(safety)
        XCTAssertEqual(s.reason, .restore)
        XCTAssertEqual(readString(s.backupURL), "edited", "restore is itself undoable")
        XCTAssertEqual(readString(rec.backupURL), "original", "backup kept for repeat restores")
    }

    func test_restore_whenOriginalDeleted_recreatesIt() async throws {
        let f = try tmp.file("gone.jpg", "original")
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .save)
        try FileManager.default.removeItem(at: f)
        let safety = try await store.restore(rec)
        XCTAssertNil(safety)
        XCTAssertEqual(readString(f), "original")
    }

    func test_backup_missingSourceThrows() async {
        let store = BackupStore(root: root)
        do {
            _ = try await store.backup(tmp.url.appendingPathComponent("nope.jpg"), reason: .save)
            XCTFail("expected throw")
        } catch let e as BackupError {
            XCTAssertEqual(e, .sourceMissing)
        } catch { XCTFail("\(error)") }
    }

    func test_backup_unwritableRootThrows_andLeavesNothing() async throws {
        let f = try tmp.file("a.jpg")
        let blocker = try tmp.file("blocker")
        let store = BackupStore(root: blocker.appendingPathComponent("Backups"))
        do {
            _ = try await store.backup(f, reason: .save)
            XCTFail("expected throw")
        } catch let e as BackupError {
            guard case .copyFailed = e else { return XCTFail("wrong error \(e)") }
        }
    }

    // MARK: - Retention

    func test_purge_removesOnlyExpired_butKeepsOriginalOfExistingFile() async throws {
        let f = try tmp.file("a.jpg", "x")
        let now = Date()
        let old = BackupStore(root: root, retentionDays: { -1 },
                              now: { now.addingTimeInterval(-40 * 86_400) })
        let origRec = try await old.backup(f, reason: .save)
        let oldRec2 = try await old.backup(f, reason: .save)
        let fresh = BackupStore(root: root, retentionDays: { -1 }, now: { now })
        let newRec = try await fresh.backup(f, reason: .batch)

        let removed = await fresh.purge(olderThan: 30)
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: origRec.backupPath),
                      "the original of a file that still exists is never purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRec2.backupPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newRec.backupPath))
    }

    func test_purge_originalGoesOnceFileIsGone() async throws {
        let f = try tmp.file("a.jpg", "x")
        let now = Date()
        let old = BackupStore(root: root, retentionDays: { -1 },
                              now: { now.addingTimeInterval(-40 * 86_400) })
        let oldRec = try await old.backup(f, reason: .save)
        try FileManager.default.removeItem(at: f)
        let fresh = BackupStore(root: root, retentionDays: { -1 }, now: { now })
        let removed = await fresh.purge(olderThan: 30)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRec.backupPath))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: oldRec.backupURL.deletingLastPathComponent().deletingLastPathComponent().path),
            "empty day folder removed")
    }

    func test_firstBackupOfSession_reapsExpired() async throws {
        let f = try tmp.file("a.jpg", "x")
        let other = try tmp.file("b.jpg", "y")
        let now = Date()
        let old = BackupStore(root: root, retentionDays: { -1 },
                              now: { now.addingTimeInterval(-40 * 86_400) })
        let oldRec = try await old.backup(other, reason: .save)
        try FileManager.default.removeItem(at: other)
        let fresh = BackupStore(root: root, retentionDays: { 30 }, now: { now })
        _ = try await fresh.backup(f, reason: .save)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldRec.backupPath))
    }

    // MARK: - Verification

    func test_backup_storesSizeAndChecksum_forLargeFile() async throws {
        // 3 MiB: head and tail windows do not overlap.
        let f = tmp.url.appendingPathComponent("big.tif")
        var bytes = [UInt8](repeating: 0, count: 3 << 20)
        for i in stride(from: 0, to: bytes.count, by: 4093) { bytes[i] = UInt8(i % 251) }
        try Data(bytes).write(to: f)
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .save)
        XCTAssertEqual(rec.byteSize, Int64(bytes.count))
        let expected = try BackupStore.fingerprint(f)
        XCTAssertEqual(rec.checksum, expected.sum)
        XCTAssertEqual(rec.checksum?.count, 64)
    }

    func test_fingerprint_detectsTailChange() throws {
        let a = tmp.url.appendingPathComponent("a.bin")
        let b = tmp.url.appendingPathComponent("b.bin")
        var bytes = [UInt8](repeating: 7, count: 5 << 20)
        try Data(bytes).write(to: a)
        bytes[bytes.count - 10] = 8
        try Data(bytes).write(to: b)
        XCTAssertNotEqual(try BackupStore.fingerprint(a).sum, try BackupStore.fingerprint(b).sum)
    }

    func test_backup_badCopyThrowsCopyFailed_andLeavesNothing() async throws {
        let f = try tmp.file("a.jpg", "original bytes")
        let store = BackupStore(
            root: root, retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() },
            copier: { _, to in try Data("truncated".utf8).write(to: to) })
        do {
            _ = try await store.backup(f, reason: .save)
            XCTFail("expected throw")
        } catch let e as BackupError {
            guard case .copyFailed(let why) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertTrue(why.contains("verification"), why)
        }
        let all = await store.allRecords()
        XCTAssertTrue(all.isEmpty)
        let days = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        for d in days {
            let entries = try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent(d).path)
            XCTAssertTrue(entries.isEmpty, "bad copy folder removed")
        }
    }

    func test_backup_outOfSpaceMapsToInsufficientSpace() async throws {
        let f = try tmp.file("a.jpg")
        let store = BackupStore(
            root: root, retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() },
            copier: { _, _ in
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            })
        do {
            _ = try await store.backup(f, reason: .save)
            XCTFail("expected throw")
        } catch let e as BackupError {
            guard case .insufficientSpace(let name) = e else { return XCTFail("wrong error \(e)") }
            XCTAssertFalse(name.isEmpty)
        }
    }

    // MARK: - State, revert

    func test_state_noneEditedReverted() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        let s0 = await store.state(for: f)
        XCTAssertEqual(s0, .none)

        try await store.backup(f, reason: .save)
        try Data("edit 1".utf8).write(to: f)
        try await store.backup(f, reason: .rotate)
        try Data("edit 2".utf8).write(to: f)
        let s1 = await store.state(for: f)
        XCTAssertEqual(s1, .edited)

        FileAttributes.setRating(4, at: f)
        let pre = try await store.revertToOriginal(f)
        XCTAssertEqual(readString(f), "original")
        XCTAssertEqual(pre.reason, .revert)
        XCTAssertEqual(readString(pre.backupURL), "edit 2", "pre-revert bytes kept")
        XCTAssertEqual(FileAttributes.rating(at: f), 4, "rating xattr carried across revert")
        let s2 = await store.state(for: f)
        XCTAssertEqual(s2, .reverted)

        let other = try tmp.file("b.jpg")
        let batch = await store.states(for: [f, other])
        XCTAssertEqual(batch, [f: .reverted, other: BackupState.none])

        // Undo the revert: restore the pre-revert record.
        try await store.restore(pre)
        XCTAssertEqual(readString(f), "edit 2")
        let s3 = await store.state(for: f)
        XCTAssertEqual(s3, .edited)
    }

    func test_state_restoreOfOriginalReadsReverted() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        let rec = try await store.backup(f, reason: .rotate)
        try Data("rotated".utf8).write(to: f)
        try await store.restore(rec)            // undo rotate
        let s = await store.state(for: f)
        XCTAssertEqual(s, .reverted)
    }

    func test_revertToOriginal_withoutHistoryThrows() async throws {
        let f = try tmp.file("a.jpg")
        let store = BackupStore(root: root)
        do {
            _ = try await store.revertToOriginal(f)
            XCTFail("expected throw")
        } catch let e as BackupError {
            XCTAssertEqual(e, .backupMissing)
        }
    }

    func test_rekey_movesChain() async throws {
        let f = try tmp.file("a.jpg", "v1")
        let store = BackupStore(root: root)
        try await store.backup(f, reason: .save)
        let g = tmp.url.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: f, to: g)
        await store.rekey(from: f, to: g)
        let s = await store.state(for: g)
        XCTAssertEqual(s, .edited)
        let fresh = BackupStore(root: root)
        let recs = await fresh.records(for: g)
        XCTAssertEqual(recs.count, 1, "rekey persisted in the record file")
    }

    // MARK: - Size cap

    func test_reap_capRemovesOldestNonOriginalsFirst_keepsYoungAndOriginals() async throws {
        let a = try tmp.file("a.jpg", String(repeating: "a", count: 1000))
        let b = try tmp.file("b.jpg", String(repeating: "b", count: 1000))
        let now = Date()
        let clock = ClockBox(now.addingTimeInterval(-10 * 86_400))
        let writer = BackupStore(root: root, retentionDays: { -1 }, maxBytes: { 0 },
                                 now: { clock.value })
        let aOrig = try await writer.backup(a, reason: .save)       // day -10, original
        clock.value = now.addingTimeInterval(-9 * 86_400)
        let a2 = try await writer.backup(a, reason: .save)          // day -9
        clock.value = now.addingTimeInterval(-8 * 86_400)
        let bOrig = try await writer.backup(b, reason: .save)       // day -8, original
        clock.value = now.addingTimeInterval(-7 * 86_400)
        let b2 = try await writer.backup(b, reason: .save)          // day -7
        clock.value = now.addingTimeInterval(-3600)
        let a3 = try await writer.backup(a, reason: .save)          // 1 h old: protected

        let store = BackupStore(root: root, retentionDays: { -1 }, maxBytes: { 3500 },
                                now: { now })
        let before = await store.totalBytes()
        XCTAssertEqual(before, 5000)
        let report = await store.reap()
        XCTAssertEqual(report.removed, 2)
        XCTAssertEqual(report.freedBytes, 2000)
        XCTAssertEqual(report.totalBytes, 3000)
        XCTAssertFalse(report.overCap)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: a2.backupPath))
        XCTAssertFalse(fm.fileExists(atPath: b2.backupPath))
        for kept in [aOrig, bOrig, a3] { XCTAssertTrue(fm.fileExists(atPath: kept.backupPath)) }

        // Tighter cap: nothing else is eligible while a and b exist.
        let tight = BackupStore(root: root, retentionDays: { -1 }, maxBytes: { 100 }, now: { now })
        let r2 = await tight.reap()
        XCTAssertEqual(r2.removed, 0)
        XCTAssertTrue(r2.overCap)

        // Once b is gone its original becomes eligible.
        try fm.removeItem(at: b)
        let r3 = await tight.reap()
        XCTAssertEqual(r3.removed, 1)
        XCTAssertFalse(fm.fileExists(atPath: bOrig.backupPath))
    }
}

/// Mutable clock for tests (only touched from the test's own task).
final class ClockBox: @unchecked Sendable {
    // @unchecked: test-only; written before each awaited call, never concurrently.
    var value: Date
    init(_ v: Date) { value = v }
}

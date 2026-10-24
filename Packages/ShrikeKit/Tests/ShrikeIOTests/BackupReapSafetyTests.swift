//
//  BackupReapSafetyTests.swift
//  ShrikeIOTests
//
//  Audit 2026-10-24 FS-3: the cleanup must not delete the original backup
//  of a photo whose disk is unplugged or whose iCloud file was evicted.
//  Temp roots only.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class BackupReapSafetyTests: XCTestCase {

    var tmp: IOTempDir!
    var root: URL { tmp.url.appendingPathComponent("Backups", isDirectory: true) }

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("BackupReapSafety")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func oldRecord(for file: URL) async throws -> (BackupStore, BackupRecord) {
        let now = Date()
        let old = BackupStore(root: root, retentionDays: { -1 }, now: { now.addingTimeInterval(-40 * 86_400) })
        let record = try await old.backup(file, reason: .save)
        let fresh = BackupStore(root: root, retentionDays: { 30 }, now: { now })
        return (fresh, record)
    }

    func testUnmountedVolumeKeepsTheOriginal() async throws {
        let f = try tmp.file("a.jpg", "x")
        let (store, record) = try await oldRecord(for: f)
        // The photo's disk is not mounted: the chain points under /Volumes/<missing>.
        let gone = URL(fileURLWithPath: "/Volumes/ShrikeNoSuchDisk-\(UUID().uuidString)/Photos/a.jpg")
        await store.rekey(from: f, to: gone)
        let removed = await store.purge(olderThan: 30)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
        let report = await store.reap()
        XCTAssertEqual(report.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
    }

    func testEvictedICloudFileKeepsTheOriginal() async throws {
        let f = try tmp.file("a.jpg", "x")
        let (store, record) = try await oldRecord(for: f)
        try FileManager.default.removeItem(at: f)
        _ = try tmp.file(".a.jpg.icloud", "placeholder")   // all that is left of an evicted file
        let removed = await store.purge(olderThan: 30)
        XCTAssertEqual(removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.backupPath))
    }

    func testFileTrulyGoneInAPresentFolderStillPurges() async throws {
        let f = try tmp.file("a.jpg", "x")
        let (store, record) = try await oldRecord(for: f)
        try FileManager.default.removeItem(at: f)
        let removed = await store.purge(olderThan: 30)
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.backupPath))
    }

    func testPredicate() {
        XCTAssertTrue(BackupStore.originalMayStillExist(atPath: "/Volumes/ShrikeNoSuchDisk/x/a.jpg"))
        XCTAssertFalse(BackupStore.originalMayStillExist(atPath: tmp.url.appendingPathComponent("missing.jpg").path))
        XCTAssertFalse(BackupStore.originalMayStillExist(atPath: "/Users/ShrikeNoSuchUser/Pictures/a.jpg"))
    }
}

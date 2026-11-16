//
//  BackupsNotSavedTests.swift
//  ShrikeIOTests
//
//  Review B-8: every operation says how many PHOTOS' backup information could not be saved.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class BackupsNotSavedTests: XCTestCase {

    var tmp: IOTempDir!
    var root: URL { tmp.url.appendingPathComponent("Backups", isDirectory: true) }

    override func setUp() { super.setUp(); tmp = IOTempDir("BackupsNotSaved") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    // MARK: B-8, review: photos, not records

    private func lockedStore(for f: URL, records: Int) async throws -> (BackupStore, [URL]) {
        let store = BackupStore(root: root)
        var folders: [URL] = []
        for _ in 0..<records {
            let rec = try await store.backup(f, reason: .save)
            folders.append(rec.backupURL.deletingLastPathComponent())
        }
        return (store, folders)
    }

    func testARenameReportsOnePhotoWhateverTheNumberOfRecords() async throws {
        let f = try tmp.file("a.jpg", "original")
        let (store, folders) = try await lockedStore(for: f, records: 3)       // three records, one photo
        for folder in folders { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in folders { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }
        let ops = FileOps(metadata: nil, backups: store, watchers: nil)
        let result = try await ops.renameReporting(ImageGroup(primary: f), toStem: "b")
        XCTAssertEqual(result.backupsNotSaved, 1, "photos, not records")
        XCTAssertEqual(result.group.primary.lastPathComponent, "b.jpg")
    }

    func testAnOrdinaryRenameReportsZero() async throws {
        let f = try tmp.file("a.jpg", "original")
        let store = BackupStore(root: root)
        try await store.backup(f, reason: .save)
        let ops = FileOps(metadata: nil, backups: store, watchers: nil)
        let result = try await ops.renameReporting(ImageGroup(primary: f), toStem: "b")
        XCTAssertEqual(result.backupsNotSaved, 0)
        let again = try await ops.rename(result.group, toStem: "a")        // the old API still works
        XCTAssertEqual(again.primary.lastPathComponent, "a.jpg")
    }

    func testTrashAndUndoOfAMoveCarryTheCount() async throws {
        let f = try tmp.file("a.jpg", "original", in: "src")
        let dest = try tmp.dir("dest")
        let (store, folders) = try await lockedStore(for: f, records: 2)
        for folder in folders { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path) }
        defer { for folder in folders { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) } }
        let fakeTrash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash"))
        let ops = FileOps(metadata: nil, backups: store, watchers: nil, trashItem: { try fakeTrash.trash($0) })
        var last: FileOpProgress?
        for try await p in ops.move([ImageGroup(primary: f)], to: dest, conflicts: .always(.keepBoth)) { last = p }
        XCTAssertEqual(last?.receipt.backupsNotSaved, 1)
        let undone = try await ops.undo(try XCTUnwrap(last).receipt)
        XCTAssertEqual(undone, 1, "the records are still locked, so moving the chain back fails again")
        let trashed = try await ops.trash([ImageGroup(primary: f)])
        XCTAssertEqual(trashed.backupsNotSaved, 1, "Trash re-keys the chain too")
    }
}

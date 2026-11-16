//
//  GuardOwnershipTests.swift
//  ShrikeIOTests
//
//  Review S2 (guards stay with the photo they belong to) and S3 (no file is un-undoable because
//  of a cache size).
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class GuardOwnershipTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("GuardOwnership") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }
    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }
    private func save(_ f: URL, _ s: BackupStore, _ text: String) async throws {
        try await s.backup(f, reason: .save)
        try Data(text.utf8).write(to: f)
        await s.noteWritten(f)
    }
    private func putAside(_ f: URL, _ s: BackupStore) async throws -> BackupRecord {
        try await save(f, s, "version two")
        let chain = await s.records(for: f)
        let original = try XCTUnwrap(chain.last)
        try Data("version two plus a keyword from another app".utf8).write(to: f)
        try await save(f, s, "shrike edit afterwards, again different")
        return original
    }

    // MARK: S2

    /// A victim with an older put-aside chain is replaced (volume with no Trash) by a moved-in photo;
    /// the move is undone; the incoming photo is deleted later. The victim's older chain must not go.
    func testAReplacedPhotosOlderGuardDoesNotLeaveWithTheIncomingPhoto() async throws {
        let s = store()
        let dest = try tmp.dir("dest")
        let victim = try tmp.file("IMG.jpg", "victim original", in: "dest")
        let incoming = try tmp.file("IMG.jpg", "incoming photo", in: "src")
        let older = try await putAside(victim, s)
        let trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash"))
        trash.noTrash = true
        let ops = FileOps(metadata: nil, backups: s, watchers: nil, trashItem: { try trash.trash($0) })
        var last: FileOpProgress?
        for try await p in ops.move([ImageGroup(primary: incoming)], to: dest, conflicts: .always(.replace)) { last = p }
        _ = try await ops.undo(try XCTUnwrap(last).receipt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path), "the victim is back")
        try FileManager.default.removeItem(at: incoming)                  // the incoming photo is deleted later
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        let ids = Set(await s.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(older.id), "the victim's older chain still guards the victim's own path")
        let guarded = await s.allRecords().first { $0.id == older.id }?.detachedFrom
        XCTAssertEqual(guarded, CanonicalPath.of(victim))
    }

    // MARK: S3

    func testNoFileIsUnundoableBecauseOfACacheSize() async throws {
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let odd = try tmp.file("a .jpg", "photo", in: "odd")
        let renamed = try await ops.rename(ImageGroup(primary: odd), toStem: "b")
        for i in 0..<300 {                                              // far more renames than any cache keeps
            let f = try tmp.file("p\(i).jpg", "x", in: "many")
            _ = try await ops.rename(ImageGroup(primary: f), toStem: "q\(i)")
        }
        let back = try await ops.rename(renamed, toStem: "a ")          // the first Undo, much later
        XCTAssertEqual(back.primary.lastPathComponent, "a .jpg")
    }
}

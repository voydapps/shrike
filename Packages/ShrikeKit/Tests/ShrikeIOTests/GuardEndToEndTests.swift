//
//  GuardEndToEndTests.swift
//  ShrikeIOTests
//
//  Review (round 5): the put-aside chain follows the photo through the real operations, driven
//  through FileOps (not by hand on BackupStore): rename, cross-volume move + Undo, Trash + Put Back.
//  Confirmation tests: green on arrival, they guard the R1 / S2 behaviour end to end.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class GuardEndToEndTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("GuardEndToEnd") }
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
    /// A photo whose chain was put aside by an outside change. Returns record 0 of that chain.
    private func putAside(_ f: URL, _ s: BackupStore) async throws -> BackupRecord {
        try await save(f, s, "version two")
        let chain = await s.records(for: f)
        let original = try XCTUnwrap(chain.last)
        try Data("version two plus a keyword from another app".utf8).write(to: f)
        try await save(f, s, "shrike edit afterwards, again different")
        return original
    }
    private func guardPath(_ r: BackupRecord, _ s: BackupStore) async -> String? {
        await s.allRecords().first { $0.id == r.id }?.detachedFrom
    }
    /// +40 days, then both clean-ups: the original must still be there.
    private func survivesCleanUp(_ r: BackupRecord, _ s: BackupStore) async -> Bool {
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        return Set(await s.allRecords().map(\.id)).contains(r.id)
    }

    func testARenameCarriesTheGuard() async throws {
        let f = try tmp.file("IMG.jpg", "original", in: "cam")
        let s = store()
        let original = try await putAside(f, s)
        let ops = FileOps(metadata: nil, backups: s, watchers: nil)
        let renamed = try await ops.rename(ImageGroup(primary: f), toStem: "IMG renamed")
        let guarded = await guardPath(original, s)
        XCTAssertEqual(guarded, CanonicalPath.of(renamed.primary))
        let kept = await survivesCleanUp(original, s)
        XCTAssertTrue(kept)
    }

    func testAnUndoOfARenameFromItsResultCarriesItBack() async throws {
        let f = try tmp.file("a .jpg", "original", in: "cam")
        let s = store()
        let original = try await putAside(f, s)
        let ops = FileOps(metadata: nil, backups: s, watchers: nil)
        let result = try await ops.renameReporting(ImageGroup(primary: f), toStem: "b")
        XCTAssertEqual(result.earlierStem, "a ")
        let back = try await ops.undoRename(result)
        XCTAssertEqual(back.group.primary.lastPathComponent, "a .jpg")
        let guarded = await guardPath(original, s)
        XCTAssertEqual(guarded, CanonicalPath.of(f))
    }

    func testACrossVolumeMoveAndItsUndoCarryTheGuard() async throws {
        let f = try tmp.file("IMG.jpg", "original", in: "src")
        let dest = try tmp.dir("dest")
        let s = store()
        let original = try await putAside(f, s)
        let trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash"))
        let ops = FileOps(metadata: nil, backups: s, watchers: nil, trashItem: { try trash.trash($0) },
                          copyFile: { try FileManager.default.copyItem(at: $0, to: $1) }, sameVolume: { _, _ in false })
        var last: FileOpProgress?
        for try await p in ops.move([ImageGroup(primary: f)], to: dest, conflicts: .always(.keepBoth)) { last = p }
        let moved = dest.appendingPathComponent("IMG.jpg")
        let afterMove = await guardPath(original, s)
        XCTAssertEqual(afterMove, CanonicalPath.of(moved))
        var kept = await survivesCleanUp(original, s)
        XCTAssertTrue(kept, "moved")
        _ = try await ops.undo(try XCTUnwrap(last).receipt)
        let afterUndo = await guardPath(original, s)
        XCTAssertEqual(afterUndo, CanonicalPath.of(f))
        kept = await survivesCleanUp(original, s)
        XCTAssertTrue(kept, "undone")
    }

    func testTrashAndPutBackCarryTheGuard() async throws {
        let f = try tmp.file("IMG.jpg", "original", in: "cam")
        let s = store()
        let original = try await putAside(f, s)
        let trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash"))
        let ops = FileOps(metadata: nil, backups: s, watchers: nil, trashItem: { try trash.trash($0) })
        let receipt = try await ops.trash([ImageGroup(primary: f)])
        let trashed = try XCTUnwrap(receipt.items.first?.files.first?.trashed)
        let inTrash = await guardPath(original, s)
        XCTAssertEqual(inTrash, CanonicalPath.of(trashed))
        var kept = await survivesCleanUp(original, s)
        XCTAssertTrue(kept, "in the Trash the file still exists")
        _ = try await ops.restore(receipt)
        let back = await guardPath(original, s)
        XCTAssertEqual(back, CanonicalPath.of(f))
        kept = await survivesCleanUp(original, s)
        XCTAssertTrue(kept, "put back")
    }
}

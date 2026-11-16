//
//  RestoreSafetyCopyTests.swift
//  ShrikeIOTests
//
//  Round 10, X1: `BackupStore.restore` puts the bytes back FIRST, so the safety copy of whatever file sits
//  at the path lands in that file's own chain (or starts one as record 0), and only then brings the
//  restored record's put-aside chain back to the path. A Save As / export onto another photo is played with
//  the same store calls `ImageExporter` makes (backup `.replace`, write, `detachForReplace`).
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class RestoreSafetyCopyTests: XCTestCase {
    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("RestoreSafetyCopy") }
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
    /// What `ImageExporter` does when it writes onto ANOTHER photo at `p`: returns the victim's record.
    private func exportOnto(_ p: URL, _ s: BackupStore, _ text: String) async throws -> BackupRecord {
        let r = try await s.backup(p, reason: .replace)
        try Data(text.utf8).write(to: p)
        await s.detachForReplace(chainAt: p)
        return r
    }
    private func keptAfter40Days(_ s: BackupStore) async -> Set<UUID> {
        advance(days: 40)
        await s.purge(olderThan: 30)
        await s.reap()
        return Set(await s.allRecords().map(\.id))
    }

    /// Normal Undo of an export with Replace: the victim's own original is record 0 at the path again;
    /// the exported file's safety copy is record 0 of its own chain, put aside under the path guard. It is
    /// kept while a file sits at that path (as 0.2.32 kept it: there it was record 0 of the live chain) and
    /// goes by the clock once no file is there.
    func testNormalUndoOfAnExportFilesTheSafetyCopyInItsOwnGuardedChain() async throws {
        let p = try tmp.file("IMG_1.jpg", "victim original")
        let s = store()
        let rv0 = try await save(p, s, "victim edited")
        let rv = try await exportOnto(p, s, "exported E")

        let safetyGot = try await s.restore(rv)
        let safety = try XCTUnwrap(safetyGot)
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8), "victim edited")
        XCTAssertEqual(try String(contentsOf: safety.backupURL, encoding: .utf8), "exported E")
        let availability = await s.availability(for: p)
        XCTAssertEqual(availability.originalRecord?.id, rv0.id, "Revert gives the victim's own original")
        let state = await s.state(for: p)
        XCTAssertNotEqual(state, .none, "the victim shows its history")
        let record = await s.allRecords().first { $0.id == safety.id }
        XCTAssertEqual(record?.detachedFrom, CanonicalPath.of(p), "the safety copy is guarded by the path")
        let safetyKey = await s.chainKey(ofRecord: safety.id)
        let sameChain = await s.allRecords().filter { BackupStore.key(for: $0.originalURL) == safetyKey }
        XCTAssertEqual(sameChain.map(\.id), [safety.id], "record 0 of its own chain, never in the victim's chain")

        let kept = await keptAfter40Days(s)
        XCTAssertTrue(kept.contains(rv0.id) && kept.contains(safety.id), "kept while the victim sits at the path")
        try FileManager.default.removeItem(at: p)
        let afterDelete = await keptAfter40Days(s)
        XCTAssertFalse(afterDelete.contains(safety.id), "no file at the path: the clock removes it")
    }

    /// X1, photo R without history: an export replaced V at p; later R was moved onto p with Replace. Undo
    /// of the export writes V over R (nothing recorded what the export wrote), but R's bytes are record 0 of
    /// a chain guarded by the path, never a non-original of V's chain that retention deletes.
    func testX1ThePhotoAtThePathWithoutHistoryKeepsItsBytesAsAGuardedOriginal() async throws {
        let p = try tmp.file("IMG_1.jpg", "victim original")
        let s = store()
        _ = try await save(p, s, "victim edited")
        let rv = try await exportOnto(p, s, "exported E")
        _ = try await exportOnto(p, s, "photo R")                         // R replaces E at p (R has no history)

        let safetyGot = try await s.restore(rv)
        let safety = try XCTUnwrap(safetyGot)
        XCTAssertEqual(try String(contentsOf: safety.backupURL, encoding: .utf8), "photo R")
        let record = await s.allRecords().first { $0.id == safety.id }
        XCTAssertEqual(record?.detachedFrom, CanonicalPath.of(p))
        let rvKey = await s.chainKey(ofRecord: rv.id), safetyKey = await s.chainKey(ofRecord: safety.id)
        XCTAssertNotEqual(rvKey, safetyKey, "R's bytes are not filed in the victim's chain")
        let kept = await keptAfter40Days(s)
        XCTAssertTrue(kept.contains(safety.id), "R's only copy survives retention")
    }

    /// X1, photo R WITH its own Shrike history: the safety copy joins R's chain as a non-original (as in
    /// 0.2.32), and R's chain is guarded by the path, so R's original survives; the victim's chain is live.
    func testX1ThePhotoAtThePathWithHistoryKeepsItsChainUnderTheGuard() async throws {
        let p = try tmp.file("IMG_1.jpg", "victim original")
        let q = try tmp.file("R.jpg", "R original")
        let s = store()
        let rv0 = try await save(p, s, "victim edited")
        let rv = try await exportOnto(p, s, "exported E")
        let rR0 = try await save(q, s, "R edited")
        _ = try await s.backup(p, reason: .replace)                       // R is moved onto p with Replace
        await s.detachForReplace(chainAt: p)
        try FileManager.default.removeItem(at: p)
        try FileManager.default.moveItem(at: q, to: p)
        await s.rekey(from: q, to: p)

        let safetyGot = try await s.restore(rv)
        let safety = try XCTUnwrap(safetyGot)
        let rRKey = await s.chainKey(ofRecord: rR0.id), safetyKey = await s.chainKey(ofRecord: safety.id)
        XCTAssertEqual(rRKey, safetyKey, "the safety copy joins R's own chain")
        let r = await s.allRecords().first { $0.id == rR0.id }
        XCTAssertEqual(r?.detachedFrom, CanonicalPath.of(p), "R's chain is guarded by the path")
        let availability = await s.availability(for: p)
        XCTAssertEqual(availability.originalRecord?.id, rv0.id)
        let kept = await keptAfter40Days(s)
        XCTAssertTrue(kept.contains(rR0.id) && kept.contains(rv0.id), "both originals survive")
        XCTAssertFalse(kept.contains(safety.id), "R's latest bytes are a non-original and go by retention (as in 0.2.32): X1 stays open for a photo with history")
    }

    /// Redo of the viewer's "Save As onto another photo" Undo restores the safety copy Undo returned: the
    /// exported file's chain is live again, so Revert offers the export's own bytes (as 0.2.32 did), never
    /// the victim's original. A second Undo gives the victim its own history again.
    func testRedoAndUndoAgainKeepEachPhotosHistoryWithIt() async throws {
        let p = try tmp.file("b.jpg", "victim original")
        let s = store()
        let rv0 = try await save(p, s, "victim edited")
        let rv = try await exportOnto(p, s, "exported E")

        let undoGot = try await s.restore(rv)
        let undo = try XCTUnwrap(undoGot)
        let redoGot = try await s.restore(undo)
        let redo = try XCTUnwrap(redoGot)
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8), "exported E")
        let afterRedo = await s.availability(for: p)
        XCTAssertEqual(afterRedo.originalRecord?.id, undo.id, "Revert offers the export's own bytes")
        XCTAssertNotEqual(afterRedo.originalRecord?.id, rv0.id)

        _ = try await s.restore(redo)
        XCTAssertEqual(try String(contentsOf: p, encoding: .utf8), "victim edited")
        let afterUndo = await s.availability(for: p)
        XCTAssertEqual(afterUndo.originalRecord?.id, rv0.id, "the victim's own original is record 0 again")
        let kept = await keptAfter40Days(s)
        XCTAssertTrue(kept.contains(rv0.id) && kept.contains(undo.id))
    }

    /// Y3: a record the heal moves back cannot be saved (its folder is read-only): `restoreReporting`
    /// counts the photo; `restore` (no channel) logs it.
    func testAHealThatCouldNotBeSavedIsCounted() async throws {
        let p = try tmp.file("IMG_1.jpg", "victim original")
        let s = store()
        let rv0 = try await save(p, s, "victim edited")
        let rv = try await exportOnto(p, s, "exported E")
        let folder = rv0.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let reported = try await s.restoreReporting(rv)
        XCTAssertEqual(reported.notSaved, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let clean = try await s.restoreReporting(try XCTUnwrap(reported.safety))   // Redo, folder writable: nothing fails
        XCTAssertEqual(clean.notSaved, 0)
    }
}

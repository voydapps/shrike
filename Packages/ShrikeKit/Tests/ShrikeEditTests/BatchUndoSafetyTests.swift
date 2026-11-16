//
//  BatchUndoSafetyTests.swift
//  ShrikeEditTests
//
//  Review W1, W2, W3: Batch Undo and the in-run rollback of a rename with Replace never write over a
//  file that sits at the victim's name, keep the victim's chain and rating with the victim, and move a
//  chain out of the Trash path only when the Trash file is really gone.
//

import XCTest
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchUndoSafetyTests: XCTestCase {

    private var root: URL!
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    private var trashFolder: URL { root.appendingPathComponent("_trash") }

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("BatchUndoSafety-\(UUID().uuidString)", isDirectory: true)
        for d in ["src", "_trash", "_db"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }
    private func metadata() throws -> MetadataStore {
        try MetadataStore(databaseURL: root.appendingPathComponent("_db/meta.sqlite"), writeFileAttributes: { false })
    }

    private struct Fixture {
        let a: URL, victim: URL
        let ra: BackupRecord, rv0: BackupRecord, rvReplace: () async -> BackupRecord?
        let ops: FileOps, store: BackupStore, metadata: MetadataStore
    }

    private func fixture(noTrash: Bool) async throws -> Fixture {
        let s = store(), m = try metadata()
        let victim = root.appendingPathComponent("src/target.jpg"), a = root.appendingPathComponent("src/a.jpg")
        try Data("victim v0".utf8).write(to: victim)
        let rv0 = try await s.backup(victim, reason: .save)
        try Data("victim v1 edited".utf8).write(to: victim)
        await s.noteWritten(victim)
        try await m.setRating(3, for: victim)
        try Data("photo a".utf8).write(to: a)
        let ra = try await s.backup(a, reason: .save)
        try Data("photo a edited".utf8).write(to: a)
        await s.noteWritten(a)
        try await m.setRating(5, for: a)
        let trashFolder = self.trashFolder
        let ops = FileOps(metadata: m, backups: s, watchers: nil, trashItem: { url in
            if noTrash { throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }
            let target = trashFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        return Fixture(a: a, victim: victim, ra: ra, rv0: rv0, rvReplace: { nil }, ops: ops, store: s, metadata: m)
    }

    private func runner(_ f: Fixture, checkpoint: (@Sendable (BatchRunner.RenameCheckpoint, URL) async throws -> Void)? = nil) -> BatchRunner {
        BatchRunner(fileOps: f.ops, backups: f.store, metadata: f.metadata, renameCheckpoint: checkpoint)
    }

    private func replacePlan(_ f: Fixture) throws -> BatchPlan {
        BatchPlan(items: [ImageGroup(primary: f.a)], rename: try RenameTemplate(parsing: "target"),
                  output: .inPlace, onConflict: .replace)
    }

    private func run(_ r: BatchRunner, _ plan: BatchPlan) async throws -> BatchResult {
        var final: BatchResult?
        for try await p in r.run(plan) { if let x = p.result { final = x } }
        return try XCTUnwrap(final)
    }

    // MARK: W1

    /// P's rename back fails (its old name is taken again), so P still sits at the victim's name. Put Back
    /// brings the victim back from the Trash under a free name; P is never written over.
    func testUndoNeverWritesTheVictimOverAPhotoThatStillSitsAtItsName() async throws {
        let f = try await fixture(noTrash: false)
        let r = runner(f)
        let result = try await run(r, try replacePlan(f))
        XCTAssertEqual(result.doneCount, 1)
        try Data("squatter".utf8).write(to: f.a)                       // a.jpg is taken again: rename back fails
        _ = try? await r.undo(result)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "photo a edited", "P's bytes are untouched")
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 5, "P's rating is untouched")
        let chain = Set(await f.store.records(for: f.victim).map(\.id))
        XCTAssertTrue(chain.contains(f.ra.id), "P's chain is untouched")
        XCTAssertFalse(chain.contains(f.rv0.id))
        let second = root.appendingPathComponent("src/target 2.jpg")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "victim v1 edited", "the victim is back under a free name")
        let back = await f.store.availability(for: second)
        XCTAssertEqual(back.originalRecord?.id, f.rv0.id, "with its own history")
    }

    // MARK: W2

    /// The rename fails after the victim went to the Trash: the rollback brings it back FROM the Trash,
    /// with its chain and rating, and leaves no duplicate there.
    func testFailedRenameRollbackBringsTheVictimBackFromTheTrashWithItsHistory() async throws {
        let f = try await fixture(noTrash: false)
        let r = runner(f, checkpoint: { point, _ in if point == .beforeMove { throw CocoaError(.fileWriteNoPermission) } })
        let result = try await run(r, try replacePlan(f))
        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited")
        let availability = await f.store.availability(for: f.victim)
        XCTAssertEqual(availability.originalRecord?.id, f.rv0.id, "the victim's chain is on the victim")
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 3, "the victim's rating is back")
        let inTrash = (try? FileManager.default.contentsOfDirectory(atPath: trashFolder.path)) ?? []
        XCTAssertTrue(inTrash.isEmpty, "no duplicate is left in the Trash: \(inTrash)")
    }

    /// The rollback itself fails once (the recovery receipt exists); a later Undo brings the victim back
    /// from the Trash with its chain and rating.
    func testUndoAfterAFailedRollbackRestoresTheVictimWithItsChainAndRating() async throws {
        let f = try await fixture(noTrash: false)
        let rollbackFails = OSAllocatedUnfairLock(initialState: true)
        let r = runner(f, checkpoint: { point, _ in
            if point == .beforeMove { throw CocoaError(.fileWriteNoPermission) }
            if point == .beforeRollback, rollbackFails.withLock({ let v = $0; $0 = false; return v }) {
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        let result = try await run(r, try replacePlan(f))
        XCTAssertEqual(result.items.first?.recoveryRequired?.originalURL, f.victim)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.victim.path))
        XCTAssertEqual(result.replacedVictims.count, 1, "the Trash receipt is kept with the recovery receipt")
        _ = try await r.undo(result)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited")
        let availability = await f.store.availability(for: f.victim)
        XCTAssertEqual(availability.originalRecord?.id, f.rv0.id)
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 3)
    }

    // MARK: W3

    /// Put Back fails for another reason than an emptied Trash (the folder is gone): the victim is still
    /// in the Trash, so its chain stays under the Trash path.
    func testAPutBackThatFailedForAnotherReasonLeavesTheChainUnderTheTrashPath() async throws {
        let f = try await fixture(noTrash: false)
        let r = runner(f)
        let result = try await run(r, try replacePlan(f))
        let moved = root.appendingPathComponent("src-gone")
        try FileManager.default.moveItem(at: root.appendingPathComponent("src"), to: moved)   // the folder is gone
        do { _ = try await r.undo(result); XCTFail("the victim could not be put back") }
        catch {
            let e = try XCTUnwrap(error as? BatchVictimNotRestoredError, "Undo says where the victim is: \(error)")
            XCTAssertEqual(e.inTrash, ["target.jpg"])
            XCTAssertTrue(e.localizedDescription.hasPrefix("“target.jpg” could not be put back. It is still in the Trash."), e.localizedDescription)
        }
        let key = await f.store.chainKey(ofRecord: f.rv0.id)
        XCTAssertNotEqual(key, BackupStore.key(for: f.victim), "the chain was not moved to a path whose folder does not exist")
        let inTrash = (try? FileManager.default.contentsOfDirectory(atPath: trashFolder.path)) ?? []
        XCTAssertEqual(inTrash.count, 1, "the victim is still in the Trash")
    }

    /// The Trash was emptied: the chain and rating go to the original path, the bytes come from the backup.
    func testWhenTheTrashWasEmptiedTheChainAndRatingGoToTheOriginalPath() async throws {
        let f = try await fixture(noTrash: false)
        let r = runner(f)
        let result = try await run(r, try replacePlan(f))
        for name in try FileManager.default.contentsOfDirectory(atPath: trashFolder.path) {
            try FileManager.default.removeItem(at: trashFolder.appendingPathComponent(name))
        }
        _ = try? await r.undo(result)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited")
        let key = await f.store.chainKey(ofRecord: f.rv0.id)
        XCTAssertEqual(key, BackupStore.key(for: f.victim))
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 3)
    }

    // MARK: X3, X4 (round 10)

    private func emptyTrash() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: trashFolder.path) {
            try FileManager.default.removeItem(at: trashFolder.appendingPathComponent(name))
        }
    }

    /// X3: the rename fails and the Trash was emptied before the rollback. The history moves to the free
    /// name BEFORE the bytes come back, so the victim's chain is live at its path and its original
    /// survives the clean-up (it was put on the clock before).
    func testRollbackAfterAnEmptiedTrashKeepsTheVictimsOriginalLive() async throws {
        let f = try await fixture(noTrash: false)
        let trash = trashFolder
        let r = runner(f, checkpoint: { point, _ in
            if point == .beforeMove { throw CocoaError(.fileWriteNoPermission) }
            if point == .beforeRollback {
                for name in try FileManager.default.contentsOfDirectory(atPath: trash.path) {
                    try FileManager.default.removeItem(at: trash.appendingPathComponent(name))
                }
            }
        })
        let result = try await run(r, try replacePlan(f))
        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited")
        let key = await f.store.chainKey(ofRecord: f.rv0.id)
        XCTAssertEqual(key, BackupStore.key(for: f.victim), "the victim's chain is live at its path")
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 3)
        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await f.store.purge(olderThan: 30)
        let kept = Set(await f.store.allRecords().map(\.id))
        XCTAssertTrue(kept.contains(f.rv0.id), "the live victim keeps its original")
    }

    /// X4: another file takes the victim's name before the rename fails. Nothing is written there; the
    /// victim stays in the Trash and Batch Undo puts it back under a free name with its own history.
    func testRollbackWithTheVictimsNameTakenKeepsTheVictimReachableForUndo() async throws {
        let f = try await fixture(noTrash: false)
        let victim = f.victim
        let r = runner(f, checkpoint: { point, _ in
            if point == .beforeMove {
                try Data("squatter".utf8).write(to: victim)
                throw CocoaError(.fileWriteNoPermission)
            }
        })
        let result = try await run(r, try replacePlan(f))
        XCTAssertEqual(result.doneCount, 0)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "squatter", "the file at the name is untouched")
        XCTAssertEqual(result.replacedVictims.count, 1, "the Trash receipt is kept")
        _ = try await r.undo(result)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "squatter")
        let second = root.appendingPathComponent("src/target 2.jpg")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "victim v1 edited", "the victim is back under a free name")
        let back = await f.store.availability(for: second)
        XCTAssertEqual(back.originalRecord?.id, f.rv0.id)
        let rating = try await f.metadata.rating(for: second)
        XCTAssertEqual(rating, 3)
    }

    /// X2: the text names every skipped victim (count + first name) and says where each one is; it never
    /// promises a second Undo.
    func testVictimNotRestoredTextNamesAllVictimsAndWhereTheyAre() {
        typealias E = BatchVictimNotRestoredError
        let kept = "Shrike's backups for a while (Settings → Editing)."
        XCTAssertEqual(E.text(inTrash: ["a.jpg", "b.jpg"], inBackups: []),
                       "2 replaced photos were not put back, including “a.jpg”. They are still in the Trash.")
        XCTAssertEqual(E.text(inTrash: [], inBackups: ["a.jpg", "b.jpg", "c.jpg"]),
                       "3 replaced photos were not put back, including “a.jpg”. Their names are taken and new names could not be saved. Copies are kept in " + kept)
        XCTAssertEqual(E.text(inTrash: ["a.jpg"], inBackups: ["b.jpg"]),
                       "2 replaced photos were not put back, including “a.jpg”. 1 is still in the Trash. 1 could not be saved under a new name; a copy is kept in " + kept)
        XCTAssertEqual(E.text(inTrash: ["a.jpg", "c.jpg"], inBackups: ["b.jpg", "d.jpg"]),
                       "4 replaced photos were not put back, including “a.jpg”. 2 are still in the Trash. 2 could not be saved under new names; copies are kept in " + kept)
        XCTAssertEqual(E.text(inTrash: [], inBackups: ["a.jpg"]),
                       "“a.jpg” was not put back: another file has its name, and a new name could not be saved. A copy is kept in " + kept)
        XCTAssertEqual(E.text(inTrash: [], inBackups: [], restoredAs: [("a.jpg", "a 2.jpg")]),
                       "“a.jpg” is back as “a 2.jpg”.")
        XCTAssertEqual(E.text(inTrash: ["b.jpg"], inBackups: [], restoredAs: [("a.jpg", "a 2.jpg"), ("c.jpg", "c 2.jpg")]),
                       "“b.jpg” could not be put back. It is still in the Trash. 2 other photos are back under new names.")
        let short = E.pieces(inTrash: [], inBackups: ["a-very-long-file-name-from-a-camera.jpg"], name: { String($0.prefix(5)) })
        XCTAssertTrue(short.main.hasPrefix("“a-ver” was not put back"), short.main)
        XCTAssertNil(short.restoredAs)
        for text in [E.text(inTrash: ["a.jpg"], inBackups: []), E.text(inTrash: [], inBackups: ["a.jpg"])] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains("undo"), text)
        }
        let error: any Error = E(inTrash: ["a.jpg"], inBackups: [], restoredAs: [], alsoFailed: nil)
        XCTAssertEqual((error as? any LocalizedError)?.errorDescription, "“a.jpg” could not be put back. It is still in the Trash.")
    }
}

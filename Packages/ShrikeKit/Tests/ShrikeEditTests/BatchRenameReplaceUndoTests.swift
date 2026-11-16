//
//  BatchRenameReplaceUndoTests.swift
//  ShrikeEditTests
//
//  Review V1: a Batch rename with Replace trashes (or, on a volume with no Trash, deletes) the victim.
//  Batch Undo brings it back with its chain, guards and rating, and the renamed photo goes back to its
//  old name with its own history.
//

import XCTest
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchRenameReplaceUndoTests: XCTestCase {

    private var root: URL!
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("BatchRenameReplace-\(UUID().uuidString)", isDirectory: true)
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
        let ra: BackupRecord, rv0: BackupRecord
        let runner: BatchRunner, store: BackupStore
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
        let trashFolder = root.appendingPathComponent("_trash")
        let ops = FileOps(metadata: m, backups: s, watchers: nil, trashItem: { url in
            if noTrash { throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }
            let target = trashFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        return Fixture(a: a, victim: victim, ra: ra, rv0: rv0,
                       runner: BatchRunner(fileOps: ops, backups: s, metadata: m), store: s)
    }

    private func runReplace(_ f: Fixture) async throws -> BatchResult {
        let plan = BatchPlan(items: [ImageGroup(primary: f.a)], rename: try RenameTemplate(parsing: "target"),
                             output: .inPlace, onConflict: .replace)
        var final: BatchResult?
        for try await p in f.runner.run(plan) { if let r = p.result { final = r } }
        return try XCTUnwrap(final)
    }

    private func assertEverythingIsBack(_ f: Fixture) async throws {
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited", "the victim is back at its name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.a.path), "the renamed photo is back at its old name")
        let availability = await f.store.availability(for: f.victim)
        XCTAssertTrue(availability.canRevert)
        XCTAssertEqual(availability.originalRecord?.id, f.rv0.id, "Revert gives the victim's OWN original")
        let aIDs = Set(await f.store.records(for: f.a).map(\.id))
        XCTAssertTrue(aIDs.contains(f.ra.id), "A has its own history back")
        let rating = try await metadata().rating(for: f.victim)
        XCTAssertEqual(rating, 3, "the victim's rating is back")
        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await f.store.purge(olderThan: 30)
        let kept = Set(await f.store.allRecords().map(\.id))
        XCTAssertTrue(kept.contains(f.rv0.id) && kept.contains(f.ra.id), "both originals survive the clean-up")
    }

    func testBatchRenameWithReplaceAndUndoBringsTheVictimBackWithItsHistory() async throws {
        let f = try await fixture(noTrash: false)
        let result = try await runReplace(f)
        XCTAssertEqual(result.doneCount, 1)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "photo a edited", "A took the name")
        _ = try await f.runner.undo(result)
        try await assertEverythingIsBack(f)
    }

    /// A volume with no Trash: the item fails with the usual "no Trash" error, nothing is deleted or
    /// renamed, and the victim keeps its bytes, history and rating (as in 0.2.32; round 10 task 1).
    func testOnAVolumeWithNoTrashTheItemFailsAndNothingIsDeleted() async throws {
        let f = try await fixture(noTrash: true)
        let result = try await runReplace(f)
        XCTAssertEqual(result.doneCount, 0)
        guard case .failed(let error)? = result.items.first?.outcome, case .noTrash? = error as? FileOpsError else {
            return XCTFail("the item fails with .noTrash: \(String(describing: result.items.first?.outcome))")
        }
        XCTAssertTrue(result.renames.isEmpty)
        XCTAssertTrue(result.replacedVictims.isEmpty)
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "victim v1 edited", "the victim is untouched")
        XCTAssertEqual(try String(contentsOf: f.a, encoding: .utf8), "photo a edited", "the photo keeps its name")
        let availability = await f.store.availability(for: f.victim)
        XCTAssertEqual(availability.originalRecord?.id, f.rv0.id, "the victim's chain stays live at its path")
        let rating = try await metadata().rating(for: f.victim)
        XCTAssertEqual(rating, 3)
        let aIDs = Set(await f.store.records(for: f.a).map(\.id))
        XCTAssertTrue(aIDs.contains(f.ra.id))
    }
}

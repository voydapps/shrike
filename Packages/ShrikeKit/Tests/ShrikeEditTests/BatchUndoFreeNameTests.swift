//
//  BatchUndoFreeNameTests.swift
//  ShrikeEditTests
//
//  Review Y1: Batch Undo of a rename with Replace, when the Trash was emptied AND another file now has the
//  victim's name. The other file (P), its chain and its rating are never touched; the victim comes back from
//  its backup under a free " 2" name with its own chain and rating. If that folder is not writable, the
//  victim is left in Shrike's backups (on the clock) and reported, as before.
//

import XCTest
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchUndoFreeNameTests: XCTestCase {

    private var root: URL!
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    private var trashFolder: URL { root.appendingPathComponent("_trash") }
    private var src: URL { root.appendingPathComponent("src") }

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("BatchUndoFreeName-\(UUID().uuidString)", isDirectory: true)
        for d in ["src", "_trash", "_db"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
    override func tearDown() async throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)
        try? FileManager.default.removeItem(at: root)
    }

    private struct Fixture {
        let a: URL, victim: URL
        let ra: BackupRecord, rv0: BackupRecord
        let runner: BatchRunner, store: BackupStore, metadata: MetadataStore
    }

    private func fixture() async throws -> Fixture {
        let clock = self.clock
        let s = BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 },
                            maxBytes: { 0 }, now: { clock.withLock { $0 } })
        let m = try MetadataStore(databaseURL: root.appendingPathComponent("_db/meta.sqlite"), writeFileAttributes: { false })
        let victim = src.appendingPathComponent("target.jpg"), a = src.appendingPathComponent("a.jpg")
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
            let target = trashFolder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        return Fixture(a: a, victim: victim, ra: ra, rv0: rv0,
                       runner: BatchRunner(fileOps: ops, backups: s, metadata: m), store: s, metadata: m)
    }

    private func runReplace(_ f: Fixture) async throws -> BatchResult {
        let plan = BatchPlan(items: [ImageGroup(primary: f.a)], rename: try RenameTemplate(parsing: "target"),
                             output: .inPlace, onConflict: .replace)
        var final: BatchResult?
        for try await p in f.runner.run(plan) { if let r = p.result { final = r } }
        let result = try XCTUnwrap(final)
        XCTAssertEqual(result.doneCount, 1)
        for name in try FileManager.default.contentsOfDirectory(atPath: trashFolder.path) {
            try FileManager.default.removeItem(at: trashFolder.appendingPathComponent(name))     // the Trash is emptied
        }
        return result
    }

    private func assertPUntouched(_ f: Fixture) async throws {
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "photo a edited", "P's bytes are untouched")
        let chain = Set(await f.store.records(for: f.victim).map(\.id))
        XCTAssertTrue(chain.contains(f.ra.id), "P keeps its own live chain")
        XCTAssertFalse(chain.contains(f.rv0.id))
        let rating = try await f.metadata.rating(for: f.victim)
        XCTAssertEqual(rating, 5, "P's rating is untouched")
    }

    private func assertVictimBackAsTarget2(_ f: Fixture) async throws {
        let second = src.appendingPathComponent("target 2.jpg")
        XCTAssertEqual(try? String(contentsOf: second, encoding: .utf8), "victim v1 edited", "the victim is back under a free name")
        let availability = await f.store.availability(for: second)
        XCTAssertEqual(availability.originalRecord?.id, f.rv0.id, "with its own original as record 0")
        let rating = try await f.metadata.rating(for: second)
        XCTAssertEqual(rating, 3, "and its own rating")
        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await f.store.purge(olderThan: 30)
        await f.store.reap()
        let kept = Set(await f.store.allRecords().map(\.id))
        XCTAssertTrue(kept.contains(f.rv0.id), "the live victim keeps its original after the clean-up")
    }

    /// P's rename back fails (a.jpg is taken again), so P still has the victim's name.
    func testWithTheRenameBackFailedTheVictimComesBackUnderAFreeName() async throws {
        let f = try await fixture()
        let result = try await runReplace(f)
        try Data("squatter".utf8).write(to: f.a)
        do { _ = try await f.runner.undo(result); XCTFail("the rename back failed: Undo says so") }
        catch {
            XCTAssertTrue(error is BatchVictimNotRestoredError, "\(error)")
            let text = (error as? any LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("“target.jpg” is back as “target 2.jpg”"), text)
            XCTAssertFalse(text.contains("backups"), text)
        }
        try await assertPUntouched(f)
        try await assertVictimBackAsTarget2(f)
    }

    /// No other problem: the renamed photo went back, but a different file now has the victim's name.
    /// The victim is back under a free name and Undo does not fail.
    func testWithNoOtherProblemUndoSucceeds() async throws {
        let f = try await fixture()
        var result = try await runReplace(f)
        result.renames = []                                               // the user moved P back by hand
        try FileManager.default.moveItem(at: f.victim, to: f.a)
        try Data("a stranger".utf8).write(to: f.victim)
        let report = try await f.runner.undo(result)
        XCTAssertEqual(report.restoredAs.map(\.old), ["target.jpg"], "spec 28 §19.7: Undo reports the new name")
        XCTAssertEqual(report.restoredAs.map(\.new), ["target 2.jpg"])
        XCTAssertEqual(try String(contentsOf: f.victim, encoding: .utf8), "a stranger", "the stranger is untouched")
        try await assertVictimBackAsTarget2(f)
    }

    /// The folder is not writable: the victim cannot be written under a new name either. It is left in
    /// Shrike's backups on the clock and reported, as before Y1 (a pin).
    func testWhenTheFolderIsNotWritableTheVictimIsKeptInBackupsAndReported() async throws {
        let f = try await fixture()
        let result = try await runReplace(f)
        try Data("squatter".utf8).write(to: f.a)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: src.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path) }
        do { _ = try await f.runner.undo(result); XCTFail("the victim could not be put back") }
        catch {
            XCTAssertTrue(error is BatchVictimNotRestoredError, "\(error)")
            let text = (error as? any LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(text.contains("“target.jpg”") && text.contains("Shrike's backups for a while"), text)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)
        try await assertPUntouched(f)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("target 2.jpg").path))
        let parked = await f.store.allRecords().first { $0.id == f.rv0.id }
        XCTAssertNotNil(parked?.detachedAt, "the victim's history is kept on the clock")
        XCTAssertNil(parked?.detachedFrom, "and guards no path that holds another photo")
    }
}

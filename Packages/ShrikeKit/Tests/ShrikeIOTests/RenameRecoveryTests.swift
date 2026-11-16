//
//  RenameRecoveryTests.swift
//  ShrikeIOTests
//
//  Review S1: recovering a rename after a crash must move the backup chain, its guards and the
//  metadata with the photo, not only the file.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class RenameRecoveryTests: XCTestCase {

    var tmp: IOTempDir!
    var dbURL: URL { tmp.url.appendingPathComponent("_db/meta.sqlite") }
    var backupRoot: URL { tmp.url.appendingPathComponent("Backups") }
    let clock = OSAllocatedUnfairLock(initialState: Date())

    override func setUp() { super.setUp(); tmp = IOTempDir("RenameRecovery") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func store(offsetDays: Double = 0) -> BackupStore {
        let at = Date().addingTimeInterval(offsetDays * 86_400)
        return BackupStore(root: backupRoot, retentionDays: { 30 }, maxBytes: { 0 }, now: { at })
    }
    private func metadata() throws -> MetadataStore {
        try MetadataStore(databaseURL: dbURL, writeFileAttributes: { false })
    }
    private func journal() throws -> RenameJournal { RenameJournal(directory: try tmp.dir("_journal")) }

    /// What Batch staging leaves behind after a crash: the photo under a temp name, its chain and
    /// its metadata filed under the temp path, and an old journal entry of a dead process.
    private func stagedPhoto(_ j: RenameJournal) async throws -> (original: URL, temp: URL) {
        let original = try tmp.file("IMG.jpg", "original", in: "cam")
        let temp = original.deletingLastPathComponent().appendingPathComponent("IMG shrike-tmp-ABCD1234.jpg")
        let s = store(), m = try metadata()
        try await s.backup(original, reason: .save)
        await s.noteWritten(original)     // a stamp is the proof recovery needs (round 6)
        try await m.setRating(4, for: original)
        try FileManager.default.moveItem(at: original, to: temp)
        await s.rekey(from: original, to: temp)                              // what renameCore does ...
        try await m.transfer(from: original, to: temp, mode: .move)          // ... for the staging rename
        j.write(RenameJournalEntry(id: UUID(), created: .distantPast,
                                   moves: [.init(original: original.path, temporary: temp.path)], pid: 999_999))
        return (original, temp)
    }

    private func ops() throws -> FileOps {
        FileOps(metadata: try metadata(), backups: store(), watchers: nil)
    }

    func testRecoveryMovesTheChainAndTheRatingBackWithThePhoto() async throws {
        let j = try journal()
        let (original, temp) = try await stagedPhoto(j)
        let report = await (try ops()).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertEqual(report.restored, [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        // A new launch: fresh stores on the same folders.
        let chain = await store().records(for: original)
        XCTAssertFalse(chain.isEmpty, "the chain follows the photo to its old name")
        let rating = try await metadata().rating(for: original)
        XCTAssertEqual(rating, 4, "the rating is on the original path")
        let later = store(offsetDays: 40)
        await later.purge(olderThan: 30)
        let kept = await later.records(for: original)
        XCTAssertEqual(kept.count, 1, "retention keeps record 0: a file sits at the original path")
        XCTAssertTrue(j.pending().isEmpty)
    }

    /// The crash came after the rename back and before the bookkeeping.
    func testACrashBetweenRenameBackAndBookkeepingIsFinishedAtTheNextLaunch() async throws {
        let j = try journal()
        let (original, temp) = try await stagedPhoto(j)
        try FileManager.default.moveItem(at: temp, to: original)              // rename back done, rekey not
        let report = await (try ops()).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(report.needsAttention.isEmpty)
        let chain = await store().records(for: original)
        XCTAssertFalse(chain.isEmpty)
        let rating = try await metadata().rating(for: original)
        XCTAssertEqual(rating, 4)
        XCTAssertTrue(j.pending().isEmpty, "the entry ends only after the bookkeeping")
    }

    /// The photo stays under the temp name: its chain is at the temp path with a file there. Fine.
    func testAPhotoThatStaysAtTheTempNameKeepsItsChain() async throws {
        let j = try journal()
        let (original, temp) = try await stagedPhoto(j)
        try Data("someone else".utf8).write(to: original)                      // the old name is taken again
        let report = await (try ops()).recoverRenames(journal: j, startedBefore: Date().addingTimeInterval(10))
        XCTAssertEqual(report.needsAttention.map(\.temporary), [temp])
        let later = store(offsetDays: 40)
        await later.purge(olderThan: 30)
        let chain = await later.records(for: temp)
        XCTAssertEqual(chain.count, 1, "a file sits at the temp path: the original is kept")
        let availability = await later.availability(for: temp)
        XCTAssertTrue(availability.canRevert)
        XCTAssertEqual(j.pending().count, 1, "reported again until solved")
    }
}

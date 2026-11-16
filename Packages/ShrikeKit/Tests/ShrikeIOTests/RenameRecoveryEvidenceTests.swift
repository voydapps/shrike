//
//  RenameRecoveryEvidenceTests.swift
//  ShrikeIOTests
//
//  Review T1: recovery attaches a history to a photo only with proof it is the same photo, and
//  never damages the history or the rating of the photo that sits at the old name.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class RenameRecoveryEvidenceTests: XCTestCase {

    var tmp: IOTempDir!
    var dbURL: URL { tmp.url.appendingPathComponent("_db/meta.sqlite") }
    var backupRoot: URL { tmp.url.appendingPathComponent("Backups") }

    override func setUp() { super.setUp(); tmp = IOTempDir("RenameRecoveryEvidence") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    private func store() -> BackupStore {
        BackupStore(root: backupRoot, retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() })
    }
    private func metadata() throws -> MetadataStore {
        try MetadataStore(databaseURL: dbURL, writeFileAttributes: { false })
    }

    private struct Setup {
        let a: URL, b: URL, btmp: URL
        let ra: BackupRecord, rb: BackupRecord
        let journal: RenameJournal
    }

    /// A (rating 4) and B (rating 2), each with a chain; B has been moved aside to a temp name.
    private func twoPhotosWithBStaged(stampB: Bool = true) async throws -> Setup {
        let a = try tmp.file("a.jpg", "photo A", in: "cam")
        let b = try tmp.file("b.jpg", "photo B is different", in: "cam")
        let s = store(), m = try metadata()
        let ra = try await s.backup(a, reason: .save); await s.noteWritten(a)
        let rb = try await s.backup(b, reason: .save)
        if stampB { await s.noteWritten(b) }          // every chain written by 0.2.32 has no stamp
        try await m.setRating(4, for: a)
        try await m.setRating(2, for: b)
        let btmp = b.deletingLastPathComponent().appendingPathComponent("b shrike-tmp-ABCD1234.jpg")
        try FileManager.default.moveItem(at: b, to: btmp)
        await s.rekey(from: b, to: btmp)
        try await m.transfer(from: b, to: btmp, mode: .move)
        return Setup(a: a, b: b, btmp: btmp, ra: ra, rb: rb,
                     journal: RenameJournal(directory: try tmp.dir("_journal")))
    }

    private func recover(_ setup: Setup, final: URL?) async throws -> RenameRecovery {
        setup.journal.write(RenameJournalEntry(
            id: UUID(), created: .distantPast,
            moves: [.init(original: setup.b.path, temporary: setup.btmp.path, final: final?.path)], pid: 999_999))
        let ops = FileOps(metadata: try metadata(), backups: store(), watchers: nil)
        return await ops.recoverRenames(journal: setup.journal, startedBefore: Date().addingTimeInterval(10))
    }

    private func ids(_ url: URL) async -> Set<UUID> { Set(await store().records(for: url).map(\.id)) }

    /// Route 1: a <-> b. A took B's old name, B was meant to get A's, and the crash came after
    /// `btmp -> a` and before its bookkeeping. B's history belongs at `a`; A's stays at `b`.
    func testSwapRecoveryGivesEachPhotoItsOwnHistoryAndRating() async throws {
        let setup = try await twoPhotosWithBStaged()
        let s = store(), m = try metadata()
        try FileManager.default.moveItem(at: setup.a, to: setup.b)            // A takes b's old name ...
        await s.rekey(from: setup.a, to: setup.b)
        try await m.transfer(from: setup.a, to: setup.b, mode: .move)
        try FileManager.default.moveItem(at: setup.btmp, to: setup.a)         // ... B goes to a ...; crash
        let report = try await recover(setup, final: setup.a)
        let atB = await ids(setup.b), atA = await ids(setup.a)
        XCTAssertEqual(atB, [setup.ra.id], "photo A keeps its own history at b.jpg")
        XCTAssertEqual(atA, [setup.rb.id], "photo B's history follows B to a.jpg")
        let ratingB = try await metadata().rating(for: setup.b)
        let ratingA = try await metadata().rating(for: setup.a)
        XCTAssertEqual(ratingB, 4, "A's rating is untouched")
        XCTAssertEqual(ratingA, 2, "B's rating follows B")
        XCTAssertEqual(report.historyNotRestored, 0)
        XCTAssertTrue(setup.journal.pending().isEmpty)
    }

    /// Route 2: the user deleted B's temp file in Finder; a different photo (A) sits at B's old name.
    func testADifferentPhotoAtTheOldNameKeepsItsHistoryAndBsHistoryIsParkedAndCounted() async throws {
        let setup = try await twoPhotosWithBStaged()
        let s = store(), m = try metadata()
        try FileManager.default.moveItem(at: setup.a, to: setup.b)            // A sits at b.jpg
        await s.rekey(from: setup.a, to: setup.b)
        try await m.transfer(from: setup.a, to: setup.b, mode: .move)
        try FileManager.default.removeItem(at: setup.btmp)                     // B's file is gone
        let report = try await recover(setup, final: nil)
        let atB = await ids(setup.b)
        XCTAssertEqual(atB, [setup.ra.id], "photo A's history is unchanged")
        let ratingB = try await metadata().rating(for: setup.b)
        XCTAssertEqual(ratingB, 4, "photo A's rating is unchanged")
        let all = await store().allRecords()
        let parked = all.first { $0.id == setup.rb.id }
        XCTAssertNotNil(parked, "B's history is not lost")
        XCTAssertNotNil(parked?.detachedAt, "it is kept by the retention clock")
        XCTAssertNil(parked?.detachedFrom, "and guards no path that holds a different photo")
        XCTAssertEqual(report.historyNotRestored, 1)
        XCTAssertTrue(setup.journal.pending().isEmpty)
    }

    /// U1: no stamp means no proof either way. The photo is alive at its final name: its only original
    /// is guarded by that path, not put on the clock, and nothing of A is touched.
    func testAnUnstampedChainOfALivePhotoIsGuardedByItsFinalNameNotPutOnTheClock() async throws {
        let setup = try await twoPhotosWithBStaged(stampB: false)
        let s = store(), m = try metadata()
        try FileManager.default.moveItem(at: setup.a, to: setup.b)
        await s.rekey(from: setup.a, to: setup.b)
        try await m.transfer(from: setup.a, to: setup.b, mode: .move)
        try FileManager.default.moveItem(at: setup.btmp, to: setup.a)          // B is alive at a.jpg
        let report = try await recover(setup, final: setup.a)
        let atB = await ids(setup.b)
        XCTAssertEqual(atB, [setup.ra.id], "A's history is untouched")
        let ratingB = try await metadata().rating(for: setup.b)
        XCTAssertEqual(ratingB, 4)
        XCTAssertEqual(report.historyNotRestored, 1, "nothing was attached")
        let all = await store().allRecords()
        let kept = all.first { $0.id == setup.rb.id }
        XCTAssertEqual(kept?.detachedFrom, CanonicalPath.of(setup.a), "guarded by the path where B lives")
        // The guard follows B through a later rename.
        let renamed = try await FileOps(metadata: nil, backups: store(), watchers: nil)
            .rename(ImageGroup(primary: setup.a), toStem: "a renamed")
        let moved = await store().allRecords().first { $0.id == setup.rb.id }
        XCTAssertEqual(moved?.detachedFrom, CanonicalPath.of(renamed.primary))
        // 40 days later both clean-ups keep it.
        let later = BackupStore(root: backupRoot, retentionDays: { 30 }, maxBytes: { 1 },
                                now: { Date().addingTimeInterval(40 * 86_400) })
        await later.purge(olderThan: 30)
        await later.reap()
        let ids = Set(await later.allRecords().map(\.id))
        XCTAssertTrue(ids.contains(setup.rb.id), "B's only original survives while B lives")
    }

    /// U3 (premise check): Finder tags are xattrs on the file, not rows in the database, so a proven
    /// attach cannot delete them.
    func testFinderTagsOnTheFileSurviveAProvenAttach() async throws {
        let setup = try await twoPhotosWithBStaged()
        let tag = "com.apple.metadata:_kMDItemUserTags"
        try FileManager.default.moveItem(at: setup.btmp, to: setup.b)           // B's file is back at its old name
        XCTAssertTrue(ExtendedAttribute.write(Data("tag-data".utf8), name: tag, at: setup.b))
        let report = try await recover(setup, final: nil)
        XCTAssertEqual(report.historyNotRestored, 0, "proven: attached")
        XCTAssertEqual(ExtendedAttribute.read(tag, at: setup.b), Data("tag-data".utf8))
        let atB = await ids(setup.b)
        XCTAssertEqual(atB, [setup.rb.id])
    }
}

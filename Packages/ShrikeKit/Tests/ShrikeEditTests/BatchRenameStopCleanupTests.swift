//
//  BatchRenameStopCleanupTests.swift
//  ShrikeEditTests
//
//  Audit B-1 (found on screen 2026-11-13): an in-place Batch rename whose new names are the
//  current names of other photos of the batch (a shuffled IMG_{counter} over IMG_1…IMG_n) moves
//  those photos aside first. A Stop, or an error, in the middle must leave no photo under a
//  temporary name, lose or duplicate nothing, keep every chain and rating with its photo, and
//  leave a result whose Undo restores every original name. Temp folders only.
//

import XCTest
import os
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchRenameStopCleanupTests: XCTestCase {

    private var root: URL!
    private var folder: URL!
    private var backups: BackupStore!
    private var metadata: MetadataStore!
    private var ops: FileOps!

    private let count = 60
    /// Photo n carries a backup chain when n % 7 == 0, a rating when n % 3 == 0.
    private var chainIDs: [Int: UUID] = [:]
    private func expectedRating(_ n: Int) -> Int { n % 3 == 0 ? n % 5 + 1 : 0 }

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("B1StopCleanup-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("src", isDirectory: true)
        for d in [folder!, root.appendingPathComponent("_db")] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        backups = BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 })
        metadata = try MetadataStore(databaseURL: root.appendingPathComponent("_db/meta.sqlite"), writeFileAttributes: { false })
        ops = FileOps(metadata: metadata, backups: backups, watchers: nil)
        chainIDs = [:]
        for n in 1...count {
            let url = url(n)
            if n % 7 == 0 {
                try Data("photo-\(n) v0".utf8).write(to: url)
                chainIDs[n] = try await backups.backup(url, reason: .save).id
            }
            try Data("photo-\(n)".utf8).write(to: url)
            if n % 7 == 0 { await backups.noteWritten(url) }
            if expectedRating(n) > 0 { try await metadata.setRating(expectedRating(n), for: url) }
        }
    }

    override func tearDown() async throws {
        // A last-resort case keeps its journal entry on purpose; it must not outlive the test.
        for entry in journalEntries() { RenameJournal.shared.end(entry.id) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func url(_ n: Int) -> URL { folder.appendingPathComponent("IMG_\(n).jpg") }
    private var startNames: [String] { (1...count).map { "IMG_\($0).jpg" }.sorted() }

    /// A fixed shuffle of IMG_1…IMG_n (no randomness: the same order every run).
    private func shuffledGroups() -> [ImageGroup] {
        var order = Array(1...count)
        var seed: UInt64 = 0x5EED_B1
        for i in stride(from: order.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            order.swapAt(i, Int((seed >> 33) % UInt64(i + 1)))
        }
        return order.map { ImageGroup(primary: url($0)) }
    }

    private func plan() throws -> BatchPlan {
        BatchPlan(items: shuffledGroups(), rename: try RenameTemplate(parsing: "IMG_{counter}"), output: .inPlace)
    }

    private func drain(_ stream: AsyncThrowingStream<BatchProgress, any Error>) async throws -> BatchResult {
        var last: BatchResult?
        for try await p in stream { if let r = p.result { last = r } }
        return try XCTUnwrap(last)
    }

    private func names() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func content(_ url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func number(of content: String?) -> Int? {
        content.flatMap { $0.hasPrefix("photo-") ? Int($0.dropFirst(6)) : nil }
    }

    private func journalEntries() -> [RenameJournalEntry] {
        guard let folder else { return [] }
        return RenameJournal.shared.pending().filter { entry in
            entry.moves.contains { $0.original.hasPrefix(folder.path) || $0.temporary.hasPrefix(folder.path) }
        }
    }

    /// Stops the run at the `k`-th final rename. `throwing`: that rename does not happen (K-1
    /// finished); otherwise it still runs, with the Stop already in force (K finished).
    private func stopping(at k: Int, _ stop: BatchStop, throwing: Bool)
        -> @Sendable (BatchRunner.RenameCheckpoint, URL) async throws -> Void {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        return { point, _ in
            guard point == .beforeMove else { return }
            let n = calls.withLock { $0 += 1; return $0 }
            guard n == k else { return }
            stop.stop()
            if throwing { throw CancellationError() }
        }
    }

    /// The B-1 contract, checked on disk, in the stores, the journal and the result; then Undo.
    private func assertClean(_ result: BatchResult, plan: BatchPlan, runner: BatchRunner,
                             allowSecondNames: Bool = false, file: StaticString = #filePath, line: UInt = #line) async throws {
        let left = names()
        XCTAssertFalse(left.contains { $0.contains("shrike-tmp-") || $0.hasPrefix(".shrike-rename-") },
                       "no temporary name is left: \(left.filter { $0.contains("shrike-tmp-") })", file: file, line: line)
        // Nothing lost, nothing duplicated.
        let numbers = left.compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted()
        XCTAssertEqual(numbers, Array(1...count), "the same photos as at the start", file: file, line: line)
        if !allowSecondNames {
            XCTAssertEqual(Set(left), Set(startNames), "every photo has its old or its planned name", file: file, line: line)
        }
        // Chains and ratings sit with the photo they belong to.
        for name in left {
            let file0 = folder.appendingPathComponent(name)
            guard let n = number(of: content(file0)) else { continue }
            let chain = await backups.records(for: file0).map(\.id)
            if let id = chainIDs[n] {
                XCTAssertTrue(chain.contains(id), "photo-\(n)'s chain is on \(name)", file: file, line: line)
            } else {
                XCTAssertTrue(chain.isEmpty, "\(name) (photo-\(n)) has no chain of its own: \(chain)", file: file, line: line)
            }
            let rating = try await metadata.rating(for: file0)
            XCTAssertEqual(rating, expectedRating(n), "photo-\(n)'s rating is on \(name)", file: file, line: line)
        }
        XCTAssertTrue(journalEntries().isEmpty, "the journal is empty: \(journalEntries().map(\.moves))", file: file, line: line)
        // Spec 28 §20.5: with no photo under a temporary name, D + K + W covers every row, and W is
        // exactly the photos with a name that is neither old nor planned.
        XCTAssertEqual(result.newNameCount + result.oldNameCount + result.putBackAsCount, result.items.count, file: file, line: line)
        XCTAssertEqual(result.putBackAsCount, left.filter { !startNames.contains($0) }.count, file: file, line: line)
        // Every row says where its photo is.
        for item in result.items {
            let start = number(of: "photo-" + item.source.primary.deletingPathExtension().lastPathComponent.dropFirst(4))
            let at = try XCTUnwrap(item.finalURL, file: file, line: line)
            XCTAssertEqual(number(of: content(at)), start,
                           "\(item.source.primary.lastPathComponent) (\(item.outcome)) is at \(at.lastPathComponent)", file: file, line: line)
        }
        // Review Remaining acts only on files that are still the photo it means.
        for group in runner.retryPlan(for: result, original: plan).items {
            let row = result.items.first { $0.finalURL == group.primary } ?? result.items.first { $0.source == group }
            let start = row.flatMap { number(of: "photo-" + $0.source.primary.deletingPathExtension().lastPathComponent.dropFirst(4)) }
            XCTAssertEqual(number(of: content(group.primary)), start,
                           "a retry of \(group.primary.lastPathComponent) would rename another photo", file: file, line: line)
        }
        // Exactly one move per photo set aside, after the move that set it aside: the clean-up is as
        // short as the old put-back.
        for (i, step) in result.renames.enumerated() where step.after.primary.lastPathComponent.contains("shrike-tmp-") {
            let later = result.renames[(i + 1)...].filter { $0.before.primary == step.after.primary }.count
            XCTAssertEqual(later, 1, "\(step.after.primary.lastPathComponent) moved \(later) times after it was set aside",
                           file: file, line: line)
        }
        // Undo restores every original name, with the history.
        _ = try await runner.undo(result)
        XCTAssertEqual(names(), startNames, "Undo restores every name", file: file, line: line)
        for n in 1...count {
            XCTAssertEqual(content(url(n)), "photo-\(n)", "IMG_\(n) after Undo", file: file, line: line)
            let rating = try await metadata.rating(for: url(n))
            XCTAssertEqual(rating, expectedRating(n), "IMG_\(n)'s rating after Undo", file: file, line: line)
            if let id = chainIDs[n] {
                let chain = await backups.records(for: url(n)).map(\.id)
                XCTAssertTrue(chain.contains(id), "IMG_\(n)'s chain after Undo", file: file, line: line)
            }
        }
    }

    // MARK: A photo that already has its planned name (28a round 2 finding 3)

    /// After a Stop, a photo whose planned name is its own name is done
    /// (nothing to do), not cancelled; the swapped pair is still cleaned up.
    func testStoppedRunCountsAnUnchangedNameAsDone() async throws {
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 1, stop, throwing: true))
        // IMG_2 → IMG_1 and IMG_1 → IMG_2 swap (moved aside); IMG_3 → IMG_3 keeps its name.
        let items = [url(2), url(1), url(3)].map { ImageGroup(primary: $0) }
        let plan = BatchPlan(items: items, rename: try RenameTemplate(parsing: "IMG_{counter}"), output: .inPlace)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertTrue(stop.isStopped)
        let same = try XCTUnwrap(result.items.first { $0.source.primary == url(3) })
        guard case .done(let at) = same.outcome else { return XCTFail("IMG_3 is \(same.outcome)") }
        XCTAssertEqual(at, url(3))
        XCTAssertEqual(content(url(3)), "photo-3")
        XCTAssertFalse(names().contains { $0.contains(BatchRunner.temporaryMarker) }, "no temporary name left")
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.doneCount + result.items.filter { !$0.isDone }.count, 3, "summary numbers add up")
        XCTAssertTrue(journalEntries().isEmpty)
    }

    // MARK: Stop after K finished renames

    func testStopAfterKFinishedRenamesLeavesNoTempNameAndUndoes() async throws {
        for k in [1, 2, 12, 30, 59] {
            try await tearDown(); try await setUp()
            let stop = BatchStop()
            let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                     renameCheckpoint: stopping(at: k, stop, throwing: true))
            let plan = try plan()
            let result = try await drain(runner.run(plan, stop: stop))
            XCTAssertTrue(stop.isStopped, "K=\(k): the run was stopped")
            XCTAssertGreaterThanOrEqual(result.doneCount, k - 1, "K=\(k): finished renames stay")
            try await assertClean(result, plan: plan, runner: runner)
        }
    }

    /// The Stop lands while a final rename is running: that rename and its bookkeeping still finish.
    func testStopDuringAFinalRenameKeepsItsHistory() async throws {
        for k in [1, 30] {
            try await tearDown(); try await setUp()
            let stop = BatchStop()
            let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                     renameCheckpoint: stopping(at: k, stop, throwing: false))
            let plan = try plan()
            let result = try await drain(runner.run(plan, stop: stop))
            XCTAssertGreaterThan(result.cancelledCount, 0, "K=\(k): the run was stopped")
            try await assertClean(result, plan: plan, runner: runner)
        }
    }

    // MARK: An item error, not a Stop

    func testItemErrorInTheMiddleOfASwapRunLeavesNoTempName() async throws {
        for m in [1, 20, 45] {
            try await tearDown(); try await setUp()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata, renameCheckpoint: { point, _ in
                guard point == .beforeMove else { return }
                if calls.withLock({ $0 += 1; return $0 }) == m { throw CocoaError(.fileWriteNoPermission) }
            })
            let plan = try plan()
            let result = try await drain(runner.run(plan))
            XCTAssertEqual(result.cancelledCount, 0)
            XCTAssertGreaterThan(result.failedCount, 0, "m=\(m): the failed item is reported")
            // One error gives at most one " 2" name; the knock-on rows (their planned name is now
            // the failed photo's) fail safely and keep their old names.
            XCTAssertLessThanOrEqual(names().filter { !startNames.contains($0) }.count, 1, "m=\(m): \(names())")
            try await assertClean(result, plan: plan, runner: runner, allowSecondNames: true)
        }
    }

    // MARK: Stop while photos are being set aside

    func testStopDuringStagingPutsEveryPhotoBack() async throws {
        for j in [1, 25] {
            try await tearDown(); try await setUp()
            let stop = BatchStop()
            let calls = OSAllocatedUnfairLock(initialState: 0)
            var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
            runner.cleanupCheckpoint = { point, _ in
                if point == .beforeStage, calls.withLock({ $0 += 1; return $0 }) == j { stop.stop() }
            }
            let plan = try plan()
            let result = try await drain(runner.run(plan, stop: stop))
            XCTAssertEqual(names(), startNames, "j=\(j): every photo is back under its old name")
            XCTAssertEqual(result.doneCount, 0)
            XCTAssertEqual(result.failedCount, 0)
            try await assertClean(result, plan: plan, runner: runner)
        }
    }

    // MARK: A clean-up step that fails

    /// The first clean-up move fails once: that photo ends under a visible " 2" name next to its old
    /// one, is reported by that name, and nothing else is disturbed.
    func testFailedCleanupStepEndsUnderAVisibleSecondName() async throws {
        let stop = BatchStop()
        let failed = OSAllocatedUnfairLock<URL?>(initialState: nil)
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 30, stop, throwing: true))
        runner.cleanupCheckpoint = { point, url in
            guard point == .beforeCleanup else { return }
            if failed.withLock({ if $0 == nil { $0 = url; return true }; return false }) { throw CocoaError(.fileWriteNoPermission) }
        }
        let plan = try plan()
        let result = try await drain(runner.run(plan, stop: stop))
        let victim = try XCTUnwrap(failed.withLock { $0 })
        let extra = names().filter { !startNames.contains($0) }
        let stem = victim.deletingPathExtension().lastPathComponent
        XCTAssertEqual(extra, ["\(stem) 2.jpg"], "the photo has a visible name next to its old one")
        let item = try XCTUnwrap(result.items.first { $0.source.primary == victim })
        guard case .failed(let error) = item.outcome else { return XCTFail("reported as failed: \(item.outcome)") }
        XCTAssertTrue(error.localizedDescription.contains("\(stem) 2.jpg"), error.localizedDescription)
        XCTAssertEqual(item.finalURL?.lastPathComponent, "\(stem) 2.jpg")
        XCTAssertEqual(names().count, count)
        try await assertClean(result, plan: plan, runner: runner, allowSecondNames: true)
    }

    /// Every move of one photo fails: the last resort. It stays under the temporary name WITH its
    /// journal entry (the next launch can still repair it), is reported by that name, and Review
    /// Remaining does not touch whatever is at its old path.
    func testCleanupThatCannotMoveAPhotoKeepsItsJournalAndReportsIt() async throws {
        let stop = BatchStop()
        let stuck = OSAllocatedUnfairLock<URL?>(initialState: nil)
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 30, stop, throwing: true))
        runner.cleanupCheckpoint = { point, url in
            guard point == .beforeCleanup else { return }
            if stuck.withLock({ if $0 == nil { $0 = url }; return $0 == url }) { throw CocoaError(.fileWriteNoPermission) }
        }
        let plan = try plan()
        let result = try await drain(runner.run(plan, stop: stop))
        let victim = try XCTUnwrap(stuck.withLock { $0 })
        let temps = names().filter { $0.contains("shrike-tmp-") }
        XCTAssertEqual(temps.count, 1, "\(temps)")
        XCTAssertEqual(journalEntries().count, 1, "the stuck photo keeps its journal entry")
        let item = try XCTUnwrap(result.items.first { $0.source.primary == victim })
        guard case .failed(let error) = item.outcome else { return XCTFail("reported as failed: \(item.outcome)") }
        XCTAssertTrue(error.localizedDescription.contains(temps[0]), error.localizedDescription)
        XCTAssertEqual(item.finalURL?.lastPathComponent, temps[0])
        let numbers = names().compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted()
        XCTAssertEqual(numbers, Array(1...count), "nothing lost")
        // Review G1: the failed " 2" move put the entry back as it was: final = the PLANNED name.
        let index = try XCTUnwrap(plan.items.firstIndex { $0.primary == victim })
        let kept = try XCTUnwrap(journalEntries().first)
        XCTAssertEqual(kept.moves.map(\.final), [folder.appendingPathComponent("IMG_\(index + 1).jpg").path])
        XCTAssertEqual(kept.moves.map(\.original), [victim.path])
        XCTAssertEqual(kept.moves.map(\.temporary), [folder.appendingPathComponent(temps[0]).path])
        // The next launch owns it: Review Remaining does not offer it (nor anything at a temp name).
        let retry = runner.retryPlan(for: result, original: plan)
        XCTAssertFalse(retry.items.contains { $0 == item.source || BatchRunner.isTemporary($0) }, "\(retry.items.map(\.primary))")
        // Next launch (no kill): the history is on the photo, wherever recovery leaves it.
        let journal = RenameJournal(directory: root.appendingPathComponent("_journal-own", isDirectory: true))
        let (store, meta) = try await relaunchRecovery(atKill: journalEntries(), into: journal, expectAllRepaired: false)
        try await assertHistoryFollowsContent(using: store, meta)
        // Undo, then one more launch: no entry is left and nothing needs attention.
        let fresh = BatchRunner(fileOps: FileOps(metadata: meta, backups: store, watchers: nil), backups: store, metadata: meta)
        _ = try? await fresh.undo(result)
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") }, "\(names())")
        let again = await FileOps(metadata: meta, backups: store, watchers: nil)
            .recoverRenames(journal: journal, startedBefore: Date().addingTimeInterval(10))
        XCTAssertTrue(again.needsAttention.isEmpty, "\(again.needsAttention)")
        XCTAssertTrue(journal.pending().isEmpty, "\(journal.pending().map(\.moves))")
        XCTAssertEqual(names(), startNames)
        for n in 1...count { XCTAssertEqual(content(url(n)), "photo-\(n)") }
        try await assertHistoryFollowsContent(using: store, meta)
    }

    /// One photo could not be set aside: the photo planned to take its name fails safely (name
    /// taken) and, if its own old name is gone, ends under a " 2" name. Nothing under a temp name.
    func testFailedStagingOfOneBlockerLeavesNoTempName() async throws {
        let first = OSAllocatedUnfairLock(initialState: true)
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        runner.cleanupCheckpoint = { point, _ in
            if point == .beforeStage, first.withLock({ let v = $0; $0 = false; return v }) { throw CocoaError(.fileWriteNoPermission) }
        }
        let plan = try plan()
        let result = try await drain(runner.run(plan))
        // Whether a photo fails depends on whether the unstaged one moved before the photo that wants its name.
        try await assertClean(result, plan: plan, runner: runner, allowSecondNames: true)
    }

    // MARK: Replace

    /// A set-aside photo whose planned name holds a file that is NOT in the batch (Replace) is never
    /// moved on by the clean-up (that would trash the other file): it gets a " 2" name instead.
    func testCleanupNeverReplacesAnOutsideFile() async throws {
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 1, stop, throwing: false))
        // IMG_1 -> IMG_2, IMG_2 -> IMG_3; IMG_3 is not in the batch and would be replaced.
        let plan = BatchPlan(items: [ImageGroup(primary: url(1)), ImageGroup(primary: url(2))],
                             rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace, onConflict: .replace)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertEqual(content(url(3)), "photo-3", "the outside file is untouched")
        XCTAssertEqual(content(url(2)), "photo-1")
        XCTAssertEqual(content(folder.appendingPathComponent("IMG_2 2.jpg")), "photo-2")
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") })
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty, "nothing trashed")
        XCTAssertTrue(journalEntries().isEmpty)
        _ = try await runner.undo(result)
        XCTAssertEqual(content(url(1)), "photo-1"); XCTAssertEqual(content(url(2)), "photo-2"); XCTAssertEqual(content(url(3)), "photo-3")
        XCTAssertEqual(names(), startNames)
    }

    // MARK: F1: the " 2" move is covered by the journal

    /// Kill between the " 2" move and its bookkeeping: the files are at "IMG_2 2.jpg", the chain and
    /// rating still under the temp name. The next launch must give them to the " 2" photo (the old
    /// and the planned name hold OTHER photos) and nothing else; 40 days later record 0 is still kept.
    func testKillDuringSecondNameMoveIsRepairedAtNextLaunch() async throws {
        try Data("photo-2 v0".utf8).write(to: url(2))
        let record0 = try await backups.backup(url(2), reason: .save)
        try Data("photo-2".utf8).write(to: url(2))
        await backups.noteWritten(url(2))
        try await metadata.setRating(4, for: url(2))
        let second = folder.appendingPathComponent("IMG_2 2.jpg")
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let stop = BatchStop()
        let source2 = url(2).path
        let atKill = OSAllocatedUnfairLock<[RenameJournalEntry]>(initialState: [])
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 1, stop, throwing: false))
        runner.cleanupCheckpoint = { point, _ in
            guard point == .beforeCleanup else { return }
            // The " 2" move: the files go, then the process dies before the bookkeeping. The journal
            // is taken as it is at that moment (the fake kill lets the code run on).
            let entry = RenameJournal.shared.pending().first { $0.moves.first?.original == source2 }
            let temp = try XCTUnwrap(entry?.moves.first?.temporary)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: temp), to: second)
            atKill.withLock { $0 = entry.map { [$0] } ?? [] }
            throw CancellationError()
        }
        // IMG_1 -> IMG_2 (done), IMG_2 -> IMG_3 (an outside file, Replace): IMG_2 gets a " 2" name.
        let plan = BatchPlan(items: [ImageGroup(primary: url(1)), ImageGroup(primary: url(2))],
                             rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace, onConflict: .replace)
        _ = try await drain(runner.run(plan, stop: stop))
        XCTAssertEqual(content(second), "photo-2")

        // Next launch: only this run's entries, in a journal of their own.
        let journal = RenameJournal(directory: root.appendingPathComponent("_journal", isDirectory: true))
        for entry in journalEntries() { RenameJournal.shared.end(entry.id) }
        XCTAssertEqual(atKill.withLock { $0 }.first?.moves.map(\.final), [second.path], "at the kill the entry names the \" 2\" name")
        for entry in atKill.withLock({ $0 }) {
            journal.write(RenameJournalEntry(id: entry.id, created: .distantPast, moves: entry.moves, pid: 999_999))
        }
        let freshStore = BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() })
        let freshMeta = try MetadataStore(databaseURL: root.appendingPathComponent("_db/meta.sqlite"), writeFileAttributes: { false })
        _ = await FileOps(metadata: freshMeta, backups: freshStore, watchers: nil)
            .recoverRenames(journal: journal, startedBefore: Date().addingTimeInterval(10))
        let onSecond = await freshStore.records(for: second).map(\.id)
        XCTAssertTrue(onSecond.contains(record0.id), "the chain is on the \" 2\" photo: \(onSecond)")
        let rating = try await freshMeta.rating(for: second)
        XCTAssertEqual(rating, 4, "the rating is on the \" 2\" photo")
        XCTAssertEqual(content(url(2)), "photo-1"); XCTAssertEqual(content(url(3)), "photo-3")
        let onTwo = await freshStore.records(for: url(2)).map(\.id), onThree = await freshStore.records(for: url(3)).map(\.id)
        XCTAssertFalse(onTwo.contains(record0.id)); XCTAssertFalse(onThree.contains(record0.id))
        let rating1 = try await freshMeta.rating(for: url(2))
        XCTAssertEqual(rating1, expectedRating(1), "the photo at IMG_2 keeps its own rating")
        let later = BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 }, maxBytes: { 0 },
                                now: { Date().addingTimeInterval(40 * 86_400) })
        _ = await later.purge(olderThan: 30)
        _ = await later.reap()
        let kept = await later.records(for: second).map(\.id)
        XCTAssertTrue(kept.contains(record0.id), "40 days later record 0 is kept")
    }

    // MARK: F4: Undo through temporary names

    /// A stopped 60-photo run whose result walks photos through temporary names.
    private func stoppedRun() async throws -> BatchResult {
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 30, stop, throwing: true))
        return try await drain(runner.run(try plan(), stop: stop))
    }

    /// Every file's chain and rating belong to its content.
    private func assertHistoryFollowsContent(using store: BackupStore, _ meta: MetadataStore,
                                             file: StaticString = #filePath, line: UInt = #line) async throws {
        for name in names() {
            let url = folder.appendingPathComponent(name)
            guard let n = number(of: content(url)) else { continue }
            let chain = await store.records(for: url).map(\.id)
            if let id = chainIDs[n] { XCTAssertTrue(chain.contains(id), "photo-\(n)'s chain is on \(name)", file: file, line: line) }
            else { XCTAssertTrue(chain.isEmpty, "\(name): \(chain)", file: file, line: line) }
            let rating = try await meta.rating(for: url)
            XCTAssertEqual(rating, expectedRating(n), "photo-\(n)'s rating is on \(name)", file: file, line: line)
        }
    }

    /// Repairs as the next launch does, from this run's entries only, with fresh stores.
    /// `atKill`: the journal as it was when the process died (the test's fake kill lets the code
    /// run on, and that code may end entries a real kill would leave).
    private func relaunchRecovery(atKill: [RenameJournalEntry], into own: RenameJournal? = nil,
                                  expectAllRepaired: Bool = true) async throws -> (BackupStore, MetadataStore) {
        let journal = own ?? RenameJournal(directory: root.appendingPathComponent("_journal-\(UUID().uuidString)", isDirectory: true))
        for entry in journalEntries() { RenameJournal.shared.end(entry.id) }
        for entry in atKill {
            journal.write(RenameJournalEntry(id: entry.id, created: .distantPast, moves: entry.moves, pid: 999_999))
        }
        let store = BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() })
        let meta = try MetadataStore(databaseURL: root.appendingPathComponent("_db/meta.sqlite"), writeFileAttributes: { false })
        _ = await FileOps(metadata: meta, backups: store, watchers: nil)
            .recoverRenames(journal: journal, startedBefore: Date().addingTimeInterval(10))
        if expectAllRepaired { XCTAssertTrue(journal.pending().isEmpty, "every entry repaired: \(journal.pending().map(\.moves))") }
        return (store, meta)
    }

    /// One Undo step out of a temporary name fails: that photo gets a " 2" name (reported), never
    /// stays under the temporary name; every other photo gets its old name back.
    func testUndoWithAFailedStepLeavesNoTempName() async throws {
        let result = try await stoppedRun()
        let failed = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let doubled = OSAllocatedUnfairLock<[String]>(initialState: [])
        let path = folder.path
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        runner.cleanupCheckpoint = { point, url in
            // Review G2: never two open entries for one temporary name, at any step.
            let temps = RenameJournal.shared.pending().flatMap(\.moves).map(\.temporary).filter { $0.hasPrefix(path) }
            let twice = Dictionary(grouping: temps, by: { $0 }).filter { $0.value.count > 1 }.map(\.key)
            if !twice.isEmpty { doubled.withLock { $0 += twice } }
            guard point == .beforeUndoStep, url.lastPathComponent.contains("shrike-tmp-") else { return }
            if failed.withLock({ if $0 == nil { $0 = url; return true }; return false }) { throw CocoaError(.fileWriteNoPermission) }
        }
        let report = try await runner.undo(result)
        XCTAssertNotNil(failed.withLock { $0 })
        XCTAssertEqual(doubled.withLock { $0 }, [], "one entry per temporary name")
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") }, "\(names())")
        let extra = names().filter { !startNames.contains($0) }
        XCTAssertEqual(extra.count, 1, "\(extra)")
        XCTAssertEqual(report.restoredAs.map(\.new), extra, "the \" 2\" name is reported")
        XCTAssertEqual(names().compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted(), Array(1...count))
        for n in 1...count where FileManager.default.fileExists(atPath: url(n).path) {
            XCTAssertEqual(content(url(n)), "photo-\(n)")
        }
        XCTAssertTrue(journalEntries().isEmpty, "\(journalEntries().map(\.moves))")
        try await assertHistoryFollowsContent(using: backups, metadata)
    }

    /// Kill while Undo moves a photo from a real name to a temporary one, after the files moved and
    /// before the bookkeeping: the next launch puts it back at the name it left, with its history.
    func testKillWhileUndoSetsAPhotoAsideIsRepaired() async throws {
        let result = try await stoppedRun()
        var steps: [String: URL] = [:]
        for step in result.renames where step.before.primary.lastPathComponent.contains("shrike-tmp-") {
            steps[step.after.primary.path] = step.before.primary
        }
        let toTemp = steps
        let dead = OSAllocatedUnfairLock(initialState: false)
        let killed = OSAllocatedUnfairLock<URL?>(initialState: nil)
        let atKill = OSAllocatedUnfairLock<[RenameJournalEntry]>(initialState: [])
        let path = folder.path
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        runner.cleanupCheckpoint = { point, url in
            if dead.withLock({ $0 }) { throw CancellationError() }        // the process is gone
            guard point == .beforeUndoStep, let temp = toTemp[url.path] else { return }
            try FileManager.default.moveItem(at: url, to: temp)          // the files moved; then the kill
            let entries = RenameJournal.shared.pending().filter { $0.moves.contains { $0.original.hasPrefix(path) } }
            atKill.withLock { $0 = entries }
            killed.withLock { $0 = url }
            dead.withLock { $0 = true }
            throw CancellationError()
        }
        _ = try? await runner.undo(result)
        let photo = try XCTUnwrap(killed.withLock { $0 })
        XCTAssertFalse(atKill.withLock { $0 }.isEmpty, "a journal entry covers the move")
        let expected = try XCTUnwrap(result.items.first { $0.finalURL == photo }).source.primary
        let (store, meta) = try await relaunchRecovery(atKill: atKill.withLock { $0 })
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") }, "\(names())")
        XCTAssertEqual(number(of: content(photo)), number(of: "photo-" + expected.deletingPathExtension().lastPathComponent.dropFirst(4)))
        try await assertHistoryFollowsContent(using: store, meta)
    }

    /// Kill while the photos are under their temporary names in the middle of Undo: the next launch
    /// completes the Undo (every photo at its original name, with its history).
    func testKillWhileUndoHoldsPhotosUnderTemporaryNamesCompletesTheUndo() async throws {
        let result = try await stoppedRun()
        let dead = OSAllocatedUnfairLock(initialState: false)
        let atKill = OSAllocatedUnfairLock<[RenameJournalEntry]>(initialState: [])
        let path = folder.path
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        runner.cleanupCheckpoint = { point, url in
            if dead.withLock({ $0 }) { throw CancellationError() }
            if point == .beforeUndoStep, url.lastPathComponent.contains("shrike-tmp-") {
                let entries = RenameJournal.shared.pending().filter { $0.moves.contains { $0.original.hasPrefix(path) } }
                atKill.withLock { $0 = entries }
                dead.withLock { $0 = true }
                throw CancellationError()
            }
        }
        _ = try? await runner.undo(result)
        let temps = names().filter { $0.contains("shrike-tmp-") }
        XCTAssertFalse(temps.isEmpty, "the kill came with photos set aside")
        XCTAssertEqual(atKill.withLock { $0 }.count, temps.count, "each photo under a temporary name has its entry")
        let (store, meta) = try await relaunchRecovery(atKill: atKill.withLock { $0 })
        XCTAssertEqual(names(), startNames)
        for n in 1...count { XCTAssertEqual(content(url(n)), "photo-\(n)") }
        try await assertHistoryFollowsContent(using: store, meta)
    }

    // MARK: F5: Review Remaining picks a " 2" photo up where it is

    func testReviewRemainingRenamesASecondNamePhotoFromWhereItIs() async throws {
        let stop = BatchStop()
        let failedOnce = OSAllocatedUnfairLock(initialState: false)
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 30, stop, throwing: true))
        runner.cleanupCheckpoint = { point, _ in
            if point == .beforeCleanup, failedOnce.withLock({ let v = $0; $0 = true; return !v }) { throw CocoaError(.fileWriteNoPermission) }
        }
        let plan = try plan()
        let first = try await drain(runner.run(plan, stop: stop))
        let second = try XCTUnwrap(names().first { !startNames.contains($0) })
        let retry = BatchRunner(fileOps: ops, backups: backups, metadata: metadata).retryPlan(for: first, original: plan)
        XCTAssertTrue(retry.items.contains { $0.primary.lastPathComponent == second }, "addressed where it is now")
        let plain = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        let done = try await drain(plain.run(retry))
        XCTAssertEqual(names(), startNames, "the job is complete: \(names())")
        for item in first.items {
            let start = number(of: "photo-" + item.source.primary.deletingPathExtension().lastPathComponent.dropFirst(4))
            XCTAssertEqual(number(of: content(try XCTUnwrap(item.plannedDestinationURL))), start)
        }
        try await assertHistoryFollowsContent(using: backups, metadata)
        _ = try await plain.undo(done)
        XCTAssertEqual(names(), startNames)
        for n in 1...count { XCTAssertEqual(content(url(n)), "photo-\(n)") }
        try await assertHistoryFollowsContent(using: backups, metadata)
    }

    /// A queued photo whose own name already holds the marker (a leftover of the old bug) that the run
    /// never moved is still offered by Review Remaining: only rows moved aside BY the run are left out.
    func testRetryStillOffersAPhotoWhoseOwnNameHasTheMarker() async throws {
        let leftover = folder.appendingPathComponent("old shrike-tmp-AAAA1111.jpg")
        try Data("leftover".utf8).write(to: leftover)
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 1, stop, throwing: true))
        let plan = BatchPlan(items: [ImageGroup(primary: url(1)), ImageGroup(primary: leftover)],
                             rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 70), output: .inPlace)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertEqual(result.cancelledCount, 2)
        XCTAssertEqual(runner.retryPlan(for: result, original: plan).items.map(\.primary), [url(1), leftover])
    }

    // MARK: H1: nor a finished photo's companion under its new name

    /// A (IMG_1.JPG + IMG_1.CR3) is renamed to X.JPG + X.CR3; B (a RAW-only IMG_2.CR3) wanted X.CR3
    /// and failed. A retry of B with Replace must not trash A's RAW at its new name.
    func testRetryWithReplaceNeverTrashesAFinishedPhotosCompanion() async throws {
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let raw1 = folder.appendingPathComponent("IMG_1.CR3"), raw2 = folder.appendingPathComponent("IMG_2.CR3")
        try Data("raw-1".utf8).write(to: raw1); try Data("raw-2".utf8).write(to: raw2)
        let a = ImageGroup(primary: url(1), companions: [.init(url: raw1, kind: .raw)])
        let b = ImageGroup(primary: raw2, primaryIsRAW: true)
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        let plan = BatchPlan(items: [a, b], rename: try RenameTemplate(parsing: "X"), output: .inPlace, onConflict: .skip)
        let first = try await drain(runner.run(plan))
        let xRaw = folder.appendingPathComponent("X.CR3")
        XCTAssertEqual(content(xRaw), "raw-1", "A finished with its RAW")
        XCTAssertEqual(first.doneCount, 1, "\(first.items.map(\.outcome))")
        var retry = runner.retryPlan(for: first, original: plan)
        XCTAssertEqual(retry.items.map(\.primary), [raw2])
        retry.onConflict = .replace
        _ = try await drain(runner.run(retry))
        XCTAssertEqual(content(xRaw), "raw-1", "A's RAW is untouched")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty, "nothing trashed")
    }

    // MARK: H2: "left under a temporary name" comes from the run's record, not from the file name

    /// A photo whose own name already holds the marker and that got a " 2" name is offered by Review
    /// Remaining (it has a real name and no open entry).
    func testSecondNamePhotoWhoseNameHasTheMarkerIsRetried() async throws {
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let marked = folder.appendingPathComponent("IMG_2 shrike-tmp-AAAA1111.jpg")
        try FileManager.default.moveItem(at: url(2), to: marked)
        try Data("outside".utf8).write(to: folder.appendingPathComponent("IMG_3 shrike-tmp-AAAA1111.jpg"))
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 1, stop, throwing: false))
        // IMG_1 -> the marked photo's name; the marked photo -> an outside file's name (Replace).
        let plan = BatchPlan(items: [ImageGroup(primary: url(1)), ImageGroup(primary: marked)],
                             rename: try RenameTemplate(parsing: "IMG_{counter} shrike-tmp-AAAA1111", counterStart: 2),
                             output: .inPlace, onConflict: .replace)
        let result = try await drain(runner.run(plan, stop: stop))
        let row = try XCTUnwrap(result.items.first { $0.source.primary == marked })
        XCTAssertEqual(row.finalURL?.lastPathComponent, "IMG_2 shrike-tmp-AAAA1111 2.jpg")
        // Spec 28 §20.5 data.
        XCTAssertEqual(row.putBackAs?.lastPathComponent, "IMG_2 shrike-tmp-AAAA1111 2.jpg")
        XCTAssertEqual(result.putBackAsCount, 1)
        XCTAssertEqual(result.newNameCount, 1)
        XCTAssertEqual(result.oldNameCount, 0)
        XCTAssertEqual(runner.retryPlan(for: result, original: plan).items.map(\.primary.lastPathComponent),
                       ["IMG_2 shrike-tmp-AAAA1111 2.jpg"])
        // Undo reads "set aside" from the run's steps too, not from the marker in a real name.
        _ = try await runner.undo(result)
        XCTAssertEqual(content(url(1)), "photo-1")
        XCTAssertEqual(content(marked), "photo-2")
        XCTAssertTrue(journalEntries().isEmpty, "\(journalEntries().map(\.moves))")
    }

    // MARK: G3: a retry with Replace never trashes a photo of the same run

    /// IMG_1 -> IMG_2, IMG_2 -> IMG_3 with Skip: IMG_2 is skipped (IMG_3 is taken) and IMG_1 fails
    /// (IMG_2 still holds its name). Review Remaining with Replace retries IMG_1 alone: IMG_2 is a
    /// photo of the same run, not an outside file, and is never trashed.
    func testRetryWithReplaceNeverTrashesAPhotoOfTheSameRun() async throws {
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata)
        let plan = BatchPlan(items: [ImageGroup(primary: url(1)), ImageGroup(primary: url(2))],
                             rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace, onConflict: .skip)
        let first = try await drain(runner.run(plan))
        XCTAssertEqual(first.doneCount, 0, "\(first.items.map(\.outcome))")
        var retry = runner.retryPlan(for: first, original: plan)
        XCTAssertEqual(retry.items.map(\.primary), [url(1)])
        retry.onConflict = .replace
        let rows = await runner.preview(retry)
        XCTAssertNotEqual(rows.first?.outputName, "IMG_2.jpg", "the same-run photo's name is a clash, not a victim")
        _ = try await drain(runner.run(retry))
        XCTAssertEqual(content(url(2)), "photo-2", "IMG_2 is untouched")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty, "nothing trashed")
        XCTAssertEqual(names().compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted(), Array(1...count))
    }

    // MARK: More shapes named by the review

    /// RAW + JPEG + sidecar groups in a stopped swap, and a RAW-primary group whose JPEG companion
    /// has the name another photo wants: every group moves as one, nothing is split.
    func testGroupsWithCompanionsMoveAsOneWhenStopped() async throws {
        let dir = root.appendingPathComponent("pairs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func file(_ name: String) -> URL { dir.appendingPathComponent(name) }
        func write(_ name: String) throws { try Data("of-\(name)".utf8).write(to: file(name)) }
        var groups: [ImageGroup] = []
        for n in 1...6 {
            for ext in ["JPG", "CR3", "xmp"] { try write("IMG_\(n).\(ext)") }
            groups.append(ImageGroup(primary: file("IMG_\(n).JPG"), companions: [
                .init(url: file("IMG_\(n).CR3"), kind: .raw), .init(url: file("IMG_\(n).xmp"), kind: .sidecar)]))
        }
        // A.CR3 (primary) + A.JPG, next to B.JPG: B -> A's name, A -> B's.
        for name in ["A_1.CR3", "A_1.JPG", "A_2.JPG"] { try write(name) }
        let a = ImageGroup(primary: file("A_1.CR3"), companions: [.init(url: file("A_1.JPG"), kind: .raw)], primaryIsRAW: true)
        let b = ImageGroup(primary: file("A_2.JPG"))
        let start = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        for (items, template, k) in [([4, 1, 6, 2, 5, 3].map { groups[$0 - 1] }, "IMG_{counter}", 2), ([b, a], "A_{counter}", 1)] {
            let stop = BatchStop()
            let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                     renameCheckpoint: stopping(at: k, stop, throwing: false))
            let plan = BatchPlan(items: items, rename: try RenameTemplate(parsing: template), output: .inPlace)
            let result = try await drain(runner.run(plan, stop: stop))
            let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertFalse(left.contains { $0.contains("shrike-tmp-") }, "\(left)")
            XCTAssertEqual(left.count, start.count)
            for item in result.items {     // the group's files sit together under one stem
                let at = try XCTUnwrap(item.finalURL)
                let stem = at.deletingPathExtension().lastPathComponent
                for url in item.source.allURLs {
                    let now = dir.appendingPathComponent(stem + "." + url.pathExtension)
                    XCTAssertEqual(String(data: (try? Data(contentsOf: now)) ?? Data(), encoding: .utf8), "of-\(url.lastPathComponent)")
                }
            }
            XCTAssertTrue(journalEntries().isEmpty)
            _ = try await runner.undo(result)
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), start)
            for name in start { XCTAssertEqual(String(data: try Data(contentsOf: file(name)), encoding: .utf8), "of-\(name)") }
        }
    }

    /// A shift with a skipped member in the middle, stopped: IMG_20 -> IMG_1, IMG_1 -> IMG_2,
    /// IMG_2 -> IMG_3 (skipped: IMG_3 is a photo not in the queue), IMG_5 <-> IMG_4. IMG_1 is set
    /// aside, fails on the skipped photo's name, and its old name is gone: a " 2" name. The Stop
    /// lands on the swap, which goes back.
    func testSkippedMemberOfAShiftLeavesNoTempName() async throws {
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 3, stop, throwing: true))
        let plan = BatchPlan(items: [20, 1, 2, 5, 4].map { ImageGroup(primary: url($0)) },
                             rename: try RenameTemplate(parsing: "IMG_{counter}"), output: .inPlace, onConflict: .skip)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertTrue(stop.isStopped)
        XCTAssertTrue(result.renames.contains { BatchRunner.isTemporary($0.after) }, "photos were set aside")
        let skipped = try XCTUnwrap(result.items.first { $0.source.primary == url(2) })
        guard case .skipped(.nameExists) = skipped.outcome else { return XCTFail("\(skipped.outcome)") }
        let wanting = try XCTUnwrap(result.items.first { $0.source.primary == url(1) })
        guard case .failed = wanting.outcome else { return XCTFail("\(wanting.outcome)") }
        XCTAssertTrue(["IMG_1.jpg", "IMG_1 2.jpg"].contains(wanting.finalURL?.lastPathComponent ?? ""), "\(String(describing: wanting.finalURL))")
        try await assertClean(result, plan: plan, runner: runner, allowSecondNames: true)
    }

    /// A longer chain (IMG_1..4 -> IMG_2..5) whose last member would Replace an outside file, stopped.
    func testLongerChainWithAReplaceMemberStopped() async throws {
        let trash = root.appendingPathComponent("_trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let ops = FileOps(metadata: metadata, backups: backups, watchers: nil, trashItem: { url in
            let target = trash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 2, stop, throwing: false))
        let plan = BatchPlan(items: (1...4).map { ImageGroup(primary: url($0)) },
                             rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2), output: .inPlace, onConflict: .replace)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertEqual(content(url(5)), "photo-5", "the outside file is untouched")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).isEmpty, "nothing trashed")
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") }, "\(names())")
        XCTAssertEqual(names().compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted(), Array(1...count))
        XCTAssertTrue(journalEntries().isEmpty)
        try await assertHistoryFollowsContent(using: backups, metadata)
        _ = try await runner.undo(result)
        XCTAssertEqual(names(), startNames)
        for n in 1...count { XCTAssertEqual(content(url(n)), "photo-\(n)") }
    }

    /// An outside file appears at the name a clean-up move wants: it is never overwritten, and the
    /// photo ends under a visible " 2" name.
    func testOutsideFileAppearingDuringCleanupIsNeverOverwritten() async throws {
        let stop = BatchStop()
        let plan = try plan()
        var planned: [URL: URL] = [:]
        for (i, g) in plan.items.enumerated() { planned[g.primary] = folder.appendingPathComponent("IMG_\(i + 1).jpg") }
        let wanted = planned
        let outside = OSAllocatedUnfairLock<URL?>(initialState: nil)
        var runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 30, stop, throwing: true))
        runner.cleanupCheckpoint = { point, url in
            guard point == .beforeCleanup, outside.withLock({ $0 }) == nil else { return }
            // Where this move goes: the old name when it is free (put back), else the planned one.
            let target = FileManager.default.fileExists(atPath: url.path) ? wanted[url]! : url
            try Data("outside".utf8).write(to: target)
            outside.withLock { $0 = target }
        }
        _ = try await drain(runner.run(plan, stop: stop))
        let target = try XCTUnwrap(outside.withLock { $0 })
        XCTAssertEqual(content(target), "outside")
        XCTAssertFalse(names().contains { $0.contains("shrike-tmp-") }, "\(names())")
        XCTAssertEqual(names().count, count + 1)
        XCTAssertEqual(names().compactMap { number(of: content(folder.appendingPathComponent($0))) }.sorted(), Array(1...count))
        XCTAssertTrue(journalEntries().isEmpty)
        try FileManager.default.removeItem(at: target)
    }

    /// A small JPEG whose width tells it apart.
    @discardableResult
    private func jpeg(_ url: URL, width w: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: w, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: F2: Rotate + Rename reserves the names of photos whose rotate failed

    /// p -> B 2, q -> B 3, y -> B 4, "B 3" -> B 5. y's rotate fails (it keeps its name, its planned
    /// name stays wanted); "B 3"'s rename fails after q took its old name, so it gets a " 2"-style
    /// name. That name must not be "B 4", which a later Review Remaining would give to y.
    func testRotateRenameFallbackNeverTakesThePlannedNameOfAPhotoWhoseRotateFailed() async throws {
        let dir = root.appendingPathComponent("rot", isDirectory: true)
        let p = try jpeg(dir.appendingPathComponent("p.jpg"), width: 96)
        let q = try jpeg(dir.appendingPathComponent("q.jpg"), width: 112)
        let y = try jpeg(dir.appendingPathComponent("y.jpg"), width: 128)
        let z = try jpeg(dir.appendingPathComponent("B 3.jpg"), width: 144)
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata, phaseCheckpoint: { phase, url in
            if phase == .rotate, url == y { throw CocoaError(.fileWriteNoPermission) }
            if phase == .rename, url == z { throw CocoaError(.fileWriteNoPermission) }
        })
        let plan = BatchPlan(items: [p, q, y, z].map { ImageGroup(primary: $0) }, rotate: 1,
                             rename: try RenameTemplate(parsing: "B {counter}", counterStart: 2), output: .inPlace)
        let result = try await drain(runner.run(plan))
        let item = try XCTUnwrap(result.items.first { $0.source.primary == z })
        let now = try XCTUnwrap(item.finalURL?.lastPathComponent)
        XCTAssertNotEqual(now, "B 4.jpg", "y's planned name stays free")
        XCTAssertFalse(now.contains("shrike-tmp-"))
        XCTAssertEqual(BatchRunner.Header(item.finalURL!).map { Int(max($0.displaySize.width, $0.displaySize.height)) }, 144)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("B 4.jpg").path))
    }

    // MARK: Rename after in-place pixel work

    /// Rename + convert always writes to an output folder (new files, nothing set aside). The
    /// in-place second rename phase comes after a lossless rotate (or an in-place recipe): a Stop in
    /// it leaves no temp name either.
    func testStopDuringRenameAfterRotateLeavesNoTempName() async throws {
        let n = 12
        let jpegs = root.appendingPathComponent("jpegs", isDirectory: true)
        try FileManager.default.createDirectory(at: jpegs, withIntermediateDirectories: true)
        var groups: [ImageGroup] = []
        for i in 1...n {   // the long side tells the photos apart: 96 + 16 i
            let url = jpegs.appendingPathComponent("IMG_\(i).jpg")
            let w = 96 + i * 16
            let ctx = CGContext(data: nil, width: w, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            groups.append(ImageGroup(primary: url))
        }
        groups = [7, 3, 11, 1, 9, 12, 5, 2, 10, 4, 8, 6].map { groups[$0 - 1] }
        let stop = BatchStop()
        let runner = BatchRunner(fileOps: ops, backups: backups, metadata: metadata,
                                 renameCheckpoint: stopping(at: 5, stop, throwing: true))
        let plan = BatchPlan(items: groups, rotate: 1, rename: try RenameTemplate(parsing: "IMG_{counter}"), output: .inPlace)
        let result = try await drain(runner.run(plan, stop: stop))
        XCTAssertTrue(stop.isStopped)
        XCTAssertTrue(result.renames.contains { $0.after.primary.lastPathComponent.contains("shrike-tmp-") },
                      "photos were set aside before the Stop")
        func longSide(_ url: URL) -> Int? { BatchRunner.Header(url).map { Int(max($0.displaySize.width, $0.displaySize.height)) } }
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: jpegs.path)) ?? []).sorted()
        XCTAssertFalse(left.contains { $0.contains("shrike-tmp-") }, "\(left)")
        XCTAssertEqual(Set(left), Set((1...n).map { "IMG_\($0).jpg" }))
        XCTAssertEqual(left.compactMap { longSide(jpegs.appendingPathComponent($0)) }.sorted(), (1...n).map { 96 + $0 * 16 },
                       "every photo once")
        for item in result.items {
            let w = 96 + Int(item.source.primary.deletingPathExtension().lastPathComponent.dropFirst(4))! * 16
            XCTAssertEqual(item.finalURL.flatMap(longSide), w, "\(item.source.primary.lastPathComponent) is where its row says")
        }
        XCTAssertTrue(journalEntries().isEmpty)
        _ = try await runner.undo(result)
        for i in 1...n {
            let url = jpegs.appendingPathComponent("IMG_\(i).jpg")
            XCTAssertEqual(longSide(url), 96 + i * 16)
            XCTAssertEqual(BatchRunner.Header(url).map { Int($0.displaySize.height) }, 48, "IMG_\(i) is upright again")
        }
    }
}

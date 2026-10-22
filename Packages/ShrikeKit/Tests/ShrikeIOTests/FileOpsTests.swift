//
//  FileOpsTests.swift
//  ShrikeIOTests
//
//  Temp directories only. Most tests use a fake
//  Trash inside the temp dir; one test round-trips through the real Trash
//  with a uniquely named temp file and removes it afterwards.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

// MARK: - Test doubles

/// Moves "trashed" files into a folder inside the test's temp dir.
final class FakeTrash: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var calls = 0
    /// Throw "no Trash on this volume" for every call.
    var noTrash = false
    /// Throw a permission error on this call number (1-based).
    var failOnCall: Int?

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws -> URL {
        lock.lock()
        calls += 1
        let call = calls
        let noTrash = self.noTrash
        let failOn = failOnCall
        lock.unlock()
        if noTrash {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        if call == failOn {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        }
        let target = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

final class RecordingSuppressor: FolderChangeSuppressing, @unchecked Sendable {
    private let lock = NSLock()
    private var _paths: [URL] = []
    var paths: [URL] { lock.lock(); defer { lock.unlock() }; return _paths }
    func ignore(paths: [URL], for duration: Duration) {
        lock.lock(); _paths.append(contentsOf: paths); lock.unlock()
    }
}

// MARK: - Tests

final class FileOpsTests: XCTestCase {

    var tmp: IOTempDir!
    var trash: FakeTrash!
    var metadata: MetadataStore!
    var backups: BackupStore!
    var suppressor: RecordingSuppressor!

    override func setUp() async throws {
        try await super.setUp()
        tmp = IOTempDir("FileOps")
        trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash", isDirectory: true))
        metadata = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("_db/meta.sqlite"),
                                     writeFileAttributes: { false })
        backups = BackupStore(root: tmp.url.appendingPathComponent("_backups", isDirectory: true),
                              retentionDays: { 30 })
        suppressor = RecordingSuppressor()
    }

    override func tearDown() async throws {
        // Undo any chmod from the rollback test so cleanup can delete.
        let locked = tmp.url.appendingPathComponent("locked")
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        tmp.cleanup()
        try await super.tearDown()
    }

    private func makeOps(backups: BackupStore?? = nil) -> FileOps {
        let trash = self.trash!
        return FileOps(metadata: metadata,
                       backups: backups ?? self.backups,
                       watchers: suppressor,
                       trashItem: { try trash.trash($0) })
    }

    /// Files in `sub`, grouped like the viewer would.
    private func group(_ names: [String], in sub: String) throws -> ImageGroup {
        let urls = try names.map { try tmp.file($0, "content of \($0)", in: sub) }
        let groups = ImageGrouping.group(urls, options: .default)
        XCTAssertEqual(groups.count, 1, "fixture must form one group")
        return groups[0]
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func drain(_ stream: AsyncThrowingStream<FileOpProgress, any Error>) async throws -> FileOpProgress {
        var last: FileOpProgress?
        for try await p in stream { last = p }
        return try XCTUnwrap(last)
    }

    // MARK: Trash / restore

    func testTrashMovesWholeGroupAndRestorePutsItBack() async throws {
        let g = try group(["P1.JPG", "P1.ORF", "P1.xmp"], in: "cam")
        try await metadata.setRating(4, for: g.primary)
        try await metadata.setRating(4, for: try XCTUnwrap(g.rawURL))
        let ops = makeOps()

        let receipt = try await ops.trash([g])
        XCTAssertEqual(receipt.items.count, 1)
        XCTAssertEqual(receipt.items[0].files.count, 3)
        XCTAssertTrue(receipt.failures.isEmpty)
        for url in g.allURLs { XCTAssertFalse(exists(url), url.lastPathComponent) }
        for file in receipt.items[0].files { XCTAssertTrue(exists(file.trashed)) }
        XCTAssertEqual(Set(suppressor.paths), Set(g.allURLs), "own writes reported to watchers")

        let restored = try await ops.restore(receipt)
        XCTAssertEqual(restored.groups, [g])
        for url in g.allURLs { XCTAssertTrue(exists(url)) }
        let rating = try await metadata.rating(for: g.primary)
        XCTAssertEqual(rating, 4, "rating survives trash + undo")
    }

    func testRestoreUsesSameSuffixWhenNameTaken() async throws {
        let g = try group(["DSC_0042.jpg", "DSC_0042.ORF"], in: "cam")
        let ops = makeOps()
        let receipt = try await ops.trash([g])
        try tmp.file("DSC_0042.jpg", "newcomer", in: "cam")

        let result = try await ops.restore(receipt)
        let names = result.groups[0].allURLs.map(\.lastPathComponent)
        XCTAssertEqual(names, ["DSC_0042 2.jpg", "DSC_0042 2.ORF"])
        XCTAssertEqual(readString(tmp.url.appendingPathComponent("cam/DSC_0042.jpg")), "newcomer")
    }

    func testRestoreFailsWhenNoLongerInTrash() async throws {
        let g = try group(["a.jpg"], in: "cam")
        let ops = makeOps()
        let receipt = try await ops.trash([g])
        try FileManager.default.removeItem(at: receipt.items[0].files[0].trashed)
        do {
            _ = try await ops.restore(receipt)
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? FileOpsError, .notFound(g.primary))
        }
    }

    func testNoTrashVolumeThrowsAndLeavesFiles() async throws {
        let g = try group(["a.jpg", "a.ORF"], in: "smb")
        trash.noTrash = true
        let ops = makeOps()
        do {
            _ = try await ops.trash([g])
            XCTFail("expected noTrash")
        } catch let error as FileOpsError {
            guard case .noTrash(_, let url) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(url, g.primary)
        }
        for url in g.allURLs { XCTAssertTrue(exists(url)) }

        // Alert A1 → Delete.
        try await ops.deleteImmediately(g)
        for url in g.allURLs { XCTAssertFalse(exists(url)) }
    }

    func testTrashRollsBackGroupWhenCompanionFails() async throws {
        let g = try group(["a.jpg", "a.ORF"], in: "cam")
        trash.failOnCall = 2
        let ops = makeOps()
        do {
            _ = try await ops.trash([g])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FileOpsError, .permissionDenied(try XCTUnwrap(g.rawURL)))
        }
        for url in g.allURLs { XCTAssertTrue(exists(url), "\(url.lastPathComponent) put back") }
    }

    func testTrashManyReportsPartialFailure() async throws {
        let a = try group(["a.jpg"], in: "cam")
        let b = try group(["b.jpg"], in: "cam")
        trash.failOnCall = 2
        let ops = makeOps()
        let receipt = try await ops.trash([a, b])
        XCTAssertEqual(receipt.trashedGroups, [a])
        XCTAssertEqual(receipt.failures.map(\.group), [b])
        XCTAssertTrue(exists(b.primary))
    }

    func testRealSystemTrashRoundTrip() async throws {
        let name = "shrike-fileops-test-\(UUID().uuidString).jpg"
        let url = try tmp.file(name, "x", in: "real")
        let g = ImageGroup(primary: url)
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let receipt = try await ops.trash([g])
        let trashed = receipt.items[0].files[0].trashed
        defer { try? FileManager.default.removeItem(at: trashed) }   // never leave test files in the Trash
        XCTAssertNotEqual(trashed, url)
        XCTAssertFalse(exists(url))
        let restored = try await ops.restore(receipt)
        XCTAssertEqual(restored.groups.first?.primary.path, url.path)
        XCTAssertTrue(exists(url))
    }

    // MARK: Copy / move

    func testCopyGroupCopiesMetadataAndUndoTrashesCopies() async throws {
        let g = try group(["P1.JPG", "P1.ORF"], in: "cam")
        try await metadata.setRating(3, for: g.primary)
        try await metadata.setFlag(true, for: g.primary)
        let dest = try tmp.dir("Selects")
        let ops = makeOps()

        let last = try await drain(ops.copy([g], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.isFinished)
        XCTAssertFalse(last.wasCancelled)
        XCTAssertEqual(last.completed, 1)
        XCTAssertEqual(last.bytesDone, last.bytesTotal)
        XCTAssertEqual(names(in: dest), ["P1.JPG", "P1.ORF"])
        for url in g.allURLs { XCTAssertTrue(exists(url), "original stays") }
        let copy = try XCTUnwrap(last.receipt.items.first?.result)
        let copiedRating = try await metadata.rating(for: copy.primary)
        let copiedFlag = try await metadata.isFlagged(copy.primary)
        XCTAssertEqual(copiedRating, 3)
        XCTAssertTrue(copiedFlag)

        try await ops.undo(last.receipt)
        XCTAssertEqual(names(in: dest), [])
        for url in g.allURLs { XCTAssertTrue(exists(url)) }
    }

    func testMoveCarriesRatingAndUndoMovesBack() async throws {
        let g = try group(["P1.JPG", "P1.ORF", "P1.xmp"], in: "cam")
        try await metadata.setRating(5, for: g.primary)
        let dest = try tmp.dir("Selects")
        let ops = makeOps()
        let feed = ops.changes()

        let last = try await drain(ops.move([g], to: dest, conflicts: .always(.skip)))
        let moved = try XCTUnwrap(last.receipt.items.first?.result)
        XCTAssertEqual(names(in: dest), ["P1.JPG", "P1.ORF", "P1.xmp"])
        for url in g.allURLs { XCTAssertFalse(exists(url)) }
        let movedRating = try await metadata.rating(for: moved.primary)
        XCTAssertEqual(movedRating, 5)
        XCTAssertEqual(moved.rawURL?.lastPathComponent, "P1.ORF")

        var iterator = feed.makeAsyncIterator()
        let change = await iterator.next()
        XCTAssertEqual(change?.kind, .move)
        XCTAssertEqual(change?.moved.map(\.from), g.allURLs)

        try await ops.undo(last.receipt)
        for url in g.allURLs { XCTAssertTrue(exists(url)) }
        XCTAssertEqual(names(in: dest), [])
        let backRating = try await metadata.rating(for: g.primary)
        XCTAssertEqual(backRating, 5)
    }

    // MARK: Backup chains follow the file (A.7 point 5)

    func testMoveAndRenameCarryBackupChain() async throws {
        let g = try group(["B1.jpg"], in: "cam")
        _ = try await backups.backup(g.primary, reason: .save)
        let dest = try tmp.dir("Out")
        let ops = makeOps()

        let last = try await drain(ops.move([g], to: dest, conflicts: .always(.skip)))
        let moved = try XCTUnwrap(last.receipt.items.first?.result)
        let atOld = await backups.records(for: g.primary)
        let atNew = await backups.records(for: moved.primary)
        XCTAssertTrue(atOld.isEmpty, "chain left the old path")
        XCTAssertEqual(atNew.count, 1)
        XCTAssertEqual(atNew.first?.originalURL.lastPathComponent, "B1.jpg")

        let renamed = try await ops.rename(moved, toStem: "Keeper")
        let afterRename = await backups.records(for: renamed.primary)
        XCTAssertEqual(afterRename.count, 1)
        let edited = await backups.state(for: renamed.primary)
        XCTAssertEqual(edited, .edited, "pencil badge survives the rename")

        _ = try await ops.rename(renamed, toStem: "B1")
        try await ops.undo(last.receipt)
        let home = await backups.records(for: g.primary)
        XCTAssertEqual(home.count, 1, "undo of the move brings the chain back")
    }

    func testReplaceBacksUpWithReplaceReasonAndChainGoesToTrash() async throws {
        let incoming = try group(["R1.jpg"], in: "cam")
        try tmp.file("R1.jpg", "old victim", in: "Dest")
        let dest = tmp.url.appendingPathComponent("Dest", isDirectory: true)
        let victim = dest.appendingPathComponent("R1.jpg")
        let ops = makeOps()

        let last = try await drain(ops.copy([incoming], to: dest, conflicts: .always(.replace)))
        let replaced = try XCTUnwrap(last.receipt.items.first?.replaced.first)
        XCTAssertEqual(replaced.backup?.reason, .replace)
        XCTAssertEqual(FileOps.replaceBackupReason, .replace)
        let destState = await backups.state(for: victim)
        XCTAssertEqual(destState, .none, "arriving file is not an edit of the victim")
        let trashed = try XCTUnwrap(replaced.trashed)
        let inTrash = await backups.records(for: trashed)
        XCTAssertEqual(inTrash.map(\.reason), [.replace])

        try await ops.undo(last.receipt)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "old victim")
        let back = await backups.records(for: victim)
        XCTAssertEqual(back.map(\.reason), [.replace], "chain returns with the file")
    }

    func testKeepBothSuffixesWholeGroupAndAppliesToRemaining() async throws {
        // "Do this for the remaining 2 conflicts" + Keep Both.
        let groups = try ["x", "y", "z"].map { try group(["\($0).jpg", "\($0).ORF"], in: "cam") }
        let dest = try tmp.dir("Selects")
        for n in ["x.jpg", "y.jpg", "z.ORF"] { try tmp.file(n, "old", in: "Selects") }
        let asked = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let ops = makeOps()

        let last = try await drain(ops.copy(groups, to: dest, conflicts: .ask { conflict in
            asked.withLock { $0.append(conflict.remainingConflicts) }
            return ConflictAnswer(.keepBoth, applyToRemaining: true)
        }))
        XCTAssertEqual(asked.withLock { $0 }, [2], "asked once, with 2 conflicts remaining")
        XCTAssertEqual(last.receipt.items.count, 3)
        // Plain `sorted()`: uppercase sorts before lowercase.
        XCTAssertEqual(names(in: dest), ["x 2.ORF", "x 2.jpg", "x.jpg", "y 2.ORF", "y 2.jpg", "y.jpg",
                                         "z 2.ORF", "z 2.jpg", "z.ORF"])
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "old")
    }

    func testKeepBothIncrementsExistingNumber() {
        let dir = tmp.url
        _ = try? tmp.file("a 2.jpg")
        XCTAssertEqual(FileOps.freeNames(for: ["a 2.jpg"], stem: "a 2", in: dir), ["a 3.jpg"])
        XCTAssertEqual(FileOps.freeNames(for: ["free.jpg"], stem: "free", in: dir), ["free.jpg"])
        XCTAssertEqual(FileOps.renamed("IMG_1.CR3.xmp", oldStem: "IMG_1", newStem: "IMG_1 2"), "IMG_1 2.CR3.xmp")
        XCTAssertEqual(FileOps.renamed("p1.orf", oldStem: "P1", newStem: "Venice"), "Venice.orf")
    }

    func testReplaceBacksUpAndTrashesExistingGroupThenUndoRestoresIt() async throws {
        let g = try group(["x.jpg"], in: "cam")
        let dest = try tmp.dir("Selects")
        for n in ["x.jpg", "x.ORF", "x.xmp"] { try tmp.file(n, "old \(n)", in: "Selects") }
        let ops = makeOps()

        let last = try await drain(ops.copy([g], to: dest, conflicts: .always(.replace)))
        let item = try XCTUnwrap(last.receipt.items.first)
        XCTAssertEqual(Set(item.replaced.map(\.original.lastPathComponent)), ["x.jpg", "x.ORF", "x.xmp"],
                       "the whole existing group goes, not just the clashing name")
        XCTAssertTrue(item.replaced.allSatisfy { $0.trashed != nil && $0.backup != nil })
        XCTAssertEqual(names(in: dest), ["x.jpg"])
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "content of x.jpg")
        let records = await backups.allRecords()
        XCTAssertEqual(records.count, 3, "every replaced file was backed up first")

        try await ops.undo(last.receipt)
        XCTAssertEqual(names(in: dest), ["x.ORF", "x.jpg", "x.xmp"])
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "old x.jpg")
    }

    func testReplaceOnVolumeWithoutTrashUsesBackup() async throws {
        let g = try group(["x.jpg"], in: "cam")
        let dest = try tmp.dir("Selects")
        try tmp.file("x.jpg", "old", in: "Selects")
        trash.noTrash = true
        let ops = makeOps()

        let last = try await drain(ops.move([g], to: dest, conflicts: .always(.replace)))
        let replaced = try XCTUnwrap(last.receipt.items.first?.replaced.first)
        XCTAssertNil(replaced.trashed)
        XCTAssertNotNil(replaced.backup)
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "content of x.jpg")

        try await ops.undo(last.receipt)
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "old", "restored from BackupStore")
        XCTAssertTrue(exists(g.primary))
    }

    func testReplaceWithoutBackupStoreRefusesOnVolumeWithoutTrash() async throws {
        let g = try group(["x.jpg"], in: "cam")
        let dest = try tmp.dir("Selects")
        try tmp.file("x.jpg", "old", in: "Selects")
        trash.noTrash = true
        let ops = makeOps(backups: .some(nil))

        let last = try await drain(ops.copy([g], to: dest, conflicts: .always(.replace)))
        XCTAssertTrue(last.receipt.isEmpty)
        guard case .noTrash = try XCTUnwrap(last.failures.first).error else {
            return XCTFail("expected noTrash, got \(last.failures)")
        }
        XCTAssertEqual(readString(dest.appendingPathComponent("x.jpg")), "old", "nothing overwritten")
    }

    func testSkipAndAlreadyInFolder() async throws {
        let a = try group(["a.jpg"], in: "cam")
        let b = try group(["b.jpg"], in: "cam")
        let dest = try tmp.dir("Selects")
        try tmp.file("b.jpg", "old", in: "Selects")
        let ops = makeOps()

        let last = try await drain(ops.copy([a, b], to: dest, conflicts: .always(.skip)))
        XCTAssertEqual(last.receipt.items.map(\.source), [a])
        XCTAssertEqual(last.skipped, [FileOpSkip(group: b, reason: .conflictSkipped)])

        let same = try await drain(ops.move([a], to: tmp.url.appendingPathComponent("cam"),
                                            conflicts: .always(.skip)))
        XCTAssertEqual(same.skipped, [FileOpSkip(group: a, reason: .alreadyInFolder)])
        XCTAssertTrue(exists(a.primary))
    }

    func testMissingDestinationThrows() async throws {
        let g = try group(["a.jpg"], in: "cam")
        let gone = tmp.url.appendingPathComponent("Unplugged", isDirectory: true)
        do {
            _ = try await drain(makeOps().copy([g], to: gone, conflicts: .always(.skip)))
            XCTFail("expected destinationUnavailable")
        } catch {
            XCTAssertEqual(error as? FileOpsError, .destinationUnavailable(gone))
        }
    }

    func testCancelStopsRemainingGroupsAndKeepsFinishedOnes() async throws {
        let groups = try ["a", "b", "c"].map { try group(["\($0).jpg"], in: "cam") }
        let dest = try tmp.dir("Selects")
        try tmp.file("b.jpg", "old", in: "Selects")
        let ops = makeOps()
        let lastSeen = OSAllocatedUnfairLock<FileOpProgress?>(initialState: nil)
        let consumer = OSAllocatedUnfairLock<Task<Void, any Error>?>(initialState: nil)

        let stream = ops.copy(groups, to: dest, conflicts: .ask { _ in
            // The user presses Esc while the conflict sheet is up.
            consumer.withLock { $0?.cancel() }
            return .keepBoth
        })
        let task = Task {
            for try await p in stream { lastSeen.withLock { $0 = p } }
        }
        consumer.withLock { $0 = task }
        _ = try? await task.value

        let last = try XCTUnwrap(lastSeen.withLock { $0 })
        XCTAssertEqual(last.receipt.items.map(\.source), [groups[0]], "a finished before the cancel")
        XCTAssertEqual(names(in: dest), ["a.jpg", "b.jpg"], "b (after cancel) and c not copied")
    }

    /// Esc must not leave a file that the count and Undo do not know about
    /// (cancelled copy said "573 of 900" with 574 on disk).
    func testStopKeepsCountReceiptAndDiskInStep() async throws {
        let groups = try (1...6).map { try group(["f\($0).jpg"], in: "cam") }
        let dest = try tmp.dir("Selects")
        let ops = makeOps()
        let stop = TransferStop()
        var last: FileOpProgress?
        for try await p in ops.copy(groups, to: dest, conflicts: .always(.keepBoth), stop: stop) {
            last = p
            if p.completed == 2, !p.isFinished { stop.stop() }
        }
        let final = try XCTUnwrap(last)
        XCTAssertTrue(final.isFinished)
        XCTAssertTrue(final.wasCancelled)
        XCTAssertLessThan(final.receipt.items.count, 6)
        XCTAssertEqual(names(in: dest).count, final.receipt.items.count, "disk matches the receipt")
        XCTAssertEqual(final.completed, final.receipt.items.count)

        try await ops.undo(final.receipt)
        XCTAssertEqual(names(in: dest), [], "Undo leaves nothing behind")
    }

    // MARK: Rename

    func testRenamePairAndUndoByRenamingBack() async throws {
        // Rename a pair, then undo by renaming back.
        let g = try group(["P1.JPG", "P1.ORF", "P1.ORF.xmp"], in: "cam")
        try await metadata.setRating(2, for: g.primary)
        let ops = makeOps()

        let renamed = try await ops.rename(g, toStem: "Venice")
        XCTAssertEqual(renamed.allURLs.map(\.lastPathComponent), ["Venice.JPG", "Venice.ORF", "Venice.ORF.xmp"])
        XCTAssertEqual(names(in: tmp.url.appendingPathComponent("cam")), ["Venice.JPG", "Venice.ORF", "Venice.ORF.xmp"])
        let rating = try await metadata.rating(for: renamed.primary)
        XCTAssertEqual(rating, 2)
        XCTAssertEqual(renamed.rawURL?.lastPathComponent, "Venice.ORF")

        let back = try await ops.rename(renamed, toStem: "P1")
        XCTAssertEqual(back, g)
    }

    func testX3FCompanionTravelsOnTrashMoveAndRename() async throws {
        // X3F / KDC are companion-only RAWs.
        let g = try group(["S1.JPG", "S1.X3F"], in: "sigma")
        XCTAssertEqual(g.rawURL?.lastPathComponent, "S1.X3F")
        let ops = makeOps()

        let renamed = try await ops.rename(g, toStem: "Venice")
        XCTAssertEqual(names(in: tmp.url.appendingPathComponent("sigma")), ["Venice.JPG", "Venice.X3F"])

        let dest = try tmp.dir("Selects")
        let moved = try await drain(ops.move([renamed], to: dest, conflicts: .always(.skip)))
        XCTAssertEqual(names(in: dest), ["Venice.JPG", "Venice.X3F"])

        let receipt = try await ops.trash([try XCTUnwrap(moved.receipt.items.first?.result)])
        XCTAssertEqual(receipt.items.first?.files.count, 2)
        XCTAssertEqual(names(in: dest), [])
    }

    func testCaseOnlyRename() async throws {
        let g = try group(["dsc_1.jpg", "dsc_1.orf"], in: "cam")
        let ops = makeOps()
        XCTAssertEqual(ops.validate(stem: "DSC_1", for: g), .valid)
        let renamed = try await ops.rename(g, toStem: "DSC_1")
        XCTAssertEqual(names(in: tmp.url.appendingPathComponent("cam")), ["DSC_1.jpg", "DSC_1.orf"])
        XCTAssertEqual(renamed.primary.lastPathComponent, "DSC_1.jpg")
    }

    func testRenameRollsBackWhenCompanionFails() async throws {
        let primary = try tmp.file("a.jpg", "p", in: "open")
        let companion = try tmp.file("a.ORF", "r", in: "locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555],
                                              ofItemAtPath: companion.deletingLastPathComponent().path)
        let g = ImageGroup(primary: primary, companions: [.init(url: companion, kind: .raw)])
        let ops = makeOps()
        do {
            _ = try await ops.rename(g, toStem: "b")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FileOpsError, .permissionDenied(companion))
        }
        XCTAssertTrue(exists(primary), "primary rename rolled back")
        XCTAssertTrue(exists(companion))
    }

    func testValidateRules() throws {
        let g = try group(["DSC_0042.jpg", "DSC_0042.ORF"], in: "cam")
        try tmp.file("Venice.ORF", in: "cam")
        let ops = makeOps()
        XCTAssertEqual(ops.validate(stem: "", for: g), .empty)
        XCTAssertEqual(ops.validate(stem: "   ", for: g), .empty)
        XCTAssertEqual(ops.validate(stem: "a/b", for: g), .invalidCharacters)
        XCTAssertEqual(ops.validate(stem: "a:b", for: g), .invalidCharacters)
        XCTAssertEqual(ops.validate(stem: ".x", for: g), .hidden)
        XCTAssertEqual(ops.validate(stem: String(repeating: "é", count: 126), for: g), .tooLong)
        XCTAssertEqual(ops.validate(stem: "DSC_0042", for: g), .unchanged)
        let taken = ops.validate(stem: "Venice", for: g)
        XCTAssertEqual(taken, .nameTaken(tmp.url.appendingPathComponent("cam/Venice.ORF")),
                       "a companion's new name counts")
        XCTAssertEqual(taken.message, "A file named “Venice.ORF” already exists.")
        XCTAssertEqual(ops.validate(stem: "Rome", for: g), .valid)
        XCTAssertEqual(RenameValidation.invalidCharacters.message, "Names can't contain “/” or “:”.")
    }

    func testRenameRefusesInvalidName() async throws {
        let g = try group(["a.jpg"], in: "cam")
        do {
            _ = try await makeOps().rename(g, toStem: "x/y")
            XCTFail("expected invalidName")
        } catch {
            XCTAssertEqual(error as? FileOpsError, .invalidName(.invalidCharacters))
        }
    }

    // MARK: Watchers

    func testRealWatcherIgnoresOwnTrashButSeesOthers() async throws {
        let dir = try tmp.dir("watched")
        try tmp.file("keep.jpg", in: "watched")
        let g = try group(["gone.jpg"], in: "watched")
        let registry = FolderWatcherRegistry()
        let watcher = try FolderWatcher(folder: dir, options: .init(debounce: .milliseconds(100)))
        registry.register(watcher)
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: registry,
                          trashItem: { try trash.trash($0) })

        _ = try await ops.trash([g])
        try tmp.file("external.jpg", in: "watched")   // a change made outside Shrike

        var seen = FolderChange()
        let deadline = ContinuousClock.now + .seconds(5)
        for await change in watcher.changes {
            seen.added += change.added
            seen.removed += change.removed
            if !seen.added.isEmpty || ContinuousClock.now > deadline { break }
        }
        watcher.stop()
        XCTAssertEqual(seen.added.map(\.lastPathComponent), ["external.jpg"])
        XCTAssertTrue(seen.removed.isEmpty, "Shrike's own trash must not come back as a removal")
    }

    func testRegistryHoldsWatchersWeakly() throws {
        let registry = FolderWatcherRegistry()
        var watcher: FolderWatcher? = try FolderWatcher(folder: tmp.url)
        registry.register(try XCTUnwrap(watcher))
        XCTAssertEqual(registry.registered.count, 1)
        watcher?.stop()
        watcher = nil
        XCTAssertEqual(registry.registered.count, 0)
    }
}

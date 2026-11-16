//
//  FileOpsSafetyTests.swift
//  ShrikeIOTests
//
//  Audit 2026-11-10, part B: B-2 (a failed copy never removes a file that was
//  already there), B-10 (copy writes to a hidden temp name first), B-4, B-9.
//

import XCTest
import Darwin
import os
import ShrikeCore
@testable import ShrikeIO

final class FileOpsSafetyTests: XCTestCase {

    var tmp: IOTempDir!
    var trash: FakeTrash!

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("FileOpsSafety")
        trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash", isDirectory: true))
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
    private func visibleAndHidden(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    private func drain(_ stream: AsyncThrowingStream<FileOpProgress, any Error>) async throws -> FileOpProgress {
        var last: FileOpProgress?
        for try await p in stream { last = p }
        return try XCTUnwrap(last)
    }

    // MARK: B-2

    func testFailedCopyWithFileExistsKeepsTheFileThatWasAlreadyThere() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let target = dest.appendingPathComponent("IMG_1.jpg")
        let trash = self.trash!
        // Another app puts a file at the target after Shrike checked for clashes,
        // so the copy fails with "file exists".
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { _, to in
            // The copy lands in a temp file; the other app's file appears at the final name.
            try Data("half".utf8).write(to: to)
            try Data("someone else".utf8).write(to: target)
        },
                          sameVolume: FileOps.onSameVolume)
        let last = try await drain(ops.copy([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertEqual(last.failures.count, 1)
        XCTAssertEqual(read(target), "someone else", "a file this transfer did not create stays")
        XCTAssertEqual(read(src), "mine")
    }

    // MARK: B-10

    func testCopyWritesToAHiddenTempNameAndRenamesIntoPlace() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let during = OSAllocatedUnfairLock(initialState: [String]())
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            during.withLock { $0 = ((try? FileManager.default.contentsOfDirectory(atPath: to.deletingLastPathComponent().path)) ?? []) }
        },
                          sameVolume: FileOps.onSameVolume)
        let last = try await drain(ops.copy([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.failures.isEmpty)
        let seen = during.withLock { $0 }
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(seen[0].hasPrefix(".IMG_1.jpg.shriketransfer."), "while copying, only the temp name exists: \(seen)")
        XCTAssertEqual(visibleAndHidden(in: dest), ["IMG_1.jpg"])
        XCTAssertEqual(read(dest.appendingPathComponent("IMG_1.jpg")), "mine")
    }

    func testCrossVolumeMoveCopiesThenRemovesTheSource() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { try FileManager.default.copyItem(at: $0, to: $1) },
                          sameVolume: { _, _ in false })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.failures.isEmpty)
        XCTAssertFalse(exists(src))
        XCTAssertEqual(visibleAndHidden(in: dest), ["IMG_1.jpg"])
    }

    func testFailedCrossVolumeMoveLeavesNoPartialFileAndKeepsTheSource() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { _, to in
            try Data("half".utf8).write(to: to)
            throw POSIXError(.ENOSPC)
        },
                          sameVolume: { _, _ in false })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertEqual(last.failures.count, 1)
        XCTAssertEqual(read(src), "mine", "the source is never touched")
        XCTAssertEqual(visibleAndHidden(in: dest), [], "no partial file at the final name, no temp")
    }

    func testSameVolumeMoveIsAPlainRename() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let copied = OSAllocatedUnfairLock(initialState: false)
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { _, _ in copied.withLock { $0 = true } },
                          sameVolume: { _, _ in true })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.failures.isEmpty)
        XCTAssertFalse(copied.withLock { $0 }, "a same-volume move never copies")
        XCTAssertEqual(read(dest.appendingPathComponent("IMG_1.jpg")), "mine")
    }

    func testFailedCopyOtherErrorRemovesOnlyItsOwnPartialFile() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { _, to in
            try Data("half".utf8).write(to: to)
            throw CocoaError(.fileWriteOutOfSpace)
        },
                          sameVolume: FileOps.onSameVolume)
        let last = try await drain(ops.copy([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertEqual(last.failures.count, 1)
        XCTAssertEqual(visibleAndHidden(in: dest), [], "no partial file and no temp left")
    }

    // MARK: B-4

    func testReplaceOnVolumeWithoutTrashMovesTheOldChainAwayAndUndoBringsItBack() async throws {
        let backups = BackupStore(root: tmp.url.appendingPathComponent("_backups"), retentionDays: { 30 })
        let incoming = try tmp.file("x.jpg", "incoming", in: "cam")
        let dest = try tmp.dir("Selects")
        let victim = try tmp.file("x.jpg", "old victim", in: "Selects")
        let trash = self.trash!
        trash.noTrash = true
        let ops = FileOps(metadata: nil, backups: backups, watchers: nil, trashItem: { try trash.trash($0) })

        let last = try await drain(ops.copy([ImageGroup(primary: incoming)], to: dest, conflicts: .always(.replace)))
        XCTAssertEqual(read(victim), "incoming")
        let atPath = await backups.records(for: victim)
        XCTAssertTrue(atPath.isEmpty, "the new file at this path has no history")
        let availability = await backups.availability(for: victim)
        XCTAssertFalse(availability.canRevert, "Revert to Original must not offer the replaced photo")
        let all = await backups.allRecords()
        XCTAssertEqual(all.map(\.reason), [.replace], "the old photo's backup is still in the store")

        _ = try await ops.undo(last.receipt)
        XCTAssertEqual(read(victim), "old victim")
        let back = await backups.records(for: victim)
        XCTAssertEqual(back.map(\.reason), [.replace], "the chain is back with the old photo")
    }

    // MARK: F3

    func testAMoveWhoseSourceRemovalReportsAnErrorAfterTheUnlinkKeepsTheNewCopy() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { try FileManager.default.copyItem(at: $0, to: $1) },
                          sameVolume: { _, _ in false },
                          removeFile: { url in
            try FileManager.default.removeItem(at: url)     // the unlink works ...
            throw POSIXError(.EIO)                          // ... and still reports an error
        })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.failures.isEmpty, "the move is reported as done")
        XCTAssertEqual(read(dest.appendingPathComponent("IMG_1.jpg")), "mine", "the only copy is kept")
        XCTAssertFalse(exists(src))
    }

    func testAMoveWhoseSourceCannotBeRemovedUndoesTheCopy() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { try FileManager.default.copyItem(at: $0, to: $1) },
                          sameVolume: { _, _ in false },
                          removeFile: { _ in throw POSIXError(.EACCES) })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertEqual(last.failures.count, 1)
        XCTAssertEqual(read(src), "mine")
        XCTAssertEqual(visibleAndHidden(in: dest), [], "no duplicate is left behind")
    }

    /// Review: Replace followed by a failed transfer gives the replaced photo (and its chain) back.
    func testReplaceFollowedByAFailedTransferPutsTheVictimBack() async throws {
        let backups = BackupStore(root: tmp.url.appendingPathComponent("_backups"), retentionDays: { 30 })
        let incoming = try tmp.file("x.jpg", "incoming", in: "cam")
        let dest = try tmp.dir("Selects")
        let victim = try tmp.file("x.jpg", "old victim", in: "Selects")
        let trash = self.trash!
        trash.noTrash = true
        let ops = FileOps(metadata: nil, backups: backups, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { _, to in
            try Data("half".utf8).write(to: to)
            throw CocoaError(.fileWriteOutOfSpace)
        }, sameVolume: FileOps.onSameVolume)
        let last = try await drain(ops.copy([ImageGroup(primary: incoming)], to: dest, conflicts: .always(.replace)))
        XCTAssertEqual(last.failures.count, 1)
        XCTAssertEqual(read(victim), "old victim", "the replaced photo is back")
        XCTAssertEqual(visibleAndHidden(in: dest), ["x.jpg"], "no temp left")
        let chain = await backups.records(for: victim)
        XCTAssertEqual(chain.map(\.reason), [.replace], "its chain is back under its own path")
    }

    // MARK: F6

    func testShrikesOwnRenameMayUseAnEarlierNameThatBreaksTheRules() async throws {
        let file = try tmp.file("Mr..jpg", "photo", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        do {
            _ = try await ops.rename(ImageGroup(primary: tmp.url.appendingPathComponent("cam/Mr..jpg")), toStem: "Mr.")
            XCTFail("unchanged is not an error, but a user may not type a new name like this")
        } catch {}
        let moved = try await ops.rename(ImageGroup(primary: file), toStem: "x")
        // The put-back of a Batch rename (and Undo) restores an earlier name the shape rules would refuse.
        let back = try await ops.rename(moved, backToEarlierStem: "Mr.")
        XCTAssertEqual(back.primary.lastPathComponent, "Mr..jpg")
    }

    // MARK: F9a, F9b, F9c

    /// Negative control: a plain rename(2) overwrites. Proves the checks below can tell the difference.
    func testAPlainRenameSyscallWouldOverwriteWhichIsWhatTheExclusiveOneMustNotDo() throws {
        let a = try tmp.file("a", "from"), b = try tmp.file("b", "taken")
        try FileOps.renameExclusive(from: a, to: b, syscall: { Darwin.rename($0, $1) })
        XCTAssertEqual(read(b), "from", "the fake syscall overwrote the target")
    }

    func testTheExclusiveSyscallRefusesAnExistingTargetAndNeverMovesTheSource() throws {
        let a = try tmp.file("a", "from"), b = try tmp.file("b", "taken")
        XCTAssertThrowsError(try FileOps.renameExclusive(from: a, to: b)) { error in
            XCTAssertEqual(FileOps.map(error, url: a), .nameTaken(a))
        }
        XCTAssertEqual(read(b), "taken")
        XCTAssertEqual(read(a), "from")
        let c = tmp.url.appendingPathComponent("c")
        try FileOps.renameExclusive(from: a, to: c)
        XCTAssertEqual(read(c), "from")
        XCTAssertFalse(exists(a))
    }

    func testTheFallbackNeverOverwritesAFileThatAppearsBetweenCheckAndMove() throws {
        let a = try tmp.file("a", "from")
        let target = tmp.url.appendingPathComponent("b")
        XCTAssertThrowsError(try FileOps.renameExclusive(
            from: a, to: target,
            syscall: { _, _ in errno = ENOTSUP; return -1 },
            betweenCheckAndMove: { try? Data("appeared".utf8).write(to: target) })) { error in
            XCTAssertEqual(FileOps.map(error, url: a), .nameTaken(a))
        }
        XCTAssertEqual(read(target), "appeared")
        XCTAssertEqual(read(a), "from")
    }

    /// Review F3: a rename's move never overwrites a file that appears at its target after the name
    /// was checked. The seam creates the outside file right before the real exclusive syscall.
    func testRenameMoveNeverOverwritesAFileThatAppearsAfterTheCheck() throws {
        let a = try tmp.file("a.jpg", "photo")
        let target = tmp.url.appendingPathComponent("b.jpg")
        XCTAssertThrowsError(try FileOps.moveFile(from: a, to: target, syscall: { from, to in
            try? Data("outside".utf8).write(to: target)
            return renamex_np(from, to, UInt32(RENAME_EXCL))
        })) { error in
            XCTAssertEqual(FileOps.map(error, url: a), .nameTaken(a))
        }
        XCTAssertEqual(read(target), "outside")
        XCTAssertEqual(read(a), "photo")
        // A free target still works, and so does a case-only rename.
        try FileOps.moveFile(from: a, to: tmp.url.appendingPathComponent("c.jpg"))
        XCTAssertEqual(read(tmp.url.appendingPathComponent("c.jpg")), "photo")
        try FileOps.moveFile(from: tmp.url.appendingPathComponent("c.jpg"), to: tmp.url.appendingPathComponent("C.jpg"))
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: tmp.url.path)) ?? []).contains("C.jpg"))
    }

    func testEveryHiddenTempNameStaysUnderTheLimitAndTheSweeperKnowsIt() {
        let long = String(repeating: "n", count: 240)
        for marker in ["shrikerotate", "shrikerestore", "shriketransfer"] {
            for name in ["IMG_1.jpg", long + ".jpg"] {
                let temp = TemporaryFileSweeper.hiddenTempName(for: name, marker: marker)
                XCTAssertLessThanOrEqual(temp.utf8.count, 255)
                XCTAssertTrue(TemporaryFileSweeper.isCopyTemp(temp), temp)
            }
        }
        let save = TemporaryFileSweeper.hiddenTempName(for: String(repeating: "s", count: 245), marker: "shrikeedit", suffix: ".jpg.tmp")
        XCTAssertLessThanOrEqual(save.utf8.count, 255)
        XCTAssertTrue(TemporaryFileSweeper.isSaveTemp(save))
        XCTAssertTrue(TemporaryFileSweeper.hiddenTempName(for: "IMG_1.jpg", marker: "shrikerotate").hasPrefix(".IMG_1.jpg.shrikerotate."))
    }

    func testACopyOfAVeryLongNameWorks() async throws {
        let name = String(repeating: "a", count: 236) + ".jpg"            // 240 bytes
        let src = try tmp.file(name, "long", in: "src")
        let dest = try tmp.dir("dest")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let last = try await drain(ops.copy([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        XCTAssertTrue(last.failures.isEmpty, "\(last.failures)")
        XCTAssertEqual(visibleAndHidden(in: dest), [name])
        let temp = FileOps.transferTempURL(for: dest.appendingPathComponent(name)).lastPathComponent
        XCTAssertLessThanOrEqual(temp.utf8.count, 255)
        XCTAssertTrue(TemporaryFileSweeper.isCopyTemp(temp), "the sweeper still knows the short form")
    }

    func testUndoOfACrossVolumeMoveAlsoGoesThroughATemp() async throws {
        let src = try tmp.file("IMG_1.jpg", "mine", in: "src")
        let dest = try tmp.dir("dest")
        let copies = OSAllocatedUnfairLock(initialState: [String]())
        let trash = self.trash!
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil,
                          trashItem: { try trash.trash($0) },
                          copyFile: { from, to in
            copies.withLock { $0.append(to.lastPathComponent) }
            try FileManager.default.copyItem(at: from, to: to)
        }, sameVolume: { _, _ in false })
        let last = try await drain(ops.move([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)))
        _ = try await ops.undo(last.receipt)
        XCTAssertEqual(read(src), "mine")
        XCTAssertEqual(visibleAndHidden(in: dest), [])
        let names = copies.withLock { $0 }
        XCTAssertEqual(names.count, 2, "the move and its Undo both copied")
        XCTAssertTrue(names.allSatisfy { $0.hasPrefix(".IMG_1.jpg.shriketransfer.") }, "both through a hidden temp: \(names)")
    }

    // MARK: N4

    /// A replaced photo's older records must survive the next clean-up, and Undo brings its chain back clean.
    func testAReplacedPhotosChainGetsAClockAndItsOriginalSurvivesPurge() async throws {
        let backups = BackupStore(root: tmp.url.appendingPathComponent("_backups"), retentionDays: { 30 })
        let incoming = try tmp.file("x.jpg", "incoming", in: "cam")
        let dest = try tmp.dir("Selects")
        let victim = try tmp.file("x.jpg", "old victim", in: "Selects")
        let trash = self.trash!
        trash.noTrash = true
        let ops = FileOps(metadata: nil, backups: backups, watchers: nil, trashItem: { try trash.trash($0) })
        let last = try await drain(ops.copy([ImageGroup(primary: incoming)], to: dest, conflicts: .always(.replace)))
        let all = await backups.allRecords()
        XCTAssertNotNil(all.first?.detachedAt, "the clock starts when the chain is set aside")
        await backups.purge(olderThan: 0)
        let afterPurge = await backups.allRecords()
        XCTAssertEqual(afterPurge.count, 1, "inside retention: the replaced photo's record stays (kept by the clock, not by the file at the path)")

        _ = try await ops.undo(last.receipt)
        let back = await backups.records(for: victim)
        XCTAssertEqual(back.count, 1)
        XCTAssertNil(back.first?.detachedAt, "Undo clears the clock")
        XCTAssertNil(back.first?.detachedFrom)
    }

    // MARK: N6, N7

    func testTheRelaxedPathStillRefusesWhatTheFileSystemCannotTake() async throws {
        let file = try tmp.file("x.jpg", "photo", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        for bad in ["/x", "a\u{0}b", ""] {
            do { _ = try await ops.renameReporting(ImageGroup(primary: file), toStem: bad, relaxed: true); XCTFail("\(bad.debugDescription)") }
            catch { XCTAssertTrue(error is FileOpsError, "\(bad.debugDescription)") }
        }
        XCTAssertTrue(exists(file), "nothing was renamed")
        // A real earlier name that breaks the user-facing shape rules is fine (the real flow: it was on disk first).
        for (stem, name) in [(".hidden", ".hidden.jpg"), ("a ", "a .jpg"), ("Mr.", "Mr..jpg"), ("two\nlines", "two\nlines.jpg"), ("a:b", "a:b.jpg")] {
            let odd = try tmp.file(name, "photo", in: "odd")
            let moved = try await ops.rename(ImageGroup(primary: odd), toStem: "plain")
            let back = try await ops.rename(moved, backToEarlierStem: stem)
            XCTAssertEqual(back.primary.lastPathComponent, name)
            try FileManager.default.removeItem(at: back.primary)
        }
    }

    /// Typed text can never pass through `backToEarlierStem`.
    func testBackToEarlierStemRefusesANameThePhotoNeverHad() async throws {
        let file = try tmp.file("x.jpg", "photo", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        do { _ = try await ops.rename(ImageGroup(primary: file), backToEarlierStem: " typed "); XCTFail("never had it") }
        catch { XCTAssertEqual(error as? FileOpsError, .invalidName(.notAnEarlierName)) }
        XCTAssertTrue(exists(file))
        XCTAssertEqual(RenameValidation.notAnEarlierName.message, "This photo never had this name.")
    }

    func testUndoOfARenameOfAnOddNameIsNotRefusedButFreshInputStillIs() async throws {
        let file = try tmp.file("a .jpg", "photo", in: "cam")
        let other = try tmp.file("c.jpg", "other", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let renamed = try await ops.rename(ImageGroup(primary: file), toStem: "b")
        // This is what the viewer's and browser's Undo do: plain rename back to the recorded stem.
        let back = try await ops.rename(renamed, toStem: "a ")
        XCTAssertEqual(back.primary.lastPathComponent, "a .jpg")
        do { _ = try await ops.rename(ImageGroup(primary: other), toStem: "a "); XCTFail("typed input stays strict") }
        catch { XCTAssertEqual(error as? FileOpsError, .invalidName(.edgeSpace)) }
    }

    /// Two renames and two Undos: a -> b -> c, then c -> b, then b -> "a ".
    func testTwoLevelUndoOfAnOddNameIsNotRefused() async throws {
        let file = try tmp.file("a .jpg", "photo", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let b = try await ops.rename(ImageGroup(primary: file), toStem: "b")
        let c = try await ops.rename(b, toStem: "c")
        let backToB = try await ops.rename(c, toStem: "b")          // first Undo
        let backToA = try await ops.rename(backToB, toStem: "a ")    // second Undo
        XCTAssertEqual(backToA.primary.lastPathComponent, "a .jpg")
    }

    // MARK: R4

    /// A real name may contain ":" (Finder shows "/"). A strict rename away from it must be undoable.
    func testAFileWhoseRealNameContainsAColonCanBeUndone() async throws {
        let file = try tmp.file("a:b.jpg", "photo", in: "cam")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let renamed = try await ops.rename(ImageGroup(primary: file), toStem: "c")
        let back = try await ops.rename(renamed, backToEarlierStem: "a:b")
        XCTAssertEqual(back.primary.lastPathComponent, "a:b.jpg")
    }
}

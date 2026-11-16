//
//  ConflictExtraFilesTests.swift
//  ShrikeIOTests
//
//  Audit B-5 (spec 28 §17.2): the conflict alert gets M = how many of the remaining conflicts would
//  also move other same-name files away, and the receipt counts them after the run. Read-only
//  information: the transfer itself must do exactly what it did before.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class ConflictExtraFilesTests: XCTestCase {

    var tmp: IOTempDir!
    var trash: FakeTrash!
    var backups: BackupStore!

    override func setUp() async throws {
        try await super.setUp()
        tmp = IOTempDir("ConflictExtra")
        trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash", isDirectory: true))
        backups = BackupStore(root: tmp.url.appendingPathComponent("_backups", isDirectory: true),
                              retentionDays: { 30 })
    }

    override func tearDown() async throws {
        tmp.cleanup()
        try await super.tearDown()
    }

    private func makeOps() -> FileOps {
        let trash = self.trash!
        return FileOps(metadata: nil, backups: backups, watchers: nil, trashItem: { try trash.trash($0) })
    }

    /// Five single-file groups a...e. Conflicts: a, c, e. Extras at the destination: c (a sidecar
    /// `c.CR3.xmp`) and e (a RAW with another letter case, `E.CR2`); a has none.
    private func fixture(_ tag: String) throws -> (groups: [ImageGroup], dest: URL) {
        let groups = try ["a", "b", "c", "d", "e"].map {
            ImageGroup(primary: try tmp.file("\($0).jpg", "new \($0)", in: "cam\(tag)"))
        }
        let dest = try tmp.dir("dest\(tag)")
        for n in ["a.jpg", "c.jpg", "c.CR3.xmp", "e.jpg", "E.CR2", "z.jpg"] {
            try tmp.file(n, "old \(n)", in: "dest\(tag)")
        }
        return (groups, dest)
    }

    private static func listing(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func drain(_ stream: AsyncThrowingStream<FileOpProgress, any Error>) async throws -> FileOpProgress {
        var last: FileOpProgress?
        for try await p in stream { last = p }
        return try XCTUnwrap(last)
    }

    func testFirstConflictReportsRemainingAndHowManyHaveExtras() async throws {
        let (groups, dest) = try fixture("1")
        let before = Self.listing(dest)
        let seen = OSAllocatedUnfairLock<[[Int]]>(initialState: [])
        let unchanged = OSAllocatedUnfairLock(initialState: true)
        let list = Self.listing
        let last = try await drain(makeOps().move(groups, to: dest, conflicts: .ask { c in
            seen.withLock { $0.append([c.remainingConflicts, c.remainingWithExtraFiles]) }
            if list(dest) != before { unchanged.withLock { $0 = false } }
            return ConflictAnswer(.replace, applyToRemaining: true)
        }))
        XCTAssertEqual(seen.withLock { $0 }, [[2, 2]], "asked once; c and e would also move other files")
        XCTAssertTrue(unchanged.withLock { $0 }, "the look-ahead writes nothing")
        // Prediction equals what happened (a had none, c and e had one each).
        XCTAssertEqual(last.receipt.extraFilesTrashed, 2)
        XCTAssertEqual(last.receipt.items.filter { !$0.replaced.isEmpty }.count, 3)
        XCTAssertEqual(Self.listing(dest), ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "z.jpg"])
    }

    func testPerConflictAnswersSeeShrinkingNumbers() async throws {
        let (groups, dest) = try fixture("2")
        let seen = OSAllocatedUnfairLock<[[Int]]>(initialState: [])
        _ = try await drain(makeOps().copy(groups, to: dest, conflicts: .ask { c in
            seen.withLock { $0.append([c.remainingConflicts, c.remainingWithExtraFiles]) }
            return .skip
        }))
        XCTAssertEqual(seen.withLock { $0 }, [[2, 2], [1, 1], [0, 0]])
    }

    func testRunWithoutExtrasReportsZero() async throws {
        let groups = try ["a", "b", "c"].map { ImageGroup(primary: try tmp.file("\($0).jpg", "n", in: "cam")) }
        let dest = try tmp.dir("dest")
        for n in ["a.jpg", "b.jpg", "c.jpg"] { try tmp.file(n, "old", in: "dest") }
        let seen = OSAllocatedUnfairLock<[Int]>(initialState: [])
        let last = try await drain(makeOps().copy(groups, to: dest, conflicts: .ask { c in
            seen.withLock { $0.append(c.remainingWithExtraFiles) }
            return ConflictAnswer(.replace, applyToRemaining: true)
        }))
        XCTAssertEqual(seen.withLock { $0 }, [0])
        XCTAssertEqual(last.receipt.extraFilesTrashed, 0)
        XCTAssertEqual(last.receipt.items.count, 3)
    }

    func testKeepBothCountsNoExtras() async throws {
        let (groups, dest) = try fixture("3")
        let last = try await drain(makeOps().copy(groups, to: dest, conflicts: .always(.keepBoth)))
        XCTAssertEqual(last.receipt.extraFilesTrashed, 0)
    }

    /// Same inputs: `.always(.replace)` never runs the look-ahead; `.ask` + Replace-for-all does.
    /// Files, Trash, backups and receipt must match.
    func testOutcomeIsIdenticalWithAndWithoutTheLookAhead() async throws {
        let a = try fixture("A")
        let b = try fixture("B")
        let trashBefore = Self.listing(trash.folder).count
        let lastA = try await drain(makeOps().move(a.groups, to: a.dest, conflicts: .always(.replace)))
        let trashAfterA = Self.listing(trash.folder).count
        let backupsA = await backups.allRecords().count
        let lastB = try await drain(makeOps().move(
            b.groups, to: b.dest, conflicts: .ask { _ in ConflictAnswer(.replace, applyToRemaining: true) }))
        let trashAfterB = Self.listing(trash.folder).count
        let backupsB = await backups.allRecords().count - backupsA

        XCTAssertEqual(Self.listing(a.dest), Self.listing(b.dest))
        XCTAssertEqual(trashAfterA - trashBefore, trashAfterB - trashAfterA)
        XCTAssertEqual(trashAfterA - trashBefore, 5, "a, c, c.CR3.xmp, e, E.CR2")
        XCTAssertEqual(backupsA, backupsB)
        XCTAssertEqual(lastA.receipt.items.map { $0.replaced.map(\.original.lastPathComponent) },
                       lastB.receipt.items.map { $0.replaced.map(\.original.lastPathComponent) })
        XCTAssertEqual(lastA.receipt.extraFilesTrashed, lastB.receipt.extraFilesTrashed)
        XCTAssertEqual(lastA.skipped.count, lastB.skipped.count)
        XCTAssertEqual(lastA.failures.count, lastB.failures.count)
    }

    func testInitClampsTheExtrasToTheRemainingConflicts() throws {
        let g = ImageGroup(primary: tmp.url.appendingPathComponent("x.jpg"))
        let c = FileConflict(incoming: g, existing: [], destinationFolder: tmp.url,
                             remainingConflicts: 1, remainingWithExtraFiles: 5)
        XCTAssertEqual(c.remainingWithExtraFiles, 1)
        XCTAssertEqual(FileConflict(incoming: g, existing: [], destinationFolder: tmp.url,
                                    remainingConflicts: 3).remainingWithExtraFiles, 0)
    }

    /// Extras at a and e only: the first conflict (a) is not counted in its own M.
    func testExtrasCountOnlyLaterConflictsThatHaveThem() async throws {
        let groups = try ["a", "b", "c", "d", "e"].map {
            ImageGroup(primary: try tmp.file("\($0).jpg", "new", in: "cam"))
        }
        let dest = try tmp.dir("dest")
        for n in ["a.jpg", "a.CR2", "c.jpg", "e.jpg", "e.xmp"] { try tmp.file(n, "old", in: "dest") }
        let seen = OSAllocatedUnfairLock<[[Int]]>(initialState: [])
        _ = try await drain(makeOps().copy(groups, to: dest, conflicts: .ask { c in
            seen.withLock { $0.append([c.remainingConflicts, c.remainingWithExtraFiles]) }
            return .skip
        }))
        XCTAssertEqual(seen.withLock { $0 }, [[2, 1], [1, 1], [0, 0]])
    }

    /// The look-ahead runs before the first alert: 500 clashing groups into 5000 files stay fast.
    func testLookAheadIsFastOnABigDestination() async throws {
        let dest = try tmp.dir("dest")
        var groups: [ImageGroup] = []
        for i in 0..<500 {
            groups.append(ImageGroup(primary: try tmp.file("P\(i).jpg", "n", in: "cam")))
            try tmp.file("P\(i).jpg", "o", in: "dest")
        }
        for i in 0..<4500 { try tmp.file("Q\(i).jpg", "o", in: "dest") }
        let start = ContinuousClock.now
        let elapsed = OSAllocatedUnfairLock<Duration?>(initialState: nil)
        _ = try await drain(makeOps().copy(groups, to: dest, conflicts: .ask { _ in
            elapsed.withLock { if $0 == nil { $0 = ContinuousClock.now - start } }
            return .skip
        }))
        let t = try XCTUnwrap(elapsed.withLock { $0 })
        print("B5 look-ahead to first alert:", t)
        XCTAssertLessThan(t, .seconds(2))
    }
}

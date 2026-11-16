//
//  ActiveWorkRegistrationTests.swift
//  ShrikeIOTests
//
//  Audit A-1: real file work registers itself in `ActiveWork.shared`, so
//  macOS cannot end the app in the middle of it.
//

import XCTest
import os
import ShrikeCore
@testable import ShrikeIO

final class ActiveWorkRegistrationTests: XCTestCase {

    var tmp: IOTempDir!

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("ActiveWorkIO")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    func testTrashIsRegisteredWhileItRunsAndReleasedAfter() async throws {
        let file = try tmp.file("a.jpg", "x", in: "src")
        let seen = OSAllocatedUnfairLock(initialState: false)
        let trashFolder = try tmp.dir("_trash")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            seen.withLock { $0 = ActiveWork.shared.snapshot().contains(.transfer) }
            let target = trashFolder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        })
        _ = try await ops.trash([ImageGroup(primary: file)])
        XCTAssertTrue(seen.withLock { $0 }, "the trash call ran with a token open")
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }

    func testCopyStreamHoldsATokenFromCreationUntilItEnds() async throws {
        let file = try tmp.file("a.jpg", "x", in: "src")
        let dest = try tmp.dir("dest")
        let ops = FileOps(metadata: nil, backups: nil, watchers: nil)
        let stream = ops.copy([ImageGroup(primary: file)], to: dest, conflicts: .always(.skip))
        XCTAssertTrue(ActiveWork.shared.snapshot().contains(.transfer), "open before the first element")
        for try await _ in stream {}
        // The task ends its token right after the last element.
        for _ in 0..<200 where !ActiveWork.shared.snapshot().isIdle { await Task.yield() }
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }

    func testRestoreFromBackupRegistersARestoreToken() async throws {
        let file = try tmp.file("a.jpg", "v1")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let seen = OSAllocatedUnfairLock(initialState: false)
        let store = BackupStore(
            root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
            maxBytes: { 0 }, now: { Date() },
            copier: { from, to in
                if calls.withLock({ $0 += 1; return $0 }) == 2 {
                    seen.withLock { $0 = ActiveWork.shared.snapshot().contains(.restore) }
                }
                try FileManager.default.copyItem(at: from, to: to)
            })
        let record = try await store.backup(file, reason: .save)
        try Data("v2".utf8).write(to: file)
        try await store.restore(record)     // takes a safety copy (2nd copier call) inside the restore
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }
}

//
//  BackupChainFingerprintRetentionTests.swift
//  ShrikeIOTests
//
//  Review F1: deleting the newest record by retention must not hide Revert or lose the original.
//

import XCTest
import os
@testable import ShrikeIO
import ShrikeCore

final class BackupChainFingerprintRetentionTests: XCTestCase {

    var tmp: IOTempDir!
    let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() { super.setUp(); tmp = IOTempDir("BackupChainFpRetention") }
    override func tearDown() { tmp.cleanup(); super.tearDown() }

    func testRetentionOfTheNewestRecordKeepsRevertAndTheOriginal() async throws {
        let clock = self.clock
        let s = BackupStore(root: tmp.url.appendingPathComponent("Backups"), retentionDays: { 30 },
                            maxBytes: { 0 }, now: { clock.withLock { $0 } })
        let f = try tmp.file("IMG_1.jpg", "original")
        for text in ["version two", "version three is longer"] {
            try await s.backup(f, reason: .save)
            try Data(text.utf8).write(to: f)
            await s.noteWritten(f)
        }
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        await s.purge(olderThan: 0)            // the newest record goes, the original stays (file exists)
        let remaining = await s.allRecords()
        XCTAssertEqual(remaining.count, 1)
        let availability = await s.availability(for: f)
        XCTAssertTrue(availability.canRevert, "the fingerprint survived the deletion of the newest record")
        let state = await s.state(for: f)
        XCTAssertEqual(state, .edited)

        // The next save puts nothing aside and the next purge still keeps the original.
        try await s.backup(f, reason: .save)
        try Data("version four, again different".utf8).write(to: f)
        await s.noteWritten(f)
        clock.withLock { $0 = $0.addingTimeInterval(86_400) }
        await s.purge(olderThan: 0)
        let originals = await s.records(for: f)
        XCTAssertEqual(originals.count, 1)
        XCTAssertEqual(originals.first?.sequence, 0, "the first backup, the original, is still there")
    }
}

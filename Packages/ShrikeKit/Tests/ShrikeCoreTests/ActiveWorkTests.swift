//
//  ActiveWorkTests.swift
//  ShrikeCoreTests
//
//  Audit A-1: the termination switches are made once per 0 -> 1 and 1 -> 0
//  change, and the snapshot says what runs.
//

import XCTest
import os
@testable import ShrikeCore

final class ActiveWorkTests: XCTestCase {

    private func makeRegistry() -> (ActiveWork, OSAllocatedUnfairLock<(disable: Int, enable: Int)>) {
        let counts = OSAllocatedUnfairLock(initialState: (disable: 0, enable: 0))
        let work = ActiveWork(hooks: .init(
            disable: { counts.withLock { $0.disable += 1 } },
            enable: { counts.withLock { $0.enable += 1 } }))
        return (work, counts)
    }

    func testNestedTokensSwitchTerminationOffOnceAndOnOnce() {
        let (work, counts) = makeRegistry()
        let a = work.begin(kind: .transfer, detail: "3 photos")
        let b = work.begin(kind: .save, detail: "a.jpg")
        XCTAssertEqual(counts.withLock { $0 }.disable, 1)
        work.end(a)
        XCTAssertEqual(counts.withLock { $0 }.enable, 0, "one token is still open")
        work.end(b)
        XCTAssertEqual(counts.withLock { $0 }.disable, 1)
        XCTAssertEqual(counts.withLock { $0 }.enable, 1)
    }

    func testEndingATokenTwiceIsHarmless() {
        let (work, counts) = makeRegistry()
        let a = work.begin(kind: .batchRun)
        let b = work.begin(kind: .batchRun)
        work.end(a)
        work.end(a)
        XCTAssertFalse(work.snapshot().isIdle, "the second token must still count")
        XCTAssertEqual(counts.withLock { $0 }.enable, 0)
        work.end(b)
        XCTAssertEqual(counts.withLock { $0 }.enable, 1)
        XCTAssertTrue(work.snapshot().isIdle)
    }

    func testSnapshotListsKindsAndDetails() {
        let (work, _) = makeRegistry()
        let a = work.begin(kind: .transfer, detail: "Copy 3 photos")
        _ = work.begin(kind: .transfer)
        let c = work.begin(kind: .unsavedEdit, detail: "b.jpg")
        let snap = work.snapshot()
        XCTAssertEqual(snap.count(of: .transfer), 2)
        XCTAssertEqual(snap.count(of: .unsavedEdit), 1)
        XCTAssertFalse(snap.contains(.batchRun))
        XCTAssertEqual(snap.total, 3)
        XCTAssertEqual(snap.details, ["Copy 3 photos", "b.jpg"])
        work.end(a); work.end(c)
        XCTAssertEqual(work.snapshot().total, 1)
    }

    func testWithWorkEndsTheTokenWhenTheBodyThrows() {
        let (work, counts) = makeRegistry()
        struct Boom: Error {}
        XCTAssertThrowsError(try work.withWork(kind: .restore) { throw Boom() })
        XCTAssertTrue(work.snapshot().isIdle)
        XCTAssertEqual(counts.withLock { $0 }.disable, 1)
        XCTAssertEqual(counts.withLock { $0 }.enable, 1)
    }
}

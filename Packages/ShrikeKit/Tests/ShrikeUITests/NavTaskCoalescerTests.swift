//
//  NavTaskCoalescerTests.swift
//  ShrikeUITests
//
//  Regression coverage for the "rapid keypresses queue a backlog" bug.
//  Before the fix, every Space / arrow / Home / End press
//  spawned a detached Task that awaited the serial DecodeQueue actor, so a
//  burst of keystrokes drained sequentially through the actor — the first
//  press looked unresponsive while the slow decode ran, then after release
//  the viewer raced through the backlog.
//
//  These tests exercise `NavTaskCoalescer` in isolation (no NSWindow, no
//  DecodeQueue) to assert that:
//    * A second `run` call cancels the first task before it can publish.
//    * Five rapid calls leave exactly one uncancelled task.
//    * Cancelled bodies observe `Task.isCancelled` and abort cleanly.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class NavTaskCoalescerTests: XCTestCase {

    func testSingleRun_TaskCompletes() async {
        let coalescer = NavTaskCoalescer()
        let didRun = Box<Bool>(false)
        let task = coalescer.run {
            didRun.value = true
        }
        await task.value
        XCTAssertTrue(didRun.value)
        XCTAssertEqual(coalescer.replacedCount, 0)
    }

    func testSecondRun_CancelsFirst() async {
        let coalescer = NavTaskCoalescer()
        let firstCompleted = Box<Bool>(false)
        let firstObservedCancel = Box<Bool>(false)
        let secondCompleted = Box<Bool>(false)

        let firstStarted = expectation(description: "first started")
        let first = coalescer.run {
            firstStarted.fulfill()
            // Long-enough sleep that we can reliably cancel it.
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
                if Task.isCancelled {
                    firstObservedCancel.value = true
                    return
                }
            }
            firstCompleted.value = true
        }
        await fulfillment(of: [firstStarted], timeout: 1.0)

        // Replace mid-flight.
        let second = coalescer.run {
            secondCompleted.value = true
        }

        _ = await first.value
        await second.value

        XCTAssertFalse(firstCompleted.value, "first task should have been cancelled")
        XCTAssertTrue(firstObservedCancel.value, "first task should have observed cancellation")
        XCTAssertTrue(secondCompleted.value, "second task should have completed")
        XCTAssertEqual(coalescer.replacedCount, 1)
    }

    func testFiveRapidRuns_OnlyLatestWinsAndCountIsFour() async {
        // Simulate five Space presses arriving faster than the decode can
        // finish. The coalescer should replace the first four; only the
        // fifth commits its payload.
        let coalescer = NavTaskCoalescer()
        let completedIndices = Box<[Int]>([])
        var tasks: [Task<Void, Never>] = []
        for i in 0..<5 {
            let idx = i
            let task = coalescer.run {
                try? await Task.sleep(nanoseconds: 20_000_000)  // 20 ms
                if Task.isCancelled { return }
                completedIndices.value.append(idx)
            }
            tasks.append(task)
        }
        for t in tasks { await t.value }

        XCTAssertEqual(coalescer.replacedCount, 4,
                       "four earlier tasks should have been replaced")
        XCTAssertEqual(completedIndices.value, [4],
                       "only the last-scheduled body should observe completion")
    }

    func testCancel_StopsCurrent() async {
        let coalescer = NavTaskCoalescer()
        let completed = Box<Bool>(false)
        let task = coalescer.run {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100 ms
            if Task.isCancelled { return }
            completed.value = true
        }
        coalescer.cancel()
        await task.value
        XCTAssertFalse(completed.value)
    }
}

// MARK: - Helpers

/// Reference box so tests can mutate state from inside a @Sendable closure
/// without fighting Swift 6 strict concurrency. The tests are single-
/// threaded on the main actor, so unsynchronised access is fine here.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

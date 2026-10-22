//
//  PumpFreeTestRunnerTests.swift
//  ShrikeUITests
//
//  `runWithoutXCTestEventPump` exists so that no XCTest waiter (and so no
//  XCTest event pump with its method-long autorelease pool) is on the
//  stack while a window-lifetime test runs. An `async` test method fails
//  this check: every run-loop turn of its wait runs inside
//  `+[XCTWaiter _synchronouslyWaitForTimeInterval:]`.
//

import AppKit
import XCTest

@MainActor
final class PumpFreeTestRunnerTests: XCTestCase {

    @MainActor
    private final class Stacks {
        var underWaiter: [Bool] = []
    }

    /// Lets the run loop go to sleep a few times and records, for each
    /// `beforeWaiting` callout, whether an XCTest waiter is on the stack.
    private static func observeRunLoopTurns(into stacks: Stacks) async {
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0) { _, _ in
            MainActor.assumeIsolated {
                stacks.underWaiter.append(Thread.callStackSymbols.contains { $0.contains("XCTWaiter") })
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 20_000_000) }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    func testTheRunLoopTurnsWithoutAnXCTestWaiter() throws {
        let stacks = Stacks()
        try runWithoutXCTestEventPump { await Self.observeRunLoopTurns(into: stacks) }
        XCTAssertFalse(stacks.underWaiter.isEmpty, "The run loop went to sleep while the body waited")
        XCTAssertFalse(stacks.underWaiter.contains(true),
                       "No run-loop turn of the body may run inside an XCTest waiter (its event pump keeps windows alive)")
    }

    func testTheBodyRunsToItsEndAndItsErrorIsRethrown() {
        struct Marker: Error {}
        var reachedEnd = false
        XCTAssertNoThrow(try runWithoutXCTestEventPump {
            try? await Task.sleep(nanoseconds: 10_000_000)
            reachedEnd = true
        })
        XCTAssertTrue(reachedEnd)
        XCTAssertThrowsError(try runWithoutXCTestEventPump { throw Marker() }) { XCTAssertTrue($0 is Marker) }
    }
}

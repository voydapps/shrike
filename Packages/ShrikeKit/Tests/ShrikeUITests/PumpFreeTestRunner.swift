//
//  PumpFreeTestRunner.swift
//  ShrikeUITests
//
//  Runs an async test body without XCTest's waiter, for tests that
//  assert a closed window is freed.
//
//  Why: while an `async` XCTest method runs, XCTest waits for it in
//  `-[XCTWaiter _waitForExpectations:...]`, which pushes one autorelease
//  pool for the whole method. Every 0.1 s its
//  `+[XCTWaiter _synchronouslyWaitForTimeInterval:]` takes the pending
//  NSApp events (`nextEventMatchingMask:` + `sendEvent:`) outside any
//  run-loop callout, so they run in that method-long pool. `sendEvent:`
//  autoreleases the event's window (`-[NSApplication _findWindowUsingCache:]`,
//  `-[NSWindow _windowMoved:]`, ...), so a window that got a window-server
//  event stays alive until the test method returns, however long the test
//  waits for it to be freed.
//  XCTest only does this when NSApp already existed at the first wait of
//  the process. On the GitHub runner it did (the leaks dumps of the
//  2026-10-22 release gate show `_XCNSApp.applicationObject` as a root and
//  the closed viewers held only by the main thread's autorelease pool);
//  on the Mac it did not, so the release tests passed here and failed
//  there.
//
//  Here the test method is synchronous: the body runs as a main-actor task
//  and this function turns the main run loop itself, one autorelease pool
//  per turn. CFRunLoop gives every callout (main-queue jobs, observers,
//  timers) its own pool, and no XCTest waiter is on the stack, so nothing
//  outlives the window except real references. NSApp events are left in
//  the queue, as they are on the Mac.
//

import AppKit
import XCTest

@MainActor
private final class PumpFreeOutcome {
    var result: Result<Void, any Error>?
}

extension XCTestCase {

    /// Runs `body` to its end without an XCTest waiter on the stack.
    /// Call it from a synchronous test method; errors thrown by `body`
    /// are rethrown. Fails the test if `body` does not finish in
    /// `timeout` seconds.
    @MainActor
    func runWithoutXCTestEventPump(timeout: TimeInterval = 120,
                                   file: StaticString = #filePath, line: UInt = #line,
                                   _ body: @escaping @MainActor () async throws -> Void) throws {
        let outcome = PumpFreeOutcome()
        let task = Task { @MainActor in
            do { try await body(); outcome.result = .success(()) } catch { outcome.result = .failure(error) }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome.result == nil {
            if Date() > deadline {
                task.cancel()
                XCTFail("The test body did not finish in \(Int(timeout)) s", file: file, line: line)
                return
            }
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        try outcome.result?.get()
    }
}

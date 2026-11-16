//
//  CanvasDimBehaviorTests.swift
//  ShrikeUITests
//
//  Tests for `CanvasDimScheduler`, the deferred-apply bookkeeping that
//  backs the canvas dim overlay in ViewerContentView. The fix under
//  test is for a reported regression ("when I nav photos the whole window blinks"); fast
//  cached navs must never see the dim flash on.
//
//  The scheduler is a thin wrapper over `DispatchWorkItem`. We assert:
//    1. Fast path — cancel within the delay → the pending item is
//       cancelled and `onApply` never fires.
//    2. Slow path — delay elapses without a cancellation → `onApply`
//       fires exactly once.
//    3. Coalescing — two `scheduleApply()` calls in quick succession
//       produce only one pending item; the second is a no-op.
//
//  The actual NSView-level dim application (CALayer opacity + fade-out
//  animation) is exercised by manual UI + build smoke tests and is not
//  unit-testable without a real window / layer backing.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class CanvasDimBehaviorTests: XCTestCase {

    /// Resumes on the main queue after `delay` seconds. Main-queue timers run in
    /// deadline order, so anything scheduled earlier with a shorter delay has
    /// already run (or been cancelled) when this returns: no guess about speed.
    private func mainQueueSentinel(after delay: TimeInterval) async {
        await withCheckedContinuation { cont in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { cont.resume() }
        }
    }

    /// Polls until `condition` holds (up to 30 s).
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - Fast path

    /// The regression fix: when a paint lands inside the 120 ms deferral
    /// window, `cancel()` kills the pending work item and the callback
    /// never fires. This is what prevents the whole-window blink on
    /// rapid cached nav.
    func testScheduleThenCancelWithinDelay_CallbackNeverFires() async {
        let scheduler = CanvasDimScheduler(applyDelay: 0.050)
        var fireCount = 0
        scheduler.onApply = { fireCount += 1 }

        scheduler.scheduleApply()
        XCTAssertNotNil(
            scheduler.pending,
            "scheduleApply() must arm a pending work item"
        )

        // Simulate a fast paint: cancel immediately.
        scheduler.cancel()
        XCTAssertNil(
            scheduler.pending,
            "cancel() must nil the pending work item"
        )

        // A main-queue timer set later than the cancelled item's 50 ms deadline
        // has run by the time this returns; the callback must still not have fired.
        await mainQueueSentinel(after: 0.060)
        XCTAssertEqual(
            fireCount, 0,
            "onApply must not fire when cancelled within the delay window"
        )
    }

    // MARK: - Slow path

    /// When the delay elapses without a cancellation, the dim-apply
    /// callback fires exactly once. This is the "genuinely slow decode"
    /// case where the user is already perceiving the wait.
    func testScheduleWithoutCancel_CallbackFiresOnce() async {
        let scheduler = CanvasDimScheduler(applyDelay: 0.030)
        var fireCount = 0
        scheduler.onApply = { fireCount += 1 }

        scheduler.scheduleApply()

        let fired = await waitUntil { fireCount >= 1 }
        XCTAssertTrue(fired, "onApply must fire after the delay")
        await mainQueueSentinel(after: 0.040)   // a second (wrong) firing would have come by now

        XCTAssertEqual(
            fireCount, 1,
            "onApply must fire exactly once after the delay elapses"
        )
        XCTAssertNil(
            scheduler.pending,
            "pending must self-clear after the work item fires"
        )
    }

    // MARK: - Coalescing

    /// Two `scheduleApply()` calls in quick succession must produce only
    /// one pending work item. Hold-arrow nav can fire `applyCanvasDim()`
    /// many times in the span of a single frame; each must coalesce
    /// into the single outstanding deferral rather than stacking.
    func testRapidSchedule_CoalescesIntoSinglePendingItem() async {
        let scheduler = CanvasDimScheduler(applyDelay: 0.050)
        var fireCount = 0
        scheduler.onApply = { fireCount += 1 }

        scheduler.scheduleApply()
        let firstPending = scheduler.pending
        XCTAssertNotNil(firstPending)

        // Second call before the delay elapses — must be a no-op.
        scheduler.scheduleApply()
        XCTAssertTrue(
            scheduler.pending === firstPending,
            "rapid scheduleApply() must coalesce — second call must not replace the pending item"
        )

        // Let the single work item fire.
        let fired = await waitUntil { fireCount >= 1 }
        XCTAssertTrue(fired)
        await mainQueueSentinel(after: 0.060)   // a second firing would have come by now
        XCTAssertEqual(
            fireCount, 1,
            "coalesced schedules must result in exactly one callback invocation"
        )
    }

    // MARK: - Edge case: cancel with nothing pending

    /// `clearCanvasDim()` may be called with no pending apply (e.g. the
    /// user hit an error path before any nav). This must be a silent
    /// no-op — no crash, no unexpected mutation.
    func testCancelWithoutPending_IsNoOp() {
        let scheduler = CanvasDimScheduler(applyDelay: 0.050)
        scheduler.cancel()  // before any schedule
        XCTAssertNil(scheduler.pending)

        scheduler.cancel()  // again; still fine
        XCTAssertNil(scheduler.pending)
    }
}

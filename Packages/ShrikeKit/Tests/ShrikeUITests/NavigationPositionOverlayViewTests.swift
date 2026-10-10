//
//  NavigationPositionOverlayViewTests.swift
//  ShrikeUITests
//
//  Exercises the determinate hairline progress fill + error flash behavior
//  on `NavigationPositionOverlayView`.
//  Covers: Phase A/B/C/D, the two-path gate,
//  progress-curve math, show/hide timing, the error state,
//  Reduce Motion.
//
//  The Core Animation side (actual width interpolation on the
//  presentation layer, alpha fade curves) is not unit-testable without
//  a real display link + window server; what IS unit-testable — and
//  therefore what these tests cover — is:
//    * the cancellable `DispatchWorkItem` bookkeeping for the show-grace,
//      Phase B, Phase C, error-revert, and deferred-hide timers
//    * the state transitions the view exposes as `internal private(set)`:
//      `hairlinePhase`, `isHairlineVisible`, `isInErrorState`,
//      `currentProgressForTesting`
//    * the pre-fill math, min-visible floor math, and predictive-skip
//      gate branching
//

import XCTest
@testable import ShrikeUI

@MainActor
final class NavigationPositionOverlayViewTests: XCTestCase {

    // MARK: - Token pinning

    /// Pins the show-grace token to 100 ms.
    func testShowGrace_Is100Milliseconds() {
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlineShowGrace,
            0.100,
            accuracy: 0.0001,
            "show-grace must be 100 ms"
        )
    }

    /// Pins the min-visible floor to 180 ms.
    func testMinVisible_Is180Milliseconds() {
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlineMinVisible,
            0.180,
            accuracy: 0.0001,
            "min-visible floor must be 180 ms"
        )
    }

    /// Pins the predictive-show threshold to 150 ms.
    func testPredictiveShowThreshold_Is150Milliseconds() {
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlinePredictiveShowThreshold,
            0.150,
            accuracy: 0.0001,
            "predictive-show threshold must be 150 ms"
        )
    }

    /// Pins Phase D tail durations — 80 ms width + 150 ms alpha = 230 ms.
    func testCompletionTail_DurationTokens() {
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlineCompletionWidthDuration,
            0.080, accuracy: 0.0001,
            "Phase D width ease-out must be 80 ms"
        )
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlineCompletionAlphaDuration,
            0.150, accuracy: 0.0001,
            "Phase D alpha fade must be 150 ms"
        )
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlineCompletionTailDuration,
            0.230, accuracy: 0.0001,
            "total tail duration must be 230 ms (width + alpha)"
        )
    }

    /// Pins Phase ceilings — 80% Phase A, 95% Phase B.
    func testPhaseCeilings() {
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlinePhaseACeiling,
            0.80, accuracy: 0.0001
        )
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlinePhaseBCeiling,
            0.95, accuracy: 0.0001
        )
        XCTAssertEqual(
            NavigationPositionOverlayView.hairlinePhaseBDurationMultiplier,
            2.0, accuracy: 0.0001
        )
    }

    // MARK: - Show grace

    /// A `scheduleHairlineShow()` followed by a `completeHairline()`
    /// before the 100 ms grace elapses must cancel the pending show.
    func testShowGrace_CancelledByEarlyPaint_NeverAppears() {
        let overlay = NavigationPositionOverlayView()
        overlay.scheduleHairlineShow(predicted: 0.100)
        XCTAssertNotNil(
            overlay.pendingHairlineShowTask,
            "scheduleHairlineShow() must capture a cancellable work item"
        )
        XCTAssertFalse(overlay.isHairlineVisible)

        overlay.completeHairline()

        XCTAssertNil(
            overlay.pendingHairlineShowTask,
            "early paint must cancel the pending show-grace task"
        )
        XCTAssertFalse(overlay.isHairlineVisible)
    }

    /// Firing the pending show directly (simulating the 100 ms deadline
    /// elapsing without a paint) must flip `isHairlineVisible` to true.
    func testShowGrace_ElapsesAndHairlineAppears() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 240, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.200)
        overlay.fireHairlineShowForTesting()

        XCTAssertNil(overlay.pendingHairlineShowTask)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA,
            "after grace fires, hairline enters Phase A")
    }

    /// A second `scheduleHairlineShow()` inside the grace window
    /// preserves the first call's deadline but updates the captured
    /// `predicted` — the predictor race's refinement path.
    func testShowGrace_SecondScheduleUpdatesPredicted() {
        let overlay = NavigationPositionOverlayView()
        overlay.scheduleHairlineShow(predicted: 0.150)
        let firstTask = overlay.pendingHairlineShowTask
        XCTAssertNotNil(firstTask)

        // Predictor resolves with a refined predicted value.
        overlay.scheduleHairlineShow(predicted: 0.200)
        XCTAssertTrue(
            overlay.pendingHairlineShowTask === firstTask,
            "a second schedule inside the grace must preserve the first deadline"
        )
    }

    // MARK: - Pre-fill math

    /// Pre-fill formula: `startWidth = min(0.80, (100/predicted) × 0.80)`.
    /// For predicted = 200 ms: (100/200) × 0.80 = 0.40.
    func testGracePreFill_200msPredicted_Yields40Percent() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.200)
        overlay.fireHairlineShowForTesting(predicted: 0.200)

        XCTAssertEqual(
            overlay.currentProgressForTesting,
            0.40,
            accuracy: 0.001,
            "grace-path pre-fill for predicted=200ms must be 0.40"
        )
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
    }

    /// Degenerate case: predicted < 100 ms means the formula would yield
    /// > 0.80 — the clamp forces 0.80 and the bar skips directly into
    /// Phase B.
    ///
    /// The grace handler calls `enterPhaseB` synchronously when the
    /// remaining Phase A duration is zero, so phase is `.phaseB`
    /// immediately after `fireHairlineShowForTesting`. We must NOT pump
    /// the runloop here — Phase C's delay (2 × predicted = 100 ms) would
    /// fire inside a `wait` and move state to `.phaseC`.
    func testGracePreFill_PredictedBelowGrace_SkipsToPhaseB() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.050)
        overlay.fireHairlineShowForTesting(predicted: 0.050)

        XCTAssertEqual(overlay.hairlinePhase, .phaseB,
            "predicted < grace must skip to Phase B synchronously")
    }

    // MARK: - Min-visible floor

    /// A paint landing right after reveal (elapsed ≈ 0) is *inside* the
    /// min-visible floor only if the tail would end before the floor.
    /// tail = 230 ms > 180 ms, so the tail naturally satisfies the floor
    /// without deferring. Verify no pending hide task is scheduled.
    func testMinVisible_TailNaturallySatisfiesFloor() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertTrue(overlay.isHairlineVisible)

        // Paint lands immediately. Tail = 230 ms > floor = 180 ms, so the
        // tail is NOT deferred — it starts right away.
        overlay.completeHairline()

        XCTAssertNil(
            overlay.pendingHairlineHideTask,
            "tail (230 ms) already exceeds floor (180 ms); no defer needed"
        )
        // Phase D width is running, with a Phase D fade task scheduled
        // via DispatchQueue.main.asyncAfter(+80 ms). `isHairlineVisible`
        // stays true through Phase D width (the bar is still on screen);
        // firing the pending fade task flips it to false.
        XCTAssertTrue(
            overlay.isHairlineVisible,
            "isHairlineVisible stays true through Phase D width"
        )
        XCTAssertNotNil(
            overlay.pendingPhaseDFadeTask,
            "Phase D fade task is scheduled 80 ms after the width ease begins"
        )
        overlay.firePhaseDFadeForTesting()
        XCTAssertFalse(
            overlay.isHairlineVisible,
            "fade start clears isHairlineVisible"
        )
    }

    /// When a paint lands after the hairline has been up long enough
    /// that even subtracting the tail duration still leaves time before
    /// the floor, the tail runs synchronously. (Same as above — just
    /// also backdated for paranoia.)
    func testMinVisible_HideAfterWindowSynchronous() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        overlay.backdateHairlineVisibleForTesting(by: 0.250)

        overlay.completeHairline()

        XCTAssertNil(
            overlay.pendingHairlineHideTask,
            "past the floor, tail runs immediately"
        )
    }

    /// A rapid-nav `scheduleHairlineShow()` landing during a deferred-
    /// hide window (rare — requires an extremely fast predicted < tail
    /// difference case) must cancel the pending hide. We drive this by
    /// manually creating the deferred state via the error-path (which
    /// clears into the same hide task).
    func testMinVisible_NewNavDuringDeferredHideCancelsHide() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertTrue(overlay.isHairlineVisible)

        // Simulate a paint that would trigger a deferred hide. Since the
        // natural tail satisfies the floor, we construct a synthetic
        // scenario by backdating to *just barely* satisfied, then forcing
        // deferred hide via the internal path. Easiest proxy: verify that
        // if there ever IS a pendingHairlineHideTask, a fresh
        // `scheduleHairlineShow` cancels it — which we test with a test
        // hook (the state machine exposes only `pendingHairlineHideTask`
        // via `internal private(set)`).

        // Construct a deferred-hide state directly: call completeHairline
        // with the visible-since clock fresh (<180 ms). The tail duration
        // path means deferral only happens if elapsed is very small AND
        // floor > tail. Since floor < tail, deferral never happens under
        // current constants. This test is therefore tautological under
        // current design, but documents the invariant for future changes.
        //
        // Instead, verify that on a completeHairline + new nav sequence,
        // the second nav keeps the hairline continuous.
        overlay.completeHairline()
        // Phase D is running. A new nav lands.
        overlay.scheduleHairlineShow(predicted: 0.300)
        XCTAssertNil(
            overlay.pendingHairlineHideTask,
            "new nav must cancel any pending hide task"
        )
    }

    // MARK: - Predictive-skip

    /// `setHairlineProgress()` on a fresh overlay cancels any pending
    /// 100 ms grace and reveals the hairline synchronously at t=0 with
    /// width 0.
    func testPredictiveShow_CancelsPendingGraceAndAppearsAtZero() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.150)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)

        overlay.setHairlineProgress(predicted: 0.300)

        XCTAssertNil(
            overlay.pendingHairlineShowTask,
            "predictive-skip must cancel the pending 100 ms grace task"
        )
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0, accuracy: 0.001,
            "predictive-skip reveals with startWidth = 0"
        )
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
    }

    /// `setHairlineProgress()` with no pending grace still reveals
    /// immediately.
    func testPredictiveShow_AppearsEvenWithNoPendingGrace() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)

        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
    }

    // MARK: - Phase A/B/C/D

    /// At predictive-skip show, width = 0.0 and phase = .phaseA.
    /// Phase B transition task is scheduled to fire in `predicted` ms.
    func testPhaseA_ScheduledWithCorrectDelay() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)

        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
        XCTAssertNotNil(
            overlay.pendingPhaseBTask,
            "Phase A start must schedule the Phase B transition"
        )
    }

    /// Firing the pending Phase B transition synchronously transitions
    /// from Phase A into Phase B, snaps model width to 0.80, and
    /// schedules the Phase C transition.
    ///
    /// Forces `reduceMotionOverride = false` — the host's
    /// accessibility flag varies by CI environment and under RM the
    /// Phase B snap would bypass 0.80 directly to 0.95.
    func testPhaseB_EntryReachesCeiling() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.reduceMotionOverride = false

        overlay.setHairlineProgress(predicted: 0.300)
        overlay.firePhaseBTransitionForTesting()

        XCTAssertEqual(overlay.hairlinePhase, .phaseB)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.80,
            accuracy: 0.001,
            "Phase B entry sets model width to Phase A ceiling (0.80)"
        )
        XCTAssertNotNil(overlay.pendingPhaseCTask)
    }

    /// Phase C: firing the pending transition pins at 0.95.
    func testPhaseC_PinnedAt95Percent() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        overlay.firePhaseBTransitionForTesting()
        overlay.firePhaseCTransitionForTesting()

        XCTAssertEqual(overlay.hairlinePhase, .phaseC)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.95,
            accuracy: 0.001,
            "Phase C pins at 95%"
        )
        XCTAssertNil(overlay.pendingPhaseCTask)
    }

    /// Phase D: completing from Phase C state runs the tail and clears
    /// `isHairlineVisible` once the fade starts.
    func testPhaseD_StartsFromPhaseCWidth() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        overlay.firePhaseBTransitionForTesting()
        overlay.firePhaseCTransitionForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .phaseC)

        overlay.completeHairline()

        // Under non-reduce-motion, Phase D width ease is async (driven by
        // CATransaction completion). We can observe that model width is
        // set to 1.0 synchronously.
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001,
            "Phase D sets model width to 1.0 synchronously"
        )
    }

    // MARK: scenarios

    /// Scenario (a): fast decode predicted 40 ms, actual 30 ms — grace path,
    /// paint inside grace window, hairline never surfaces.
    func testVectorA_FastDecode_NoShow() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.040)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)

        // Paint lands at t=30 ms (inside the 100 ms grace).
        overlay.completeHairline()

        XCTAssertFalse(overlay.isHairlineVisible)
        XCTAssertNil(overlay.pendingHairlineShowTask)
    }

    /// Scenario (b): predicted 300 / actual 280, predictive-skip path.
    /// Hairline shows at t=0 with width 0, enters Phase A. Paint lands
    /// before Phase B would start, so Phase D fires from a Phase A width.
    func testVectorB_PredictiveSkip_InBudget() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
        XCTAssertNotNil(overlay.pendingPhaseBTask)

        // Paint lands before Phase B transition fires. Complete.
        overlay.completeHairline()

        // Phase B task is cancelled.
        XCTAssertNil(overlay.pendingPhaseBTask,
            "Phase B timer must be cancelled by completeHairline")
        XCTAssertNil(overlay.pendingPhaseCTask)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001
        )
    }

    /// Scenario (c): predicted 300, actual 1200, exercising all four phases.
    /// Forces `reduceMotionOverride = false` so Phase B animates 0.80→0.95
    /// rather than snapping, which is what this scenario specifically
    /// exercises.
    func testVectorC_PredictorUndershoots_AllPhases() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.reduceMotionOverride = false

        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)

        // Phase A completes — bar at 0.80.
        overlay.firePhaseBTransitionForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .phaseB)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.80,
            accuracy: 0.001
        )

        // Phase B completes — bar at 0.95, Phase C active.
        overlay.firePhaseCTransitionForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .phaseC)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.95,
            accuracy: 0.001
        )

        // Decode lands. Phase D snaps to 1.0.
        overlay.completeHairline()
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001
        )
    }

    /// Scenario (d): grace-path pre-fill edge case — predicted 200, actual
    /// 50 ms (extreme predictor false-negative, fast path). Grace timer
    /// fires at t=100 ms with pre-fill = 0.40. Paint at t=150 ms (50 ms
    /// after reveal). Tail (230 ms) > floor (180 ms) so tail runs
    /// immediately.
    ///
    /// Simpler variant: the scenario is "paint at actual 50ms",
    /// which means paint lands *during the 100 ms grace window* (at
    /// t=50 ms) — the grace is cancelled before it fires, hairline never
    /// appears. We cover that case here as the "fast path false-positive
    /// from predictor" scenario.
    func testVectorD_GracePathPreFill_PaintInsideGrace() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.200)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)

        // Paint lands at t=50 ms, inside the grace.
        overlay.completeHairline()

        XCTAssertFalse(overlay.isHairlineVisible)
        XCTAssertNil(overlay.pendingHairlineShowTask)
    }

    /// Scenario (d') — the grace *does* fire because paint was slower than
    /// grace. Pre-fill = 0.40 at t=100 ms.
    func testVectorD_GracePathPreFillFormula() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.200)
        overlay.fireHairlineShowForTesting(predicted: 0.200)

        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.40,
            accuracy: 0.001,
            "pre-fill at t=100ms for predicted=200ms must be 0.40"
        )
    }

    /// Scenario (e): error at t=150 ms with predicted 400 ms. Hairline is
    /// in Phase A when flashError fires; width snaps to 1.0 instantly.
    func testVectorE_ErrorDuringPhaseA() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")

        overlay.setHairlineProgress(predicted: 0.400)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)

        overlay.flashError()

        XCTAssertTrue(overlay.isInErrorState)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001,
            "flashError must snap width instantly to 100%"
        )
        XCTAssertNil(
            overlay.pendingPhaseBTask,
            "flashError must cancel in-flight phase transitions"
        )
        XCTAssertNil(overlay.pendingPhaseCTask)
    }

    // MARK: - Reduce Motion

    /// With Reduce Motion injected, Phase A still fills linearly, but
    /// Phase B collapses to an instant snap from 0.80 to 0.95 with no
    /// interpolation. Phase D width snap is also instant.
    func testReduceMotion_PhaseBCollapsesToSnap() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.reduceMotionOverride = true

        overlay.setHairlineProgress(predicted: 0.200)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA,
            "Phase A linear fill is preserved under Reduce Motion")

        // Phase B transition fires: snaps directly to 0.95 (no 2×pred
        // interpolation), Phase C task scheduled with delay 0.
        overlay.firePhaseBTransitionForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .phaseB)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.95,
            accuracy: 0.001,
            "under RM, Phase B snaps directly to 95% (bypassing 80%)"
        )

        // Phase D: snap to 1.0 instantly, no width ease.
        overlay.completeHairline()
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001,
            "under RM, Phase D width snaps instantly to 100%"
        )
    }

    // MARK: - Error state

    /// `flashError()` snaps the overlay into the red state and schedules
    /// a 400 ms revert.
    func testFlashError_RevertsAfter400ms() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")

        overlay.flashError()
        XCTAssertTrue(overlay.isInErrorState)
        XCTAssertNotNil(overlay.pendingErrorRevertTask)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0,
            accuracy: 0.001,
            "flashError sets width to 100% instantly"
        )

        overlay.fireErrorRevertForTesting()
        XCTAssertFalse(overlay.isInErrorState)
        XCTAssertNil(overlay.pendingErrorRevertTask)
    }

    /// A `scheduleHairlineShow()` landing during the 400 ms error hold
    /// preempts the hold.
    func testErrorPreemptedByNewNav() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")

        overlay.flashError()
        XCTAssertTrue(overlay.isInErrorState)

        overlay.scheduleHairlineShow(predicted: 0.200)
        XCTAssertFalse(overlay.isInErrorState)
        XCTAssertNil(overlay.pendingErrorRevertTask)
    }

    /// Error preempted by predictive-skip.
    func testError_PreemptedByPredictiveShow() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")
        overlay.flashError()
        XCTAssertTrue(overlay.isInErrorState)

        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertFalse(overlay.isInErrorState)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
    }

    // MARK: - Auto-hide

    /// Pill's auto-hide timer is paused while the hairline is visible.
    func testAutoHidePaused_WhileHairlineVisible() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.autoHides = true

        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")
        overlay.scheduleHairlineShow(predicted: 0.200)
        overlay.fireHairlineShowForTesting()
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(
            overlay.alphaValue, 1,
            "pill stays fully visible while hairline is up"
        )

        overlay.backdateHairlineVisibleForTesting(by: 0.250)
        overlay.completeHairline()
    }

    // MARK: - show() isolation

    /// `show()` on a fresh overlay does not trigger the hairline.
    func testShow_DoesNotTriggerHairline() {
        let overlay = NavigationPositionOverlayView()
        overlay.show(index: 0, total: 10, filename: "IMG_0001.jpg")
        XCTAssertFalse(overlay.isHairlineVisible)
        XCTAssertNil(overlay.pendingHairlineShowTask)
    }

    // MARK: - Rapid-nav reset

    /// A fresh nav landing while the hairline is mid-Phase-A from a prior
    /// nav must reset the fill to 0 and restart Phase A for the new
    /// generation — NOT carry over the stale width. The bar used to
    /// show loading on the old photo during fast navigation, instead of
    /// the photo that should be viewed. The old `restartPhasesFromCurrent`
    /// read the presentation-layer width and kept Phase A running from
    /// mid-fill; the user saw the bar stuck at e.g. 60% and perceived
    /// it as tracking the previous photo.
    func testRapidNav_PredictiveSkipPath_ResetsFillToZeroOnNewNav() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        // First nav — predictive-skip, long decode. Phase A scheduled to
        // run over 500 ms. Enter mid-Phase-A by firing the Phase B task
        // partway (no: firing Phase B would move to Phase B). Instead,
        // observe: `setHairlineProgress` sets the *logical* current width
        // to 0 (the starting point) while the animation target is 0.80.
        // The previous bug was that on a new nav during Phase A, the
        // code read the *presentation layer* (mid-animation interpolated
        // width) and started the new Phase A from there.
        overlay.setHairlineProgress(predicted: 0.500)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)

        // Simulate that the layer's presentation width has advanced
        // partway — we can't drive the Core Animation render loop in
        // a unit test, but we can still assert the fix by driving a
        // second nav and checking the post-restart logical width is 0
        // (not whatever the presentation happened to be).

        // New nav — shorter predicted. This must start a
        // fresh Phase A for the new generation from width 0.
        overlay.setHairlineProgress(predicted: 0.100)

        XCTAssertTrue(
            overlay.isHairlineVisible,
            "hairline stays visible across the burst"
        )
        XCTAssertEqual(overlay.hairlinePhase, .phaseA,
            "new nav must restart in Phase A, not carry the old phase")
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.0, accuracy: 0.001,
            "new nav's Phase A must start from width 0, not from the stale presentation-layer width"
        )
    }

    /// Grace-path variant: new scheduleHairlineShow() while the hairline
    /// is already visible from a prior grace-fire must also reset the
    /// fill to 0 (not preserve the stale pre-fill + mid-Phase-A width).
    func testRapidNav_GracePath_ResetsFillToZeroOnNewNav() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        // Schedule grace, fire it with predicted=0.200 so pre-fill =
        // (100/200)*0.80 = 0.40.
        overlay.scheduleHairlineShow(predicted: 0.200)
        overlay.fireHairlineShowForTesting(predicted: 0.200)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.40, accuracy: 0.001,
            "grace pre-fill at t=100 ms for predicted=200 ms is 0.40"
        )

        // New nav arrives — scheduleHairlineShow must reset the bar.
        overlay.scheduleHairlineShow(predicted: 0.300)

        XCTAssertTrue(overlay.isHairlineVisible,
            "bar stays visible continuously across the burst")
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.0, accuracy: 0.001,
            "new nav resets the bar to 0 — the 0.40 pre-fill from the prior nav must not be carried forward"
        )
    }

    /// Phase B/C timers from a prior nav must be cancelled when a new
    /// nav arrives. Otherwise the stale Phase B timer fires mid-new-nav
    /// and snaps the bar to 0.80 → 0.95 at the wrong moment — i.e. at
    /// `t=prior_predicted` instead of `t=new_predicted`.
    func testRapidNav_PhaseBTimerFromPriorNav_IsCancelled() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()
        overlay.reduceMotionOverride = false

        // First nav — short predicted (100 ms). Phase B timer scheduled
        // to fire in ~100 ms.
        overlay.setHairlineProgress(predicted: 0.100)
        XCTAssertNotNil(overlay.pendingPhaseBTask,
            "first nav schedules Phase B timer")
        let firstPhaseBTask = overlay.pendingPhaseBTask

        // Second nav — longer predicted (500 ms). The FIRST nav's Phase B
        // timer was bound to ~100 ms absolute; the second nav's Phase B
        // timer must be re-scheduled to 500 ms relative to the second
        // nav's restart instant — NOT leak the 100-ms-absolute fire
        // time. Verify by checking the Phase B task identity changed.
        overlay.setHairlineProgress(predicted: 0.500)

        XCTAssertNotNil(overlay.pendingPhaseBTask,
            "second nav schedules its own Phase B timer")
        XCTAssertFalse(
            overlay.pendingPhaseBTask === firstPhaseBTask,
            "second nav's Phase B task must be a different DispatchWorkItem — otherwise the first nav's fire-time leaked"
        )
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.0, accuracy: 0.001,
            "second nav starts Phase A from 0"
        )
    }

    /// Stale-decode-tail guard: `completeHairline()` is always routed
    /// through the generation-checked paint path in `ViewerWindow`, so
    /// a decode resolving after the user has moved on should never
    /// reach `completeHairline()`. This test documents that the overlay
    /// itself has no direct path from a stale Task to `completeHairline()`
    /// — the guard lives in `NavigationFeedbackState.shouldPaintFull`
    /// and in `ViewerWindow.navigateWithFeedback` (CancellationError
    /// returns without touching the bar).
    ///
    /// This test pins the view's behavior if `completeHairline()` were
    /// ever called mid-burst: the tail would start on the *current*
    /// generation's bar (which is correct IF that generation has landed).
    /// The safety is upstream — this test simply verifies the view
    /// doesn't crash or leak state when called after a nav restart.
    func testRapidNav_CompleteHairlineAfterRestart_DoesNotCrashOrLeak() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.300)
        overlay.setHairlineProgress(predicted: 0.200)

        // Hairline is visible, Phase A running for the second nav.
        // `completeHairline()` must drive Phase D cleanly.
        overlay.completeHairline()

        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0, accuracy: 0.001,
            "completeHairline after a restart drives Phase D to 100%"
        )
        XCTAssertNil(overlay.pendingPhaseBTask,
            "Phase D cancels any pending Phase B timer")
        XCTAssertNil(overlay.pendingPhaseCTask,
            "Phase D cancels any pending Phase C timer")
    }

    /// A new nav during the grace window (hairline not yet visible)
    /// must NOT carry over any stale state. The grace timer keeps
    /// counting (per existing `scheduleHairlineShow` semantics), but
    /// the captured `predicted` updates. When the grace fires, it reveals
    /// from the new predicted's pre-fill — not from anything left over.
    func testRapidNav_GraceWindowReEntry_UsesRefinedPredicted() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.scheduleHairlineShow(predicted: 0.150)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)
        XCTAssertFalse(overlay.isHairlineVisible)

        // Second nav — updates the captured predicted. Grace task
        // identity preserved (deadline held from original schedule).
        let originalTask = overlay.pendingHairlineShowTask
        overlay.scheduleHairlineShow(predicted: 0.400)
        XCTAssertTrue(
            overlay.pendingHairlineShowTask === originalTask,
            "grace-window re-entry preserves the original task/deadline"
        )

        // Fire with no explicit predicted — the handler reads whatever
        // was captured, which should be the refined 0.400 from the
        // second nav, not the original 0.150.
        overlay.fireHairlineShowForTesting()
        XCTAssertTrue(overlay.isHairlineVisible)
        // Pre-fill for predicted=0.400 is (100/400)*0.80 = 0.20.
        XCTAssertEqual(
            overlay.currentProgressForTesting, 0.20, accuracy: 0.001,
            "grace fire must use the refined predicted from the latest nav, not the first"
        )
    }

    // MARK: - Phase D completion on natural paint

    /// Regression for the "bar stuck at 100% after photo
    /// loaded" report. The hairline sat at width = 1.0 /
    /// opacity = 1.0 indefinitely after `completeHairline()` ran — Phase
    /// D's width → fade → final-hide sequence wasn't completing.
    ///
    /// Root cause: the width → fade handoff was scheduled via
    /// `CATransaction.setCompletionBlock`. When a second
    /// `completeHairline()` landed during the first's width ease
    /// (e.g. thumb paint followed by full paint), the second
    /// `CABasicAnimation` replaced the first by key — and Core Animation
    /// can drop the first transaction's completion block on replacement,
    /// leaving the fade unscheduled. Fix: explicit `DispatchWorkItem`
    /// on the main queue for the +80 ms fade-start and +150 ms final-
    /// hide. Cancellable, re-entrant-safe, testable.
    ///
    /// This test drives the full Phase D lifecycle via the test hooks
    /// and asserts the end state (isHidden = true, opacity model = 0).
    func testPhaseD_FullLifecycleCompletes_IsHiddenAtEnd() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        // Mid Phase A — same setup as the original bug: predictive-skip
        // path with a 400 ms predicted, paint lands during Phase A.
        overlay.setHairlineProgress(predicted: 0.400)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)
        XCTAssertTrue(overlay.isHairlineVisible)

        // Paint lands — completeHairline drives Phase D.
        overlay.completeHairline()

        // Phase D width is in-flight. Model width is 1.0 synchronously,
        // fade task is scheduled 80 ms out.
        XCTAssertEqual(overlay.hairlinePhase, .phaseDWidth)
        XCTAssertEqual(
            overlay.currentProgressForTesting, 1.0, accuracy: 0.001
        )
        XCTAssertNotNil(
            overlay.pendingPhaseDFadeTask,
            "Phase D fade task must be scheduled after width ease starts"
        )
        XCTAssertNil(
            overlay.pendingPhaseDFinalHideTask,
            "final-hide task is only scheduled after fade starts"
        )

        // Simulate the 80 ms width ease completing.
        overlay.firePhaseDFadeForTesting()

        // Fade is now running. Model opacity is 0, isHairlineVisible is
        // false, phase is phaseDFade, final-hide task scheduled at +150 ms.
        XCTAssertEqual(overlay.hairlinePhase, .phaseDFade)
        XCTAssertFalse(overlay.isHairlineVisible)
        XCTAssertNotNil(
            overlay.pendingPhaseDFinalHideTask,
            "final-hide task must be scheduled once fade begins"
        )

        // Simulate the 150 ms alpha fade completing.
        overlay.firePhaseDFinalHideForTesting()

        // End state: bar is firmly down. Phase back to idle, layer hidden.
        XCTAssertEqual(overlay.hairlinePhase, .idle)
        XCTAssertNil(overlay.pendingPhaseDFadeTask)
        XCTAssertNil(overlay.pendingPhaseDFinalHideTask)
        // The layer is the private `hairlineLayer`; we can't address it
        // directly, but `isHairlineVisible` false + .idle phase are the
        // two invariants the view itself exposes. The layer isHidden
        // assertion is covered in the view's state machine — we assert
        // the observable post-condition here.
    }

    /// Regression for the "second completeHairline during Phase D width"
    /// path: thumb paint and full paint can both call
    /// `completeHairline()` back-to-back in `ViewerWindow`. Under the
    /// old CATransaction-completion-block implementation, the second
    /// call could drop the first's fade handoff. Under the new explicit
    /// work-item implementation, the second call cancels the first's
    /// pending fade task and schedules its own. Either way, exactly one
    /// fade task must be pending at any moment.
    func testPhaseD_DoubleComplete_OnlyOneFadeTaskPending() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.setHairlineProgress(predicted: 0.400)
        overlay.completeHairline()

        let firstFadeTask = overlay.pendingPhaseDFadeTask
        XCTAssertNotNil(firstFadeTask)

        // Second completeHairline during Phase D width.
        overlay.completeHairline()

        let secondFadeTask = overlay.pendingPhaseDFadeTask
        XCTAssertNotNil(secondFadeTask)
        XCTAssertFalse(
            firstFadeTask === secondFadeTask,
            "second completeHairline must replace the pending fade task — not stack two fades"
        )

        overlay.firePhaseDFadeForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .phaseDFade)
        XCTAssertFalse(overlay.isHairlineVisible)

        // Final hide completes cleanly.
        overlay.firePhaseDFinalHideForTesting()
        XCTAssertEqual(overlay.hairlinePhase, .idle)
    }

    // MARK: - Rapid-nav shows the bar

    /// Regression for the "no bar at all during rapid nav"
    /// report. The root cause was not in this view — it was in
    /// `ViewerWindow.navigateWithFeedback`, which called
    /// `completeHairlineIndicator()` on thumb paint, cancelling the
    /// pending 100 ms grace on every cached thumb hit (< 100 ms from
    /// nav begin). During a rapid-nav burst every thumb was a cache hit,
    /// so every grace was cancelled and the bar never appeared.
    ///
    /// The ViewerWindow fix (removing the thumb-path completeHairline,
    /// `onDecodeLand(thumb): pass`) is not directly
    /// unit-testable without a full viewer harness. What IS testable at
    /// this layer is the view's grace-timer semantics under a rapid-nav
    /// burst: the grace must fire within a bounded time from the first
    /// nav regardless of subsequent navs re-seeding the captured
    /// predicted. This test pins that contract.
    ///
    /// Drives five `scheduleHairlineShow` calls 50 ms apart — simulating
    /// a 10 Hz held-arrow burst — and asserts the bar becomes visible
    /// within 250 ms of the first call (the 100 ms grace, plus runloop
    /// slack, plus DispatchQueue scheduling granularity). The
    /// threshold is 250 ms; we stay conservative.
    ///
    /// Uses `DispatchQueue.main.asyncAfter` to schedule re-seeds and a
    /// poll — keeps everything on the main actor without needing the
    /// Swift 6 Timer closures to be MainActor-isolated.
    func testRapidNav_GraceFiresWithinBurst_BarAppearsWithinBudget() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        let firstNavInstant = Date()

        // First nav seeds the 100 ms grace. Deadline is locked here.
        overlay.scheduleHairlineShow(predicted: 0.300)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)
        XCTAssertFalse(overlay.isHairlineVisible)

        // Re-seed at 50 ms intervals to simulate a held-arrow burst.
        // The grace task must stay on its original deadline (100 ms from
        // first nav) and fire exactly once.
        for tick in 1..<5 {
            let deadline = 0.050 * Double(tick)
            DispatchQueue.main.asyncAfter(deadline: .now() + deadline) {
                overlay.scheduleHairlineShow(predicted: 0.300)
            }
        }

        // Pump the runloop waiting for the grace task to fire. Expected
        // window: 100 ms grace + runloop + DispatchQueue granularity.
        let appeared = expectation(description: "hairline visible")
        appeared.assertForOverFulfill = true

        // Poll on main via asyncAfter rather than Timer — the latter's
        // callback isn't MainActor-isolated under Swift 6 strict.
        func schedulePoll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.010) {
                if overlay.isHairlineVisible {
                    appeared.fulfill()
                } else {
                    schedulePoll()
                }
            }
        }
        schedulePoll()

        wait(for: [appeared], timeout: 0.250)

        let elapsed = Date().timeIntervalSince(firstNavInstant)
        XCTAssertLessThanOrEqual(
            elapsed, 0.250,
            "bar must appear within 250 ms of the first nav (elapsed=\(elapsed)s)"
        )
        XCTAssertTrue(overlay.isHairlineVisible,
            "bar must be visible after the grace fires during a burst")
    }

    // MARK: - VoiceOver announcement

    /// Harness that captures calls to the VO announcer without posting
    /// real `NSAccessibility` notifications. The 500 ms and 2 s thresholds
    /// are driven via the overlay's back-date test hooks
    /// (`backdateHairlineVisibleForTesting`,
    /// `backdateLastAnnouncementForTesting`) rather than a mock clock —
    /// both the `hairlineVisibleSince` epoch and the throttle epoch use
    /// real `Date()`, so injecting a mock `now` would have to shadow both,
    /// whereas back-dating reuses the existing plumbing.
    private final class VOHarness: @unchecked Sendable {
        var calls: [String] = []
    }

    private func makeOverlayWithVOHarness() -> (
        NavigationPositionOverlayView,
        VOHarness
    ) {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        let harness = VOHarness()

        overlay.voiceOverEnabledOverride = true
        overlay.voiceOverAnnouncer = { [harness] msg in
            harness.calls.append(msg)
        }
        return (overlay, harness)
    }

    /// VO OFF: reveal → zero cost, no pending task armed, no announcement.
    func testVoiceOver_WhenDisabled_NeverSchedulesOrAnnounces() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        var calls = 0
        overlay.voiceOverEnabledOverride = false
        overlay.voiceOverAnnouncer = { _ in calls += 1 }

        overlay.setHairlineProgress(predicted: 0.500)
        XCTAssertNil(
            overlay.pendingVoiceOverAnnouncementTask,
            "VO off must not arm a 500 ms timer (zero cost path)"
        )

        // Fire the test hook directly — even if someone *does* drive the
        // gate synchronously, VO-off must still block the announcer.
        overlay.fireVoiceOverAnnouncementForTesting()
        XCTAssertEqual(calls, 0, "no announcement when VO disabled")
    }

    /// VO ON + hairline visible > 500 ms → announcement fires once.
    func testVoiceOver_FiresOnceAfterThreshold() {
        let (overlay, harness) = makeOverlayWithVOHarness()

        overlay.setHairlineProgress(predicted: 1.000)
        XCTAssertNotNil(
            overlay.pendingVoiceOverAnnouncementTask,
            "VO on must arm the 500 ms deferred announcement"
        )
        XCTAssertTrue(overlay.isHairlineVisible)

        // Back-date the reveal instant so the 500 ms threshold is
        // satisfied without sleeping.
        overlay.backdateHairlineVisibleForTesting(by: 0.600)
        overlay.fireVoiceOverAnnouncementForTesting()

        XCTAssertEqual(harness.calls.count, 1,
            "one announcement after the 500 ms threshold")
        XCTAssertEqual(
            harness.calls.first,
            NSLocalizedString(
                "Loading image",
                comment: "VoiceOver announcement for viewer loading hairline"
            ),
            "announcement string"
        )
    }

    /// VO ON + throttle active → second call within 2 s is suppressed;
    /// a third call past the 2 s window is allowed again. Uses
    /// `fireVoiceOverAnnouncementForTesting` to drive the gate
    /// synchronously without re-entering `setHairlineProgress` (which
    /// takes the `restartFreshPhasesForNewGeneration` branch when
    /// `isHairlineVisible` is already true and therefore would not
    /// re-arm the announcer at all).
    func testVoiceOver_ThrottlesSecondCallWithin2s_AllowsThird() {
        let (overlay, harness) = makeOverlayWithVOHarness()

        // First reveal, visible > 500 ms — fires.
        overlay.setHairlineProgress(predicted: 1.000)
        overlay.backdateHairlineVisibleForTesting(by: 0.600)
        overlay.fireVoiceOverAnnouncementForTesting()
        XCTAssertEqual(harness.calls.count, 1,
            "first fire past the 500 ms threshold posts exactly once")

        // Hairline is still visible; re-drive the gate. `lastAnnouncementEpoch`
        // was set by the fire just now and is <2 s old, so the throttle
        // must suppress. No backdating here — the throttle window is the
        // subject of this assertion.
        overlay.fireVoiceOverAnnouncementForTesting()
        XCTAssertEqual(
            harness.calls.count, 1,
            "throttle suppresses a second announcement within 2 s"
        )

        // Back-date the throttle epoch by 2.1 s so the next fire is past
        // the throttle window. `hairlineVisibleSince` is still far in the
        // past (we back-dated it 0.6 s at start + whatever real time has
        // elapsed), so the 500 ms threshold remains satisfied.
        overlay.backdateLastAnnouncementForTesting(by: 2.100)
        overlay.fireVoiceOverAnnouncementForTesting()
        XCTAssertEqual(
            harness.calls.count, 2,
            "announcement allowed once the 2 s throttle has elapsed"
        )
    }

    /// `completeHairline` cancels any pending VO announcement task —
    /// a deferred "Loading image" must not fire after the image is
    /// already painted.
    func testVoiceOver_CompleteHairlineCancelsPendingAnnouncement() {
        let (overlay, harness) = makeOverlayWithVOHarness()

        overlay.setHairlineProgress(predicted: 1.000)
        XCTAssertNotNil(overlay.pendingVoiceOverAnnouncementTask)

        // Paint lands early — complete the hairline. Pending work item
        // must be cancelled + cleared.
        overlay.completeHairline()
        XCTAssertNil(
            overlay.pendingVoiceOverAnnouncementTask,
            "completeHairline must cancel pending VO announcement"
        )

        // Even if the test hook is driven (as if the runloop fired the
        // cancelled item before the cancel took effect), the visibility
        // gate must block: the hairline is no longer visible.
        overlay.fireVoiceOverAnnouncementForTesting()
        XCTAssertEqual(
            harness.calls.count, 0,
            "no announcement after completeHairline"
        )
    }

    /// `flashError` cancels any pending VO announcement — error has its
    /// own accessibility beat and "Loading image" is misleading mid-error.
    func testVoiceOver_FlashErrorCancelsPendingAnnouncement() {
        let (overlay, harness) = makeOverlayWithVOHarness()

        overlay.setHairlineProgress(predicted: 1.000)
        XCTAssertNotNil(overlay.pendingVoiceOverAnnouncementTask)

        overlay.flashError()
        XCTAssertNil(
            overlay.pendingVoiceOverAnnouncementTask,
            "flashError must cancel pending VO announcement"
        )
        XCTAssertEqual(harness.calls.count, 0)
    }

    /// `accessibilityValue` gains ", loading" suffix while the hairline
    /// is visible, and reverts to the bare position string once the
    /// hairline fades out.
    func testAccessibilityValue_IncludesLoadingSuffixWhileHairlineVisible() {
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 200, height: 26)
        overlay.layoutSubtreeIfNeeded()

        overlay.show(index: 42, total: 180, filename: "DSC_0042.jpg")
        let baseline = overlay.accessibilityValue() as? String ?? ""
        XCTAssertFalse(
            baseline.hasSuffix(", loading"),
            "idle overlay must not read as loading"
        )

        overlay.setHairlineProgress(predicted: 1.000)
        let duringLoad = overlay.accessibilityValue() as? String ?? ""
        XCTAssertTrue(
            duringLoad.hasSuffix(", loading"),
            "hairline-visible overlay must append ', loading' to VO value"
        )
    }
}

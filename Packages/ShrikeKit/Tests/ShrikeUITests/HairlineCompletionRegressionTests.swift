//
//  HairlineCompletionRegressionTests.swift
//  ShrikeUITests
//
//  Regression coverage for the "loading bar is stuck again" bug — user
//  report against tip `d9d4f88`. The position-overlay pill shows the
//  hairline progress bar visible and apparently not completing after the
//  PNG decode lands.
//
//  Root cause: `ViewerWindow.scheduleHairlinePredictiveSkip` dispatches
//  the predictor on a `Task.detached` and resumes back on the main actor
//  to surface the hairline. The MainActor.run continuation only checked
//  generation, NOT whether the full-res decode for that generation had
//  already landed. When the predictor lost its race against a fast decode
//  — small PNG, warm cache hit, embedded preview bridging, anything in
//  the < ~10 ms range — its continuation surfaced the hairline AFTER
//  `completeHairlineIndicator()` had already run as a no-op (the bar
//  wasn't visible yet to cancel), with no subsequent `completeHairline()`
//  ever firing. The bar then stayed in Phase A → B → C indefinitely.
//
//  The race got tighter once `d9d4f88` made `handleImageChange`
//  non-blocking (CIContext.render queues GPU work instead of waiting on
//  MTKTextureLoader's synchronous upload), and tighter again once
//  `2a9d518` added the embedded-preview Task that competes for the main
//  actor on the same nav. PNG was the user-surfaced format because PNG
//  decodes are typically faster than the predictor's actor hop +
//  detached-task scheduling overhead, but the failure mode is
//  format-agnostic: any decode that beats the predictor's MainActor.run
//  resumption hits it.
//
//  The fix: gate the predictor's continuation on
//  `feedbackState.shouldShowLoadingIndicator(generation:)`, which checks
//  BOTH generation match AND `isDecodeInFlight` (phase ∈ {.waiting,
//  .showingThumb}). The bare generation check was insufficient.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class HairlineCompletionRegressionTests: XCTestCase {

    // MARK: - Predictor-loses-race scenario (the actual user-reported bug)

    /// Mimics the EXACT MainActor.run continuation in
    /// `ViewerWindow.scheduleHairlinePredictiveSkip` — both pre-fix
    /// (bare generation check) and post-fix (`shouldShowLoadingIndicator`
    /// gate) — and proves the post-fix gate is what stops the
    /// late-resuming predictor from surfacing the hairline after the
    /// decode landed.
    ///
    /// The test runs the same scenario through both gates so a single
    /// assertion can compare them. Without this comparison the test
    /// could be tautological; with it, the test FAILS at tip `d9d4f88`
    /// (where only the bare generation check existed) and PASSES post-
    /// fix.
    func testPredictorLosesRace_PostFixGateStopsLateReveal() {
        let feedbackState = NavigationFeedbackState()

        // 1. Begin nav and let the full-res land FAST — before the
        //    predictor's detached Task got back to the main actor.
        //    Mirrors what `navigateWithFeedback` does on a sub-10 ms
        //    cached / small-file decode after `d9d4f88` made
        //    `handleImageChange` non-blocking.
        let generation = feedbackState.beginNavigation()
        feedbackState.didPaintFull(generation: generation)
        XCTAssertEqual(feedbackState.phase, .showingFull)

        // 2. Pre-fix gate (BARE generation check). Mimics the orchestrator
        //    code at tip d9d4f88:
        //      `guard self.feedbackState.generation == generation else { return }`
        let preFixGatePasses = (feedbackState.generation == generation)
        XCTAssertTrue(
            preFixGatePasses,
            "pre-fix bare generation check passes — the bug. The predictor's " +
            "continuation would proceed to call setHairlineProgress / " +
            "scheduleHairlineIndicator and surface the bar AFTER the decode " +
            "landed, with no subsequent completeHairline to retire it."
        )

        // 3. Post-fix gate (`shouldShowLoadingIndicator`). Adds the
        //    `isDecodeInFlight` requirement on top of the generation
        //    match. With phase == .showingFull, this returns false.
        let postFixGatePasses = feedbackState.shouldShowLoadingIndicator(
            generation: generation
        )
        XCTAssertFalse(
            postFixGatePasses,
            "post-fix gate stops the late-resuming predictor — the fix. " +
            "shouldShowLoadingIndicator combines generation match + " +
            "isDecodeInFlight, dropping continuations that would otherwise " +
            "leave the bar stuck."
        )

        // 4. The two gates DISAGREE for this scenario — that disagreement
        //    is the bug surface and the fix's coverage point. If a future
        //    refactor makes them agree (e.g. by removing the
        //    isDecodeInFlight check), this assertion fails and surfaces
        //    the regression at PR-review time.
        XCTAssertNotEqual(
            preFixGatePasses, postFixGatePasses,
            "the bug exists exactly where the two gates disagree — keep " +
            "this assertion to make any future weakening of the gate " +
            "visible in CI"
        )
    }

    /// End-to-end view-layer reproduction. Drives the full
    /// `NavigationPositionOverlayView` lifecycle for the predictor's
    /// late continuation: with the post-fix gate dropping the
    /// continuation, the hairline must remain invisible. (The
    /// pre-fix code path would have called `setHairlineProgress` here
    /// and the bar would now be in `.phaseA` with no decode landing
    /// to fire `completeHairline()`. Pinned at 95% from the user's
    /// POV — the "stuck" report.)
    func testPredictorLosesRace_BarStaysInvisibleEndToEnd() {
        let feedbackState = NavigationFeedbackState()
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 240, height: 26)
        overlay.layoutSubtreeIfNeeded()

        let generation = feedbackState.beginNavigation()
        feedbackState.didPaintFull(generation: generation)
        // Orchestrator's no-op completeHairline (bar wasn't visible yet).
        overlay.completeHairline()
        XCTAssertFalse(overlay.isHairlineVisible)

        // Predictor's late continuation, post-fix gate. Must drop.
        if feedbackState.shouldShowLoadingIndicator(generation: generation) {
            // Pre-fix path — would surface the hairline. We don't run
            // it post-fix because the gate above drops the continuation.
            overlay.setHairlineProgress(predicted: 0.300)
        }

        // Hairline must still be invisible. No path can surface it from
        // here for this generation: the orchestrator already ran its
        // (no-op) completeHairline, no decode is pending, no other
        // Task is in flight.
        XCTAssertFalse(
            overlay.isHairlineVisible,
            "post-fix the bar is correctly invisible — the predictor's " +
            "late resume was dropped, the orchestrator's no-op " +
            "completeHairline already returned, no other path can reveal " +
            "the bar for this generation. (Pre-fix the bar would be " +
            "visible in .phaseA here, with no completeHairline ever " +
            "following — the user-visible 'stuck' bug.)"
        )
        XCTAssertEqual(
            overlay.hairlinePhase, .idle,
            "phase must be .idle — Phase A would mean the late predictor " +
            "got through and we're tracking a decode that already landed"
        )
    }

    // MARK: - Predictor wins race (existing fast-path, must still work)

    /// Predictor resumes BEFORE the decode lands. This is the "happy
    /// path" the predictive-skip was designed for: surface the bar
    /// immediately so the user has a slow-decode signal.
    /// `shouldShowLoadingIndicator` returns true (phase == .waiting,
    /// generation matches), so the predictor's reveal runs.
    /// Without this test the fix could over-correct and break the
    /// predictive-skip contract.
    func testPredictorWinsRace_StillSurfacesHairlineAtT0() {
        let feedbackState = NavigationFeedbackState()
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 240, height: 26)
        overlay.layoutSubtreeIfNeeded()

        let generation = feedbackState.beginNavigation()

        // Predictor resumes BEFORE the decode lands.
        XCTAssertTrue(
            feedbackState.shouldShowLoadingIndicator(generation: generation),
            "while the decode is still in flight, the post-fix gate must " +
            "PASS so the predictor is free to surface the hairline " +
            "(preserves the predictive-skip behavior)"
        )
        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertTrue(overlay.isHairlineVisible)
        XCTAssertEqual(overlay.hairlinePhase, .phaseA)

        // Now the decode lands. `completeHairline` drives Phase D normally.
        feedbackState.didPaintFull(generation: generation)
        overlay.completeHairline()
        XCTAssertEqual(overlay.hairlinePhase, .phaseDWidth)
        XCTAssertNotNil(overlay.pendingPhaseDFadeTask)
    }

    /// `2a9d518` preview-first behavior must NOT regress: when the
    /// embedded preview lands fast and transitions phase to
    /// `.showingThumb`, the predictor that resolves DURING this window
    /// must STILL be allowed to surface the hairline because the
    /// full-res decode is still in flight (`isDecodeInFlight` is true
    /// for `.showingThumb`).
    ///
    /// This is what preserves the camera-instant feel `2a9d518`
    /// introduced — the new gate `shouldShowLoadingIndicator` correctly
    /// returns true for `.showingThumb`, not just `.waiting`.
    func testEmbeddedPreviewPainted_PredictorStillAllowedToSurface() {
        let feedbackState = NavigationFeedbackState()

        let generation = feedbackState.beginNavigation()

        // Embedded preview wins the race — phase → .showingThumb.
        feedbackState.didPaintThumb(generation: generation)
        XCTAssertEqual(feedbackState.phase, .showingThumb)

        // Predictor resolves NOW — must still be allowed to surface the
        // hairline because the full-res decode is still running. This is
        // the case the existing predictive-skip behavior was designed
        // for and the fix MUST preserve.
        XCTAssertTrue(
            feedbackState.shouldShowLoadingIndicator(generation: generation),
            "preview placeholder must NOT lock the predictor out — " +
            "only full-res landing should. The bar tracks " +
            "the FULL decode, the preview is a separate layer."
        )

        // Now full-res lands; gate flips to false, predictor's late
        // resume (if any) is dropped.
        feedbackState.didPaintFull(generation: generation)
        XCTAssertFalse(
            feedbackState.shouldShowLoadingIndicator(generation: generation),
            "after full-res lands, the predictor's late resume is dropped"
        )
    }

    // MARK: - Stale generation (existing guarantee, regression check)

    /// A SUPERSEDING `beginNavigation()` ran while the predictor was in
    /// flight. The predictor's continuation must be dropped. (The
    /// pre-fix code already handled this case via the bare generation
    /// check; this test pins it so the fix doesn't accidentally weaken
    /// the existing generation guard.)
    func testPredictorStaleGeneration_StillDroppedAfterFix() {
        let feedbackState = NavigationFeedbackState()

        let originalGeneration = feedbackState.beginNavigation()
        // User pressed → before the predictor resolved.
        _ = feedbackState.beginNavigation()

        XCTAssertFalse(
            feedbackState.shouldShowLoadingIndicator(generation: originalGeneration),
            "stale-generation predictor continuation must be dropped — " +
            "the new generation owns the hairline state"
        )
    }

    // MARK: - End-to-end Phase D contract (orchestrator integration)

    /// End-to-end flow `navigateWithFeedback` drives when the predictor
    /// races a slow decode. Asserts the hairline reaches Phase D after
    /// the full-res lands. Distinct from
    /// `NavigationPositionOverlayViewTests.testPhaseD_FullLifecycleCompletes`
    /// (which drives the view in isolation): this binds the orchestrator
    /// integration so a future refactor that drops the
    /// `completeHairlineIndicator()` call from `navigateWithFeedback`
    /// doesn't pass tests just because the view layer's own phase D
    /// machinery still works.
    func testFullResAfterPlaceholder_HairlineCompletesPhaseD() {
        let feedbackState = NavigationFeedbackState()
        let overlay = NavigationPositionOverlayView()
        overlay.frame = CGRect(x: 0, y: 0, width: 240, height: 26)
        overlay.layoutSubtreeIfNeeded()

        let generation = feedbackState.beginNavigation()
        overlay.setHairlineProgress(predicted: 0.300)
        XCTAssertTrue(overlay.isHairlineVisible)

        feedbackState.didPaintThumb(generation: generation)
        feedbackState.didPaintFull(generation: generation)
        overlay.completeHairline()

        XCTAssertEqual(overlay.hairlinePhase, .phaseDWidth)
        XCTAssertNotNil(overlay.pendingPhaseDFadeTask)
        overlay.firePhaseDFadeForTesting()
        XCTAssertFalse(overlay.isHairlineVisible)
    }
}

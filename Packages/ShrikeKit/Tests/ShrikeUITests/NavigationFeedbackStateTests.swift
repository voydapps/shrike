//
//  NavigationFeedbackStateTests.swift
//  ShrikeUITests
//
//  Exercises the pure-logic state machine that drives the viewer's
//  layered nav feedback (thumb bridge, position overlay, hairline
//  loading indicator). Because the state machine owns no AppKit / Metal
//  / actor dependencies, these tests run synchronously on the main actor.
//
//  The race the state machine is guarding against is: a thumbnail Task
//  lands *after* a full-res decode has already committed its paint — we
//  don't want a 1024 px placeholder stomping the full-res image. Mirror:
//  a stale decode from a previous nav generation must not commit its
//  paint after the user has pressed the arrow key again.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class NavigationFeedbackStateTests: XCTestCase {

    // MARK: - Initial state

    func testInitialState_IsIdle() {
        let state = NavigationFeedbackState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.generation, 0)
    }

    // MARK: - Generation bumping

    func testBeginNavigation_BumpsGenerationAndEntersWaiting() {
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()
        XCTAssertEqual(g1, 1)
        XCTAssertEqual(state.phase, .waiting)

        let g2 = state.beginNavigation()
        XCTAssertEqual(g2, 2)
        XCTAssertEqual(state.phase, .waiting,
                       "a second nav event should re-enter waiting, not stay idle")
    }

    // MARK: - Fast path: full-res lands before thumb

    func testFullPaintBeforeThumb_SkipsThumb() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()

        // Full-res lands instantly (cache hit).
        XCTAssertTrue(state.shouldPaintFull(generation: gen))
        state.didPaintFull(generation: gen)
        XCTAssertEqual(state.phase, .showingFull)

        // Late-arriving thumb must NOT paint on top of the full-res.
        XCTAssertFalse(
            state.shouldPaintThumb(generation: gen),
            "a thumb arriving after full-res paint must not stomp the real image"
        )
    }

    // MARK: - Thumb bridge happy path

    func testThumbPaintThenFullPaint_EndsInShowingFull() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()

        XCTAssertTrue(state.shouldPaintThumb(generation: gen))
        state.didPaintThumb(generation: gen)
        XCTAssertEqual(state.phase, .showingThumb)

        XCTAssertTrue(state.shouldPaintFull(generation: gen),
                      "full-res should still paint to replace the thumb")
        state.didPaintFull(generation: gen)
        XCTAssertEqual(state.phase, .showingFull)
    }

    // MARK: - Stale generation handling

    func testStaleThumbFromPreviousGeneration_DoesNotPaint() {
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()

        // User presses Space again before g1's thumb lands.
        let g2 = state.beginNavigation()
        XCTAssertNotEqual(g1, g2)

        XCTAssertFalse(
            state.shouldPaintThumb(generation: g1),
            "a thumb from an earlier generation must not paint over the newer nav"
        )
        XCTAssertTrue(
            state.shouldPaintThumb(generation: g2),
            "the current generation's thumb is still eligible to paint"
        )
    }

    func testStaleFullFromPreviousGeneration_DoesNotPaint() {
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()
        let g2 = state.beginNavigation()
        _ = g2

        XCTAssertFalse(
            state.shouldPaintFull(generation: g1),
            "a full-res decode from an earlier generation must not paint"
        )
    }

    // MARK: - Cold-cache thumb bridge guards

    /// Covers the 2 s safety-net scenario: a truly cold thumbnail
    /// generation (large HEIC/RAW) takes long enough that full-res lands
    /// first. By the time the thumb resolves the phase is `.showingFull`,
    /// and `shouldPaintThumb` must refuse the stale paint — even though
    /// the generation still matches — so the real image isn't stomped.
    func testLateThumb_AfterFullShown_SameGeneration_DoesNotPaint() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()

        // Full-res commits first (cold thumb, warm decode pipeline).
        state.didPaintFull(generation: gen)
        XCTAssertEqual(state.phase, .showingFull)

        // Thumb task finally resolves — same generation, but full is up.
        XCTAssertFalse(
            state.shouldPaintThumb(generation: gen),
            "a slow cold-cache thumb that resolves after full-res must not stomp the real image"
        )

        // Defensive: even if a buggy call site skipped the `should*` gate
        // and invoked `didPaintThumb`, the state machine must not regress
        // from `.showingFull` back to `.showingThumb`.
        state.didPaintThumb(generation: gen)
        XCTAssertEqual(
            state.phase, .showingFull,
            "didPaintThumb must be a no-op once full-res is on screen"
        )
    }

    /// Guards the cold-cache bug this fix targets: the thumb task was
    /// still in flight when the user pressed the arrow key a second
    /// time. A new generation must invalidate the prior generation's
    /// thumb paint attempt, and `didPaintThumb` on the stale generation
    /// must leave the newer waiting phase untouched.
    func testNewGeneration_InvalidatesInflightThumb() {
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()
        XCTAssertTrue(
            state.shouldPaintThumb(generation: g1),
            "precondition: g1 thumb was eligible while in flight"
        )

        // User presses arrow again before g1's thumb resolves.
        let g2 = state.beginNavigation()
        XCTAssertEqual(state.phase, .waiting)

        XCTAssertFalse(
            state.shouldPaintThumb(generation: g1),
            "outstanding g1 thumb must be invalidated by g2's begin()"
        )

        // Even if the stale task raced past its gate and called
        // didPaintThumb, the newer generation's waiting phase must
        // survive — we don't want a stale thumb to paint over g2's
        // fresh overlay / upcoming full-res.
        state.didPaintThumb(generation: g1)
        XCTAssertEqual(
            state.phase, .waiting,
            "stale didPaintThumb must not transition g2's waiting phase"
        )
        XCTAssertTrue(
            state.shouldPaintFull(generation: g2),
            "g2's full-res is still eligible after the stale thumb was dropped"
        )
    }

    func testNewNavDuringShowingThumb_RestartsFlow() {
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()
        state.didPaintThumb(generation: g1)
        XCTAssertEqual(state.phase, .showingThumb)

        // User presses arrow again before full-res from g1 lands.
        let g2 = state.beginNavigation()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(state.shouldPaintFull(generation: g1),
                       "stale full-res from g1 must not commit to screen")
        XCTAssertTrue(state.shouldPaintThumb(generation: g2),
                      "g2 thumb is still eligible")
    }

    // MARK: - Reset

    func testReset_ReturnsToIdle() {
        let state = NavigationFeedbackState()
        _ = state.beginNavigation()
        state.didPaintFull(generation: state.generation)
        XCTAssertEqual(state.phase, .showingFull)

        state.reset()
        XCTAssertEqual(state.phase, .idle)
    }

    // MARK: - Defaults

    func testDefaultTimings_MatchSpec() {
        let state = NavigationFeedbackState()
        XCTAssertEqual(state.spinnerDelay, 0.200, accuracy: 0.001)
        XCTAssertEqual(state.thumbBudget, 0.200, accuracy: 0.001)
        XCTAssertEqual(state.overlayIdleTimeout, 1.2, accuracy: 0.001)
    }

    func testDefaultOverlayAutoHides_IsFalse() {
        // Always-on is the default so a user who opens a single file sees
        // their position without having to trigger a nav event.
        let state = NavigationFeedbackState()
        XCTAssertFalse(state.overlayAutoHides)
    }

    // MARK: - Position overlay visibility — always-on mode (default)

    func testOverlay_AlwaysOnMode_StaysVisibleAfterIdleTimeout() {
        let state = NavigationFeedbackState(overlayAutoHides: false)
        let token = state.didShowOverlay()
        XCTAssertTrue(state.overlayVisible)

        // Idle timeout fires — in always-on mode it must be a no-op.
        XCTAssertFalse(
            state.overlayIdleTimeoutFired(token: token),
            "always-on overlay must not fade when the idle timer fires"
        )
        XCTAssertTrue(
            state.overlayVisible,
            "always-on overlay must remain visible after the idle timeout"
        )
    }

    func testOverlay_AlwaysOnMode_InitialShowSetsVisible() {
        // The viewer surfaces the overlay on the initial image load, not
        // just on nav events. Exercising this path ensures that a
        // single-file open still leaves the user looking at "1 / 1 —
        // filename.jpg" from the first frame.
        let state = NavigationFeedbackState(overlayAutoHides: false)
        XCTAssertFalse(state.overlayVisible, "precondition: starts hidden")
        state.didShowOverlay()
        XCTAssertTrue(state.overlayVisible)
    }

    // MARK: - Position overlay visibility — auto-hide mode (opt-in)

    func testOverlay_AutoHideMode_FadesAfterIdleTimeout() {
        let state = NavigationFeedbackState(overlayAutoHides: true)
        let token = state.didShowOverlay()
        XCTAssertTrue(state.overlayVisible)

        XCTAssertTrue(
            state.overlayIdleTimeoutFired(token: token),
            "auto-hide overlay should fade when the idle timer fires"
        )
        XCTAssertFalse(state.overlayVisible)
    }

    func testOverlay_AutoHideMode_StaleTokenDoesNotFade() {
        // Hold-to-scroll hammers `didShowOverlay()` repeatedly. Each call
        // should reset the idle timer — a stale task from an earlier token
        // must not close the overlay the user is still watching update.
        let state = NavigationFeedbackState(overlayAutoHides: true)
        let t1 = state.didShowOverlay()
        let t2 = state.didShowOverlay()
        XCTAssertNotEqual(t1, t2)

        XCTAssertFalse(
            state.overlayIdleTimeoutFired(token: t1),
            "stale idle-timer tail from a prior show must not fade the overlay"
        )
        XCTAssertTrue(
            state.overlayVisible,
            "overlay must still be visible — the current token is live"
        )

        XCTAssertTrue(state.overlayIdleTimeoutFired(token: t2))
        XCTAssertFalse(state.overlayVisible)
    }

    // MARK: - PREVIEW badge visibility
    //
    // The badge is surfaced by the view layer (`PreviewBadgeView`) while
    // the 1024 px thumb bridge is on screen. These tests guard the pure
    // predicate the view calls into — `shouldShowPreviewBadge(generation:)`
    // — in the same shape as `shouldShowLoadingIndicator`. The badge must be:
    //   * visible in `.showingThumb` (the phase it exists to explain),
    //   * hidden in every other phase,
    //   * hidden for stale generations even if phase happens to be
    //     `.showingThumb` for a newer generation.

    func testPreviewBadge_HiddenInIdle() {
        let state = NavigationFeedbackState()
        XCTAssertFalse(
            state.shouldShowPreviewBadge(generation: state.generation),
            "badge must be hidden at startup — nothing has been painted"
        )
    }

    func testPreviewBadge_HiddenInWaiting() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertFalse(
            state.shouldShowPreviewBadge(generation: gen),
            "badge must be hidden while waiting — no thumb on screen yet"
        )
    }

    func testPreviewBadge_VisibleInShowingThumb() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        state.didPaintThumb(generation: gen)
        XCTAssertEqual(state.phase, .showingThumb)
        XCTAssertTrue(
            state.shouldShowPreviewBadge(generation: gen),
            "badge must be visible whenever the thumb bridge is painted"
        )
    }

    func testPreviewBadge_HiddenInShowingFull() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        state.didPaintThumb(generation: gen)
        XCTAssertTrue(state.shouldShowPreviewBadge(generation: gen))

        // Full-res lands — badge must hide immediately (same frame).
        state.didPaintFull(generation: gen)
        XCTAssertEqual(state.phase, .showingFull)
        XCTAssertFalse(
            state.shouldShowPreviewBadge(generation: gen),
            "badge must be hidden the moment full-res commits"
        )
    }

    func testPreviewBadge_StaleGenerationNotVisible() {
        // A thumb paint attempt from a superseded nav must never surface
        // the badge, even if the newer generation happens to also be
        // showing a thumb. Mirrors `shouldPaintThumb`'s generation gate.
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()

        // User presses arrow again before g1 finishes.
        let g2 = state.beginNavigation()
        state.didPaintThumb(generation: g2)
        XCTAssertTrue(
            state.shouldShowPreviewBadge(generation: g2),
            "precondition: newer generation's thumb shows the badge"
        )
        XCTAssertFalse(
            state.shouldShowPreviewBadge(generation: g1),
            "a stale generation must not surface the badge"
        )
    }

    func testPreviewBadge_HiddenAfterReset() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        state.didPaintThumb(generation: gen)
        XCTAssertTrue(state.shouldShowPreviewBadge(generation: gen))

        // Error path resets the pipeline — badge must follow.
        state.reset()
        XCTAssertFalse(
            state.shouldShowPreviewBadge(generation: gen),
            "reset must hide the badge (phase returns to .idle)"
        )
    }

    // MARK: - Loading indicator visibility (hairline)
    //
    // The hairline underline inside the position overlay replaces the
    // deleted top-edge loading bar.
    // The predicate is driven by the orthogonal `isDecodeInFlight` flag —
    // eligible across `.waiting` and `.showingThumb`, hidden in
    // `.showingFull` and `.idle`. The 200 ms show-grace is the view
    // layer's responsibility; this predicate is pure and time-free.

    func testLoadingIndicator_VisibleInWaiting() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(
            state.shouldShowLoadingIndicator(generation: gen),
            "loading indicator must be eligible the instant we enter .waiting"
        )
    }

    func testLoadingIndicator_VisibleInShowingThumb() {
        // Full-res is still decoding while the thumb bridge is painted —
        // the indicator must remain eligible until full-res commits.
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        state.didPaintThumb(generation: gen)
        XCTAssertEqual(state.phase, .showingThumb)
        XCTAssertTrue(
            state.shouldShowLoadingIndicator(generation: gen),
            "loading indicator must remain eligible during .showingThumb (full-res still in flight)"
        )
    }

    func testLoadingIndicator_HiddenInShowingFull() {
        let state = NavigationFeedbackState()
        let gen = state.beginNavigation()
        state.didPaintFull(generation: gen)
        XCTAssertEqual(state.phase, .showingFull)
        XCTAssertFalse(
            state.shouldShowLoadingIndicator(generation: gen),
            "loading indicator must report hidden the instant full-res commits"
        )
    }

    func testLoadingIndicator_HiddenInIdle() {
        let state = NavigationFeedbackState()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertFalse(
            state.shouldShowLoadingIndicator(generation: state.generation),
            "loading indicator must report hidden at startup — no nav in flight"
        )
    }

    func testLoadingIndicator_StaleGeneration_Hidden() {
        // A late `shouldShowLoadingIndicator` query from a superseded nav
        // must never surface the indicator on behalf of an older
        // generation, same invariant that guards `shouldPaintThumb`.
        let state = NavigationFeedbackState()
        let g1 = state.beginNavigation()
        let g2 = state.beginNavigation()
        XCTAssertNotEqual(g1, g2)
        XCTAssertFalse(
            state.shouldShowLoadingIndicator(generation: g1),
            "stale generation must not report the indicator as visible"
        )
        XCTAssertTrue(
            state.shouldShowLoadingIndicator(generation: g2),
            "the current generation is still eligible"
        )
    }

    func testOverlay_ForceHidden_BypassesAutoHidePref() {
        // Teardown path — window is closing, overlay goes away regardless
        // of user preference.
        let state = NavigationFeedbackState(overlayAutoHides: false)
        state.didShowOverlay()
        XCTAssertTrue(state.overlayVisible)

        state.forceOverlayHidden()
        XCTAssertFalse(state.overlayVisible)
    }
}

//
//  ViewerInputRulesTests.swift
//  ShrikeRenderingTests
//
//  Scroll, swipe, zoom and pan-clamp rules,
//  run on the pure rule types with plain values (no real events).
//

import XCTest
import CoreGraphics
@testable import ShrikeRendering

final class ViewerInputRulesTests: XCTestCase {

    private func wheel(_ dy: Double, dx: Double = 0, t: TimeInterval,
                       inverted: Bool = false, swap: Bool = false) -> ScrollInput {
        ScrollInput(isPrecise: false, deltaX: dx, deltaY: dy,
                    isDirectionInverted: inverted, swapsAction: swap, timestamp: t)
    }

    // One notch down at Fit → next; 8 fast notches (12.5 ms apart) → 8 changes (0.2.10: none dropped).
    func testVector1_notchDownAtFitGoesNext_fastSpinLosesNoNotch() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(-1, t: 0), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: true))

        var router = ScrollInputRouter()
        var changes = 0
        for i in 0..<8 {   // 8 notches in 100 ms
            let a = router.route(wheel(-1, t: 10 + Double(i) * 0.0125), atFit: true,
                                 wheelChangesImage: true, swipeEnabled: true)
            if case .navigate = a { changes += 1 }
        }
        XCTAssertEqual(changes, 8)
    }

    // A small tick (0.1-0.3, slow turn with acceleration) is still one notch.
    func testWheelUpGoesPrevious_andSmallTicksStepAtOnce() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(0.4, t: 0), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: false))
        XCTAssertEqual(r.route(wheel(0.4, t: 0.2), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: false))
        XCTAssertEqual(r.accumulator, 0)
    }

    private let fit = (atFit: true, wheelChangesImage: true, swipeEnabled: true)

    /// Runs `events` at Fit; returns the steps (true = next, false = previous).
    private func steps(_ events: [ScrollInput], router: inout ScrollInputRouter,
                       atFit: Bool = true, wheelChangesImage: Bool = true) -> [Bool] {
        events.compactMap {
            if case .navigate(let f) = router.route($0, atFit: atFit,
                                                    wheelChangesImage: wheelChangesImage,
                                                    swipeEnabled: true) { return f }
            return nil
        }
    }

    func testNotchedFractionalTicks_oneStepPerTick_withAcceleration() {
        var r = ScrollInputRouter()
        // 5 slow notches, 0.1 -> 0.3 per tick, 200 ms apart.
        let ev = [0.1, 0.1, 0.2, 0.3, 0.3].enumerated().map { wheel(-$1, t: Double($0) * 0.2) }
        XCTAssertEqual(steps(ev, router: &r), [true, true, true, true, true])
        // Wheel up goes back.
        var up = ScrollInputRouter()
        XCTAssertEqual(steps([wheel(0.1, t: 0), wheel(0.1, t: 0.2)], router: &up), [false, false])
    }

    func testNotchedWholeLines_oneStepPerNotch() {
        var r = ScrollInputRouter()
        let ev = (0..<4).map { wheel(-1, t: Double($0) * 0.1) }
        XCTAssertEqual(steps(ev, router: &r), [true, true, true, true])
    }

    func testNotchedTicksOfOneNotchInsideDropWindowStepOnce() {
        var r = ScrollInputRouter()
        // A driver that splits one notch into three ticks 8 ms apart.
        let ev = (0..<3).map { wheel(-0.2, t: Double($0) * 0.008) }
        XCTAssertEqual(steps(ev, router: &r), [true])
    }

    func testNotchedHorizontalOnlyAtFitDoesNothing() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(0, dx: -1, t: 0), atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
    }

    func testNotchedPrefZooms_swapNavigatesOnSmallTick() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(-0.2, t: 0, swap: true), atFit: false, wheelChangesImage: false, swipeEnabled: true),
                       .navigate(forward: true))
    }

    private func precise(_ dy: Double, t: TimeInterval, began: Bool = false, ended: Bool = false,
                         phased: Bool = true, momentum: Bool = false, dx: Double = 0,
                         swap: Bool = false, inverted: Bool = false) -> ScrollInput {
        ScrollInput(isPrecise: true, deltaX: dx, deltaY: dy, isDirectionInverted: inverted,
                    phaseBegan: began, isMomentum: momentum, phaseEnded: ended,
                    hasPhase: phased, swapsAction: swap, timestamp: t)
    }

    // Smooth-scrolling wheel: precise, no phase, small vertical deltas.
    func testPreciseVerticalWithoutPhase_stepsEvery80Points() {
        var r = ScrollInputRouter()
        let ev = (0..<16).map { precise(-10, t: Double($0) * 0.02, phased: false) }
        XCTAssertEqual(steps(ev, router: &r), [true, true], "8 events of 10 pt = one image")
        var up = ScrollInputRouter()
        XCTAssertEqual(steps((0..<8).map { precise(10, t: Double($0) * 0.02, phased: false) }, router: &up), [false])
    }

    func testPreciseVerticalWithoutPhase_pauseStartsNewGesture() {
        var r = ScrollInputRouter()
        var ev = (0..<5).map { precise(-10, t: Double($0) * 0.02, phased: false) }
        ev += (0..<5).map { precise(-10, t: 2 + Double($0) * 0.02, phased: false) }
        XCTAssertEqual(steps(ev, router: &r), [], "50 pt, a pause, 50 pt never adds up")
    }

    func testPreciseVerticalWithPhases_stepsAndEndResetsCounter() {
        var r = ScrollInputRouter()
        var ev = [precise(-30, t: 0, began: true)]
        ev += (1..<4).map { precise(-30, t: Double($0) * 0.016) }          // 120 pt -> one step
        ev += [precise(-30, t: 0.07, ended: true)]                         // leaves 70 + 30 -> second step? no: 40 left
        XCTAssertEqual(steps(ev, router: &r), [true])
        XCTAssertEqual(r.accumulator, 0, "phase end resets")
        // New gesture starts clean: 60 pt is not enough.
        let next = [precise(-30, t: 1, began: true), precise(-30, t: 1.016)]
        XCTAssertEqual(steps(next, router: &r), [])
    }

    func testPreciseVerticalReversalRestartsCounter() {
        var r = ScrollInputRouter()
        let ev = [precise(-60, t: 0, began: true), precise(60, t: 0.016), precise(60, t: 0.032)]
        XCTAssertEqual(steps(ev, router: &r), [false], "60 down is dropped; the 120 up steps back once")
    }

    func testPreciseMomentumAtFitNeverSteps() {
        var r = ScrollInputRouter()
        let ev = (0..<20).map { precise(-40, t: Double($0) * 0.016, momentum: true) }
        XCTAssertEqual(steps(ev, router: &r), [])
    }

    func testPreciseVerticalAtFit_prefZoomsDoesNotStep() {
        var r = ScrollInputRouter()
        let ev = [precise(-200, t: 0, began: true)]
        XCTAssertEqual(steps(ev, router: &r, wheelChangesImage: false), [])
    }

    func testPreciseHorizontalStartStillSwipes_verticalStartDoesNot() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(precise(1, t: 0, began: true, dx: -8), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .beginSwipe)
        var v = ScrollInputRouter()
        XCTAssertEqual(v.route(precise(-8, t: 0, began: true, dx: 1), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .none, "8 pt is far from a step")
    }

    func testPreciseZoomedInPans_neverSteps() {
        var r = ScrollInputRouter()
        for i in 0..<20 {
            let a = r.route(precise(-40, t: Double(i) * 0.016, began: i == 0), atFit: false,
                            wheelChangesImage: true, swipeEnabled: true)
            XCTAssertEqual(a, .pan(dx: 0, dy: 40))
        }
    }

    func testPreciseSwapModifierZooms() {
        var r = ScrollInputRouter()
        // 40 pt = two lines = 1.12^2; a flick of 400 pt in one event is capped at 60 pt.
        XCTAssertEqual(r.route(precise(40, t: 0, swap: true), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .zoom(factor: pow(1.12, 2)))
        XCTAssertEqual(r.route(precise(400, t: 1, swap: true), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .zoom(factor: pow(1.12, 3)))
    }

    /// Audit item 8: six 40-pt events (and six accelerated notches) are not 25 % -> 1600 %.
    func testZoomIsGentle() {
        var r = ScrollInputRouter()
        var total = 1.0
        for i in 0..<6 {
            if case .zoom(let f) = r.route(precise(40, t: Double(i), swap: true), atFit: true,
                                           wheelChangesImage: true, swipeEnabled: true) { total *= f }
        }
        XCTAssertLessThan(total, 4.5)
        XCTAssertGreaterThan(total, 3)
        var n = ScrollInputRouter()
        var notches = 1.0
        for i in 0..<6 {   // accelerated wheel: 5 lines per notch
            if case .zoom(let f) = n.route(wheel(5, t: Double(i), swap: true), atFit: true,
                                           wheelChangesImage: true, swipeEnabled: true) { notches *= f }
        }
        XCTAssertEqual(notches, pow(1.12, 6), accuracy: 1e-9, "the size of a notch does not matter")
    }

    /// 0.2.10 audit item 6: whole notches 10 / 15 / 25 / 40 ms apart all step.
    func testWholeNotchesStepAtEverySpacing() {
        for ms in [10.0, 15, 25, 40] {
            var r = ScrollInputRouter()
            let ev = (0..<6).map { wheel(-1, t: 1 + Double($0) * ms / 1000) }
            XCTAssertEqual(steps(ev, router: &r), Array(repeating: true, count: 6), "\(ms) ms")
            var up = ScrollInputRouter()
            let evUp = (0..<6).map { wheel(1, t: 1 + Double($0) * ms / 1000) }
            XCTAssertEqual(steps(evUp, router: &up), Array(repeating: false, count: 6), "\(ms) ms up")
        }
    }

    /// One notch split into small ticks (any spacing under the burst window) is still one step;
    /// a second notch split the same way is a second step.
    func testSplitTicksStepOncePerNotch() {
        for ms in [4.0, 8, 12] {
            var r = ScrollInputRouter()
            var ev = (0..<5).map { wheel(-0.2, t: 1 + Double($0) * ms / 1000) }
            ev += (0..<5).map { wheel(-0.2, t: 1 + Double($0 + 5) * ms / 1000) }
            XCTAssertEqual(steps(ev, router: &r), [true, true], "\(ms) ms")
        }
    }

    /// A change of direction inside the window is its own step, not swallowed.
    func testReversalInsideTheWindowSteps() {
        var r = ScrollInputRouter()
        XCTAssertEqual(steps([wheel(-1, t: 1), wheel(1, t: 1.01)], router: &r), [true, false])
    }

    // Zoomed to 200 %, a notch pans 24 pt; ⇧ + notch pans horizontally.
    func testVector2_zoomedInNotchPans24pt_shiftPansHorizontally() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(-1, t: 0), atFit: false, wheelChangesImage: true, swipeEnabled: true),
                       .pan(dx: 0, dy: 24))
        // ⇧ + wheel arrives as scrollingDeltaX.
        XCTAssertEqual(r.route(wheel(0, dx: -1, t: 1), atFit: false, wheelChangesImage: true, swipeEnabled: true),
                       .pan(dx: -24, dy: 0))
    }

    // ⌘ + wheel up zooms ×1.12 per notch; the anchor stays put.
    func testVector3_commandWheelZoomsAtPointer() {
        var r = ScrollInputRouter()
        let a = r.route(wheel(1, t: 0, swap: true), atFit: true, wheelChangesImage: true, swipeEnabled: true)
        XCTAssertEqual(a, .zoom(factor: 1.12))
        let a2 = r.route(wheel(-1, t: 1, swap: true), atFit: false, wheelChangesImage: true, swipeEnabled: true)
        XCTAssertEqual(a2, .zoom(factor: 1 / 1.12))

        let view = CGSize(width: 800, height: 600)
        let anchor = CGPoint(x: 600, y: 200)
        let pan = CGPoint(x: 30, y: -10)
        let oldScale = 0.5, newScale = 0.625
        let newPan = PanGeometry.anchoredPan(pan: pan, anchor: anchor, viewSize: view,
                                             from: oldScale, to: newScale)
        // Image-space point under the anchor before and after.
        let before = (anchor.x - 400 - pan.x) / oldScale
        let after = (anchor.x - 400 - newPan.x) / newScale
        XCTAssertEqual(before, after, accuracy: 1e-9)
        let beforeY = (anchor.y - 300 - pan.y) / oldScale
        let afterY = (anchor.y - 300 - newPan.y) / newScale
        XCTAssertEqual(beforeY, afterY, accuracy: 1e-9)
    }

    // Pref Zooms — wheel zooms; ⌘ + wheel changes image (at any zoom).
    func testVector4_prefZooms_wheelZooms_commandWheelNavigates() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(1, t: 0), atFit: true, wheelChangesImage: false, swipeEnabled: true),
                       .zoom(factor: 1.12))
        XCTAssertEqual(r.route(wheel(-1, t: 1, swap: true), atFit: false, wheelChangesImage: false, swipeEnabled: true),
                       .navigate(forward: true))
    }

    // Natural scrolling on and off — wheel down is next in both.
    func testVector5_naturalScrollingDoesNotFlipWheelDirection() {
        var off = ScrollInputRouter()
        XCTAssertEqual(off.route(wheel(-1, t: 0, inverted: false), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: true))
        var on = ScrollInputRouter()
        XCTAssertEqual(on.route(wheel(1, t: 0, inverted: true), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: true))
    }

    // Trackpad zoomed in pans and stops at the edge; momentum
    // never changes image.
    func testVector7_trackpadZoomedInPansClamped_momentumNeverNavigates() {
        var r = ScrollInputRouter()
        let pad = ScrollInput(isPrecise: true, deltaX: 12, deltaY: -5, phaseBegan: true)
        XCTAssertEqual(r.route(pad, atFit: false, wheelChangesImage: true, swipeEnabled: true), .pan(dx: 12, dy: 5))
        let momentum = ScrollInput(isPrecise: true, deltaX: 40, deltaY: 0, isMomentum: true)
        XCTAssertEqual(r.route(momentum, atFit: false, wheelChangesImage: true, swipeEnabled: true), .pan(dx: 40, dy: 0))
        XCTAssertEqual(r.route(momentum, atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)

        // Clamp: a 1600 × 1200 image in an 800 × 600 view moves ±400 / ±300.
        let clamped = PanGeometry.clamp(pan: CGPoint(x: 900, y: -900),
                                        imageSize: CGSize(width: 1600, height: 1200),
                                        viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(clamped, CGPoint(x: 400, y: -300))
        // Smaller on an axis: stays centred there.
        let narrow = PanGeometry.clamp(pan: CGPoint(x: 50, y: 50),
                                       imageSize: CGSize(width: 500, height: 1200),
                                       viewSize: CGSize(width: 800, height: 600))
        XCTAssertEqual(narrow, CGPoint(x: 0, y: 50))
    }

    func testTrackpadAtFit_horizontalStartSwipes_verticalOrSettingOffDoesNothing() {
        var r = ScrollInputRouter()
        let h = ScrollInput(isPrecise: true, deltaX: -8, deltaY: 1, phaseBegan: true)
        XCTAssertEqual(r.route(h, atFit: true, wheelChangesImage: true, swipeEnabled: true), .beginSwipe)
        XCTAssertEqual(r.route(h, atFit: true, wheelChangesImage: true, swipeEnabled: false), .none)
        let v = ScrollInput(isPrecise: true, deltaX: 1, deltaY: -8, phaseBegan: true)
        XCTAssertEqual(r.route(v, atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)   // 8 pt < 80
        let changed = ScrollInput(isPrecise: true, deltaX: -8, deltaY: 0, phaseBegan: false)
        XCTAssertEqual(r.route(changed, atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
    }

    func testSwipeMapping_fingersLeftIsNext_endsRubberBand() {
        // Natural scrolling on: positive amount = fingers right = previous.
        XCTAssertEqual(SwipeMapping.result(finalAmount: -1, isComplete: true, isDirectionInverted: true), true)
        XCTAssertEqual(SwipeMapping.result(finalAmount: 1, isComplete: true, isDirectionInverted: true), false)
        XCTAssertNil(SwipeMapping.result(finalAmount: 0.4, isComplete: true, isDirectionInverted: true))
        XCTAssertNil(SwipeMapping.result(finalAmount: -1, isComplete: false, isDirectionInverted: true))
        // Last image: the "next" side has threshold 0.
        let t = SwipeMapping.thresholds(hasPrevious: true, hasNext: false, isDirectionInverted: true)
        XCTAssertEqual(t.min, 0)
        XCTAssertEqual(t.max, 1)
        // Offset follows the fingers, max 40 pt.
        XCTAssertEqual(SwipeMapping.threeFingerForward(deltaX: 1), true)
        XCTAssertEqual(SwipeMapping.threeFingerForward(deltaX: -1), false)
        XCTAssertNil(SwipeMapping.threeFingerForward(deltaX: 0))
    }

    // Pinch out past 100 % holds there; pinch in below Fit returns to Fit.
    func testVector8_pinchDetentAt100_andReleaseBelowFit() {
        var p = PinchZoomState(scale: 0.8, fit: 0.5)
        XCTAssertTrue(p.apply(magnification: 0.3), "crossing 100 % plays the haptic")
        XCTAssertEqual(p.scale, 1.0)
        XCTAssertFalse(p.apply(magnification: 0.02))
        XCTAssertEqual(p.scale, 1.0, "held until the pinch moves another 4 %")
        XCTAssertFalse(p.apply(magnification: 0.03))
        XCTAssertGreaterThan(p.scale, 1.04)

        var q = PinchZoomState(scale: 0.5, fit: 0.5)
        q.apply(magnification: -0.5)
        XCTAssertLessThan(q.scale, 0.5)
        XCTAssertGreaterThanOrEqual(q.scale, 0.8 * 0.25)
        XCTAssertNil(q.releaseScale, "released below Fit → back to Fit")

        var r = PinchZoomState(scale: 10, fit: 0.5)
        r.apply(magnification: 5)
        XCTAssertEqual(r.scale, 16, "max 1600 %")
    }

    // ⌘− from 1600 % walks down the ladder and stops at
    // min(fit, 25 %); Zoom Out is then disabled.
    func testVector10_zoomOutLadderStopsAtLowest() {
        let fit = 0.4
        var s = 16.0
        var visited: [Double] = []
        while let next = ZoomLadder.stepOut(from: s, fit: fit) {
            visited.append(next)
            s = next
        }
        XCTAssertEqual(visited, [8, 4, 3, 2, 1.5, 1, 0.67, 0.5, 0.4, 0.33, 0.25])
        XCTAssertFalse(ZoomLadder.canZoomOut(from: s, fit: fit))
        XCTAssertFalse(ZoomLadder.canZoomIn(from: 16, fit: fit))
        XCTAssertEqual(ZoomLadder.stepIn(from: 0.4, fit: fit), 0.5)

        // Fit below 25 % is the lowest step.
        XCTAssertEqual(ZoomLadder.stepOut(from: 0.25, fit: 0.1), 0.1)
        XCTAssertNil(ZoomLadder.stepOut(from: 0.1, fit: 0.1))
    }

    // ⌘+ / ⌘− skip a step less than ~10 %
    // away, so a key press never looks like it did nothing.
    func testZoomStepsSkipAStepCloserThanTenPercent() {
        XCTAssertEqual(ZoomLadder.stepIn(from: 0.66, fit: 0.66), 1, "Fit 66 % → 100 %, not 67 %")
        XCTAssertEqual(ZoomLadder.stepOut(from: 0.72, fit: 0.72), 0.5, "Fit 72 % → 50 %, not 67 %")
        XCTAssertEqual(ZoomLadder.stepIn(from: 0.95, fit: 0.95), 1.5, "95 % → 150 %, not 100 %")
        XCTAssertEqual(ZoomLadder.stepOut(from: 1.05, fit: 0.4), 0.67, "105 % → 67 %, not 100 %")
        // Far enough: the next step as before.
        XCTAssertEqual(ZoomLadder.stepIn(from: 0.5, fit: 0.4), 0.67)
        XCTAssertEqual(ZoomLadder.stepOut(from: 2, fit: 0.4), 1.5)
        // The ends stay reachable even when they are closer than 10 %.
        XCTAssertEqual(ZoomLadder.stepIn(from: 15.5, fit: 0.4), 16)
        XCTAssertEqual(ZoomLadder.stepOut(from: 0.26, fit: 0.4), 0.25)
        // Every step moves by at least 10 % unless it lands on an end.
        for fit in stride(from: 0.05, through: 3.0, by: 0.01) {
            var s = fit
            while let next = ZoomLadder.stepIn(from: s, fit: fit) {
                XCTAssertTrue(next >= s * 1.09 || next == ZoomLadder.maxScale, "\(s) → \(next) at fit \(fit)")
                s = next
            }
            while let next = ZoomLadder.stepOut(from: s, fit: fit) {
                XCTAssertTrue(next <= s / 1.09 || next == ZoomLadder.lowest(fit: fit), "\(s) → \(next) at fit \(fit)")
                s = next
            }
            XCTAssertEqual(s, ZoomLadder.lowest(fit: fit), accuracy: 1e-9)
        }
    }

    func testZoomAnnouncementThrottleAndText() {
        var t = ZoomAnnouncementThrottle()
        XCTAssertTrue(t.allow(at: 10))
        XCTAssertFalse(t.allow(at: 10.3))
        XCTAssertTrue(t.allow(at: 10.6))
        XCTAssertEqual(ZoomAnnouncementThrottle.text(scale: 2, atFit: false), "Zoom 200 percent")
        XCTAssertEqual(ZoomAnnouncementThrottle.text(scale: 0.3, atFit: true), "Zoom to fit")
    }

    func testToggleZoomTargets() {
        XCTAssertEqual(ToggleZoom.target(atFit: true), 1.0)
        XCTAssertNil(ToggleZoom.target(atFit: false))
    }
}

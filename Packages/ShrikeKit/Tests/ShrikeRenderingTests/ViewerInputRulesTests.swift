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

    // One notch down at Fit → next; 8 fast notches → ≤ 2 changes.
    func testVector1_notchDownAtFitGoesNext_fastSpinAdvancesAtMostTwice() {
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
        XCTAssertGreaterThanOrEqual(changes, 1)
        XCTAssertLessThanOrEqual(changes, 2)
    }

    func testWheelUpGoesPrevious_andSubLineDeltasAccumulate() {
        var r = ScrollInputRouter()
        XCTAssertEqual(r.route(wheel(0.4, t: 0), atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
        XCTAssertEqual(r.route(wheel(0.4, t: 0.2), atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
        XCTAssertEqual(r.route(wheel(0.4, t: 0.4), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: false))
        XCTAssertEqual(r.accumulator, 0)
    }

    func testEventsInsideDropWindowAreDroppedNotQueued() {
        var r = ScrollInputRouter()
        _ = r.route(wheel(-1, t: 1.0), atFit: true, wheelChangesImage: true, swipeEnabled: true)
        XCTAssertEqual(r.route(wheel(-1, t: 1.05), atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
        XCTAssertEqual(r.accumulator, 0, "dropped deltas must not build up")
        XCTAssertEqual(r.route(wheel(-1, t: 1.07), atFit: true, wheelChangesImage: true, swipeEnabled: true),
                       .navigate(forward: true))
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

    // ⌘ + wheel up zooms ×1.25 per notch; the anchor stays put.
    func testVector3_commandWheelZoomsAtPointer() {
        var r = ScrollInputRouter()
        let a = r.route(wheel(1, t: 0, swap: true), atFit: true, wheelChangesImage: true, swipeEnabled: true)
        XCTAssertEqual(a, .zoom(factor: 1.25))
        let a2 = r.route(wheel(-1, t: 1, swap: true), atFit: false, wheelChangesImage: true, swipeEnabled: true)
        XCTAssertEqual(a2, .zoom(factor: 0.8))

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
                       .zoom(factor: 1.25))
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
        XCTAssertEqual(r.route(v, atFit: true, wheelChangesImage: true, swipeEnabled: true), .none)
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

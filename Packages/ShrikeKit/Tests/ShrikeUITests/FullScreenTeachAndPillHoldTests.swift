//
//  FullScreenTeachAndPillHoldTests.swift
//  ShrikeUITests
//
//  Spec 24 §1.1 (teach once: the capsule and the pill show for 2 s on the
//  first full-screen entry of the run) and §1.2 (the pill shows while the
//  capsule shows and hides with it).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class FullScreenTeachAndPillHoldTests: XCTestCase {

    private var wasTaught = true

    override func setUp() {
        super.setUp()
        Prefs.resetAll()
        wasTaught = ViewerContentView.teachOnceDone
    }

    override func tearDown() {
        ViewerContentView.resetTeachOnceForTesting(taught: wasTaught)
        Prefs.resetAll()
        super.tearDown()
    }

    /// `autoHides`: the pill's own idle fade. Most tests force it; nil
    /// leaves the real pref in charge (a fresh store: on, spec 24 §1.2).
    private func makeContent(mode: ViewerContentView.WindowMode = .windowed,
                             autoHides: Bool? = true) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        content.animatesPanelFades = false
        content.navigationPositionOverlayForTesting.autoHidesOverrideForTesting = autoHides
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        content.navigationPositionOverlayForTesting.show(index: 3, total: 41, filename: "IMG_0001.jpg")
        return content
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func pillShown(_ content: ViewerContentView) -> Bool {
        let pill = content.navigationPositionOverlayForTesting
        return !pill.isHidden && pill.alphaValue > 0
    }

    // MARK: Teach once

    func testFirstEntryShowsCapsuleAndPillThenFadesAndASecondEntryStaysClean() async {
        ViewerContentView.resetTeachOnceForTesting(taught: false)
        let first = makeContent()
        first.windowMode = .fullscreen
        first.layoutSubtreeIfNeeded()
        XCTAssertTrue(first.teachOnceActiveForTesting)
        XCTAssertTrue(first.isCapsuleBuiltForTesting)
        XCTAssertEqual(first.alphaForTesting(.toolbar), 1, "the capsule shows")
        XCTAssertTrue(pillShown(first), "the pill shows with it")
        XCTAssertEqual(first.alphaForTesting(.inspector), 0)

        // A first pointer move elsewhere must not cut the lesson short.
        first.evaluateZonesForTesting(at: NSPoint(x: 700, y: 500))
        XCTAssertEqual(first.alphaForTesting(.toolbar), 1)

        first.fireTeachOnceExpiryForTesting()
        XCTAssertFalse(first.teachOnceActiveForTesting)
        XCTAssertEqual(first.alphaForTesting(.toolbar), 0, "the capsule fades")
        let hidden = await waitUntil { !self.pillShown(first) }
        XCTAssertTrue(hidden, "the pill goes with it")

        // Later entries in the same run start clean.
        let second = makeContent()
        second.windowMode = .fullscreen
        second.layoutSubtreeIfNeeded()
        XCTAssertFalse(second.teachOnceActiveForTesting)
        XCTAssertEqual(second.alphaForTesting(.toolbar), 0)
        XCTAssertFalse(second.isCapsuleBuiltForTesting && second.alphaForTesting(.toolbar) > 0)
    }

    /// The second window of a run (a viewer opened from the Browser) never
    /// teaches again, even with the pointer resting in the bottom zone
    /// (where the Browser's strip sits) and after the full-screen landing.
    func testASecondWindowsFirstFullScreenEntryStaysCleanWithThePointerInTheBottomZone() async {
        ViewerContentView.resetTeachOnceForTesting(taught: false)
        let first = makeContent()
        first.windowMode = .fullscreen
        first.fullScreenDidEnter()
        XCTAssertTrue(first.teachOnceActiveForTesting, "the first window of the run teaches")
        first.fireTeachOnceExpiryForTesting()
        first.windowMode = .windowed

        // Two more windows, as opened from the Browser; a pointer at rest
        // 20 pt above the bottom edge sends no mouse-move.
        for _ in 0..<2 {
            let next = makeContent()
            next.cursorLocationOverrideForTesting = NSPoint(x: 720, y: 20)
            next.windowMode = .fullscreen
            next.layoutSubtreeIfNeeded()
            next.fullScreenDidEnter()
            XCTAssertFalse(next.teachOnceActiveForTesting, "teach-once is a per-run flag")
            XCTAssertEqual(next.alphaForTesting(.toolbar), 0, "no capsule without a pointer move")
            XCTAssertFalse(next.navigationPositionOverlayForTesting.isHeldByCapsule)
            let gone = await waitUntil(4) { !self.pillShown(next) }
            XCTAssertTrue(gone, "the pill fades on its own 2 s clock")
            XCTAssertEqual(next.alphaForTesting(.toolbar), 0)
        }
    }

    // MARK: Pill in a window (spec 24 §5.1)

    private func mouseMoved(in content: ViewerContentView, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    }

    func testInAWindowThePillShowsOnPointerMovementAndFadesAfterTwoSeconds() async throws {
        let content = makeContent(mode: .windowed)
        let pill = content.navigationPositionOverlayForTesting
        pill.fadeOutNow()
        let gone = await waitUntil { !self.pillShown(content) }
        XCTAssertTrue(gone, "the photo-change pill faded")

        content.mouseMoved(with: try mouseMoved(in: content, at: NSPoint(x: 700, y: 450)))
        XCTAssertTrue(pillShown(content), "pointer movement shows the pill")
        try await Task.sleep(for: .milliseconds(1200))
        content.mouseMoved(with: try mouseMoved(in: content, at: NSPoint(x: 710, y: 455)))
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(pillShown(content), "each movement restarts the 2 s")
        let faded = await waitUntil(3) { !self.pillShown(content) }
        XCTAssertTrue(faded, "fades after 2 s without movement")
    }

    func testPointerMovementShowsNothingWithAutoHideOffOrBeforeAPhoto() throws {
        let off = makeContent(mode: .windowed, autoHides: false)
        let before = off.navigationPositionOverlayForTesting
        off.mouseMoved(with: try mouseMoved(in: off, at: NSPoint(x: 700, y: 450)))
        XCTAssertTrue(pillShown(off), "auto-hide off: the pill is simply always on")
        XCTAssertNotNil(before)

        let empty = ViewerContentView(services: .makeDefault())
        empty.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        empty.navigationPositionOverlayForTesting.autoHidesOverrideForTesting = true
        empty.windowMode = .windowed
        empty.mouseMoved(with: try mouseMoved(in: empty, at: NSPoint(x: 700, y: 450)))
        XCTAssertFalse(pillShown(empty), "no photo, no pill")
    }

    func testInFullScreenPointerMovementOutsideTheBottomZoneDoesNotShowThePill() async throws {
        let content = makeContent(mode: .fullscreen)
        let pill = content.navigationPositionOverlayForTesting
        pill.fadeOutNow()
        let gone = await waitUntil { !self.pillShown(content) }
        XCTAssertTrue(gone)
        content.mouseMoved(with: try mouseMoved(in: content, at: NSPoint(x: 700, y: 450)))
        XCTAssertFalse(pillShown(content), "full screen keeps the capsule rule")
    }

    func testLeavingFullScreenEndsTheLesson() {
        ViewerContentView.resetTeachOnceForTesting(taught: false)
        let content = makeContent()
        content.windowMode = .fullscreen
        XCTAssertTrue(content.teachOnceActiveForTesting)
        content.windowMode = .windowed
        XCTAssertFalse(content.teachOnceActiveForTesting)
    }

    // MARK: Pill with the capsule

    func testThePillShowsWhileTheCapsuleShowsAndHidesWithIt() async {
        let content = makeContent(mode: .fullscreen)
        let pill = content.navigationPositionOverlayForTesting
        // The pill's own 2.0 s timer has not run; let it go first.
        pill.fadeOutNow()
        let gone = await waitUntil { !self.pillShown(content) }
        XCTAssertTrue(gone)

        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))   // bottom zone
        XCTAssertEqual(content.alphaForTesting(.toolbar), 1)
        XCTAssertTrue(pill.isHeldByCapsule)
        XCTAssertTrue(pillShown(content), "pill shows while the capsule shows")

        // It stays past its own idle timeout while the capsule is up.
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(pillShown(content), "no idle fade while held")

        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 500))   // away
        content.forceExitGraceFireForTesting(.toolbar)
        XCTAssertEqual(content.alphaForTesting(.toolbar), 0)
        XCTAssertFalse(pill.isHeldByCapsule)
        let hidden = await waitUntil { !self.pillShown(content) }
        XCTAssertTrue(hidden, "pill hides with the capsule")
    }

    func testAPhotoChangeWhileHeldDoesNotScheduleAFade() async {
        let content = makeContent(mode: .fullscreen)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        let pill = content.navigationPositionOverlayForTesting
        pill.show(index: 4, total: 41, filename: "IMG_0002.jpg")
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(pillShown(content))
    }

    func testWithAutoHideOffThePillStaysWhateverTheCapsuleDoes() async {
        let content = makeContent(mode: .fullscreen, autoHides: false)
        let pill = content.navigationPositionOverlayForTesting
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        XCTAssertTrue(pill.isHeldByCapsule)
        XCTAssertTrue(pillShown(content))
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 500))
        content.forceExitGraceFireForTesting(.toolbar)
        XCTAssertFalse(pill.isHeldByCapsule)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(pillShown(content), "held open by the pref: the capsule never hides it")
    }

    // MARK: Spec 24 vectors 1 and 4 on a fresh store (no test override)

    func testFreshStoreDefaultsToAutoHideWithAnIdleFadeOfTwoSeconds() {
        Prefs.resetAll()
        let pill = makeContent(mode: .fullscreen, autoHides: nil).navigationPositionOverlayForTesting
        XCTAssertTrue(pill.autoHides, "no stored value: the pill auto-hides")
        XCTAssertEqual(NavigationPositionOverlayView.idleTimeout, 2.0)
        XCTAssertEqual(NavigationFeedbackState.defaultOverlayIdleTimeout, 2.0)
    }

    func testVector1FreshStoreFullScreenEndsWithOnlyThePhoto() async {
        Prefs.resetAll()
        ViewerContentView.resetTeachOnceForTesting(taught: false)
        let content = makeContent(mode: .fullscreen, autoHides: nil)
        XCTAssertEqual(content.alphaForTesting(.toolbar), 1, "teach-once shows the capsule")
        XCTAssertTrue(pillShown(content), "and the pill")
        content.fireTeachOnceExpiryForTesting()
        let hidden = await waitUntil(4) { !self.pillShown(content) }
        XCTAssertTrue(hidden, "the pill is gone after the lesson, on the real pref")
        XCTAssertEqual(content.alphaForTesting(.toolbar), 0)
        XCTAssertEqual(content.alphaForTesting(.inspector), 0)
    }

    func testVector4FreshStorePhotoChangeShowsThePillForTwoSecondsWithoutTheCapsule() async {
        Prefs.resetAll()
        ViewerContentView.resetTeachOnceForTesting(taught: true)
        let content = makeContent(mode: .fullscreen, autoHides: nil)
        let pill = content.navigationPositionOverlayForTesting
        // The pill from setup fades first; then a key press changes the photo.
        _ = await waitUntil(4) { !self.pillShown(content) }
        pill.show(index: 4, total: 41, filename: "IMG_0002.jpg")
        XCTAssertTrue(pillShown(content), "the pill shows on the photo change")
        XCTAssertEqual(content.alphaForTesting(.toolbar), 0, "the capsule does not show")
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertTrue(pillShown(content), "still up before 2.0 s (the old 1.2 s would be gone)")
        let hidden = await waitUntil(4) { !self.pillShown(content) }
        XCTAssertTrue(hidden, "then it fades")
        XCTAssertEqual(content.alphaForTesting(.toolbar), 0)
    }

    func testAWindowNeverHoldsThePill() {
        let content = makeContent(mode: .windowed)
        XCTAssertFalse(content.navigationPositionOverlayForTesting.isHeldByCapsule)
    }
}

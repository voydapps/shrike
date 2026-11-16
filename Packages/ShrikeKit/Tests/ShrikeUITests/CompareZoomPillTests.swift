//
//  CompareZoomPillTests.swift
//  ShrikeUITests
//
//  Spec 28 §14 Compare: each pane's zoom pill (text, spoken form, place,
//  hidden with no photo) and the broken pane keeping its controls.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class CompareZoomPillTests: XCTestCase {

    func testTextAndSpokenForm() {
        XCTAssertEqual(CompareZoomPill.text(pixelScale: 0.24), "24 %")
        XCTAssertEqual(CompareZoomPill.text(pixelScale: 1), "100 %")
        XCTAssertEqual(CompareZoomPill.text(pixelScale: 2.004), "200 %")
        XCTAssertEqual(CompareZoomPill.spoken(pixelScale: 0.24), "Zoom 24 percent")
        XCTAssertEqual(CompareZoomPill.percent(pixelScale: 0.125), 13)
    }

    func testHiddenWithoutAPhoto() {
        XCTAssertNil(CompareZoomPill.shownScale(hasImage: false, pixelScale: 1))
        XCTAssertNil(CompareZoomPill.shownScale(hasImage: true, pixelScale: .nan))
        XCTAssertEqual(CompareZoomPill.shownScale(hasImage: true, pixelScale: 0.5), 0.5)
    }

    func testPillLookAndPlace() {
        let pane = ComparePaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        pane.layoutSubtreeIfNeeded()
        XCTAssertTrue(pane.zoomPill.isHidden, "no photo yet")
        pane.zoomPill.setPixelScale(0.24)
        pane.zoomPill.isHidden = false
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.zoomPill.text, "24 %")
        XCTAssertEqual(pane.zoomPill.accessibilityLabel(), "Zoom 24 percent")
        XCTAssertEqual(pane.zoomPill.fontForTesting?.pointSize, ChromeTypography.size(11))
        XCTAssertTrue(pane.zoomPill.isKind(of: HUDSurfaceView.self), "the viewer zoom HUD's surface")
        let frame = pane.zoomPill.frame
        XCTAssertEqual(frame.maxX, 600 - CompareZoomPill.inset, accuracy: 0.5, "right edge")
        XCTAssertGreaterThanOrEqual(frame.minY, pane.footer.frame.maxY, "above the footer strip")
        XCTAssertLessThan(frame.minY, pane.footer.frame.maxY + 20, "at the bottom")
        XCTAssertGreaterThan(frame.width, 20)
    }

    /// Spec 28 §14: a broken pane keeps Keep photo and the arrows, in place and
    /// working; the error text stays centred; there is no zoom to show.
    func testBrokenPaneKeepsItsControls() {
        let pane = ComparePaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var previous = 0, next = 0, keep = 0
        pane.onPrevious = { previous += 1 }
        pane.onNext = { next += 1 }
        pane.onKeep = { keep += 1 }
        pane.isFocused = true   // the controls show on the focused or hovered pane
        pane.setReference(false, canPrevious: true, canNext: true)
        pane.layoutSubtreeIfNeeded()
        let before = pane.paneControlsForTesting.map { $0.convert($0.bounds, to: pane) }
        pane.showError(CompareFooter.errorText("broken.jpg"))
        pane.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.errorLabel.stringValue, "Can't open “broken.jpg”.")
        XCTAssertFalse(pane.errorLabel.isHidden)
        XCTAssertEqual(pane.errorLabel.frame.midX, 300, accuracy: 1)
        XCTAssertTrue(pane.zoomPill.isHidden)
        let controls = pane.paneControlsForTesting
        XCTAssertEqual(controls.map { $0.convert($0.bounds, to: pane) }, before, "in their place")
        for control in controls {
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(control.isEnabled)
            control.performClick(nil)
        }
        XCTAssertEqual([previous, keep, next], [1, 1, 1])
    }
}

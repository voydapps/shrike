//
//  OneHistogram028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-13 (one histogram at a time) and P3-3 (a photo that cannot be
//  read has no histogram).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class OneHistogram028Tests: XCTestCase {

    private var saved = false

    override func setUp() async throws { saved = Prefs.viewerHistogramVisible }
    override func tearDown() async throws { Prefs.viewerHistogramVisible = saved }

    private func makeContent() -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.animatesPanelFades = false
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        return content
    }

    func testInspectorOpenHidesTheFloatingHistogramAndClosingBringsItBack() {
        Prefs.viewerHistogramVisible = true
        let content = makeContent()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "inspector closed: the HUD shows")
        content.setWindowedInspectorShown(true)
        XCTAssertFalse(content.histogramOverlayVisibleForTesting, "inspector open: one histogram, in the inspector")
        XCTAssertTrue(content.inspectorForTesting.histogramSectionShownForTesting)
        content.setWindowedInspectorShown(false)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        XCTAssertFalse(content.inspectorForTesting.histogramSectionShownForTesting, "toggled off: both gone")
    }

    /// 0.2.10 on-screen check item 5: the canvas is at alpha 0 behind the error card
    /// and the wheel must still reach it (it did not: the wheel could not leave a broken photo).
    func testWheelStepsFromABrokenPhotoWithAGoodOneBefore() throws {
        let content = makeContent()
        let window = NSWindow(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        defer { window.orderOut(nil) }
        let savedWheel = Prefs.scrollWheelNavigates
        Prefs.scrollWheelNavigates = true
        defer { Prefs.scrollWheelNavigates = savedWheel }
        var steps: [Bool] = []
        content.onCanvasNavigate = { steps.append($0) }
        content.setImage(SaveFlowTests.image(), index: 0, total: 3)
        content.showDecodeError()
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                       wheel1: -1, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg.flags = []   // the real keyboard state must not leak into the event
        cg.timestamp = CGEventTimestamp(2_000_000_000)
        content.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(steps, [true], "the wheel steps to the next photo from the error card")
        // A zoomed-in photo before the broken one must not turn the wheel into a pan.
        steps = []
        content.clearDecodeErrorForTesting()
        content.imageView.setPixelScale(content.imageView.pixelScale * 4, anchor: .zero)
        try XCTSkipIf(content.imageView.isAtFit, "no Metal device: cannot zoom")
        content.showDecodeError()
        let cg2 = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                        wheel1: -1, wheel2: 0, wheel3: 0))
        cg2.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)
        cg2.flags = []
        cg2.timestamp = CGEventTimestamp(3_000_000_000)
        content.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg2)))
        XCTAssertEqual(steps, [true], "zoomed in before: the wheel still steps off the card")
    }

    func testDecodeErrorHidesBothHistogramsAndTheNextPhotoRestoresThem() {
        Prefs.viewerHistogramVisible = true
        let content = makeContent()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        content.showDecodeError()
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        XCTAssertFalse(content.inspectorForTesting.histogramSectionShownForTesting)
        content.clearDecodeErrorForTesting()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        XCTAssertTrue(content.inspectorForTesting.histogramSectionShownForTesting)
    }

    /// 0.2.10 audit item 5: the good photo before a broken one must not show behind the card.
    func testErrorCardEmptiesTheCanvasAndTheNextPhotoBringsItBack() {
        let content = makeContent()
        content.setImage(SaveFlowTests.image(), index: 0, total: 3)
        XCTAssertEqual(content.imageView.alphaValue, 1)
        content.showDecodeError()
        XCTAssertEqual(content.imageView.alphaValue, 0, "the old photo is not drawn behind the card")
        let behind = content.imageView.canvasColor.resolvedCGColor(for: content.effectiveAppearance)
        XCTAssertEqual(content.layer?.backgroundColor, behind, "the canvas colour shows behind the card")
        XCTAssertTrue(content.isShowingDecodeError)
        content.showDecodeError(nextEnabled: false)   // a second broken photo in a row
        XCTAssertEqual(content.imageView.alphaValue, 0)
        content.setImage(SaveFlowTests.image(), index: 2, total: 3)
        XCTAssertEqual(content.imageView.alphaValue, 1, "the next readable photo is drawn again")
        XCTAssertFalse(content.isShowingDecodeError)
        content.showDecodeError()
        content.clearDecodeErrorForTesting()
        XCTAssertEqual(content.imageView.alphaValue, 1)
    }

    func testInspectorPositionFollowsAPhotoThatFailedToOpen() {
        let content = makeContent()
        content.updateInspectorPosition(index: 0, total: 20)
        XCTAssertEqual(content.inspectorForTesting.indexSummaryForTesting, "1 of 20")
    }

    func testErrorCardMetrics() {
        XCTAssertEqual(ErrorOverlayView.cardWidth, 420)
        XCTAssertEqual(ErrorOverlayView.glyphPointSize, 36)
        XCTAssertEqual(ErrorOverlayView.headingFontSize, 15)
        XCTAssertEqual(ErrorOverlayView.bodyFontSize, 13)
        XCTAssertEqual(ErrorOverlayView.message, "This file appears to be damaged or isn't a supported format.")
    }
}

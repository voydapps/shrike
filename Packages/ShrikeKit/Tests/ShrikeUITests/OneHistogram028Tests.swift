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

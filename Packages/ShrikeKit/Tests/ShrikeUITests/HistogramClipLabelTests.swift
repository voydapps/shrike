//
//  HistogramClipLabelTests.swift
//  ShrikeUITests
//
//  User test 8 / spec 24 §3.3: the end-bin spike reads as a bug because a
//  3 % and an 18 % spike look the same. The plot scales by the inner bins
//  (bins 1-254), caps the end bins at the plot height, lights the clip
//  triangle, and writes the clipped share next to it. The × hides the
//  histogram.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class HistogramClipLabelTests: XCTestCase {

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    private func bins(_ values: [Int: UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 256)
        for (i, v) in values { out[i] = v }
        return out
    }

    func testClipLabelText() {
        XCTAssertEqual(HistogramPlot.clipLabel(percent: 12.0), "12 %")
        XCTAssertEqual(HistogramPlot.clipLabel(percent: 17.6), "18 %")
        XCTAssertEqual(HistogramPlot.clipLabel(percent: 0.7), "0.7 %")
        XCTAssertEqual(HistogramPlot.clipLabel(percent: 2.14), "2.1 %")
        XCTAssertNil(HistogramPlot.clipLabel(percent: 0.5), "at the threshold: no label")
        XCTAssertNil(HistogramPlot.clipLabel(percent: 0.3))
        XCTAssertNil(HistogramPlot.clipLabel(percent: 0))
    }

    /// A huge bin 255 neither sets the scale nor leaves the plot: the
    /// inner bins decide the scale, the end bin is capped at full height.
    func testEndBinsDoNotSetTheScaleAndAreCapped() {
        let data = HistogramData(
            red: bins([100: 40, 255: 2_000]), green: bins([100: 30]), blue: bins([:]),
            luminance: bins([100: 35]), pixelCount: 10_000, sampleWidth: 100, sampleHeight: 100,
            anyChannelHighlightPixels: 2_000)
        let scale = HistogramPlot.scaleMax(data, mode: .rgb)
        XCTAssertEqual(scale, 40, "bins 0 and 255 are left out of the maximum")
        let heights = HistogramPlot.heights(data.red, scaleMax: scale)
        XCTAssertEqual(heights[255], 1, "the end bin is capped at the plot height")
        XCTAssertEqual(heights[100], 1)
        XCTAssertTrue(HistogramPlot.showsHighlightClip(data), "the triangle is lit")
        XCTAssertEqual(HistogramPlot.clipLabel(percent: data.anyChannelHighlightsClippedPercent), "20 %")
        // A pure black-and-white picture still draws something.
        let bw = HistogramData(red: bins([0: 50, 255: 50]), green: bins([:]), blue: bins([:]),
                               luminance: bins([:]), pixelCount: 100, sampleWidth: 10, sampleHeight: 10)
        XCTAssertEqual(HistogramPlot.scaleMax(bw, mode: .rgb), 50)
    }

    func testTheCrossHidesTheHistogramAndSitsClearOfTheClipMark() throws {
        Prefs.viewerHistogramVisible = true
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        _ = content.histogramOverlayFrameForTesting()
        let overlay = try XCTUnwrap(content.histogramOverlayIfBuiltForTesting)
        let cross = overlay.closeButton
        XCTAssertEqual(cross.accessibilityLabel(), "Hide Histogram")
        XCTAssertTrue(cross.toolTip?.hasPrefix("Hide Histogram") ?? false, "\(cross.toolTip ?? "")")
        XCTAssertTrue(cross.toolTip?.contains("⇧⌘J") ?? false, "tooltip names the key")
        XCTAssertEqual(cross.frame.width, 28)
        XCTAssertEqual(overlay.plotView.highlightMarkTrailingInset, 24, "the clip mark moves left of the ×")
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        cross.performClick(nil)
        XCTAssertFalse(Prefs.viewerHistogramVisible)
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
    }
}

//
//  HistogramViewTests.swift
//  ShrikeUITests
//
//  Clip marks, the mode chip and its
//  pref, the scale rule, the VoiceOver value, latest-request-wins, the
//  edit-mode throttle, placement, and the main-thread cost of a request
//  during fast navigation. Temp folders only.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class HistogramViewTests: XCTestCase {

    private var tempDir: URL!
    private var savedVisible = false
    private var savedMode = "rgbl"

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-histogram-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedVisible = Prefs.viewerHistogramVisible
        savedMode = Prefs.viewerHistogramMode
    }

    override func tearDown() async throws {
        Prefs.viewerHistogramVisible = savedVisible
        Prefs.viewerHistogramMode = savedMode
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Black frame with a white square in the middle.
    private func blackFrameWhiteSquare(size: Int = 400) -> CGImage {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: size / 4, y: size / 4, width: size / 2, height: size / 2))
        return ctx.makeImage()!
    }

    private func writeJPEG(_ image: CGImage, _ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func bins(_ values: [Int: UInt32]) -> [UInt32] {
        var b = [UInt32](repeating: 0, count: 256)
        for (k, v) in values { b[k] = v }
        return b
    }

    // MARK:

    func testBlackFrameWhiteSquareShowsBothClipMarks() async throws {
        let url = try writeJPEG(blackFrameWhiteSquare(), "square.jpg")
        let controller = HistogramController()
        controller.isWanted = { true }
        controller.imageShown(blackFrameWhiteSquare(size: 8), url: url)
        await controller.waitForIdle()
        let data = try XCTUnwrap(controller.state.data)
        XCTAssertTrue(HistogramPlot.showsShadowClip(data))
        XCTAssertTrue(HistogramPlot.showsHighlightClip(data))
        XCTAssertLessThanOrEqual(max(data.sampleWidth, data.sampleHeight), 1024)
        XCTAssertFalse(controller.state.isStale)
        XCTAssertFalse(controller.state.noData)
    }

    // MARK:

    func testModeChipCyclesAndPersists() {
        Prefs.viewerHistogramMode = "rgbl"
        let controller = HistogramController()
        let overlay = HistogramOverlayView()
        controller.onChange = { overlay.apply($0) }
        overlay.onCycleMode = { controller.cycleMode() }
        overlay.apply(controller.state)
        XCTAssertEqual(overlay.modeChip.title, "RGB + L")
        overlay.modeChip.performClick(nil)
        XCTAssertEqual(overlay.modeChip.title, "L")
        XCTAssertEqual(Prefs.viewerHistogramMode, "l")
        // "After relaunch": a new controller reads the stored mode.
        XCTAssertEqual(HistogramController().state.mode, .l)
        overlay.modeChip.performClick(nil)
        XCTAssertEqual(Prefs.viewerHistogramMode, "rgb")
        XCTAssertEqual(overlay.modeChip.title, "RGB")
    }

    func testUnknownStoredModeReadsDefault() {
        Prefs.viewerHistogramMode = "bogus"
        XCTAssertEqual(HistogramMode.current, .rgbl)
    }

    // MARK: Fast navigation stays off the main thread

    func testFiftyFastRequestsCostLittleMainThreadTimeAndOnlyTheLastComputes() async throws {
        var urls: [URL] = []
        for i in 0..<5 { urls.append(try writeJPEG(blackFrameWhiteSquare(size: 1600), "n\(i).jpg")) }
        let image = blackFrameWhiteSquare(size: 16)
        let controller = HistogramController()
        controller.isWanted = { true }
        var worst: Double = 0
        for i in 0..<50 {
            let start = CFAbsoluteTimeGetCurrent()
            controller.markStale()
            controller.imageShown(image, url: urls[i % urls.count])
            worst = max(worst, CFAbsoluteTimeGetCurrent() - start)
            // One vsync apart, like a held arrow key: a newer request
            // always arrives inside the 30 ms settle.
            try await Task.sleep(for: .milliseconds(8))
        }
        XCTAssertLessThan(worst * 1000, 16, "a histogram request blocked the main thread")
        await controller.waitForIdle()
        XCTAssertEqual(controller.completedCount, 1, "skipped images were decoded")
        XCTAssertNotNil(controller.state.data)
    }

    // MARK: Scale, states, VoiceOver

    func testScaleIgnoresSpikesAtZeroAnd255() {
        let data = HistogramData(
            red: bins([0: 10_000, 100: 50, 255: 9_000]), green: bins([120: 80]),
            blue: bins([:]), luminance: bins([110: 60]),
            pixelCount: 20_000, sampleWidth: 200, sampleHeight: 100)
        XCTAssertEqual(HistogramPlot.scaleMax(data, mode: .rgbl), 80)
        XCTAssertEqual(HistogramPlot.scaleMax(data, mode: .l), 60)
        let h = HistogramPlot.heights(data.red, scaleMax: 80)
        XCTAssertEqual(h[0], 1, "the spike clips at the top")
        XCTAssertEqual(h[100], 50.0 / 80.0, accuracy: 0.0001)
    }

    func testClipMarksNeedMoreThanATenthOfAPercent() {
        let few = HistogramData(red: bins([:]), green: bins([:]), blue: bins([:]), luminance: bins([:]),
                                pixelCount: 10_000, sampleWidth: 100, sampleHeight: 100,
                                anyChannelShadowPixels: 10, anyChannelHighlightPixels: 11)
        XCTAssertFalse(HistogramPlot.showsShadowClip(few))
        XCTAssertTrue(HistogramPlot.showsHighlightClip(few))
    }

    func testVoiceOverValue() {
        let data = HistogramData(red: bins([:]), green: bins([:]), blue: bins([:]),
                                 luminance: bins([0: 40, 128: 900, 255: 60]),
                                 pixelCount: 1000, sampleWidth: 10, sampleHeight: 100,
                                 anyChannelShadowPixels: 4, anyChannelHighlightPixels: 21)
        let value = HistogramPlot.accessibilityValue(HistogramDisplayState(data: data))
        XCTAssertEqual(value, "Shadows clipped 0.4 percent. Highlights clipped 2.1 percent. "
                       + "Average brightness 51 percent.")
        let view = HistogramPlotView()
        view.state = HistogramDisplayState(data: data)
        XCTAssertEqual(view.accessibilityRole(), .image)
        XCTAssertEqual(view.accessibilityLabel(), "Histogram")
        XCTAssertEqual(view.accessibilityValue() as? String, value)
    }

    func testStaleDimsToFortyPercentAndNoDataHidesBins() async throws {
        let url = try writeJPEG(blackFrameWhiteSquare(), "a.jpg")
        let controller = HistogramController()
        controller.isWanted = { true }
        let view = HistogramPlotView()
        controller.onChange = { view.state = $0 }
        controller.imageShown(blackFrameWhiteSquare(size: 8), url: url)
        await controller.waitForIdle()
        XCTAssertEqual(view.alphaValue, 1)
        controller.markStale()
        XCTAssertTrue(controller.state.isStale)
        XCTAssertNotNil(controller.state.data, "the previous histogram stays")
        XCTAssertEqual(view.alphaValue, 0.4, accuracy: 0.001)
        controller.showNoData()
        XCTAssertTrue(controller.state.noData)
        XCTAssertNil(controller.state.data)
        XCTAssertEqual(view.accessibilityValue() as? String, "No data")
    }

    func testNothingComputesWhileHiddenAndTheDeferredSourceRunsOnShow() async throws {
        let url = try writeJPEG(blackFrameWhiteSquare(), "b.jpg")
        var wanted = false
        let controller = HistogramController()
        controller.isWanted = { wanted }
        controller.imageShown(blackFrameWhiteSquare(size: 8), url: url)
        await controller.waitForIdle()
        XCTAssertEqual(controller.completedCount, 0)
        wanted = true
        controller.wantedDidChange()
        await controller.waitForIdle()
        XCTAssertEqual(controller.completedCount, 1)
    }

    func testEditRendersAreThrottledTo100ms() async throws {
        let controller = HistogramController()
        controller.isWanted = { true }
        let image = blackFrameWhiteSquare(size: 64)
        let start = ContinuousClock.now
        for _ in 0..<10 {
            controller.editImageRendered(image)
            try await Task.sleep(for: .milliseconds(10))
        }
        await controller.waitForIdle()
        try await Task.sleep(for: .milliseconds(150))
        await controller.waitForIdle()
        let elapsed = ContinuousClock.now - start
        // ≥ 100 ms apart: at most one per 100 ms window plus the trailing one.
        let windows = Int(elapsed / .milliseconds(100)) + 1
        XCTAssertGreaterThanOrEqual(controller.completedCount, 1)
        XCTAssertLessThanOrEqual(controller.completedCount, windows)
        XCTAssertLessThan(controller.completedCount, 10)
    }

    // MARK: Placement and toggle

    func testOverlayPlacementAndToggleWindowed() {
        Prefs.viewerHistogramVisible = false
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        XCTAssertTrue(Prefs.viewerHistogramVisible)
        XCTAssertTrue(content.isHistogramShown)
        let frame = content.histogramOverlayFrameForTesting()
        XCTAssertEqual(frame.size, NSSize(width: 320, height: 180))
        XCTAssertEqual(frame.maxX, 1200 - 16, accuracy: 0.5)
        XCTAssertEqual(frame.minY, content.imageView.frame.minY + 12, accuracy: 0.5)
        content.toggleHistogramOverlay()
        XCTAssertFalse(Prefs.viewerHistogramVisible)
    }

    func testFullScreenOverlayStaysUntilToggledOff() {
        Prefs.viewerHistogramVisible = true
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        XCTAssertEqual(content.histogramOverlayFrameForTesting().minY, 16, accuracy: 0.5)
        content.animatesPanelFades = false
        content.forceIdleFireForTesting()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "no idle fade: a toggle stays on")
        content.toggleHistogramOverlay()
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "shows on every press")
    }
}

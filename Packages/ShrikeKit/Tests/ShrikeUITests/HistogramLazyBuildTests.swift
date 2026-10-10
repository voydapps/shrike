//
//  HistogramLazyBuildTests.swift
//  ShrikeUITests
//
//  The floating histogram is built on its first show, not in
//  ViewerContentView.init. Its place and size are the same as when it was
//  built up front (the frames below were read from the eager build,
//  commit 2eed9a1, in the same windows).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeUI

@MainActor
final class HistogramLazyBuildTests: XCTestCase {

    private var dir: URL!
    private var savedHistogram = false
    private var savedInspector = false
    private var savedFilmstrip = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-histlazy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedHistogram = Prefs.viewerHistogramVisible
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        Prefs.viewerInspectorVisibleWindowed = false
        Prefs.filmstripVisibleInWindowed = true
        // The macOS 14 / 15 geometry, also used on
        // macOS 26. GlassHUDTests covers the glass geometry.
        HUDGlass.forceFallbackForTesting = true
    }

    override func tearDown() async throws {
        HUDGlass.forceFallbackForTesting = false
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerHistogramVisible = savedHistogram
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
    }

    private func viewer(_ size: NSSize) throws -> ViewerWindow {
        let url = dir.appendingPathComponent("a.jpg")
        if !FileManager.default.fileExists(atPath: url.path) { try SaveFlowTests.writeImage(url, type: .jpeg) }
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        viewer.setContentSize(size)
        viewer.markDisplayedForTesting(0)
        viewer.contentView?.layoutSubtreeIfNeeded()
        return viewer
    }

    private func describe(_ r: NSRect) -> String {
        String(format: "%.1f %.1f %.1f %.1f", r.minX, r.minY, r.width, r.height)
    }

    /// Frames of the shown overlay: open with the pref on, and turned on
    /// after the window opened, in a small and a large window; full
    /// screen; beside the edit panel.
    private func frames() throws -> [String: NSRect] {
        var out: [String: NSRect] = [:]
        for (name, size) in [("small", NSSize(width: 800, height: 550)), ("large", NSSize(width: 1800, height: 1200))] {
            Prefs.viewerHistogramVisible = true
            let open = try viewer(size)
            open.contentRootForTesting.layoutSubtreeIfNeeded()
            XCTAssertTrue(open.contentRootForTesting.histogramOverlayVisibleForTesting)
            out["\(name)-open"] = open.contentRootForTesting.histogramOverlayFrameForTesting()
            open.close()

            Prefs.viewerHistogramVisible = false
            let later = try viewer(size)
            later.contentRootForTesting.toggleHistogramOverlay()
            XCTAssertTrue(later.contentRootForTesting.histogramOverlayVisibleForTesting)
            out["\(name)-toggled"] = later.contentRootForTesting.histogramOverlayFrameForTesting()
            later.close()
        }

        Prefs.viewerHistogramVisible = true
        let full = ViewerContentView(services: .makeDefault())
        full.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        full.windowMode = .fullscreen
        full.layoutSubtreeIfNeeded()
        out["fullscreen"] = full.histogramOverlayFrameForTesting()

        Prefs.viewerHistogramVisible = false
        let edit = try viewer(NSSize(width: 1000, height: 700))
        let content = edit.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .color)
        content.toggleHistogramOverlay()
        content.layoutSubtreeIfNeeded()
        out["edit-toggled"] = content.histogramOverlayFrameForTesting()
        content.editModeController.finalizeExit()
        content.layoutSubtreeIfNeeded()
        out["edit-after"] = content.histogramOverlayFrameForTesting()
        edit.close()

        for (k, v) in out.sorted(by: { $0.key < $1.key }) { print("[histogram] \(k) \(describe(v))") }
        return out
    }

    func testSameFramesAsTheEagerBuild() throws {
        // Read from the earlier eager build, same windows and prefs.
        // The histogram is smaller in small canvases (at most
        // 0.36 × width − 112 pt): the 800 and 1000 pt windows changed
        // size (same corner); large windows and full screen did not.
        let before: [String: NSRect] = [
            "small-open": NSRect(x: 608, y: 92, width: 176, height: 99),
            "small-toggled": NSRect(x: 608, y: 92, width: 176, height: 99),
            "large-open": NSRect(x: 1464, y: 92, width: 320, height: 180),
            "large-toggled": NSRect(x: 1464, y: 92, width: 320, height: 180),
            "fullscreen": NSRect(x: 868, y: 16, width: 320, height: 180),
            // Edit mode hides the docked strip, so the
            // histogram drops to the 16 pt bottom inset while editing.
            "edit-toggled": NSRect(x: 452, y: 16, width: 248, height: 139.5),
            "edit-after": NSRect(x: 736, y: 92, width: 248, height: 139.5),
        ]
        let now = try frames()
        XCTAssertEqual(Set(now.keys), Set(before.keys))
        for (name, frame) in before {
            let got = try XCTUnwrap(now[name])
            XCTAssertEqual(got.minX, frame.minX, accuracy: 0.5, name)
            XCTAssertEqual(got.minY, frame.minY, accuracy: 0.5, name)
            XCTAssertEqual(got.width, frame.width, accuracy: 0.5, name)
            XCTAssertEqual(got.height, frame.height, accuracy: 0.5, name)
        }
    }

    func testBuiltOnTheFirstShowOnly() {
        Prefs.viewerHistogramVisible = false
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.layoutSubtreeIfNeeded()
        XCTAssertNil(content.histogramOverlayIfBuiltForTesting, "no histogram view after init")
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)

        // Mode changes, the idle fade and the empty state build nothing.
        content.windowMode = .fullscreen
        content.animatesPanelFades = false
        content.forceIdleFireForTesting()
        content.kickIdleTimer()
        content.windowMode = .windowed
        content.setEmptyStateChrome(true)
        XCTAssertTrue(content.emptyStateChromeHiddenForTesting.histogram)
        content.setEmptyStateChrome(false)
        XCTAssertNil(content.histogramOverlayIfBuiltForTesting)

        // The first show builds one; later toggles reuse it.
        content.toggleHistogramOverlay()
        let first = content.histogramOverlayIfBuiltForTesting
        XCTAssertNotNil(first)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        content.toggleHistogramOverlay()
        XCTAssertTrue(content.histogramOverlayIfBuiltForTesting === first)
        XCTAssertEqual(content.subviews.filter { $0 is HistogramOverlayView }.count, 1)
        content.toggleHistogramOverlay()
    }

    /// Opened with the pref on, the overlay is there from the start (as
    /// before); the empty state set before a first show still hides it.
    func testPrefOnAtOpenAndEmptyStateCarriedOver() {
        Prefs.viewerHistogramVisible = true
        let shown = ViewerContentView(services: .makeDefault())
        XCTAssertNotNil(shown.histogramOverlayIfBuiltForTesting)
        // Shown once the canvas has a real size (a view with no
        // size lays out a tiny canvas, where the histogram hides).
        shown.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        shown.layoutSubtreeIfNeeded()
        XCTAssertTrue(shown.histogramOverlayVisibleForTesting)

        Prefs.viewerHistogramVisible = false
        let empty = ViewerContentView(services: .makeDefault())
        empty.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        empty.setEmptyStateChrome(true)
        empty.toggleHistogramOverlay()
        let overlay = empty.histogramOverlayIfBuiltForTesting
        XCTAssertNotNil(overlay)
        XCTAssertTrue(overlay?.isHidden ?? false, "the empty state still hides it")
        empty.setEmptyStateChrome(false)
        XCTAssertFalse(overlay?.isHidden ?? true)
        empty.toggleHistogramOverlay()
    }

    /// While Crop is the tool, the floating histogram
    /// steps aside (it sat beside the crop frame's bottom-right handle at
    /// 1200 × 800). The setting stays on; another tool or leaving edit
    /// mode brings it back.
    func testCropToolMovesTheFloatingHistogramAside() throws {
        Prefs.viewerHistogramVisible = true
        let window = try viewer(NSSize(width: 1200, height: 800))
        defer { window.close() }
        let content = window.contentRootForTesting
        content.animatesPanelFades = false
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        for round in 0..<2 {
            content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
            XCTAssertTrue(content.isCropToolActive)
            XCTAssertFalse(content.histogramOverlayVisibleForTesting, "round \(round): hidden during Crop")
            XCTAssertTrue(content.isHistogramShown, "the setting stays on")
            content.editModeController.selectTool(.color)
            XCTAssertTrue(content.histogramOverlayVisibleForTesting, "back with another tool")
            content.editModeController.selectTool(.crop)
            XCTAssertFalse(content.histogramOverlayVisibleForTesting)
            content.editModeController.finalizeExit()
            XCTAssertFalse(content.isCropToolActive)
            XCTAssertTrue(content.histogramOverlayVisibleForTesting, "back after edit mode")
        }
    }

    /// The histogram data reaches an overlay built after it was computed.
    func testLateOverlayGetsTheCurrentState() {
        Prefs.viewerHistogramVisible = false
        let content = ViewerContentView(services: .makeDefault())
        content.histogram.showNoData()
        content.toggleHistogramOverlay()
        let overlay = content.histogramOverlayIfBuiltForTesting
        XCTAssertNotNil(overlay)
        XCTAssertEqual(overlay?.stateForTesting, content.histogram.state)
        content.toggleHistogramOverlay()
    }
}

//
//  FullScreenExitChromeTests.swift
//  ShrikeUITests
//
//  After full screen,
//  with a photo change and an edit session in between, the window's
//  chrome equals its chrome before entry and follows the settings (no
//  empty filmstrip band, no empty histogram box). Offscreen windows,
//  driven through the same calls the full-screen transition makes.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering

@MainActor
final class FullScreenExitChromeTests: XCTestCase {

    private var root: URL!
    private var saved: (strip: Bool, hist: Bool, stripPin: Bool, railPin: Bool, inspPin: Bool) = (false, false, false, false, false)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-fsexit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        saved = (Prefs.filmstripVisibleInWindowed, Prefs.viewerHistogramVisible,
                 Prefs.filmstripPinnedFullscreen, Prefs.editRailPinnedFullscreen,
                 Prefs.exifPanelPinnedFullscreen)
    }

    override func tearDown() async throws {
        Prefs.filmstripVisibleInWindowed = saved.strip
        Prefs.viewerHistogramVisible = saved.hist
        Prefs.filmstripPinnedFullscreen = saved.stripPin
        Prefs.editRailPinnedFullscreen = saved.railPin
        Prefs.exifPanelPinnedFullscreen = saved.inspPin
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewer() throws -> ViewerWindow {
        var groups: [ImageGroup] = []
        for name in ["a", "b", "c"] {
            let url = root.appendingPathComponent("\(name).jpg")
            XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
            groups.append(ImageGroup(primary: url))
        }
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: ShrikeServices.makeDefault())
        viewer.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 800), display: false)
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants()
        let content = viewer.contentRootForTesting
        content.animatesPanelFades = false
        content.voiceOverOverrideForTesting = false
        content.simulateFirstFrameForTesting()
        content.layoutSubtreeIfNeeded()
        return viewer
    }

    /// Sync on purpose: as an async test body this flow crashed inside
    /// XCTest's own task allocator ("freed pointer was not the last
    /// allocation"); run-loop turns give the same waits.
    private func waitFor(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    /// Shows on screen: not hidden (itself or an ancestor) and not faded.
    private func shows(_ view: NSView?) -> Bool {
        guard let view, view.window != nil else { return false }
        var v: NSView? = view
        while let cur = v {
            if cur.isHidden || cur.alphaValue == 0 { return false }
            v = cur.superview
        }
        return true
    }

    /// A shown surface whose content has no size.
    private func contentCollapsed(_ surface: HUDSurfaceView) -> Bool {
        guard shows(surface) else { return false }
        surface.layoutSubtreeIfNeeded()
        let host = surface.contentHost
        if host.frame.width < 1 || host.frame.height < 1 { return true }
        for sub in host.subviews where !sub.isHidden {
            if sub.frame.width < 1 || sub.frame.height < 1 { return true }
        }
        return false
    }

    private struct Chrome: Equatable, CustomStringConvertible {
        var strip: Bool, stripFrame: NSRect
        var hist: Bool, histFrame: NSRect
        var rail: Bool, railFrame: NSRect
        var canvas: NSRect
        /// Shown surfaces whose content lost its size.
        var collapsed: [String]
        var description: String {
            "strip \(strip) \(stripFrame), hist \(hist) \(histFrame), rail \(rail) \(railFrame), canvas \(canvas), collapsed \(collapsed)"
        }
    }

    private func chrome(_ viewer: ViewerWindow) -> Chrome {
        let content = viewer.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        func inRoot(_ v: NSView?) -> NSRect {
            guard let v, let sup = v.superview else { return .zero }
            return sup.convert(v.frame, to: content).integral
        }
        let strip = content.filmstripForTesting
        let hist = content.histogramOverlayForTesting
        let rail = content.editRailForTesting
        let stripShows = shows(strip)
        let histShows = shows(hist)
        let railShows = shows(rail)
        var collapsed: [String] = []
        if contentCollapsed(strip) { collapsed.append("strip") }
        if contentCollapsed(rail) { collapsed.append("rail") }
        if let surface = hist as? HUDSurfaceView, contentCollapsed(surface) { collapsed.append("hist") }
        return Chrome(strip: stripShows, stripFrame: stripShows ? inRoot(strip) : .zero,
                      hist: histShows, histFrame: histShows ? inRoot(hist) : .zero,
                      rail: railShows, railFrame: railShows ? inRoot(rail) : .zero,
                      canvas: inRoot(viewer.imageViewForTesting), collapsed: collapsed)
    }

    /// Enter, → to another photo, edit mode and Esc, leave: the same
    /// calls the custom transition and AppKit's notifications make.
    private func roundTrip(_ viewer: ViewerWindow, histogramInFullScreen: Bool?) {
        let content = viewer.contentRootForTesting
        let transition = viewer.fullScreenTransition
        let center = NotificationCenter.default
        let windowed = viewer.frame
        center.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        transition.animate(viewer, to: NSRect(x: 0, y: 0, width: 1512, height: 982), duration: 0)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: viewer)
        content.layoutSubtreeIfNeeded()
        // The bottom edge shows the strip and the capsule (hover).
        content.evaluateZonesForTesting(at: NSPoint(x: content.bounds.midX, y: 2))
        content.layoutSubtreeIfNeeded()
        if let histogramInFullScreen, histogramInFullScreen != Prefs.viewerHistogramVisible {
            content.toggleHistogramOverlay()
        }
        viewer.dispatch(.nextImage)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants()
        content.layoutSubtreeIfNeeded()
        viewer.dispatch(.openEditMode)
        waitFor("edit mode") { content.isEditModeActive }
        content.layoutSubtreeIfNeeded()
        viewer.dispatch(.exitEditMode)
        if content.isEditModeActive { content.exitEditMode() }
        XCTAssertFalse(content.isEditModeActive)
        content.evaluateZonesForTesting(at: NSPoint(x: content.bounds.midX, y: 2))
        content.layoutSubtreeIfNeeded()
        if histogramInFullScreen == true { content.toggleHistogramOverlay() }   // back to the setting
        center.post(name: NSWindow.willExitFullScreenNotification, object: viewer)
        transition.animate(viewer, to: windowed, duration: 0)
        center.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        // The display cycles that follow (the animation's completion too).
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        content.layoutSubtreeIfNeeded()
    }

    func testChromeAfterFullScreenEqualsChromeBefore_SettingsOff() throws {
        Prefs.filmstripVisibleInWindowed = false
        Prefs.viewerHistogramVisible = false
        Prefs.filmstripPinnedFullscreen = false
        Prefs.editRailPinnedFullscreen = true
        let viewer = try makeViewer()
        defer { viewer.close() }
        // The window rail's band ends at the pill: the same pill before
        // and after (the round trip moves to another photo).
        viewer.dispatch(.nextImage)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = chrome(viewer)
        XCTAssertFalse(before.strip, "the setting hides the docked strip")
        XCTAssertFalse(before.hist, "the setting hides the histogram")
        roundTrip(viewer, histogramInFullScreen: true)
        let after = chrome(viewer)
        XCTAssertEqual(after, before, "the window's chrome after full screen equals the chrome before")
        XCTAssertFalse(viewer.contentRootForTesting.isFilmstripShown)
        XCTAssertFalse(viewer.contentRootForTesting.isHistogramShown)
    }

    func testChromeAfterFullScreenEqualsChromeBefore_SettingsOn() throws {
        Prefs.filmstripVisibleInWindowed = true
        Prefs.viewerHistogramVisible = true
        Prefs.filmstripPinnedFullscreen = true
        Prefs.editRailPinnedFullscreen = true
        let viewer = try makeViewer()
        defer { viewer.close() }
        // The window rail's band ends at the pill: the same pill before
        // and after (the round trip moves to another photo).
        viewer.dispatch(.nextImage)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let before = chrome(viewer)
        XCTAssertTrue(before.strip)
        XCTAssertTrue(before.hist)
        XCTAssertEqual(before.collapsed, [])
        roundTrip(viewer, histogramInFullScreen: nil)
        let after = chrome(viewer)
        XCTAssertEqual(after, before, "the window's chrome after full screen equals the chrome before")
    }
}

//
//  ViewerToolbarAccessibilityTests.swift
//  ShrikeUITests
//
//  VoiceOver values on the viewer toolbar: each toggle item
//  reports "On" / "Off", and Zoom reports the zoom as the HUD shows it
//  (`pixelScale`). Read through the accessibility API of an offscreen
//  window, by both the new getters and the legacy attribute call that
//  VoiceOver uses, so an item whose value never reaches VoiceOver fails.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerToolbarAccessibilityTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false
    private var savedAutoHide = false
    private var savedFilmstrip = false
    private var savedHistogram = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-tbax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedAutoHide = Prefs.viewerToolbarAutoHide
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        savedHistogram = Prefs.viewerHistogramVisible
        Prefs.viewerInspectorVisibleWindowed = false
        Prefs.viewerToolbarAutoHide = false
        Prefs.filmstripVisibleInWindowed = false
        Prefs.viewerHistogramVisible = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        Prefs.viewerToolbarAutoHide = savedAutoHide
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
        Prefs.viewerHistogramVisible = savedHistogram
    }

    // MARK: Helpers

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    /// An 800 × 600 offscreen viewer with a photo on screen. The toolbar
    /// stops autosaving, so items a test adds never reach the next test.
    private func makeViewer() async throws -> (ViewerWindow, ViewerWindowToolbar) {
        let url = try writeJPEG("p.jpg")
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        let bar = try XCTUnwrap(window.toolbarController)
        bar.toolbar.autosavesConfiguration = false
        // AppKit loads the toolbar's autosaved item set from
        // the xctest process's standard defaults, which outlive a run.
        // Some runs had saved a set that pushed Zoom into the overflow
        // (the test then failed with "no toolbar element labelled Zoom"
        // and passed alone). Start every test from the default set.
        while !bar.toolbar.items.isEmpty { bar.toolbar.removeItem(at: 0) }
        for (index, id) in ViewerWindowToolbar.defaultItems.enumerated() {
            bar.toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        let view = window.imageViewForTesting
        let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
        XCTAssertTrue(shown, "photo never reached the canvas")
        refresh(window, bar)
        return (window, bar)
    }

    private func refresh(_ window: NSWindow, _ bar: ViewerWindowToolbar) {
        bar.validate()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
    }

    /// Waits until the inspector's slide has finished: the canvas width has
    /// not changed for 100 ms. The split item animates for a fixed time, and
    /// the floating histogram only returns once the widened canvas is at
    /// least its minimum width, so a check made mid-slide depends on how
    /// busy the machine is (the flaky testFloatingHistogramStepsAsideForTheInspector).
    private func waitForInspectorSlide(_ window: ViewerWindow, _ bar: ViewerWindowToolbar) async {
        var last: CGFloat = -1
        var stableSince = Date()
        _ = await waitUntil(8) {
            refresh(window, bar)
            let width = window.imageViewForTesting.frame.width
            if width != last { last = width; stableSince = Date() }
            return Date().timeIntervalSince(stableSince) >= 0.1
        }
    }

    /// The toolbar's accessibility element (role toolbar), found from the
    /// window's frame view the way the accessibility tree reaches it.
    private func toolbarElement(_ window: NSWindow) -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityRole() == .toolbar { return view }
            for sub in view.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return window.contentView?.superview.flatMap(find)
    }

    /// The toolbar's child element whose label is `label`.
    private func element(_ label: String, in window: NSWindow) -> NSView? {
        let children = toolbarElement(window)?.accessibilityChildren() ?? []
        return children.compactMap { $0 as? NSView }.first { $0.accessibilityLabel() == label }
    }

    /// The value VoiceOver reads (the legacy attribute call), and the
    /// new-style getter; both must agree.
    private func values(_ label: String, in window: NSWindow,
                        file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let el = element(label, in: window) else {
            XCTFail("no toolbar element labelled \(label)", file: file, line: line)
            return nil
        }
        let modern = el.accessibilityValue() as? String
        let legacy = el.accessibilityAttributeValue(.value) as? String
        XCTAssertEqual(modern, legacy, "\(label): the value VoiceOver reads differs", file: file, line: line)
        return legacy
    }

    // MARK: Tests

    func testToggleItemsReportOnAndOff() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        XCTAssertNotNil(toolbarElement(window), "no toolbar in the accessibility tree")

        XCTAssertEqual(values("Inspector", in: window), "Off")
        XCTAssertEqual(values("Flag", in: window), "Off")

        // A click on the item runs the command; the value follows the host.
        let inspector = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.inspector)?.view as? ToolbarToggleButton)
        inspector.performClick(nil)
        XCTAssertTrue(window.splitController?.isInspectorShown ?? false)
        refresh(window, bar)
        XCTAssertEqual(values("Inspector", in: window), "On")

        // The menu (or a key) turns it off: the next validation says so.
        window.dispatch(.toggleInspector)
        refresh(window, bar)
        XCTAssertEqual(values("Inspector", in: window), "Off")

        // Optional toggles from the Customize palette.
        let count = bar.toolbar.items.count
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.histogram, at: count)
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.filmstrip, at: count + 1)
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.fullScreen, at: count + 2)
        defer { for _ in 0..<3 { bar.toolbar.removeItem(at: count) } }
        refresh(window, bar)
        XCTAssertEqual(values("Histogram", in: window), "Off")
        XCTAssertEqual(values("Filmstrip", in: window), "Off")
        XCTAssertEqual(values("Full Screen", in: window), "Off")

        window.dispatch(.toggleHistogram)
        window.dispatch(.toggleFilmstrip)
        refresh(window, bar)
        XCTAssertTrue(window.contentRootForTesting.isHistogramShown)
        XCTAssertEqual(values("Histogram", in: window), "On")
        XCTAssertEqual(values("Filmstrip", in: window), "On")
        XCTAssertEqual(values("Full Screen", in: window), "Off")

        window.dispatch(.toggleHistogram)
        window.dispatch(.toggleFilmstrip)
        refresh(window, bar)
        XCTAssertEqual(values("Histogram", in: window), "Off")
        XCTAssertEqual(values("Filmstrip", in: window), "Off")
    }

    func testZoomReportsTheHUDPercent() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        let fit = "\(Int((view.pixelScale * 100).rounded())) %"
        XCTAssertEqual(values("Zoom", in: window), fit)

        view.setPixelScale(2.0, anchor: nil)
        refresh(window, bar)
        XCTAssertEqual(values("Zoom", in: window), "200 %")
        let hud = window.contentRootForTesting.zoomBadgeTextForTesting
        if !hud.isEmpty { XCTAssertEqual(hud, "200 %", "the HUD and VoiceOver say the same number") }

        view.setPixelScale(0.5, anchor: nil)
        refresh(window, bar)
        XCTAssertEqual(values("Zoom", in: window), "50 %")
    }

    /// Rating reports "N stars" / "No rating".
    func testRatingReportsStars() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        XCTAssertEqual(values("Rating", in: window), "No rating")
        // Culling writes land asynchronously: validate until the value moves.
        for (stars, expected) in [(3, "3 stars"), (1, "1 star"), (0, "No rating")] {
            window.dispatch(.rate(stars))
            let landed = await waitUntil {
                self.refresh(window, bar)
                return self.element("Rating", in: window)?.accessibilityValue() as? String == expected
            }
            XCTAssertTrue(landed, "rating \(stars) never reached the item")
            XCTAssertEqual(values("Rating", in: window), expected)
        }
        // The pull-down lists the rows with a check on the current one.
        bar.menuNeedsUpdate(bar.ratingMenu)
        XCTAssertEqual(bar.ratingMenu.items.first?.title, "", "row 0 is the glyph")
        XCTAssertEqual(bar.ratingMenu.items.dropFirst().first?.state, .on, "None is checked")
        let overflow = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.rating)?.menuFormRepresentation)
        XCTAssertNotNil(overflow.image, "the » row has an icon")
        XCTAssertTrue(overflow.submenu === bar.ratingOverflowMenu)
    }

    /// Never two histograms. With the inspector (which has its
    /// own) open, the floating one hides; it returns when the inspector
    /// hides. The toggle reports the setting throughout.
    func testFloatingHistogramStepsAsideForTheInspector() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        let content = window.contentRootForTesting
        let count = bar.toolbar.items.count
        bar.toolbar.insertItem(withItemIdentifier: ViewerWindowToolbar.ID.histogram, at: count)
        defer { bar.toolbar.removeItem(at: count) }

        window.dispatch(.toggleHistogram)
        refresh(window, bar)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "shown with no inspector")

        window.dispatch(.toggleInspector)
        await waitForInspectorSlide(window, bar)
        XCTAssertTrue(window.splitController?.isInspectorShown ?? false)
        XCTAssertFalse(content.histogramOverlayVisibleForTesting, "the inspector has its own histogram")
        XCTAssertEqual(values("Histogram", in: window), "On", "the setting is still on")
        XCTAssertTrue(content.isHistogramShown)

        window.dispatch(.toggleInspector)
        await waitForInspectorSlide(window, bar)
        // The asserted condition itself, in case the slide's first frame was
        // slower than the 100 ms the width check waits for.
        _ = await waitUntil(8) { refresh(window, bar); return content.histogramOverlayVisibleForTesting }
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "back when the inspector hides")
        XCTAssertEqual(values("Histogram", in: window), "On")
    }

    /// The items keep a text form for the overflow menu, sending the same
    /// command as the button.
    func testOverflowFormsSendTheCommands() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        let inspector = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.inspector)?.menuFormRepresentation)
        XCTAssertEqual(inspector.representedObject as? String, ShrikeCommand.toggleInspector.rawValue)
        let zoom = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.zoom)?.menuFormRepresentation?.submenu)
        bar.menuNeedsUpdate(zoom)
        XCTAssertEqual(zoom.items.first?.title, window.toolbarZoomLine)
        XCTAssertTrue(zoom.items.contains { $0.representedObject as? String == ShrikeCommand.actualSize.rawValue })
        // The pull-down's own menu starts with the glyph row it never lists,
        // and keeps the menu rule's enabled state.
        let popup = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.zoom)?.view as? NSPopUpButton)
        XCTAssertTrue(popup.menu === bar.zoomMenu)
        XCTAssertFalse(popup.autoenablesItems)
        bar.menuNeedsUpdate(bar.zoomMenu)
        XCTAssertEqual(bar.zoomMenu.items.first?.title, "")
        XCTAssertEqual(bar.zoomMenu.items.dropFirst().first?.title, window.toolbarZoomLine)
    }
}

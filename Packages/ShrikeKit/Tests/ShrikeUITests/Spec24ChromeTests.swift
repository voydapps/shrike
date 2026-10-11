//
//  Spec24ChromeTests.swift
//  ShrikeUITests
//
//  Spec 24 (after first use): zoom HUD place, capsule inventory, toolbar
//  defaults, pin toasts, the idle hide.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class Spec24ChromeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Prefs.resetAll()
    }

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    private func makeContent(_ size: NSSize = NSSize(width: 1440, height: 900),
                             mode: ViewerContentView.WindowMode = .fullscreen) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(origin: .zero, size: size)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// Content inside a window: the idle rule reads the pointer through the
    /// window, and without one it sees no pointer at all (everything hides).
    private func inWindow() -> (NSWindow, ViewerContentView) {
        let content = ViewerContentView(services: .makeDefault())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        return (window, content)
    }

    // MARK: Zoom HUD (user test 3, spec 24 §1.5, vector 8)

    func testZoomHUDIsTopCentreAndNeverMeetsTheOtherPanels() {
        for width in [CGFloat(1440), 480] {
            let content = makeContent(NSSize(width: width, height: 900))
            content.evaluateZonesForTesting(at: NSPoint(x: width / 2, y: 40))   // capsule + strip
            content.togglePanel(.editRail)
            if width > 1000 { content.togglePanel(.inspector) }   // 280 pt wide: it would cover a 480 pt centre
            content.navigationPositionOverlayForTesting.show(index: 3, total: 41, filename: "IMG_0001.jpg")
            content.navigationPositionOverlayForTesting.alphaValue = 1
            content.zoomBadgeForTesting.alphaValue = 1
            content.layoutSubtreeIfNeeded()
            let badge = content.zoomBadgeForTesting.frame
            XCTAssertEqual(badge.midX, width / 2, accuracy: 1, "centred (\(width))")
            XCTAssertEqual(content.bounds.maxY - badge.maxY, ViewerContentView.zoomBadgeTopInset, accuracy: 1,
                           "12 pt below the top (\(width))")
            let others: [(String, NSRect)] = [
                ("capsule", content.capsuleFrameForTesting),
                ("strip", content.filmstripForTesting.frame),
                ("pill", content.pillFrameForTesting),
                ("rail", content.editRailForTesting.frame),
                ("inspector", content.inspectorForTesting.frame),
            ]
            for (name, frame) in others where name != "inspector" || width > 1000 {
                XCTAssertFalse(badge.intersects(frame), "zoom HUD \(badge) meets \(name) \(frame) at \(width)")
            }
        }
    }

    func testZoomHUDIsAtTheTopInAWindowToo() {
        let content = makeContent(mode: .windowed)
        content.zoomBadgeForTesting.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        let badge = content.zoomBadgeForTesting.frame
        XCTAssertGreaterThan(badge.midY, content.bounds.midY)
        XCTAssertFalse(badge.intersects(content.capsuleFrameForTesting))
        XCTAssertEqual(ViewerContentView.zoomBadgeLifetime, 1.2)
    }

    // MARK: Capsule inventory (vector 5)

    func testCapsuleHasExactlyTheElevenButtonsAndNoFlagOrHistogram() {
        let toolbar = ViewerToolbar()
        XCTAssertEqual(toolbar.buttonActionsForTesting(), [
            .prevImage, .nextImage, .zoomMenu, .rotateLeft, .rotateRight, .share, .openEditMode,
            .deleteToTrash, .showInBrowser, .toggleInspector, .toggleFullscreen,
        ])
        let actions = toolbar.buttonActionsForTesting()
        XCTAssertFalse(actions.contains(.toggleFlag))
        XCTAssertFalse(actions.contains(.toggleHistogram))
    }

    func testCapsuleTooltipsNameTheirKeys() {
        let toolbar = ViewerToolbar()
        for (ident, key) in [("toolbar.showInBrowser", "⌘B"), ("toolbar.toggleInspector", "⌘I"),
                             ("toolbar.openEditMode", "⌘E"), ("toolbar.prevImage", "←")] {
            let tip = toolbar.buttonWithIdentifierForTesting(ident)?.toolTip ?? ""
            XCTAssertTrue(tip.contains(key), "\(ident): \(tip)")
        }
        XCTAssertTrue(toolbar.buttonWithIdentifierForTesting("toolbar.toggleFullscreen")?.toolTip?
            .hasPrefix("Exit Full Screen") ?? false)
    }

    func testCapsuleZoomMenuEndsWithTheHistogramLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spec24-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let window = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        defer { window.close() }
        Prefs.viewerHistogramVisible = false
        var menu = try XCTUnwrap(window.contentRootForTesting.capsuleZoomMenu.makeMenu())
        XCTAssertEqual(menu.items.last?.attributedTitle?.string.hasPrefix("Show Histogram"), true)
        Prefs.viewerHistogramVisible = true
        menu = try XCTUnwrap(window.contentRootForTesting.capsuleZoomMenu.makeMenu())
        XCTAssertEqual(menu.items.last?.attributedTitle?.string.hasPrefix("Hide Histogram"), true)
        XCTAssertEqual(menu.items.compactMap { $0.representedObject as? String }.last,
                       ShrikeCommand.toggleHistogram.rawValue)
    }

    // MARK: Toolbar defaults (vector 10, 11)

    func testWindowToolbarDefaultsHaveShowInBrowserAndHistogram() {
        let items = ViewerWindowToolbar.defaultItems
        XCTAssertEqual(items[0], ViewerWindowToolbar.ID.nav)
        XCTAssertEqual(items[1], ViewerWindowToolbar.ID.showInBrowser, "right after the nav group")
        let histogram = items.firstIndex(of: ViewerWindowToolbar.ID.histogram)
        let separator = items.firstIndex(of: .inspectorTrackingSeparator)
        let fullScreen = items.firstIndex(of: ViewerWindowToolbar.ID.fullScreen)
        XCTAssertEqual(histogram.map { $0 + 1 }, fullScreen, "Full Screen right after Histogram")
        XCTAssertEqual(fullScreen.map { $0 + 1 }, separator, "last item before the tracking separator")
        XCTAssertEqual(items.last, ViewerWindowToolbar.ID.inspector, "then the Inspector button")
        XCTAssertEqual(ViewerWindowToolbar.identifier, "shrike.viewer.toolbar.v3")
        XCTAssertEqual(ViewerWindowToolbar.visibilityPriority(ViewerWindowToolbar.ID.histogram), .low)
        for id in [ViewerWindowToolbar.ID.nav, ViewerWindowToolbar.ID.showInBrowser, ViewerWindowToolbar.ID.inspector] {
            XCTAssertEqual(ViewerWindowToolbar.visibilityPriority(id), .high)
        }
        XCTAssertEqual(Set(items.map(\.rawValue)).count, items.count, "no duplicates")
    }

    // MARK: Pins (vector 7)

    func testPinToastsAndUnpinAll() {
        let content = makeContent()
        content.togglePanel(.filmstrip)
        XCTAssertEqual(ViewerContentView.pinToast(.filmstrip, pinned: true), "Filmstrip pinned. Press ⌘K to unpin.")
        XCTAssertEqual(ViewerContentView.pinToast(.editRail, pinned: true), "Edit rail pinned. Press ⇧⌘E to unpin.")
        XCTAssertEqual(ViewerContentView.pinToast(.inspector, pinned: false), "Inspector unpinned.")
        XCTAssertTrue(content.toastHost.isShowing)
        content.togglePanel(.inspector)
        XCTAssertTrue(content.hasPinnedPanels)
        content.unpinAllPanels()
        XCTAssertFalse(content.hasPinnedPanels)
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen)
        XCTAssertFalse(Prefs.exifPanelPinnedFullscreen)
    }

    // MARK: Idle hide (vector 2)

    func testAStillPointerInTheBottomZoneHidesTheStackAfterTheIdleDelay() {
        let (window, content) = inWindow()
        defer { window.close() }
        content.cursorLocationOverrideForTesting = NSPoint(x: 720, y: 40)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        XCTAssertFalse(content.toolbarForTesting.isHidden)
        // The pointer rests in the zone but not over a panel: the idle
        // timer hides both.
        content.cursorLocationOverrideForTesting = NSPoint(x: 720, y: 4)
        content.forceIdleFireForTesting()
        XCTAssertTrue(content.toolbarForTesting.isHidden, "capsule hidden after the idle delay")
        XCTAssertTrue(content.filmstripForTesting.isHidden, "strip hidden")
        XCTAssertEqual(ViewerContentView.idleHideDelay, 2.0)
    }

    /// UX-02 P2-1: the two pointer places the check found stuck on: left of
    /// the strip (x 2, 67 pt up) and under it (3 pt from the bottom).
    func testTheStackFadesFromTheAuditRestingPlacesButNotFromOverThePanels() {
        let (window, content) = inWindow()
        defer { window.close() }
        let places = [NSPoint(x: 2, y: 67), NSPoint(x: 720, y: 3), NSPoint(x: 720, y: 95)]
        for place in places {
            content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
            XCTAssertFalse(content.toolbarForTesting.isHidden, "shown first")
            content.cursorLocationOverrideForTesting = place
            content.evaluateZonesForTesting(at: place)
            content.forceIdleFireForTesting()
            let strip = content.filmstripForTesting.frame, capsule = content.toolbarForTesting.frame
            let over = strip.contains(place) || capsule.contains(place)
            XCTAssertEqual(content.toolbarForTesting.isHidden, !over, "capsule at \(place), strip \(strip)")
            XCTAssertEqual(content.filmstripForTesting.isHidden, !over, "strip at \(place)")
            // Back to a clean start; a move in the zone shows them again.
            content.cursorLocationOverrideForTesting = NSPoint(x: 720, y: 500)
            content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 500))
            content.forceIdleFireForTesting()
            content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        }
        // Over the strip itself the stack stays however long.
        let strip = content.filmstripForTesting.frame
        let onStrip = NSPoint(x: strip.midX, y: strip.midY)
        content.cursorLocationOverrideForTesting = onStrip
        content.evaluateZonesForTesting(at: onStrip)
        for _ in 0..<3 { content.forceIdleFireForTesting() }
        XCTAssertFalse(content.filmstripForTesting.isHidden, "over the strip: held")
        XCTAssertFalse(content.toolbarForTesting.isHidden, "and the capsule with it")
    }
}

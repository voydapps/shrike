//
//  FullScreenChromeTests.swift
//  ShrikeUITests
//
//  Full-screen chrome: the bottom stack (filmstrip + capsule),
//  reveal zones with a 120 ms rest, pins in their own slots, capsule
//  symbols, pill / histogram placement.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class FullScreenChromeTests: XCTestCase {

    private let pinKeys = [
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.exifPanel.pinnedFullscreen",
        "shrike.viewer.histogramVisible",
    ]

    override func setUp() async throws {
        try await super.setUp()
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        // The macOS 14 / 15 geometry, also used on
        // macOS 26. GlassHUDTests covers the glass geometry.
        HUDGlass.forceFallbackForTesting = true
    }

    override func tearDown() async throws {
        HUDGlass.forceFallbackForTesting = false
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        try await super.tearDown()
    }

    private func makeContent(_ size: CGSize = CGSize(width: 1440, height: 900)) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(origin: .zero, size: size)
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// Waits for the 120 ms rest itself to elapse (its work item ran), not
    /// for a fixed time: on a busy machine the main queue can run it late.
    private func waitForZoneRest(_ content: ViewerContentView) async throws {
        let deadline = Date().addingTimeInterval(5)
        while content.zoneRestPendingForTesting(.filmstrip) || content.zoneRestPendingForTesting(.toolbar) {
            if Date() > deadline { XCTFail("the zone rest never elapsed"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func visiblePins(in root: NSView) -> [PinCornerOverlay] {
        var found: [PinCornerOverlay] = []
        func walk(_ v: NSView) {
            if let pin = v as? PinCornerOverlay, !pin.isHiddenOrHasHiddenAncestor { found.append(pin) }
            v.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    // MARK: Layout

    func testFilmstripDocksAtTheBottomAndTheCapsuleFloatsAboveIt() {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        let strip = content.filmstripForTesting.frame
        XCTAssertEqual(strip.minY, 12, accuracy: 0.5, "floats 12 pt above the bottom edge")
        XCTAssertEqual(strip.height, 88, accuracy: 0.5)
        XCTAssertEqual(strip.width, 1440 - 24, accuracy: 0.5)
        let capsule = content.capsuleFrameForTesting
        XCTAssertEqual(capsule.height, 44, accuracy: 0.5)
        XCTAssertEqual(capsule.minY, strip.maxY + 12, accuracy: 0.5, "12 pt above the filmstrip")
        XCTAssertEqual(capsule.midX, 720, accuracy: 0.5, "centred")
    }

    func testCapsuleSits16ptAboveTheBottomWithoutTheFilmstrip() {
        let content = makeContent()
        content.toolbarForTesting.setHoldsOpenForTesting(true)   // a capsule menu is open
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.toolbarForTesting.isHidden, "the capsule shows while its menu is open")
        XCTAssertTrue(content.filmstripForTesting.isHidden)
        XCTAssertEqual(content.capsuleFrameForTesting.minY, 16, accuracy: 0.5)
        content.toolbarForTesting.setHoldsOpenForTesting(false)
        XCTAssertTrue(content.toolbarForTesting.isHidden, "and hides once the menu closes")
    }

    /// Spec 24 §1.2: a pinned strip no longer carries the capsule.
    func testPinnedFilmstripDoesNotShowTheCapsuleAndTheCapsuleIsNeverPinned() {
        let content = makeContent()
        content.togglePanel(.toolbar)
        XCTAssertFalse(content.isPinnedForTesting(.toolbar), "no capsule pin")
        XCTAssertTrue(content.toolbarForTesting.isHidden)
        content.togglePanel(.filmstrip)
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        XCTAssertTrue(content.toolbarForTesting.isHidden, "a pinned filmstrip leaves the capsule hidden")
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        XCTAssertFalse(content.toolbarForTesting.isHidden, "the pointer in the bottom zone shows it")
        content.togglePanel(.filmstrip)
    }

    // MARK: Nothing of ours at the top edge

    func testVector1_TopEdgeRevealsNothingAndNoPanelTouchesIt() {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 899))
        for panel in ViewerContentView.PanelKind.allCases {
            XCTAssertFalse(content.isHoveredForTesting(panel))
        }
        content.togglePanel(.filmstrip)
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()
        for view in [content.filmstripForTesting, content.toolbarForTesting,
                     content.inspectorForTesting] as [NSView] {
            // The inspector's top is 12 pt below the safe-area top.
            let limit: CGFloat = view === content.inspectorForTesting ? 900 - 12 : 900 - 24
            XCTAssertLessThanOrEqual(view.frame.maxY, limit + 0.5, "\(type(of: view)) stays out of the menu-bar zone")
        }
        content.togglePanel(.filmstrip)
        content.togglePanel(.inspector)
    }

    // MARK: 120 ms rest, filmstrip + capsule together

    func testVector2_BottomZoneRevealsTogetherAfterTheRest() async throws {
        let content = makeContent()
        let imageBefore = content.layoutAndReturnImageViewFrameForTesting()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 90), rested: false)
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip), "no reveal before the rest")
        XCTAssertTrue(content.zoneRestPendingForTesting(.filmstrip))
        XCTAssertTrue(content.zoneRestPendingForTesting(.toolbar))

        try await waitForZoneRest(content)
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip))
        XCTAssertTrue(content.isHoveredForTesting(.toolbar), "together")
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        XCTAssertFalse(content.toolbarForTesting.isHidden)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.layoutAndReturnImageViewFrameForTesting(), imageBefore, "the image does not move")
    }

    func testVector2_LeavingTheZoneBeforeTheRestCancelsTheReveal() async throws {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 90), rested: false)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 450), rested: false)
        XCTAssertFalse(content.zoneRestPendingForTesting(.filmstrip))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip), "a pass-through does not reveal")
    }

    /// 0.2.4 smoke: could a pointer move wake the capsule and strip after
    /// they faded? A real `mouseMoved` NSEvent goes in through the method
    /// AppKit's tracking area calls. (Headless AppKit makes no tracking-area
    /// moves from `sendEvent`, so the tracking area itself is checked for
    /// the options that make AppKit send them.)
    func testARealMouseMovedWakesTheCapsuleAndStripAfterTheyFaded() async throws {
        let content = makeContent()
        let areas = content.trackingAreas.filter { $0.owner === content }
        XCTAssertEqual(areas.count, 1, "one tracking area for the content view")
        let options = try XCTUnwrap(areas.first).options
        XCTAssertTrue(options.contains(.mouseMoved), "it reports moves")
        XCTAssertTrue(options.contains(.activeAlways), "also while the app is inactive")
        XCTAssertTrue(options.contains(.inVisibleRect), "over the whole view")

        func move(to p: NSPoint) throws {
            content.mouseMoved(with: try XCTUnwrap(NSEvent.mouseEvent(
                with: .mouseMoved, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)))
        }
        let bottom = NSPoint(x: 720, y: 50)

        // Shown by a first move, then faded by the idle clock.
        try move(to: bottom)
        try await waitForZoneRest(content)
        XCTAssertEqual(content.alphaForTesting(.toolbar), 1)
        XCTAssertEqual(content.alphaForTesting(.filmstrip), 1)
        content.forceIdleFireForTesting()
        XCTAssertEqual(content.alphaForTesting(.toolbar), 0, "the capsule faded")
        XCTAssertEqual(content.alphaForTesting(.filmstrip), 0, "the strip faded")

        // One small move in the same zone brings both back after the rest.
        try move(to: NSPoint(x: 724, y: 52))
        try await waitForZoneRest(content)
        XCTAssertTrue(content.isHoveredForTesting(.toolbar))
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip))
        XCTAssertEqual(content.alphaForTesting(.toolbar), 1, "the capsule is back")
        XCTAssertEqual(content.alphaForTesting(.filmstrip), 1, "the strip is back")
        XCTAssertFalse(content.toolbarForTesting.isHidden)
        XCTAssertFalse(content.filmstripForTesting.isHidden)
    }

    func testZoneSizes() {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 97))
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip), "the bottom zone is 96 pt")
        content.evaluateZonesForTesting(at: NSPoint(x: 1440 - 57, y: 450))
        XCTAssertFalse(content.isHoveredForTesting(.inspector), "the right zone is 56 pt")
        content.evaluateZonesForTesting(at: NSPoint(x: 1440 - 55, y: 450))
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
    }

    func testThePointerOnTheCapsuleKeepsTheWholeStack() {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        let capsule = content.capsuleFrameForTesting
        // Above the 96 pt zone, on the capsule.
        content.evaluateZonesForTesting(at: NSPoint(x: capsule.midX, y: capsule.maxY - 4))
        XCTAssertFalse(content.panelExitGraceActiveForTesting(.filmstrip), "the strip stays with the capsule")
        XCTAssertFalse(content.panelExitGraceActiveForTesting(.toolbar))
    }

    func testFadeTimings() {
        XCTAssertEqual(ViewerContentView.fadeInDuration, 0.08, accuracy: 0.001)
        XCTAssertEqual(ViewerContentView.fadeOutDuration, 0.12, accuracy: 0.001)
    }

    // MARK: No pin in a window

    func testVector3_NoPinGlyphInAWindow() {
        let content = makeContent()
        content.togglePanel(.filmstrip)
        XCTAssertFalse(visiblePins(in: content).isEmpty, "precondition: full screen draws pins when panels show")
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(visiblePins(in: content).isEmpty, "no pin glyph in a window")
        content.windowMode = .fullscreen
        content.togglePanel(.filmstrip)
    }

    // MARK: ⌘K pins the filmstrip; VoiceOver

    func testVector5_PinnedFilmstripStaysAndReadsPinned() {
        let content = makeContent()
        let pin = content.filmstripForTesting.pinOverlayForTesting
        XCTAssertEqual(pin.accessibilityLabel(), "Pin Filmstrip")
        XCTAssertEqual(pin.accessibilityValue() as? String, "Not pinned")
        XCTAssertEqual(pin.toolTip, "Pin Filmstrip")
        XCTAssertEqual(pin.symbolNameForTesting, "pin")
        XCTAssertEqual(pin.glyphTintForTesting, .secondaryLabelColor)

        content.togglePanel(.filmstrip)   // the ⌘K path in full screen
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 450))
        content.forceExitGraceFireForTesting(.filmstrip)
        content.forceIdleFireForTesting()
        XCTAssertFalse(content.filmstripForTesting.isHidden, "stays after the pointer leaves")
        XCTAssertEqual(pin.symbolNameForTesting, "pin.fill")
        XCTAssertEqual(pin.glyphTintForTesting, ShrikeAccent.mark)
        XCTAssertEqual(pin.accessibilityLabel(), "Pin Filmstrip")
        XCTAssertEqual(pin.accessibilityValue() as? String, "Pinned")
        XCTAssertEqual(pin.toolTip, "Unpin Filmstrip")
        content.togglePanel(.filmstrip)
    }

    func testPinLabelsNameTheirPanels() {
        let content = makeContent()
        XCTAssertEqual(content.inspectorForTesting.pinOverlayForTesting.accessibilityLabel(), "Pin Inspector")
        XCTAssertEqual(PinCornerOverlay.hitSize, 28)
    }

    // MARK: Pill and capsule do not intersect

    func testVector6_LongNamePillNeverOverlapsTheCapsule() {
        let content = makeContent()
        let name = String(repeating: "LongName_", count: 6) + "123456.jpg"   // 64 characters
        content.navigationPositionOverlayForTesting.show(index: 43, total: 180, filename: name)
        content.togglePanel(.filmstrip)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        let pill = content.pillFrameForTesting
        let capsule = content.capsuleFrameForTesting
        XCTAssertFalse(content.toolbarForTesting.isHidden)
        XCTAssertFalse(pill.intersects(capsule), "pill \(pill) vs capsule \(capsule)")
        XCTAssertEqual(pill.minX, 12, accuracy: 0.5)
        content.layoutSubtreeIfNeeded()
        content.togglePanel(.filmstrip)
    }

    // MARK: Left edge (spec 26 §3, vector 12)

    func testTheLeftEdgeRevealsNothing() {
        let content = makeContent()
        // `rested: true` is the pointer having waited in the zone already.
        content.evaluateZonesForTesting(at: NSPoint(x: 8, y: 450), rested: true)
        for panel in ViewerContentView.PanelKind.allCases {
            XCTAssertFalse(content.isHoveredForTesting(panel), "\(panel) stays down at the left edge")
        }
        XCTAssertTrue(ViewerContentView.zonePanels(at: NSPoint(x: 8, y: 450), in: content.bounds).isEmpty)
        XCTAssertEqual(ViewerContentView.zonePanels(at: NSPoint(x: 1435, y: 450), in: content.bounds), [.inspector])
    }

    // MARK: Histogram

    func testHistogramStaysOnScreenWithTheFilmstripPinned() {
        Prefs.viewerHistogramVisible = true
        let content = makeContent()
        content.togglePanel(.filmstrip)
        content.kickIdleTimer()
        content.layoutSubtreeIfNeeded()
        let histogram = content.histogramOverlayFrameForTesting()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "the histogram shows")
        XCTAssertTrue(content.bounds.contains(histogram), "on screen: \(histogram)")
        XCTAssertEqual(histogram.minY, content.filmstripForTesting.frame.maxY + 12, accuracy: 1,
                       "12 pt above the pinned strip (no capsule rides with it)")
        XCTAssertEqual(histogram.maxX, 1440 - 12, accuracy: 1)
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.histogramOverlayFrameForTesting().maxX, 1440 - 12 - 280 - 12, accuracy: 1,
                       "left of the inspector")
        content.togglePanel(.inspector)
        content.togglePanel(.filmstrip)
    }

    // MARK: Symbols

    func testCapsuleSymbolsExistAndNamesFollowSpec() {
        for name in ViewerToolbar.symbolNamesForTesting {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
        // Spec 24 §1.3: the histogram and flag buttons left the capsule.
        XCTAssertFalse(ViewerToolbar.symbolNamesForTesting.contains("chart.bar.xaxis"))
        XCTAssertFalse(ViewerToolbar.symbolNamesForTesting.contains("flag"))
        XCTAssertEqual(ViewerToolbar.symbolNamesForTesting.count, 11)
        XCTAssertFalse(ViewerToolbar.symbolNamesForTesting.contains("waveform"))
        let toolbar = ViewerToolbar()
        let inspector = toolbar.buttonWithIdentifierForTesting("toolbar.toggleInspector")
        XCTAssertEqual(inspector?.image?.accessibilityDescription, "Inspector")
        for name in ["pin", "pin.fill"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }
}

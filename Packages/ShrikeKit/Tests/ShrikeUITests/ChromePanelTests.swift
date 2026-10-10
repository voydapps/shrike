//
//  ChromePanelTests.swift
//  ShrikeUITests
//
//  Tests for the fullscreen edge-activated chrome panels managed by
//  ViewerContentView
//
//  Covered contracts:
//   * edge hover reveals only the correct panel (top →
//            filmstrip, bottom → toolbar, left → editRail, right →
//            inspector); other panels stay hidden.
//   * pin toggle persists to the matching Prefs key and flips
//            the in-memory `pinnedPanels` set. Pinned panels ignore
//            the idle-expiry timer.
//   * cursor-idle auto-hide: `handleIdleExpired()` hides
//            hovered-but-not-pinned panels, leaves pinned ones alone.
//   * windowed mode disables edge-hover reveal for all panels.
//            The fullscreen-pin prefs don't bleed through into
//            windowed visibility.
//   * Mode swap — pinned state is preserved across fullscreen ↔
//                 windowed swaps because it's persisted in Prefs and
//                 re-read on init (ViewerContentView.init seeds from
//                 Prefs). A fresh windowed content view with
//                 pinned-fullscreen prefs set should end up with those
//                 bits flipped in pinnedPanels.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ChromePanelTests: XCTestCase {

    // MARK: - Setup

    private func clearChromePrefs() {
        let ud = ShrikeDefaults.store
        for key in [
            "shrike.viewer.filmstrip.visibleInWindowed",
            "shrike.viewer.filmstrip.heightPt",
            "shrike.viewer.filmstrip.pinnedFullscreen",
            "shrike.viewer.editRail.pinnedFullscreen",
            "shrike.viewer.editRail.visibleInWindowed",
            "shrike.viewer.exifPanel.pinnedFullscreen",
            "shrike.viewer.chromeFadeOutDelayMs",
        ] { ud.removeObject(forKey: key) }
    }

    override func setUp() async throws {
        try await super.setUp()
        clearChromePrefs()
    }

    override func tearDown() async throws {
        clearChromePrefs()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func makeContent(
        size: CGSize = CGSize(width: 1200, height: 800)
    ) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: - Edge hover reveals correct panel (fullscreen)

    /// The top edge belongs to the menu bar.
    func testEdgeHover_TopZone_RevealsNothing() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // AppKit bottom-origin: the top of the view is at y = 800.
        content.evaluateZonesForTesting(at: CGPoint(x: 600, y: 798))

        for panel in ViewerContentView.PanelKind.allCases {
            XCTAssertFalse(content.isHoveredForTesting(panel), "top edge reveals no \(panel)")
        }
    }

    /// The bottom 96 pt reveal the filmstrip and the capsule
    /// together.
    func testEdgeHover_BottomZone_RevealsFilmstripAndCapsule() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: CGPoint(x: 600, y: 90))
        XCTAssertTrue(content.isHoveredForTesting(.toolbar))
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip))
        XCTAssertFalse(content.isHoveredForTesting(.editRail))
        XCTAssertFalse(content.isHoveredForTesting(.inspector))
    }

    func testEdgeHover_LeftZone_RevealsEditRailOnly() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: CGPoint(x: 20, y: 400))
        XCTAssertTrue(content.isHoveredForTesting(.editRail))
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip))
        XCTAssertFalse(content.isHoveredForTesting(.toolbar))
        XCTAssertFalse(content.isHoveredForTesting(.inspector))
    }

    func testEdgeHover_RightZone_RevealsInspectorOnly() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: CGPoint(x: 1180, y: 400))
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip))
        XCTAssertFalse(content.isHoveredForTesting(.toolbar))
        XCTAssertFalse(content.isHoveredForTesting(.editRail))
    }

    func testEdgeHover_Center_RevealsNothing() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: CGPoint(x: 600, y: 400))
        for panel in ViewerContentView.PanelKind.allCases {
            XCTAssertFalse(content.isHoveredForTesting(panel),
                           "center hover reveals no panels (\(panel))")
        }
    }

    // MARK: - Windowed mode: no hover reveal
    //
    // In a window no panel reveals on hover, the edit rail included
    // (View › Show Edit Rail shows it).

    func testWindowedMode_HoverEdges_NoPanelReveals() {
        Prefs.editRailVisibleInWindowed = true
        let content = makeContent()
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()

        // Top, bottom, right edges + center: NO panel revealed.
        for p in [
            CGPoint(x: 600, y: 790),    // top
            CGPoint(x: 600, y: 10),     // bottom
            CGPoint(x: 1190, y: 400),   // right
            CGPoint(x: 600, y: 400),    // center
        ] {
            content.evaluateZonesForTesting(at: p)
            for panel in ViewerContentView.PanelKind.allCases {
                XCTAssertFalse(
                    content.isHoveredForTesting(panel),
                    "windowed mode: hover at \(p) must NOT reveal \(panel)"
                )
            }
        }

        // Left edge: nothing either.
        content.evaluateZonesForTesting(at: CGPoint(x: 10, y: 400))
        XCTAssertFalse(content.isHoveredForTesting(.editRail),
                       "windowed mode: the left edge does not reveal the rail")
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip))
        XCTAssertFalse(content.isHoveredForTesting(.toolbar))
        XCTAssertFalse(content.isHoveredForTesting(.inspector))
    }

    func testWindowedMode_EdgeActivationDisabled_NoPanelReveals() {
        // With the edge-activation pref off, even the left edge yields
        // nothing in windowed mode.
        Prefs.editRailVisibleInWindowed = false
        let content = makeContent()
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()

        for p in [
            CGPoint(x: 600, y: 790),
            CGPoint(x: 600, y: 10),
            CGPoint(x: 10, y: 400),
            CGPoint(x: 1190, y: 400),
        ] {
            content.evaluateZonesForTesting(at: p)
            for panel in ViewerContentView.PanelKind.allCases {
                XCTAssertFalse(
                    content.isHoveredForTesting(panel),
                    "edge-activation disabled: \(panel) must not reveal at \(p)"
                )
            }
        }
    }

    // MARK: - Pin toggle persists

    func testPinToggle_Filmstrip_PersistsToPrefs() {
        let content = makeContent()
        content.windowMode = .fullscreen

        XCTAssertFalse(Prefs.filmstripPinnedFullscreen,
                       "pref starts false (cleared in setUp)")
        XCTAssertFalse(content.isPinnedForTesting(.filmstrip))

        content.togglePanel(.filmstrip)
        XCTAssertTrue(Prefs.filmstripPinnedFullscreen,
                      "toggle must write-through to Prefs")
        XCTAssertTrue(content.isPinnedForTesting(.filmstrip))

        content.togglePanel(.filmstrip)
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen,
                       "toggle again unpins")
        XCTAssertFalse(content.isPinnedForTesting(.filmstrip))
    }

    func testPinToggle_EachPanel_WritesCorrectPrefKey() {
        let content = makeContent()
        content.windowMode = .fullscreen

        // The capsule is never pinned.
        content.togglePanel(.toolbar)
        XCTAssertFalse(content.isPinnedForTesting(.toolbar))
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen,
                       "toolbar toggle must not touch filmstrip pref")

        content.togglePanel(.editRail)
        XCTAssertTrue(Prefs.editRailPinnedFullscreen)

        content.togglePanel(.inspector)
        XCTAssertTrue(Prefs.exifPanelPinnedFullscreen,
                      "inspector maps to the 'exifPanelPinnedFullscreen' pref")
    }

    // MARK: - Mode swap preserves pin state

    func testModeSwap_PinPreserved_ViaPrefs() {
        // Set up a pinned inspector in Prefs *before* the view exists —
        // this simulates closing & reopening the viewer, or fullscreen
        // toggles bouncing the mode through. The init path must read
        // Prefs and seed pinnedPanels accordingly.
        Prefs.exifPanelPinnedFullscreen = true

        let content = makeContent()
        XCTAssertTrue(content.isPinnedForTesting(.inspector),
                      "init must seed pinnedPanels from Prefs")

        // Swap modes a few times. Pin state is driven by Prefs; we
        // never call togglePanel here, so the pref stays true and the
        // in-memory bit must too.
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isPinnedForTesting(.inspector))

        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isPinnedForTesting(.inspector))

        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isPinnedForTesting(.inspector))
    }

    // MARK: - Idle expiry hides hover but not pin

    func testIdleExpiry_HidesHoveredPanels_LeavesPinnedAlone() {
        let content = makeContent()
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Pin the inspector, then hover over the editRail zone.
        // Expected post-hover state: inspector pinned (visible),
        // editRail hovered (visible), rest hidden.
        content.togglePanel(.inspector)
        XCTAssertTrue(content.isPinnedForTesting(.inspector))

        content.evaluateZonesForTesting(at: CGPoint(x: 20, y: 400))
        XCTAssertTrue(content.isHoveredForTesting(.editRail))

        // Force the idle timer to fire. The editRail is hover-only,
        // so it must drop out of `hoveredPanels`. The inspector is
        // pinned, so it survives.
        content.forceIdleFireForTesting()
        XCTAssertFalse(content.isHoveredForTesting(.editRail),
                       "idle expiry must clear hover-only panels")
        XCTAssertTrue(content.isPinnedForTesting(.inspector),
                      "pinned panels survive idle expiry")
    }

    // MARK: - Filmstrip windowed-toggle path

    func testFilmstripToggle_InWindowedMode_FlipsVisibilityPref() {
        let content = makeContent()
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()

        XCTAssertTrue(Prefs.filmstripVisibleInWindowed,
                      "windowed filmstrip visible by default")

        // In windowed mode, togglePanel(.filmstrip) flips the
        // visibility pref — NOT the fullscreen pin pref.
        content.togglePanel(.filmstrip)
        XCTAssertFalse(Prefs.filmstripVisibleInWindowed,
                       "windowed toggle flips the visibility pref off")
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen,
                       "windowed toggle must NOT touch the fullscreen pin pref")

        content.togglePanel(.filmstrip)
        XCTAssertTrue(Prefs.filmstripVisibleInWindowed)
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen)
    }
}

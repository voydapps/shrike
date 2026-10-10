//
//  GlassHUDTests.swift
//  ShrikeUITests
//
//  Liquid Glass on the full-screen HUDs (macOS 26) and the
//  solid recipe on macOS 14 / 15, the lazy
//  build ("nothing on the first-pixel path"), the glass
//  geometry and the HUD buttons.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class GlassHUDTests: XCTestCase {

    private let pinKeys = [
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.editRail.pinnedFullscreen",
        "shrike.viewer.exifPanel.pinnedFullscreen",
        "shrike.viewer.histogramVisible",
    ]

    override func setUp() {
        super.setUp()
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        HUDGlass.forceFallbackForTesting = false
        ShrikeTokens.increaseContrastOverride = false
    }

    override func tearDown() {
        HUDGlass.forceFallbackForTesting = false
        ShrikeTokens.increaseContrastOverride = nil
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        super.tearDown()
    }

    private func makeContent(_ mode: ViewerContentView.WindowMode = .fullscreen) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func requireGlass() throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Liquid Glass needs macOS 26") }
    }

    /// Shows every HUD.
    private func revealEverything(_ content: ViewerContentView) {
        content.togglePanel(.filmstrip)          // filmstrip + capsule
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        _ = content.histogramOverlayFrameForTesting()   // builds it
        if let histogram = content.histogramOverlayIfBuiltForTesting {
            histogram.isHidden = false
            histogram.alphaValue = 1
        }
        let pill = content.navigationPositionOverlayForTesting
        pill.isHidden = false
        pill.alphaValue = 1
        content.zoomBadgeForTesting.alphaValue = 1
        content.toastHost.show("Copied")
        content.toastHost.alphaValue = 1
        content.layoutSubtreeIfNeeded()
    }

    private func surfaces(_ content: ViewerContentView) -> [(String, HUDSurfaceView)] {
        var out: [(String, HUDSurfaceView)] = [
            ("capsule", content.toolbarForTesting),
            ("filmstrip", content.filmstripForTesting),
            ("rail", content.editRailForTesting),
            ("inspector", content.inspectorForTesting),
            ("pill", content.navigationPositionOverlayForTesting),
            ("zoom badge", content.zoomBadgeForTesting),
            ("toast", content.toastHost),
        ]
        if let histogram = content.histogramOverlayIfBuiltForTesting {
            out.append(("histogram", histogram))
        }
        return out
    }

    private func srgb(_ color: CGColor?) -> NSColor? {
        color.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    }

    // MARK: The capsule is a capsule of glass, in one container

    func testVector1_CapsuleIsRegularGlassWithAHalfHeightRadiusInTheOneContainer() throws {
        try requireGlass()
        guard #available(macOS 26, *) else { return }
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()

        let capsule = content.toolbarForTesting
        XCTAssertFalse(capsule.isHidden)
        XCTAssertEqual(capsule.look, .glass)
        let glass = try XCTUnwrap(capsule.glassViewForTesting as? NSGlassEffectView)
        XCTAssertEqual(glass.style, .regular)
        XCTAssertEqual(glass.tintColor, HUDGlass.glassTintColor, "dark tint")
        XCTAssertEqual(capsule.frame.height, 44, accuracy: 0.5)
        XCTAssertEqual(glass.cornerRadius, capsule.bounds.height / 2, accuracy: 0.01,
                       "cornerRadius = height / 2")

        let container = try XCTUnwrap(content.glassContainerForTesting as? NSGlassEffectContainerView)
        XCTAssertEqual(container.spacing, 0)
        XCTAssertTrue(capsule.isDescendant(of: container))
        XCTAssertTrue(content.filmstripForTesting.isDescendant(of: container))
        // A tall panel is solid, never glass.
        XCTAssertNil(content.filmstripForTesting.glassViewForTesting)
        XCTAssertEqual(content.filmstripForTesting.fillLayerForTesting?.cornerRadius, 16)
    }

    func testEveryFullScreenHUDIsGlassInsideTheSameContainer() throws {
        try requireGlass()
        guard #available(macOS 26, *) else { return }
        let content = makeContent()
        revealEverything(content)
        let container = try XCTUnwrap(content.glassContainerForTesting)
        var containers = 0
        func walk(_ v: NSView) {
            if v is NSGlassEffectContainerView { containers += 1 }
            v.subviews.forEach(walk)
        }
        walk(content)
        XCTAssertEqual(containers, 1, "one glass container per full-screen viewer")
        for (name, surface) in surfaces(content) {
            let capsuleShaped = ["capsule", "pill", "toast", "zoom badge"].contains(name)
            XCTAssertTrue(surface.isDescendant(of: container), "\(name) is in the container")
            if capsuleShaped {
                XCTAssertEqual(surface.look, .glass, name)
                let glass = try XCTUnwrap(surface.glassViewForTesting as? NSGlassEffectView, name)
                XCTAssertEqual(glass.style, .regular, name)
                XCTAssertEqual(glass.cornerRadius, surface.bounds.height / 2, accuracy: 0.01, name)
            } else {
                XCTAssertEqual(surface.look, .solid, "\(name): solid panel")
                XCTAssertNil(surface.glassViewForTesting, name)
            }
        }
        for (_, surface) in surfaces(content) { surface.alphaValue = 0 }
        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        content.toastHost.dismiss(animated: false)
    }

    // MARK: Glass geometry

    func testGlassPanelsFloat12ptFromTheScreenEdges() throws {
        try requireGlass()
        let content = makeContent()
        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()

        let strip = content.filmstripForTesting.frame
        XCTAssertEqual(strip.minY, 12, accuracy: 0.5, "12 pt above the bottom edge")
        XCTAssertEqual(strip.minX, 12, accuracy: 0.5)
        XCTAssertEqual(strip.maxX, 1440 - 12, accuracy: 0.5)
        XCTAssertEqual(strip.height, 88, accuracy: 0.5)
        XCTAssertEqual(content.capsuleFrameForTesting.minY, strip.maxY + 12, accuracy: 0.5,
                       "the capsule still sits 12 pt above the filmstrip")
        XCTAssertEqual(content.editRailForTesting.frame.minX, 12, accuracy: 0.5)
        XCTAssertEqual(content.inspectorForTesting.frame.maxX, 1440 - 12, accuracy: 0.5)
        // The pill shares the rail's left edge and the
        // capsule's row.
        let pill = content.pillFrameForTesting
        XCTAssertEqual(pill.minX, 12, accuracy: 0.5)
        XCTAssertEqual(pill.minY, content.capsuleFrameForTesting.minY, accuracy: 0.5)

        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
    }

    func testGlassHistogramSits12ptFromTheRightEdge() throws {
        try requireGlass()
        let content = makeContent()
        _ = content.histogramOverlayFrameForTesting()   // builds it
        let histogram = try XCTUnwrap(content.histogramOverlayIfBuiltForTesting)
        histogram.isHidden = false
        histogram.alphaValue = 1
        XCTAssertEqual(histogram.look, .solid)
        let frame = content.histogramOverlayFrameForTesting()
        XCTAssertEqual(frame.maxX, 1440 - 12, accuracy: 0.5)
        XCTAssertEqual(frame.minY, 16, accuracy: 0.5)
        XCTAssertEqual(frame.width, 320, accuracy: 0.5)
        XCTAssertEqual(frame.height, 180, accuracy: 0.5)
    }

    func testLeavingFullScreenRestoresTheMaterialAndReusesTheGlassLater() throws {
        try requireGlass()
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        let capsule = content.toolbarForTesting
        XCTAssertEqual(capsule.look, .glass)
        let built = HUDGlass.glassViewsBuiltForTesting

        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        let strip = content.filmstripForTesting
        XCTAssertNotEqual(strip.look, .glass)
        XCTAssertNil(strip.glassViewForTesting?.superview, "the glass leaves the window")
        XCTAssertEqual(strip.frame.minX, 0, accuracy: 0.5, "docked edge to edge in a window")
        XCTAssertEqual(strip.frame.maxX, 1440, accuracy: 0.5)
        XCTAssertEqual(strip.contentHost.superview, strip, "the docked strip has no material")

        content.windowMode = .fullscreen
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(capsule.look, .glass)
        XCTAssertEqual(content.capsuleFrameForTesting.height, 44, accuracy: 0.5,
                       "the capsule keeps its layout through the moves")
        XCTAssertEqual(HUDGlass.glassViewsBuiltForTesting, built, "the glass views are reused")
    }

    // MARK: MacOS 14 / 15: the material, no glass

    func testVector2_FallbackRevealBuildsNoGlassAndKeepsTheHUDMaterial() {
        HUDGlass.forceFallbackForTesting = true
        let views = HUDGlass.glassViewsBuiltForTesting
        let containers = HUDGlass.containersBuiltForTesting
        let content = makeContent()
        revealEverything(content)

        XCTAssertNil(content.glassContainerForTesting, "no glass container on macOS 14 / 15")
        XCTAssertEqual(HUDGlass.containersBuiltForTesting, containers)
        XCTAssertEqual(HUDGlass.glassViewsBuiltForTesting, views, "no glass view on macOS 14 / 15")
        XCTAssertEqual(surfaces(content).count, 8)
        for (name, surface) in surfaces(content) {
            XCTAssertFalse(surface.isHidden, name)
            XCTAssertEqual(surface.look, .solid, name)
            XCTAssertNil(surface.glassViewForTesting, name)
            XCTAssertNotNil(surface.fillLayerForTesting, name)
            XCTAssertTrue(surface.contentHost.superview === surface, name)
        }
        // The strip floats on macOS 14 / 15 as well.
        XCTAssertEqual(content.filmstripForTesting.frame.minY, 12, accuracy: 0.5)
        XCTAssertEqual(content.filmstripForTesting.frame.width, 1440 - 24, accuracy: 0.5)
        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        content.toastHost.dismiss(animated: false)
    }

    // MARK: Increase Contrast

    /// The layer that draws the border: the fill layer (solid look) or
    /// the surface layer (glass look).
    private func borderLayer(_ surface: HUDSurfaceView) -> CALayer? {
        surface.look == .glass ? surface.layer : surface.fillLayerForTesting
    }

    func testVector3_IncreaseContrastGivesFullScreenHUDsAWhiteBorder() {
        ShrikeTokens.increaseContrastOverride = true
        for fallback in [false, true] {
            HUDGlass.forceFallbackForTesting = fallback
            let content = makeContent()
            revealEverything(content)
            for (name, surface) in surfaces(content) {
                let layer = borderLayer(surface)
                XCTAssertEqual(layer?.borderWidth, 1, "\(name) (fallback \(fallback))")
                let color = srgb(layer?.borderColor)
                XCTAssertEqual(color?.redComponent ?? 0, 1, accuracy: 0.01, name)
                XCTAssertEqual(color?.greenComponent ?? 0, 1, accuracy: 0.01, name)
                XCTAssertEqual(color?.blueComponent ?? 0, 1, accuracy: 0.01, name)
                XCTAssertEqual(color?.alphaComponent ?? 0, 0.35, accuracy: 0.01, "\(name): white at 35 %")
            }
            content.togglePanel(.filmstrip)
            content.togglePanel(.editRail)
            content.togglePanel(.inspector)
            content.toastHost.dismiss(animated: false)
        }
    }

    func testVector3_IncreaseContrastGivesWindowedHUDsASeparatorBorder() {
        ShrikeTokens.increaseContrastOverride = true
        let content = makeContent(.windowed)
        let badge = content.zoomBadgeForTesting
        badge.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(badge.fillLayerForTesting?.borderWidth, 1)
        XCTAssertEqual(badge.fillLayerForTesting?.borderColor,
                       NSColor.separatorColor.resolvedCGColor(for: badge.effectiveAppearance),
                       "separatorColor in a window")
        // The docked filmstrip is not a HUD: no border.
        XCTAssertEqual(content.filmstripForTesting.layer?.borderWidth ?? 0, 0)
        XCTAssertEqual(content.filmstripForTesting.fillLayerForTesting?.borderWidth ?? 0, 0)
    }

    /// The 1 pt hairline (white at 12 %) is always on.
    func testVector3_AlwaysAHairlineWithoutIncreaseContrast() {
        let content = makeContent()
        revealEverything(content)
        for (name, surface) in surfaces(content) {
            let layer = borderLayer(surface)
            XCTAssertEqual(layer?.borderWidth ?? 0, 1, name)
            XCTAssertEqual(srgb(layer?.borderColor)?.alphaComponent ?? 0, 0.12, accuracy: 0.01, name)
        }
        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        content.toastHost.dismiss(animated: false)
    }

    func testVector3_SelectionRingIs3ptUnderIncreaseContrast() {
        let strip = FilmstripView()
        let plain = strip.injectCellForTesting(globalIndex: 0, aspect: 1)
        XCTAssertEqual(strip.selectionRingWidthForTesting(selecting: plain), 2)
        ShrikeTokens.increaseContrastOverride = true
        let contrast = strip.injectCellForTesting(globalIndex: 1, aspect: 1)
        XCTAssertEqual(strip.selectionRingWidthForTesting(selecting: contrast), 3)
    }

    // MARK: Nothing built before a reveal

    func testNoGlassIsBuiltBeforeAHUDShows() throws {
        try requireGlass()
        let views = HUDGlass.glassViewsBuiltForTesting
        let windowed = makeContent(.windowed)
        XCTAssertNil(windowed.glassContainerForTesting, "a viewer opens in a window: no container")
        windowed.zoomBadgeForTesting.alphaValue = 1
        windowed.layoutSubtreeIfNeeded()
        XCTAssertEqual(HUDGlass.glassViewsBuiltForTesting, views, "no glass in a window")

        let full = makeContent()
        XCTAssertNotNil(full.glassContainerForTesting, "the container comes with full screen")
        XCTAssertEqual(HUDGlass.glassViewsBuiltForTesting, views, "no glass until a HUD shows")
        for (name, surface) in surfaces(full) {
            XCTAssertNil(surface.glassViewForTesting, name)
        }
        full.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        XCTAssertEqual(HUDGlass.glassViewsBuiltForTesting, views + 1,
                       "the first reveal builds the capsule's glass only (the strip is solid)")
    }

    // MARK: Standalone buttons and Done

    func testStandaloneButtonsAreGlassAndDoneIsProminentOnMacOS26() throws {
        try requireGlass()
        guard #available(macOS 26, *) else { return }
        let empty = ViewerEmptyStateView()
        XCTAssertEqual(empty.showFolderButton.bezelStyle, .glass)
        XCTAssertEqual(empty.closeButton.bezelStyle, .glass)

        let welcome = WelcomeWindowController(recentURLs: { [] })
        defer { welcome.close() }
        // Plain push buttons; Open… is not the accent default button.
        XCTAssertEqual(welcome.openButton.bezelStyle, .push)
        XCTAssertEqual(welcome.openFolderButton.bezelStyle, .push)
        XCTAssertNil(welcome.openButton.bezelColor)
        XCTAssertEqual(welcome.openButton.keyEquivalent, "")

        let edit = EditToolbarController()
        let done = edit.toolbar(edit.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.done,
                                willBeInsertedIntoToolbar: true)
        XCTAssertNotEqual(done?.style, .prominent, "no own blue")
        XCTAssertEqual((done?.view as? NSButton)?.bezelColor, .controlAccentColor)
        let cancel = edit.toolbar(edit.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.cancel,
                                  willBeInsertedIntoToolbar: true)
        XCTAssertEqual(cancel?.style, .plain)
    }

    func testFullScreenEditCapsuleIsAGlassCapsuleInTheContainer() throws {
        try requireGlass()
        guard #available(macOS 26, *) else { return }
        let content = makeContent()
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        content.layoutSubtreeIfNeeded()
        let capsule = content.editCapsule
        XCTAssertEqual(capsule.look, .glass)
        XCTAssertTrue(capsule.isDescendant(of: try XCTUnwrap(content.glassContainerForTesting)))
        let glass = try XCTUnwrap(capsule.glassViewForTesting as? NSGlassEffectView)
        XCTAssertGreaterThan(capsule.bounds.height, 0)
        XCTAssertEqual(glass.cornerRadius, capsule.bounds.height / 2, accuracy: 0.01)
        XCTAssertEqual(capsule.frame.minY, 16, accuracy: 0.5)
        XCTAssertEqual(capsule.frame.midX, 720, accuracy: 0.5)
        content.editModeController.finalizeExit()
    }

    // MARK: HUD buttons

    func testCapsuleButtonsAreBorderless28ptWithA15ptSymbolAndAHoverPlatter() throws {
        let content = makeContent()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))
        content.layoutSubtreeIfNeeded()
        var buttons: [HUDButton] = []
        func walk(_ v: NSView) {
            if let b = v as? HUDButton { buttons.append(b) }
            v.subviews.forEach(walk)
        }
        walk(content.toolbarForTesting)
        XCTAssertFalse(buttons.isEmpty)
        for button in buttons {
            XCTAssertFalse(button.isBordered)
            XCTAssertEqual(button.frame.width, 28, accuracy: 0.5)
            XCTAssertEqual(button.frame.height, 28, accuracy: 0.5)
            XCTAssertEqual(button.contentTintColor, .labelColor)
        }
        let button = try XCTUnwrap(buttons.first)
        XCTAssertEqual(button.platterAlphaForTesting, 0, accuracy: 0.001)
        button.setPointerStateForTesting(hovered: true, pressed: false)
        XCTAssertEqual(button.platterAlphaForTesting, 0.10, accuracy: 0.001)
        button.setPointerStateForTesting(hovered: true, pressed: true)
        XCTAssertEqual(button.platterAlphaForTesting, 0.18, accuracy: 0.001)
        button.setPointerStateForTesting(hovered: false, pressed: false)
        XCTAssertEqual(button.platterAlphaForTesting, 0, accuracy: 0.001)
    }
}

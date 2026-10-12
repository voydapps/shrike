//
//  PanelPolishTests.swift
//  ShrikeUITests
//
//  Panel polish: pin placement, the edit tool picker, plus these behaviours:
//
//   * the fullscreen filmstrip cell doesn't clip against the pin strip
//   * the fullscreen filmstrip leaves enough headroom to scroll cleanly
//   * the position overlay's auto-hide flag responds to pref flips live
//   * in windowed mode, the position overlay never overlaps the docked
//     filmstrip — it anchors 8 pt above the strip's top
//   * thumbnail aspect derives from the delivered CGImage (authoritative),
//     not a separate header read (that was racing ahead → portraits
//     landed as squares for 100 ms)
//   * each toolbar button has its own target/action so zoom/rotate
//     misrouting is structurally impossible
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class PanelPolishTests: XCTestCase {

    // MARK: - Fixture helpers

    private func clearChromePrefs() {
        let ud = ShrikeDefaults.store
        for key in [
            "shrike.viewer.filmstrip.visibleInWindowed",
            "shrike.viewer.filmstrip.heightPt",
            "shrike.viewer.filmstrip.pinnedFullscreen",
            "shrike.viewer.exifPanel.pinnedFullscreen",
            "shrike.viewer.chromeFadeOutDelayMs",
            "shrike.viewer.positionOverlayAutoHides",
        ] { ud.removeObject(forKey: key) }
    }

    override func setUp() async throws {
        try await super.setUp()
        clearChromePrefs()
        // The macOS 14 / 15 geometry, also used on
        // macOS 26. GlassHUDTests covers the glass geometry.
        HUDGlass.forceFallbackForTesting = true
    }

    override func tearDown() async throws {
        HUDGlass.forceFallbackForTesting = false
        clearChromePrefs()
        try await super.tearDown()
    }

    private func makeContent(
        size: CGSize = CGSize(width: 1200, height: 800)
    ) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(origin: .zero, size: size)
        content.layoutSubtreeIfNeeded()
        return content
    }

    // MARK: - Pins have their own slots

    func testPin_Filmstrip_TrailingSlotOutsideTheScroller() {
        let strip = FilmstripView()
        strip.setMode(.fullscreen)
        strip.frame = CGRect(x: 0, y: 0, width: 1200, height: 88)
        strip.layoutSubtreeIfNeeded()

        let overlay = strip.pinOverlayForTesting
        XCTAssertEqual(overlay.frame.width, 28, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.height, 28, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.midX, 1200 - 18, accuracy: 0.5, "centred in the 36 pt slot")
        XCTAssertEqual(overlay.frame.midY, 44, accuracy: 0.5, "centred vertically")
        XCTAssertEqual(strip.scrollerFrameForTesting.maxX, 1200 - 36, accuracy: 0.5,
                       "the scroller ends before the slot")
        XCTAssertFalse(strip.scrollerFrameForTesting.intersects(overlay.frame))

        strip.setMode(.windowed)
        XCTAssertEqual(strip.scrollerFrameForTesting.maxX, 1200, accuracy: 0.5, "no slot in a window")
    }

    func testPin_Inspector_TrailingEndOfHeaderRow() {
        let inspector = InspectorPanel()
        inspector.frame = CGRect(x: 0, y: 0, width: 280, height: 600)
        inspector.layoutSubtreeIfNeeded()

        let overlay = inspector.pinOverlayForTesting
        let header = inspector.headerFrameForTesting
        XCTAssertEqual(overlay.frame.width, 28, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.maxX, 280 - 8, accuracy: 0.5)
        XCTAssertEqual(overlay.frame.midY, header.height / 2, accuracy: 0.5)
        XCTAssertEqual(header.maxY, 600, accuracy: 0.5, "the header is the top row")
    }



    // MARK: - Rotate Left / Right are toolbar (file) actions

    func testRotateLeftRight_OnToolbarNotInThePicker() {
        XCTAssertEqual(EditChromeTools.order, [.crop, .rotate, .resize, .color, .levels],
                       "the picker holds tools, not the file actions")

        let toolbar = ViewerToolbar()
        let toolbarActions = toolbar.buttonActionsForTesting()
        var toolLeft = 0, toolRight = 0
        for a in toolbarActions {
            switch a {
            case .rotateLeft:  toolLeft += 1
            case .rotateRight: toolRight += 1
            default: break
            }
        }
        XCTAssertEqual(toolLeft, 1, "toolbar retains Rotate Left")
        XCTAssertEqual(toolRight, 1, "toolbar retains Rotate Right")
    }

    // MARK: Tool picker inventory: Crop, Rotate, Resize, Color, Levels

    func testToolPicker_Inventory_CropRotateResizeColorLevels() {
        let picker = EditToolPicker()
        XCTAssertEqual(picker.segmentCount, 5)
        XCTAssertEqual(EditChromeTools.order.map(EditChromeTools.name), ["Crop", "Rotate", "Resize", "Color", "Levels"])
        for i in 0..<5 {
            XCTAssertEqual(picker.width(forSegment: i), 32)
            XCTAssertNotNil(picker.image(forSegment: i))
            XCTAssertEqual(picker.label(forSegment: i) ?? "", "", "icon-only")
        }
        XCTAssertEqual(picker.selectedSegment, -1, "no tool on entry")
        XCTAssertEqual(picker.accessibilityLabel(), "Tool")
    }

    // MARK: - ⇧⌘E is free

    func testShiftCommandE_HasNoBindingAndNoCommand() {
        let shiftCmdE = KeyBinding("e", [.command, .shift])
        let contexts: [ShortcutContext] = [.viewer, .browser, .compare, .slideshow, .editMode]
        for preset in ShortcutPreset.allCases {
            for context in contexts {
                for command in ShrikeCommand.allCases {
                    let bound = ShortcutTable.bindings(for: command, context: context, preset: preset)
                    XCTAssertFalse(bound.contains(shiftCmdE), "\(command) must not use ⇧⌘E (\(context))")
                }
            }
        }
        XCTAssertFalse(ShrikeCommand.allCases.contains { $0.rawValue.lowercased().contains("rail") })
    }

    // MARK: - Fullscreen filmstrip returns to 88/72

    func testFullscreenFilmstrip_CellsAre72pt() {
        let strip = FilmstripView()
        strip.setMode(.fullscreen)
        strip.frame = CGRect(x: 0, y: 0, width: 1200, height: 88)
        strip.layoutSubtreeIfNeeded()

        XCTAssertEqual(strip.cellSizeForTesting, 72, accuracy: 0.5,
                       "fullscreen cell size is 72 pt")
    }

    // MARK: - Fullscreen filmstrip has a scrollable content region

    func testFullscreenFilmstrip_ContentFrameLeavesRoomForCellPlusInsets() {
        let strip = FilmstripView()
        strip.setMode(.fullscreen)
        strip.frame = CGRect(x: 0, y: 0, width: 1200, height: 88)
        strip.layoutSubtreeIfNeeded()

        let contentFrame = strip.contentViewForTesting.frame
        let cellSize = strip.cellSizeForTesting

        XCTAssertGreaterThanOrEqual(contentFrame.height, cellSize,
                                    "scroll view height must accommodate a cell")
    }

    // MARK: - Issue #4 — position overlay auto-hide reads pref live

    func testPositionOverlay_AutoHides_ReadsPrefLive() {
        let overlay = NavigationPositionOverlayView()
        Prefs.viewerPositionOverlayAutoHides = false
        XCTAssertFalse(overlay.autoHides,
                       "overlay reads pref on every access — pref false → false")

        Prefs.viewerPositionOverlayAutoHides = true
        XCTAssertTrue(overlay.autoHides,
                      "pref flip is visible without a setter call")
    }

    func testPositionOverlay_AutoHidesOverride_TakesPrecedence() {
        let overlay = NavigationPositionOverlayView()
        Prefs.viewerPositionOverlayAutoHides = false
        overlay.autoHidesOverrideForTesting = true
        XCTAssertTrue(overlay.autoHides,
                      "test override wins over UserDefaults read")
    }

    // MARK: - Issue #5 — position overlay anchors above filmstrip in windowed

    func testWindowed_PositionOverlay_AnchorsAboveFilmstrip() {
        Prefs.filmstripVisibleInWindowed = true
        let content = makeContent()
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()

        let overlayFrame = content.navigationPositionOverlayForTesting.frame
        let filmstripFrame = content.filmstripForTesting.frame

        // In the AppKit bottom-origin coord, overlay.maxY < filmstrip.minY
        // would mean overlay is fully below strip top. We want 'above
        // filmstrip top', i.e. overlay.minY > filmstrip.maxY (strictly
        // above) — except in AppKit origin, filmstrip is DOCKED AT BOTTOM
        // so filmstrip.maxY = height-of-strip. Overlay should sit 8 pt
        // above that.
        XCTAssertGreaterThanOrEqual(
            overlayFrame.minY,
            filmstripFrame.maxY,
            "position overlay's bottom must be at or above the filmstrip's top in windowed mode"
        )
    }

    /// The pill sits 16 pt above the bottom with no stack,
    /// 12 pt above the capsule while the stack shows.
    func testFullscreen_PositionOverlay_FollowsTheBottomStack() {
        Prefs.filmstripPinnedFullscreen = false
        let content = makeContent()
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.pillFrameForTesting.minY, 16, accuracy: 1.5)
        XCTAssertEqual(content.pillFrameForTesting.minX, 12, accuracy: 1.5)

        content.togglePanel(.filmstrip)   // pinned strip
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))   // the pointer rests in the bottom zone: capsule + strip   // (spec 24: the pointer shows the capsule, not the pin)
        let capsule = content.capsuleFrameForTesting
        XCTAssertEqual(capsule.minY, 12 + 88 + 12, accuracy: 1.5, "capsule 12 pt above the floating strip")
        XCTAssertEqual(capsule.height, 44, accuracy: 0.5)
        XCTAssertEqual(content.pillFrameForTesting.minY, capsule.minY, accuracy: 1.5, "the pill shares the capsule's row")
        content.togglePanel(.filmstrip)
    }

    // MARK: - Issue #9 — aspect from thumb takes precedence over header

    func testCellAspect_DerivesFromDeliveredThumb() {
        let strip = FilmstripView()
        strip.setMode(.fullscreen)
        strip.frame = CGRect(x: 0, y: 0, width: 1200, height: 88)

        // Inject a synthetic cell; the header-probe path is a no-op for
        // SyntheticPlaceholderSource, so the initial aspect is 1.0.
        _ = strip.injectCellForTesting(globalIndex: 7, aspect: 1.0)

        var observed: [(Int, CGFloat)] = []
        strip.cellAspectAppliedSink = { idx, a in observed.append((idx, a)) }

        // Simulate a portrait thumbnail landing (e.g. 1200×1800).
        strip.simulateThumbnailDeliveredForTesting(
            globalIndex: 7, pixelWidth: 1200, pixelHeight: 1800
        )

        XCTAssertEqual(observed.count, 1)
        XCTAssertEqual(observed.first?.0, 7)
        XCTAssertEqual(observed.first?.1 ?? 0, 1200.0 / 1800.0, accuracy: 0.001)
    }

    // MARK: - Issue #10 — each toolbar button has its own selector

    func testToolbar_EachButtonHasUniqueSelector() {
        let toolbar = ViewerToolbar()
        let buttonActions: [ViewerAction] = [
            .prevImage, .nextImage, .zoomMenu,
            .rotateLeft, .rotateRight,
            .share, .openEditMode, .deleteToTrash,
            .showInBrowser, .toggleInspector, .toggleFullscreen,
        ]

        var selectors: [Selector] = []
        for action in buttonActions {
            guard let pair = toolbar.targetActionForButtonTesting(action),
                  let sel = pair.1 else {
                XCTFail("missing button for \(action)")
                continue
            }
            XCTAssertFalse(selectors.contains(sel),
                           "selector \(sel) reused across buttons — issue #10 regression")
            selectors.append(sel)
        }
        XCTAssertEqual(selectors.count, buttonActions.count)
    }

    func testToolbar_RotateLeftAndRotateRight_RouteToDistinctSelectors() {
        let toolbar = ViewerToolbar()
        guard let l = toolbar.targetActionForButtonTesting(.rotateLeft)?.1,
              let r = toolbar.targetActionForButtonTesting(.rotateRight)?.1 else {
            XCTFail("missing rotate button")
            return
        }
        XCTAssertNotEqual(l, r, "rotate-left and rotate-right use distinct selectors")
    }

    func testToolbar_ButtonOrder() {
        let toolbar = ViewerToolbar()
        // Spec 24 §1.3: exactly these 11, in this order.
        let expected: [ViewerAction] = [
            .prevImage, .nextImage, .zoomMenu,
            .rotateLeft, .rotateRight,
            .share, .openEditMode, .deleteToTrash,
            .showInBrowser, .toggleInspector, .toggleFullscreen,
        ]
        XCTAssertEqual(toolbar.buttonActionsForTesting(), expected)
    }

    // MARK: - Hover hysteresis

    /// When cursor is inside the hot zone, the panel is visible. Baseline
    /// check before the hysteresis paths.
    func testHover_ZoneHit_RevealsPanel() {
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        // Cursor near the left edge (inspector zone).
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
    }

    /// Once a panel is visible, the cursor may drift onto its body and
    /// still count as "hovered" — this is the hysteresis fix. Without it,
    /// moving from the edge band into the panel content would hide it.
    func testHover_CursorOnPanelBodyKeepsPanelVisible() {
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // 1. Reveal the inspector via zone.
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.inspector))

        // 2. Move cursor onto the inspector body (past the zone edge but still
        //    within the inspector's own frame). Use the
        //    panel's actual frame as source of truth.
        let panelFrame = content.inspectorForTesting.frame
        let bodyPoint = NSPoint(x: panelFrame.midX, y: panelFrame.midY)
        content.evaluateZonesForTesting(at: bodyPoint)

        // the inspector should still be considered hovered (body-hit path).
        XCTAssertTrue(content.isHoveredForTesting(.inspector),
                      "cursor over panel body must keep it in hoveredPanels")
    }

    /// When the cursor leaves both the zone AND the body, a 200 ms
    /// grace timer is scheduled. Until it fires, the panel stays
    /// visible (still in hoveredPanels).
    func testHover_ExitGraceTimerScheduled_NotImmediatelyDropped() {
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Reveal the inspector.
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.inspector))

        // Move cursor to the middle of the canvas — well away from any
        // zone or panel body.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))

        // Grace timer should be scheduled, panel still listed as hovered.
        XCTAssertTrue(content.panelExitGraceActiveForTesting(.inspector),
                      "leaving the zone+body schedules a 200 ms exit-grace timer")
        XCTAssertTrue(content.isHoveredForTesting(.inspector),
                      "panel is not immediately dropped — timer owns the hide")
    }

    /// Re-entering the zone during the grace window cancels the timer.
    func testHover_ReentryDuringGraceCancelsHide() {
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Reveal.
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        content.layoutSubtreeIfNeeded()
        // Exit.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))
        XCTAssertTrue(content.panelExitGraceActiveForTesting(.inspector))

        // Re-enter before the timer fires.
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        XCTAssertFalse(content.panelExitGraceActiveForTesting(.inspector),
                       "re-entry cancels the pending exit-grace timer")
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
    }

    /// Regression: "in fullscreen mode, panels are
    /// not hiding if cursor leaves." After the cursor reveals an edge
    /// panel and then drifts back to the canvas centre, the 200 ms exit
    /// grace must actually drop the panel — not just schedule a timer
    /// that is silently cancelled when its body-hit check misfires.
    ///
    /// This test forces the queued grace work item to run synchronously
    /// (via `forceExitGraceFireForTesting`) and asserts the panel ends up
    /// removed from `hoveredPanels` AND hidden by `updatePanelVisibility`.
    func testHover_ExitGraceFires_HidesPanelOnceCursorLeftFullscreen() {
        Prefs.filmstripPinnedFullscreen = false
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        // The hide runs a 0.3 s alpha fade and only sets `isHidden` in its
        // completion; turn fades off so `isHidden` is checkable right away.
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Reveal filmstrip via bottom-edge hover.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 4))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip),
                      "precondition: bottom-edge hover reveals filmstrip")
        XCTAssertFalse(content.filmstripForTesting.isHidden,
                       "precondition: filmstrip is on-screen after reveal")

        // Cursor moves to the middle of the canvas — far from every
        // edge band and from every panel body.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))
        XCTAssertTrue(content.panelExitGraceActiveForTesting(.filmstrip),
                      "leaving the panel schedules a 200 ms exit-grace timer")
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip),
                      "panel still listed as hovered until the timer fires")

        // Fire the grace timer (simulates the 200 ms `DispatchWorkItem`).
        content.forceExitGraceFireForTesting(.filmstrip)

        XCTAssertFalse(content.isHoveredForTesting(.filmstrip),
                       "after grace fires, the panel must be removed from hoveredPanels")
        XCTAssertTrue(content.filmstripForTesting.isHidden,
                      "after grace fires, the panel must be hidden — this is the user-reported bug")
    }

    /// Regression continued: exercise the path where the view IS attached
    /// to a real NSWindow. In production `applyExitGrace` reads the live
    /// cursor via `window.mouseLocationOutsideOfEventStream` and bails out
    /// (without rescheduling) if the cursor happens to be inside the
    /// panel's frame. If a panel's frame is wrong (gotcha #1) or always
    /// trips contains(), the grace path silently no-ops and the panel
    /// never hides — matching the user-reported symptom.
    func testHover_ExitGraceFires_HidesPanelEvenWithRealWindow() {
        Prefs.filmstripPinnedFullscreen = false
        Prefs.exifPanelPinnedFullscreen = false
        Prefs.exifPanelPinnedFullscreen = false

        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        // Attach to a real window so `applyExitGrace`'s `if let window`
        // branch is taken. Without this the body-hit re-check is skipped
        // entirely and the bug is masked.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.contentView = content
        content.layoutSubtreeIfNeeded()

        // Reveal all four panels by walking the cursor through every edge.
        for p in [
            NSPoint(x: 600, y: 4),    // bot  → filmstrip + capsule
            NSPoint(x: 4,   y: 400),  // left → nothing
            NSPoint(x: 1196, y: 400), // right→ inspector
        ] {
            content.evaluateZonesForTesting(at: p)
            content.layoutSubtreeIfNeeded()
        }

        // Cursor moves to the dead-centre of the canvas — far from every
        // edge zone and from every panel body.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))
        // `applyExitGrace` re-reads the pointer from the window. Pin it to
        // the same centre point: the live pointer is wherever the real
        // mouse sits on screen, which made this test flaky (it failed
        // whenever the mouse was over the test window's inspector area).
        content.cursorLocationOverrideForTesting = NSPoint(x: 600, y: 400)

        // Fire each panel's exit-grace as if the 200 ms timer expired.
        for panel in ViewerContentView.PanelKind.allCases {
            content.forceExitGraceFireForTesting(panel)
        }

        // Every panel must be hidden after grace fires.
        for panel in ViewerContentView.PanelKind.allCases {
            XCTAssertFalse(
                content.isHoveredForTesting(panel),
                "after grace fires, \(panel) must drop out of hoveredPanels"
            )
        }
    }

    /// Regression, root cause of the same bug. `scheduleExitGrace`
    /// cancels any prior work item before scheduling a new one, and
    /// `evaluateZones` re-enters that path on EVERY mouseMoved while the
    /// cursor is sitting in the canvas (`leavingNow` keeps containing the
    /// panel because `hoveredPanels` deliberately keeps the leaving entries
    /// until the timer fires). The result: the timer's 200 ms deadline
    /// gets reset on every cursor jitter, so the panel never hides. The
    /// test pins this by asserting the work-item identity is STABLE across
    /// successive ticks while the cursor remains away from the panel.
    func testHover_ExitGrace_TimerNotResetByEachMouseMoveTick() {
        Prefs.filmstripPinnedFullscreen = false
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Reveal filmstrip via bottom-edge hover.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 4))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip))

        // Cursor moves to canvas centre — schedule grace.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))
        let identityAfterFirst = content.panelExitGraceWorkItemIdentityForTesting(.filmstrip)
        XCTAssertNotNil(identityAfterFirst,
                        "first mid-canvas tick schedules a grace timer")

        // Cursor jitters — three more ticks, all still mid-canvas, all
        // far from any panel body. The grace timer must NOT be replaced
        // each time, otherwise its 200 ms deadline keeps sliding forward
        // and the panel never hides (this is the user-reported bug).
        for _ in 0..<3 {
            content.evaluateZonesForTesting(at: NSPoint(x: 601, y: 401))
            content.evaluateZonesForTesting(at: NSPoint(x: 599, y: 399))
        }
        let identityAfterJitter = content.panelExitGraceWorkItemIdentityForTesting(.filmstrip)
        XCTAssertEqual(identityAfterJitter, identityAfterFirst,
                       "grace timer must be stable across cursor jitter — " +
                       "rescheduling on every tick would prevent the 200 ms deadline " +
                       "from ever elapsing if the user keeps moving the mouse")
    }

    /// When the pointer leaves the view
    /// entirely (another screen, the Dock) no further mouseMoved arrives,
    /// so `mouseExited` itself must start the exit grace — otherwise a
    /// hover-revealed panel stays up until the pointer comes back.
    func testHover_MouseExitedStartsExitGraceForRevealedPanels() throws {
        Prefs.filmstripPinnedFullscreen = false
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 4))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip), "precondition")
        XCTAssertFalse(content.panelExitGraceActiveForTesting(.filmstrip))

        let exit = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: NSPoint(x: -10, y: -10),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        content.mouseExited(with: exit)

        XCTAssertTrue(content.panelExitGraceActiveForTesting(.filmstrip),
                      "leaving the view schedules the exit grace")
        content.forceExitGraceFireForTesting(.filmstrip)
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip))
        XCTAssertTrue(content.filmstripForTesting.isHidden)
    }

    /// Same regression, exercised via the inspector (the right-edge panel).
    func testHover_ExitGraceFires_HidesTheInspectorOnceCursorLeftFullscreen() {
        Prefs.exifPanelPinnedFullscreen = false
        let content = makeContent(size: CGSize(width: 1200, height: 800))
        content.animatesPanelFades = false  // see the filmstrip variant above
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        // Reveal the inspector via right-edge hover.
        content.evaluateZonesForTesting(at: NSPoint(x: 1196, y: 400))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
        XCTAssertFalse(content.inspectorForTesting.isHidden)

        // Cursor moves to the middle of the canvas.
        content.evaluateZonesForTesting(at: NSPoint(x: 600, y: 400))
        XCTAssertTrue(content.panelExitGraceActiveForTesting(.inspector))

        // Fire the grace timer.
        content.forceExitGraceFireForTesting(.inspector)

        XCTAssertFalse(content.isHoveredForTesting(.inspector),
                       "after grace fires, the inspector must be removed from hoveredPanels")
        XCTAssertTrue(content.inspectorForTesting.isHidden,
                      "after grace fires, the inspector must be hidden")
    }

    // MARK: - Filmstrip aspect cache

    /// Aspect delivered via a thumbnail is cached in `recentAspects`,
    /// then seeded into a later cell for the same global index.
    func testFilmstrip_AspectCachedAfterThumbnailDelivery() {
        let strip = FilmstripView()
        strip.setMode(.fullscreen)
        strip.frame = CGRect(x: 0, y: 0, width: 1200, height: 88)
        strip.layoutSubtreeIfNeeded()

        _ = strip.injectCellForTesting(globalIndex: 42, aspect: 1.0)
        strip.simulateThumbnailDeliveredForTesting(
            globalIndex: 42, pixelWidth: 1800, pixelHeight: 1200
        )

        // Hook runs on MainActor Task — flush via runloop spin.
        let exp = expectation(description: "aspect cache populated")
        DispatchQueue.main.async {
            if strip.recentAspectsForTesting[42] != nil { exp.fulfill() }
            else {
                // Retry one more hop in case the Task landed after our
                // enqueue but before the expectation.
                DispatchQueue.main.async {
                    if strip.recentAspectsForTesting[42] != nil { exp.fulfill() }
                }
            }
        }
        wait(for: [exp], timeout: 1.0)

        let cached = strip.recentAspectsForTesting[42] ?? 0
        XCTAssertEqual(cached, 1800.0 / 1200.0, accuracy: 0.001)
    }
}

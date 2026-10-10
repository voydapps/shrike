//
//  EditEntryTests.swift
//  ShrikeUITests
//
//  The edit rail
//  shows in a window by default with labels and fades on the pointer
//  clock; E / ⌘E / Edit land on no tool; no filmstrip in edit mode; the
//  pin sits in the rail; Done is prominent; the panel menu items read
//  Show / Hide. Offscreen windows only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering

@MainActor
final class EditEntryTests: XCTestCase {

    private var root: URL!
    private var store: BackupStore!
    private let keys = [
        "shrike.viewer.editRail.visibleInWindowed",
        "shrike.viewer.editRail.defaultOnApplied",
        "shrike.viewer.editRail.pinnedFullscreen",
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.filmstrip.visibleInWindowed",
    ]
    private var savedFilmstripPinned = false
    private var savedFilmstripVisible = true
    private var savedRailPinned = false

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-edit-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        savedFilmstripPinned = Prefs.filmstripPinnedFullscreen
        savedFilmstripVisible = Prefs.filmstripVisibleInWindowed
        savedRailPinned = Prefs.editRailPinnedFullscreen
        ShrikeDefaults.store.removeObject(forKey: "shrike.viewer.editRail.visibleInWindowed")
        ShrikeDefaults.store.removeObject(forKey: "shrike.viewer.editRail.defaultOnApplied")
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: "shrike.viewer.editRail.visibleInWindowed")
        ShrikeDefaults.store.removeObject(forKey: "shrike.viewer.editRail.defaultOnApplied")
        Prefs.filmstripPinnedFullscreen = savedFilmstripPinned
        Prefs.filmstripVisibleInWindowed = savedFilmstripVisible
        Prefs.editRailPinnedFullscreen = savedRailPinned
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func makeViewer(size: NSSize = NSSize(width: 1280, height: 800)) -> ViewerWindow {
        let url = root.appendingPathComponent("p-\(UUID().uuidString.prefix(6)).jpg")
        XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.setContentSize(size)
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants()
        let content = viewer.contentRootForTesting
        content.animatesPanelFades = false
        content.voiceOverOverrideForTesting = false
        content.simulateFirstFrameForTesting()
        return viewer
    }

    private func key(_ chars: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> KeyEventSnapshot {
        KeyEventSnapshot.from(KeyCharactersTests.key(chars, keyCode: code, flags), isKeyUp: false)
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "timed out waiting for \(what)")
    }

    private func railFrameInWindow(_ rail: EditRail) -> NSRect {
        rail.superview?.convert(rail.frame, to: nil) ?? .zero
    }

    // MARK: Default and the one-time switch

    func testV1FreshStoreShowsTheLabelledRailInAWindow() {
        XCTAssertTrue(Prefs.editRailVisibleInWindowed, "missing value reads true")
        let viewer = makeViewer()
        defer { viewer.close() }
        let rail = viewer.contentRootForTesting.editRailForTesting
        XCTAssertFalse(rail.isHidden)
        XCTAssertEqual(rail.alphaValue, 1)
        XCTAssertFalse(rail.isCompact)
        XCTAssertEqual(rail.buttonsForTesting.map(\.labelField.stringValue),
                       ["Crop", "Rotate", "Resize", "Color", "Levels"])
        XCTAssertTrue(rail.buttonsForTesting.allSatisfy { !$0.labelField.isHidden })
        XCTAssertEqual(rail.frame.height, EditRail.labeledHeight, accuracy: 0.5, "282 pt in a window")
    }

    func testV2toV4TheOneTimeSwitch() {
        let d = ShrikeDefaults.store
        let marker = "shrike.viewer.editRail.defaultOnApplied"
        // 2: stored off, no marker → on, marker set.
        d.set(false, forKey: "shrike.viewer.editRail.visibleInWindowed")
        Prefs.applyEditRailDefaultOnce()
        XCTAssertTrue(Prefs.editRailVisibleInWindowed)
        XCTAssertEqual(d.object(forKey: marker) as? Bool, true)
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        XCTAssertFalse(content.editRailForTesting.isHidden)

        // 3: ⇧⌘E off, the switch runs again: it stays off.
        viewer.perform(.toggleEditRail)
        XCTAssertFalse(Prefs.editRailVisibleInWindowed)
        Prefs.applyEditRailDefaultOnce()
        XCTAssertFalse(Prefs.editRailVisibleInWindowed, "the marker keeps the user's choice")
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.editRailForTesting.isHidden)
        XCTAssertEqual(viewer.panelMenuTitle(.toggleEditRail), "Show Edit Rail")

        // 4: stored on, no marker → still on, marker set.
        d.removeObject(forKey: marker)
        d.set(true, forKey: "shrike.viewer.editRail.visibleInWindowed")
        Prefs.applyEditRailDefaultOnce()
        XCTAssertTrue(Prefs.editRailVisibleInWindowed)
        XCTAssertEqual(d.object(forKey: marker) as? Bool, true)

        // No value at all: nothing is written but the marker.
        d.removeObject(forKey: marker)
        d.removeObject(forKey: "shrike.viewer.editRail.visibleInWindowed")
        Prefs.applyEditRailDefaultOnce()
        XCTAssertNil(d.object(forKey: "shrike.viewer.editRail.visibleInWindowed"))
        XCTAssertTrue(Prefs.editRailVisibleInWindowed)
    }

    // MARK: Show and fade

    func testV5V6ThePointerClockFadesTheRail() throws {
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let rail = content.editRailForTesting
        let hider = try XCTUnwrap(viewer.autoHider)
        let canvasPoint = content.convert(NSPoint(x: content.bounds.midX + 100, y: content.bounds.midY), to: nil)
        content.cursorLocationOverrideForTesting = canvasPoint
        hider.pointerLocation = { canvasPoint }
        let frameBefore = viewer.imageViewForTesting.frame
        let drawBefore = viewer.imageViewForTesting.clipSpaceTransform()

        hider.pointerMoved(inTitlebar: false)
        hider.hideIfAllowed()   // the 2 s clock ran out
        XCTAssertTrue(rail.isHidden, "5: still pointer over the canvas → the rail fades")
        XCTAssertEqual(viewer.imageViewForTesting.frame, frameBefore, "the photo never moves")
        XCTAssertEqual(viewer.imageViewForTesting.clipSpaceTransform(), drawBefore)
        hider.pointerMoved(inTitlebar: false)
        XCTAssertFalse(rail.isHidden, "a pointer move shows it")
        XCTAssertEqual(rail.alphaValue, 1)

        // 6: the pointer on the rail holds it.
        content.layoutSubtreeIfNeeded()
        let onRail = railFrameInWindow(rail)
        content.cursorLocationOverrideForTesting = NSPoint(x: onRail.midX, y: onRail.midY)
        hider.hideIfAllowed()
        XCTAssertFalse(rail.isHidden, "pointer on the rail: stays")
        // VoiceOver holds it.
        content.cursorLocationOverrideForTesting = canvasPoint
        content.voiceOverOverrideForTesting = true
        hider.hideIfAllowed()
        XCTAssertFalse(rail.isHidden, "VoiceOver on: never fades")
        content.voiceOverOverrideForTesting = false
        // Keys never change it.
        _ = viewer.handleKeySnapshot(key("\u{F703}", 124))
        XCTAssertFalse(rail.isHidden)
        // Auto-hide off: the titlebar stays, the rail still fades.
        hider.isEnabled = false
        hider.hideIfAllowed()
        XCTAssertTrue(rail.isHidden, "auto-hide off: only the rail fades")
        XCTAssertTrue(hider.isShown, "the titlebar stays")
    }

    // MARK: Place and size

    func testV7TheRailSitsBetweenTheTitlebarAndThePill() {
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        let rail = railFrameInWindow(content.editRailForTesting)
        XCTAssertLessThanOrEqual(rail.maxY, viewer.contentLayoutRect.maxY - 8 + 0.5, "clear of the titlebar")
        let pill = content.convert(content.pillFrameForTesting, to: nil)
        XCTAssertFalse(rail.intersects(pill), "clear of the pill")
        XCTAssertGreaterThanOrEqual(rail.minY, pill.maxY + 8 - 0.5)
        let canvas = content.convert(viewer.imageViewForTesting.frame, to: nil)
        XCTAssertEqual(rail.minX - canvas.minX, 16, accuracy: 0.5, "16 pt from the canvas edge")
    }

    func testV8ShortBandsGoCompactThenHide_NarrowCanvasHides() {
        var seen: Set<String> = []
        for height in stride(from: 280, through: 720, by: 20) {
            let content = ViewerContentView(services: .makeDefault())
            content.frame = CGRect(x: 0, y: 0, width: 1000, height: CGFloat(height))
            content.animatesPanelFades = false
            content.windowMode = .windowed
            content.simulateFirstFrameForTesting()
            let rail = content.editRailForTesting
            let pill = content.pillFrameForTesting
            let top = CGFloat(height) - ViewerContentView.railBandGap
            let bottom = (pill.height > 0 ? pill.maxY : 0) + ViewerContentView.railBandGap
            let band = top - bottom
            if band < EditRail.compactHeight {
                XCTAssertTrue(rail.isHidden, "band \(band): hidden")
                seen.insert("hidden")
            } else if band < EditRail.labeledHeight {
                XCTAssertFalse(rail.isHidden, "band \(band)")
                XCTAssertTrue(rail.isCompact, "band \(band): compact")
                XCTAssertEqual(rail.frame.height, EditRail.compactHeight, accuracy: 0.5)
                XCTAssertTrue(rail.buttonsForTesting.allSatisfy { $0.labelField.isHidden })
                XCTAssertGreaterThanOrEqual(rail.frame.minY, bottom - 0.5)
                XCTAssertLessThanOrEqual(rail.frame.maxY, top + 0.5)
                seen.insert("compact")
            } else {
                XCTAssertFalse(rail.isHidden, "band \(band)")
                XCTAssertFalse(rail.isCompact)
                XCTAssertEqual(rail.frame.height, EditRail.labeledHeight, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(rail.frame.minY, bottom - 0.5)
                XCTAssertLessThanOrEqual(rail.frame.maxY, top + 0.5)
                seen.insert("labelled")
            }
        }
        XCTAssertEqual(seen, ["hidden", "compact", "labelled"], "the sweep covers every form")
        XCTAssertEqual(EditRail.compactHeight, 228)
        XCTAssertEqual(EditRail.labeledHeight, 282)

        // A canvas under 480 pt (the inspector open in a small window).
        let narrow = ViewerContentView(services: .makeDefault())
        narrow.frame = CGRect(x: 0, y: 0, width: 420, height: 700)
        narrow.animatesPanelFades = false
        narrow.windowMode = .windowed
        narrow.simulateFirstFrameForTesting()
        XCTAssertTrue(narrow.editRailForTesting.isHidden, "canvas 420 pt: no rail")
        XCTAssertTrue(narrow.isEditRailShown, "the setting is kept: the menu reads Hide Edit Rail")
    }

    // MARK: Labels, tooltips, VoiceOver

    func testV9LabelsAreWholeAndButtonsAreNamed() {
        let rail = EditRail()
        rail.frame = NSRect(x: 0, y: 0, width: EditRail.totalWidth, height: 320)
        rail.layoutSubtreeIfNeeded()
        let names = ["Crop", "Rotate", "Resize", "Color", "Levels"]
        XCTAssertEqual(rail.accessibilityLabel(), "Edit Tools")
        XCTAssertEqual(rail.accessibilityRole(), .group)
        for (button, name) in zip(rail.buttonsForTesting, names) {
            let label = button.labelField
            let whole = label.intrinsicContentSize.width
            XCTAssertLessThanOrEqual(whole, 48, "\(name) fits the cell")
            XCTAssertGreaterThanOrEqual(label.frame.width, whole - 0.5, "\(name) is not truncated")
            XCTAssertEqual(button.accessibilityLabel(), name)
            XCTAssertEqual(button.frame.size, NSSize(width: 48, height: 50))
        }
        XCTAssertTrue(rail.buttonTitlesForTesting().first?.hasPrefix("Crop") == true)
        rail.setActiveTool(.crop)
        XCTAssertEqual(rail.buttonsForTesting.first?.accessibilityValue() as? String, "Selected")
    }

    // MARK: No tool on entry

    func testV10EveryEntryLandsOnNoTool() async throws {
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let controller = content.editModeController
        let entries: [(String, () -> Void)] = [
            ("E", { _ = viewer.handleKeySnapshot(self.key("e", 14)) }),
            ("⌘E", { _ = viewer.handleKeySnapshot(self.key("e", 14, .command)) }),
            ("Image ▸ Edit Image", { viewer.perform(.editImage) }),
            ("toolbar / capsule Edit", { viewer.dispatch(.openEditMode) }),
        ]
        for (name, enter) in entries {
            enter()
            try await waitFor("\(name) → edit mode") { content.isEditModeActive }
            XCTAssertNil(controller.currentTool, name)
            XCTAssertTrue(controller.cropOverlay.isHidden, "\(name): no crop frame")
            XCTAssertTrue(controller.parameterPanel._installed is ChooseToolPanel, "\(name): Choose a Tool")
            XCTAssertEqual(content.editToolbarController.toolGroup?.selectedIndex ?? -1, -1, name)
            XCTAssertTrue(content.editRailForTesting.activeToolsForTesting().isEmpty, "\(name): no active rail button")
            content.exitEditMode()
            XCTAssertFalse(content.isEditModeActive)
        }
    }

    func testV11V12PickingAToolAndDoneWithNoEdits() async throws {
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let controller = content.editModeController
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        content.layoutSubtreeIfNeeded()
        let drawn = viewer.imageViewForTesting.clipSpaceTransform()

        // 11: C → Crop, the frame shows, the photo does not move.
        XCTAssertTrue(viewer.handleKeySnapshot(key("c", 8)))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.currentTool, .crop)
        XCTAssertFalse(controller.cropOverlay.isHidden)
        XCTAssertEqual(viewer.imageViewForTesting.clipSpaceTransform(), drawn, "photo frame as in the no-tool state")

        // 12: Done with no edits ends edit mode without an alert.
        controller.perform(.done)
        try await waitFor("exit") { !content.isEditModeActive }
        XCTAssertNil(viewer.attachedSheet)

        // `]` from the no-tool state: one 90° op, still no tool.
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode again") { content.isEditModeActive }
        XCTAssertNil(controller.currentTool)
        XCTAssertTrue(viewer.handleKeySnapshot(key("]", 30)))
        try await waitFor("the turn lands in the recipe") { controller.chromeState.hasEdits }
        let ops = await controller.recipe?.operations
        XCTAssertEqual(ops?.count, 1, "one 90° op")
        XCTAssertNil(controller.currentTool)
        XCTAssertTrue(controller.chromeState.hasEdits, "Reset enabled")
        content.exitEditMode()
    }

    // MARK: Full screen, filmstrip, pin, Done, menus

    func testV13TheCapsuleHasEditAndTheRailShowsInEditMode() async throws {
        XCTAssertEqual(ViewerToolbar.symbolNamesForTesting.suffix(3),
                       ["square.and.arrow.up", "slider.horizontal.3", "trash"])
        XCTAssertEqual(ViewerToolbar.command(for: .openEditMode), .editImage)
        Prefs.editRailPinnedFullscreen = false
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        XCTAssertTrue(content.editRailForTesting.isHidden, "unpinned rail waits for the edge")
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        XCTAssertNil(content.editModeController.currentTool)
        XCTAssertFalse(content.editRailForTesting.isHidden, "held open in edit mode although not pinned")
        content.exitEditMode()
        content.windowMode = .windowed
    }

    func testV14FullScreenPinnedFilmstripStaysHiddenInEditMode() async throws {
        Prefs.filmstripPinnedFullscreen = true
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        XCTAssertFalse(content.filmstripForTesting.isHidden, "pinned")
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        content.evaluateZonesForTesting(at: NSPoint(x: content.bounds.midX, y: 2))
        XCTAssertTrue(content.filmstripForTesting.isHidden, "no filmstrip in edit mode")
        content.exitEditMode()
        XCTAssertTrue(content.isPinnedForTesting(.filmstrip), "pinned again after exit")
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        content.windowMode = .windowed
    }

    func testV15WindowFilmstripHidesInEditModeAndThePhotoComesBack() async throws {
        Prefs.filmstripVisibleInWindowed = true
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        let before = viewer.imageViewForTesting.frame
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.filmstripForTesting.isHidden, "the docked strip hides")
        XCTAssertFalse(viewer.canPerform(.toggleFilmstrip), "⌘K and the menu item are disabled")
        viewer.perform(.toggleFilmstrip)
        XCTAssertTrue(Prefs.filmstripVisibleInWindowed, "⌘K does nothing in edit mode")
        content.exitEditMode()
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        XCTAssertEqual(viewer.imageViewForTesting.frame, before, "the photo frame equals the one before entry")
    }

    func testV16ThePinSitsInsideTheRailInFullScreen() {
        Prefs.editRailPinnedFullscreen = true
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1440, height: 900)
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        let rail = content.editRailForTesting
        XCTAssertFalse(rail.isHidden)
        let railFrame = rail.superview.map { content.convert(rail.frame, from: $0) } ?? rail.frame
        let pin = rail.pinOverlayForTesting
        let pinFrame = content.convert(pin.frame, from: pin.superview)
        XCTAssertTrue(railFrame.contains(pinFrame), "pin \(pinFrame) inside the rail \(railFrame)")
        XCTAssertEqual(pinFrame.midY, railFrame.maxY - 16, accuracy: 0.5, "16 pt below the top")
        XCTAssertEqual(pinFrame.midX, railFrame.midX, accuracy: 0.5, "on the centre line")
        // The pin row (24 pt) ends 6 pt above the Crop cell; the 28 pt
        // hit square overhangs the row by 2 pt and still clears the cell.
        let crop = rail.buttonFramesForTesting()[0]
        let cropTop = railFrame.minY + crop.maxY
        let row = pin.superview.map { content.convert($0.bounds, from: $0) } ?? .zero
        XCTAssertGreaterThanOrEqual(row.minY - cropTop, 6 - 0.5, "the pin row is ≥ 6 pt above Crop")
        XCTAssertGreaterThan(pinFrame.minY, cropTop, "the pin never overlaps Crop")
        XCTAssertEqual(railFrame.height, EditRail.labeledHeight + EditRail.pinRowExtra, accuracy: 0.5, "308 pt")
        XCTAssertEqual(EditRail.labeledHeight + EditRail.pinRowExtra, 308)
    }

    func testV17DoneIsTheProminentDefaultButton() {
        let content = ViewerContentView(services: .makeDefault())
        let capsule = content.editCapsule
        XCTAssertEqual(capsule.doneButton.keyEquivalent, "\r")
        // The same accent fill as the Apply buttons.
        XCTAssertEqual(capsule.doneButton.bezelColor, .controlAccentColor)
        XCTAssertNil(capsule.cancelButton.bezelColor)
    }

    func testV18PanelMenuItemsReadShowOrHideWithNoCheckMark() {
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        func validated(_ command: ShrikeCommand) -> NSMenuItem {
            let item = NSMenuItem(title: "x", action: ShrikeMainMenu.commandAction, keyEquivalent: "")
            item.representedObject = command.rawValue
            _ = viewer.validateMenuItem(item)
            return item
        }
        let panels: [ShrikeCommand] = [.toggleEditRail, .toggleFilmstrip, .toggleHistogram, .toggleInspector]
        for command in panels {
            XCTAssertEqual(validated(command).state, .off, "\(command): no check mark")
        }
        XCTAssertEqual(validated(.toggleEditRail).title, "Hide Edit Rail")
        content.windowMode = .fullscreen
        if content.isPinnedForTesting(.editRail) { content.togglePanel(.editRail) }
        XCTAssertEqual(validated(.toggleEditRail).title, "Show Edit Rail", "full screen, unpinned")
        content.togglePanel(.editRail)
        XCTAssertEqual(validated(.toggleEditRail).title, "Hide Edit Rail", "full screen, pinned")
        for command in panels {
            XCTAssertEqual(validated(command).state, .off, "\(command): no check mark in full screen")
        }
        content.togglePanel(.editRail)
        content.windowMode = .windowed
    }
}

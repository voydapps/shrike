//
//  EditEntryTests.swift
//  ShrikeUITests
//
//  E / ⌘E / Edit land on no tool; no filmstrip in edit mode; Done is
//  prominent; the panel menu items read Show / Hide. Offscreen windows only.
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
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.filmstrip.visibleInWindowed",
    ]
    private var savedFilmstripPinned = false
    private var savedFilmstripVisible = true

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-edit-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        savedFilmstripPinned = Prefs.filmstripPinnedFullscreen
        savedFilmstripVisible = Prefs.filmstripVisibleInWindowed
    }

    override func tearDown() async throws {
        Prefs.filmstripPinnedFullscreen = savedFilmstripPinned
        Prefs.filmstripVisibleInWindowed = savedFilmstripVisible
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
            ("context menu ▸ Edit Image", { viewer.perform(.editImage) }),
        ]
        for (name, enter) in entries {
            enter()
            try await waitFor("\(name) → edit mode") { content.isEditModeActive }
            XCTAssertNil(controller.currentTool, name)
            XCTAssertTrue(controller.cropOverlay.isHidden, "\(name): no crop frame")
            XCTAssertTrue(controller.parameterPanel._installed is ChooseToolPanel, "\(name): Choose a Tool")
            XCTAssertEqual(content.editToolbarController.toolPicker.selectedSegment, -1, "\(name): picker lights nothing")
            XCTAssertEqual(content.editCapsule.toolPicker.selectedSegment, -1, "\(name): capsule picker lights nothing")
            XCTAssertEqual((controller.parameterPanel._installed as? ChooseToolPanel)?.bodyLabel.stringValue,
                           "Pick Crop, Rotate, Resize, Color or Levels in the bar at the top.", name)
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

    func testV13TheCapsuleHasEditAndTheEditBarHoldsTheTools() async throws {
        XCTAssertEqual(ViewerToolbar.symbolNamesForTesting[5...7],
                       ["square.and.arrow.up", "slider.horizontal.3", "trash"])
        XCTAssertEqual(ViewerToolbar.command(for: .openEditMode), .editImage)
        let viewer = makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        XCTAssertNil(content.editModeController.currentTool)
        XCTAssertEqual(content.editCapsule.toolPicker.selectedSegment, -1)
        XCTAssertEqual((content.editModeController.parameterPanel._installed as? ChooseToolPanel)?.bodyLabel.stringValue,
                       "Pick Crop, Rotate, Resize, Color or Levels in the bar at the bottom.")
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

    func testV15WindowFilmstripStaysInEditModeAndThePhotoDoesNotMove() async throws {
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
        // Spec 25 §3.3: a window keeps its docked strip in edit mode, and ⌘K works.
        XCTAssertFalse(content.filmstripForTesting.isHidden, "the docked strip stays")
        XCTAssertTrue(viewer.canPerform(.toggleFilmstrip), "⌘K and the menu item work")
        content.exitEditMode()
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.filmstripForTesting.isHidden)
        XCTAssertEqual(viewer.imageViewForTesting.frame, before, "the photo frame equals the one before entry")
    }

    func testV17DoneIsTheProminentDefaultButton() {
        let content = ViewerContentView(services: .makeDefault())
        let capsule = content.editCapsule
        XCTAssertEqual(capsule.doneButton.keyEquivalent, "\r")
        // The system accent fill, in the capsule and in the edit toolbar.
        if #available(macOS 26, *) {
            XCTAssertEqual(capsule.doneButton.tintProminence, .primary)
            XCTAssertEqual(capsule.cancelButton.tintProminence, .automatic)
        } else {
            XCTAssertEqual(capsule.doneButton.bezelColor, .controlAccentColor)
        }
        XCTAssertNil(capsule.cancelButton.bezelColor)
        let edit = EditToolbarController()
        let item = edit.toolbar(edit.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.done,
                                willBeInsertedIntoToolbar: true)
        XCTAssertEqual((item?.view as? NSButton)?.keyEquivalent, "\r")
        if #available(macOS 26, *) { XCTAssertNotEqual(item?.style, .prominent) }
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
        let panels: [ShrikeCommand] = [.toggleFilmstrip, .toggleHistogram, .toggleInspector]
        for command in panels {
            XCTAssertEqual(validated(command).state, .off, "\(command): no check mark")
        }
        content.windowMode = .fullscreen
        for command in panels {
            XCTAssertEqual(validated(command).state, .off, "\(command): no check mark in full screen")
        }
        content.windowMode = .windowed
    }
}

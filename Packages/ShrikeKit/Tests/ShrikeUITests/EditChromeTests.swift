//
//  EditChromeTests.swift
//  ShrikeUITests
//
//  The windowed edit toolbar, the full-screen
//  edit capsule, and the keys in edit mode.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class EditChromeTests: XCTestCase {

    private var dir: URL!
    private var savedStripDocked = true

    override func setUp() async throws {
        // ⌘K in testKeysInEditMode flips the docked-strip pref; put it back
        // so later tests (EditEntryTests) see the default.
        savedStripDocked = Prefs.filmstripVisibleInWindowed
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditChromeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Prefs.filmstripVisibleInWindowed = savedStripDocked
        try? FileManager.default.removeItem(at: dir)
    }

    private func viewer() throws -> ViewerWindow {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // The toolbar shows Cancel, the five tools, Undo/Redo, Reset, Done (spec 26).
    func testEditToolbarItemsInOrder() {
        let c = EditToolbarController()
        XCTAssertEqual(c.toolbar.identifier, "shrike.viewer.editToolbar")
        XCTAssertEqual(c.toolbar.displayMode, .iconOnly)
        XCTAssertFalse(c.toolbar.allowsUserCustomization)
        XCTAssertEqual(EditToolbarController.itemOrder, [
            EditToolbarController.ItemID.cancel, .flexibleSpace, EditToolbarController.ItemID.tools,
            EditToolbarController.ItemID.undoRedo, .flexibleSpace, EditToolbarController.ItemID.reset,
            EditToolbarController.ItemID.done,
        ], "Cancel · tools · Undo/Redo · Reset · Done (spec 26 §1.2)")
        let done = c.toolbar(c.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.done,
                             willBeInsertedIntoToolbar: true)
        XCTAssertEqual((done?.view as? NSButton)?.title, "Done")
        XCTAssertEqual(c.doneButton.keyEquivalent, "\r")
        XCTAssertEqual(c.resetButton.toolTip, "Reset All Edits")
        XCTAssertFalse(c.resetButton.isEnabled, "Reset is disabled while the recipe is empty")
    }

    // Windowed entry swaps the toolbar; subtitle + dot follow the recipe.
    func testWindowedEditSwapsToolbarAndSubtitle() async throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let before = viewer.toolbar
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertEqual(viewer.toolbar?.identifier, EditToolbarController.toolbarIdentifier)
        XCTAssertEqual(viewer.subtitle, "Editing")
        XCTAssertFalse(viewer.isDocumentEdited)
        XCTAssertNil(content.editCapsule.superview, "no capsule in a window")

        content.editModeController.appendSnapped90(quarters: 1)
        let dirty = await waitUntil { viewer.subtitle == "Editing · Unsaved changes" }
        XCTAssertTrue(dirty)
        XCTAssertTrue(viewer.isDocumentEdited)
        XCTAssertTrue(content.editToolbarController.resetButton.isEnabled)

        content.editModeController.finalizeExit()
        XCTAssertTrue(viewer.toolbar === before)
        XCTAssertFalse(viewer.isDocumentEdited)
        XCTAssertNotEqual(viewer.subtitle, "Editing")
    }

    // Full screen shows the capsule, stays up for the session.
    func testFullScreenEditUsesCapsule() {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        content.windowMode = .fullscreen
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertTrue(content.editCapsule.isDescendant(of: content))
        XCTAssertEqual(content.editCapsule.label.stringValue, "Editing")
        XCTAssertTrue(content.editCapsule.allSubviewsForTesting.contains { $0 === content.editCapsule.toolPicker },
                      "the capsule has the tool picker (spec 26 §3)")
        content.editModeController.perform(.selectTool(.color))
        XCTAssertEqual(content.editModeController.currentTool, .color)
        // Leaving full screen mid-session moves the chrome back to a toolbar.
        content.windowMode = .windowed
        XCTAssertNil(content.editCapsule.superview)
        content.editModeController.finalizeExit()
        XCTAssertFalse(content.isEditModeActive)
    }

    // R selects Rotate; ⌘K toggles the filmstrip and arms nothing.
    func testKeysInEditMode() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: "r", modifiers: [])))
        XCTAssertEqual(content.editModeController.currentTool, .rotate)
        XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: "k", modifiers: .command)))
        XCTAssertNil(viewer.chordPrefix, "⌘K no longer arms a tool chord")
        XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: "c", modifiers: [])))
        XCTAssertEqual(content.editModeController.currentTool, .crop)
        content.editModeController.finalizeExit()
    }

    // (first half) + Done with nothing to save: both just leave.
    func testDoneAndCancelWithNoChangesLeaveWithoutAlert() async throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .rotate)
        XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: "\r", modifiers: [])))
        let left = await waitUntil { !content.isEditModeActive }
        XCTAssertTrue(left)
        XCTAssertNil(viewer.attachedSheet)

        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .rotate)
        content.editModeController.perform(.cancel)
        let cancelled = await waitUntil { !content.isEditModeActive }
        XCTAssertTrue(cancelled)
        XCTAssertNil(viewer.attachedSheet)
    }
}

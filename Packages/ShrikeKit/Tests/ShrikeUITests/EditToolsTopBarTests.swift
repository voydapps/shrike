//
//  EditToolsTopBarTests.swift
//  ShrikeUITests
//
//  Spec 26: the five edit tools are one icon-only picker in the edit
//  toolbar (window) and the edit capsule (full screen); the left rail is
//  gone. Offscreen windows only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering

@MainActor
final class EditToolsTopBarTests: XCTestCase {

    private enum ReadinessError: Error { case timedOut }
    private var root: URL!
    private var store: BackupStore!
    private var savedPreset: ShortcutPreset = .macNative

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-edit-topbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        savedPreset = Prefs.shortcutPreset
    }

    override func tearDown() async throws {
        Prefs.shortcutPreset = savedPreset
        LiveTooltips.shared.refreshIfPresetChanged()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewer(size: NSSize = NSSize(width: 1280, height: 800)) async throws -> ViewerWindow {
        let url = root.appendingPathComponent("p-\(UUID().uuidString.prefix(6)).jpg")
        XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.setContentSize(size)
        do {
            try await waitFor("accepted photo ready for editing") { viewer.canPerform(.editImage) }
        } catch {
            viewer.close()
            throw error
        }
        viewer.contentRootForTesting.animatesPanelFades = false
        return viewer
    }

    private func waitFor(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail("timed out waiting for \(what)")
            throw ReadinessError.timedOut
        }
    }

    // MARK: 1. Order and the picker

    func testV1_ItemOrderAndPickerSegments() throws {
        let controller = EditToolbarController()
        XCTAssertEqual(controller.toolbarDefaultItemIdentifiers(controller.toolbar), [
            EditToolbarController.ItemID.cancel, .flexibleSpace, EditToolbarController.ItemID.tools,
            EditToolbarController.ItemID.undoRedo, .flexibleSpace, EditToolbarController.ItemID.reset,
            EditToolbarController.ItemID.done,
        ])
        let item = try XCTUnwrap(controller.toolbar(controller.toolbar,
                                                    itemForItemIdentifier: EditToolbarController.ItemID.tools,
                                                    willBeInsertedIntoToolbar: true))
        let picker = try XCTUnwrap(item.view as? EditToolPicker)
        XCTAssertEqual(picker.segmentCount, EditChromeTools.order.count)
        for (i, tool) in EditChromeTools.order.enumerated() {
            XCTAssertEqual(picker.width(forSegment: i), 32)
            XCTAssertNotNil(picker.image(forSegment: i))
            XCTAssertEqual(picker.image(forSegment: i)?.accessibilityDescription, EditChromeTools.name(tool))
            XCTAssertTrue((picker.label(forSegment: i) ?? "").isEmpty, "icon-only")
        }
        XCTAssertEqual(controller.toolbar.displayMode, .iconOnly)
    }

    // MARK: 2. The picker follows the chrome state, window and capsule

    func testV2_PickerFollowsTheState() {
        let controller = EditToolbarController()
        let capsule = EditCapsuleView()
        XCTAssertEqual(controller.toolPicker.selectedSegment, -1)
        XCTAssertEqual(capsule.toolPicker.selectedSegment, -1)
        for (i, tool) in EditChromeTools.order.enumerated() {
            let state = EditChromeState(tool: tool)
            controller.apply(state)
            capsule.apply(state)
            XCTAssertEqual(controller.toolPicker.selectedSegment, i)
            XCTAssertEqual(capsule.toolPicker.selectedSegment, i)
        }
        controller.apply(EditChromeState())
        capsule.apply(EditChromeState())
        XCTAssertEqual(controller.toolPicker.selectedSegment, -1)
        XCTAssertEqual(capsule.toolPicker.selectedSegment, -1)
    }

    func testV2_PressingCOnAViewerLightsCropAndKeepsThePhotoFrame() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.editToolbarController.toolPicker.selectedSegment, -1)
        XCTAssertEqual(content.editCapsule.toolPicker.selectedSegment, -1)
        let drawn = viewer.imageViewForTesting.clipSpaceTransform()
        let key = KeyEventSnapshot.from(KeyCharactersTests.key("c", keyCode: 8), isKeyUp: false)
        XCTAssertTrue(viewer.handleKeySnapshot(key))
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.editToolbarController.toolPicker.selectedSegment, 0)
        XCTAssertEqual(content.editCapsule.toolPicker.selectedSegment, 0)
        XCTAssertFalse(content.editModeController.cropOverlay.isHidden)
        XCTAssertEqual(viewer.imageViewForTesting.clipSpaceTransform(), drawn, "the photo does not move")
        content.exitEditMode()
    }

    // MARK: 3. Clicking a segment sends the tool

    func testV3_ClickingEachSegmentSendsSelectTool() {
        let controller = EditToolbarController()
        let capsule = EditCapsuleView()
        var fromWindow: [EditChromeAction] = []
        var fromCapsule: [EditChromeAction] = []
        controller.onAction = { fromWindow.append($0) }
        capsule.onAction = { fromCapsule.append($0) }
        for i in EditChromeTools.order.indices {
            for picker in [controller.toolPicker, capsule.toolPicker] {
                picker.selectedSegment = i
                _ = picker.sendAction(picker.action, to: picker.target)
            }
        }
        let expected = EditChromeTools.order.map(EditChromeAction.selectTool)
        XCTAssertEqual(fromWindow, expected)
        XCTAssertEqual(fromCapsule, expected)
    }

    // MARK: 4. Tooltips

    func testV4_TooltipsAndTheLiveLevelsKey() {
        let picker = EditToolPicker()
        XCTAssertEqual(picker.toolTip(forSegment: 0), "Crop  ·  C")
        XCTAssertEqual(picker.toolTip(forSegment: 1), "Rotate  ·  R")
        XCTAssertEqual(picker.toolTip(forSegment: 2), "Resize  ·  S")
        XCTAssertEqual(picker.toolTip(forSegment: 3), "Color  ·  J")
        XCTAssertEqual(picker.toolTip(forSegment: 4), "Levels  ·  ⇧⌘L")
        Prefs.shortcutPreset = .fastStoneCompat
        LiveTooltips.shared.refreshIfPresetChanged()
        XCTAssertEqual(picker.toolTip(forSegment: 4), "Levels  ·  ⌃L", "follows a preset change")
    }

    // MARK: 5. Enabled, accent, and the Edit button's reason line

    func testV5_AllSegmentsAreEnabled() {
        let picker = EditToolPicker()
        for i in 0..<picker.segmentCount { XCTAssertTrue(picker.isEnabled(forSegment: i)) }
    }

    func testV5_TheEditToolTipKeepsItsReasonLineAcrossAPresetChange() throws {
        let bar = ViewerWindowToolbar(host: nil)
        let item = try XCTUnwrap(bar.toolbar(bar.toolbar, itemForItemIdentifier: ViewerWindowToolbar.ID.edit,
                                             willBeInsertedIntoToolbar: true))
        let base = try XCTUnwrap(item.toolTip)
        XCTAssertFalse(base.contains("\n"))
        bar.setEditExtraLine(ViewerWindow.rawEditBlockedCopy)
        XCTAssertEqual(item.toolTip, base + "\n" + ViewerWindow.rawEditBlockedCopy)
        Prefs.shortcutPreset = .fastStoneCompat
        LiveTooltips.shared.refreshIfPresetChanged()
        let rewritten = try XCTUnwrap(item.toolTip)
        XCTAssertTrue(rewritten.hasSuffix("\n" + ViewerWindow.rawEditBlockedCopy), rewritten)
        XCTAssertTrue(rewritten.hasPrefix("Edit Image"), "the base text is still there")
        bar.setEditExtraLine(nil)
        XCTAssertFalse(try XCTUnwrap(item.toolTip).contains("\n"), "cleared")
    }

    func testV15_TheEditButtonSaysWhyOnADecodeError() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let item = try XCTUnwrap(viewer.toolbarController?.item(ViewerWindowToolbar.ID.edit))
        content.showDecodeError()
        XCTAssertEqual(content.editEntryReason, ViewerContentView.decodeErrorEditReason)
        XCTAssertTrue(try XCTUnwrap(item.toolTip).hasSuffix("\n" + ViewerContentView.decodeErrorEditReason))
        XCTAssertFalse(viewer.canPerform(.editImage), "Edit Image is off on a decode error")
        content.setImage(RotateDirectionTests.quadrants(), index: 0, total: 1)
        XCTAssertNil(content.editEntryReason)
        XCTAssertFalse(try XCTUnwrap(item.toolTip).contains("\n"))
    }

    /// On screen (2026-10-12): E on a broken photo entered edit mode over the PREVIOUS photo's
    /// pixels (the image view keeps them behind the error card) and could save them over the file.
    func testV15b_NoEditModeOnADecodeError() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.setImage(RotateDirectionTests.quadrants(), index: 0, total: 1)
        content.showDecodeError()
        viewer.enterEditMode(landOn: nil)
        viewer.enterEditMode(landOn: .crop)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(content.isEditModeActive, "a photo that cannot be opened has nothing to edit")
    }

    // MARK: 6. Priorities and overflow forms (the bar's real overflow is not probed offscreen)

    func testV6_PrioritiesAndMenuForms() throws {
        let priorities: [(NSToolbarItem.Identifier, NSToolbarItem.VisibilityPriority)] = [
            (EditToolbarController.ItemID.done, .high), (EditToolbarController.ItemID.cancel, .high),
            (EditToolbarController.ItemID.tools, .standard), (EditToolbarController.ItemID.undoRedo, .low),
            (EditToolbarController.ItemID.reset, .low),
        ]
        let controller = EditToolbarController()
        for (id, priority) in priorities {
            XCTAssertEqual(EditToolbarController.visibilityPriority(id), priority, id.rawValue)
            let item = try XCTUnwrap(controller.toolbar(controller.toolbar, itemForItemIdentifier: id,
                                                        willBeInsertedIntoToolbar: true))
            XCTAssertEqual(item.visibilityPriority, priority, id.rawValue)
            XCTAssertNotNil(item.menuFormRepresentation, "\(id.rawValue) has an overflow form")
        }
        // The tools' form: five names, a check on the current tool.
        let tools = try XCTUnwrap(controller.toolItem?.menuFormRepresentation?.submenu)
        XCTAssertEqual(tools.items.map(\.title), ["Crop", "Rotate", "Resize", "Color", "Levels"])
        XCTAssertEqual(tools.items.map(\.state), Array(repeating: .off, count: 5))
        controller.apply(EditChromeState(tool: .resize))
        XCTAssertEqual(tools.items.map(\.state), [.off, .off, .on, .off, .off])
        controller.apply(EditChromeState())
        XCTAssertEqual(tools.items.map(\.state), Array(repeating: .off, count: 5))
        // Reset's form follows the edits; the menu rows send the same actions.
        var actions: [EditChromeAction] = []
        controller.onAction = { actions.append($0) }
        let reset = try XCTUnwrap(controller.toolbar(controller.toolbar,
                                                     itemForItemIdentifier: EditToolbarController.ItemID.reset,
                                                     willBeInsertedIntoToolbar: true)?.menuFormRepresentation)
        XCTAssertEqual(reset.title, "Reset All Edits")
        XCTAssertFalse(reset.isEnabled)
        controller.apply(EditChromeState(hasEdits: true))
        XCTAssertTrue(reset.isEnabled)
        _ = NSApp.sendAction(try XCTUnwrap(tools.items[3].action), to: tools.items[3].target, from: tools.items[3])
        XCTAssertEqual(actions, [.selectTool(.color)])
    }

    // MARK: 7. One accent fill

    func testV7_OnlyDoneIsTheAccentButtonAndThePlatterIsAccent() {
        let controller = EditToolbarController()
        XCTAssertEqual(controller.doneButton.keyEquivalent, "\r")
        XCTAssertEqual(controller.cancelButton.keyEquivalent, "")
        XCTAssertEqual(controller.resetButton.keyEquivalent, "")
        for picker in [controller.toolPicker, EditCapsuleView().toolPicker] {
            let color = picker.selectedSegmentBezelColor?.usingColorSpace(.deviceRGB)
            XCTAssertEqual(color?.alphaComponent ?? 0, EditToolPicker.platterAlpha, accuracy: 0.001)
        }
    }

    // MARK: 8-10. Nothing named after the rail is left

    func testV8_NoRailCommandOrPanelKindOrKeyRemains() {
        XCTAssertFalse(ShrikeCommand.allCases.contains { $0.rawValue.lowercased().contains("rail") })
        XCTAssertEqual(ViewerContentView.PanelKind.allCases.count, 3)
        XCTAssertFalse(ViewerContentView.PanelKind.allCases.contains { "\($0)".lowercased().contains("rail") })
    }

    func testV10_NoRailMenuItemOrShortcutRow() {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { [$0.title] + ($0.submenu.map(titles) ?? []) }
        }
        let all = (bar.menu.items.compactMap(\.submenu)).flatMap(titles)
        XCTAssertFalse(all.contains { $0.contains("Edit Rail") }, "no Show / Hide Edit Rail item")
        for preset in ShortcutPreset.allCases {
            for section in ShortcutsTab.sections(for: preset) {
                XCTAssertFalse(section.rows.contains { $0.action.lowercased().contains("rail") }, section.title)
            }
        }
    }

    // MARK: 11-12. Fit insets and the left edge are covered in EditFitAreaTests / FullScreenChromeTests

    // MARK: 13. The capsule's inventory

    func testV13_CapsuleOrderAndNoPanelOverlap() throws {
        let capsule = EditCapsuleView()
        let stack = try XCTUnwrap(capsule.allSubviewsForTesting.compactMap { $0 as? NSStackView }.first)
        XCTAssertEqual(stack.arrangedSubviews.count, 7)
        XCTAssertTrue(stack.arrangedSubviews[0] === capsule.label)
        XCTAssertTrue(stack.arrangedSubviews[1] === capsule.cancelButton)
        XCTAssertTrue(stack.arrangedSubviews[2] === capsule.toolPicker)
        XCTAssertTrue(stack.arrangedSubviews[3] === capsule.undoRedo)
        XCTAssertTrue(stack.arrangedSubviews[4] === capsule.resetButton)
        XCTAssertTrue(stack.arrangedSubviews[5] === capsule.saveCopyButton)
        XCTAssertTrue(capsule.saveCopyButton.isHidden, "Clean edit has no secondary action")
        XCTAssertTrue(stack.arrangedSubviews[6] === capsule.doneButton)
        XCTAssertEqual(stack.spacing, 10)
    }

    func testV13_InFullScreenTheCapsuleNeverOverlapsThePanel() async throws {
        let viewer = try await makeViewer(size: NSSize(width: 1440, height: 900))
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        content.layoutSubtreeIfNeeded()
        let capsule = content.editCapsule.frame
        let panel = content.editModeController.parameterPanel.frame
        XCTAssertGreaterThan(capsule.width, 0)
        XCTAssertFalse(capsule.intersects(panel), "capsule \(capsule) vs panel \(panel)")
        content.exitEditMode()
        content.windowMode = .windowed
    }

    // MARK: 14. Every way in, and the tools through the Image menu

    func testV14_ImageMenuToolEntriesLandOnTheirTool() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let entries: [(ShrikeCommand, EditTool, Int)] = [
            (.editColor, .color, 3), (.levels, .levels, 4), (.autoContrast, .levels, 4), (.editCrop, .crop, 0),
        ]
        for (command, tool, segment) in entries {
            viewer.perform(command)
            try await waitFor("\(command) → edit mode") {
                content.isEditModeActive && content.editModeController.currentTool == tool
            }
            XCTAssertEqual(content.editToolbarController.toolPicker.selectedSegment, segment, "\(command)")
            XCTAssertEqual(content.editCapsule.toolPicker.selectedSegment, segment, "\(command)")
            content.editModeController.finalizeExit()
            XCTAssertFalse(content.isEditModeActive)
        }
    }

    // MARK: 15. The viewer context menu

    func testV15_ContextMenuHasEditImageAfterRotateRight() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let menu = viewer.contextMenu.menu
        let rotateRight = try XCTUnwrap(menu.items.firstIndex { $0.title == ShrikeCommand.rotateRight.title })
        let edit = menu.items[rotateRight + 1]
        XCTAssertTrue(edit.title.hasPrefix("Edit Image"), edit.title)
        XCTAssertTrue(viewer.validateMenuItem(edit), "enabled for a normal photo")
        XCTAssertTrue(menu.items[rotateRight + 2].isSeparatorItem, "Edit Image closes the rotate group")
    }

    // MARK: 9. Shift-Command-E is free

    func testV9_ShiftCommandEDoesNothing() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let key = KeyEventSnapshot.from(KeyCharactersTests.key("e", keyCode: 14, [.command, .shift]), isKeyUp: false)
        XCTAssertFalse(viewer.handleKeySnapshot(key), "no binding takes ⇧⌘E in the viewer")
        XCTAssertFalse(content.isEditModeActive)
        viewer.dispatch(.openEditMode)
        try await waitFor("edit mode") { content.isEditModeActive }
        XCTAssertFalse(viewer.handleKeySnapshot(key), "…nor in edit mode")
        content.exitEditMode()
    }

    // MARK: 16. Spec 26 §5: the photo's centre in edit mode

    func testV16_TheEditFitAreaIsCentredOnTheCanvasMinusThePanelColumn() async throws {
        let viewer = try await makeViewer(size: NSSize(width: 1200, height: 800))
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        viewer.enterEditMode(landOn: nil)
        await viewer.waitForEditLoad()
        content.layoutSubtreeIfNeeded()
        let iv = content.imageView
        let margin = ViewerContentView.editHandleMargin
        let panelColumn = iv.frame.maxX - content.editModeController.parameterPanel.frame.minX
        XCTAssertEqual(panelColumn, 296, accuracy: 1, "280 pt panel + 16 pt gap")
        let insets = content.currentFitInsets()
        XCTAssertEqual(insets.left, margin)
        XCTAssertEqual(insets.right, margin + panelColumn, accuracy: 0.5)
        // The free area is [margin, width - margin - column]; the photo is centred in it.
        let expectedMid = (margin + iv.bounds.width - margin - panelColumn) / 2
        XCTAssertEqual(iv.drawnImageRect.midX, expectedMid, accuracy: 1.5, "centre (W - 296) / 2")
        XCTAssertGreaterThanOrEqual(iv.drawnImageRect.minX, margin - 0.5, "clear of the left edge by the handle margin")
        content.editModeController.finalizeExit()
    }

    // MARK: 18. The viewer toolbar hidden: Edit still works

    func testV18_EditEntersWithTheViewerToolbarHidden() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        viewer.toolbar?.isVisible = false
        for (name, enter) in [("E", { viewer.perform(.editImage) }), ("Edit button", { viewer.dispatch(.openEditMode) })] {
            try await waitFor("accepted photo ready again") { viewer.canPerform(.editImage) }
            enter()
            try await waitFor("\(name) → edit mode") { content.isEditModeActive }
            XCTAssertTrue(viewer.toolbar === content.editToolbarController.toolbar, "\(name): the edit toolbar is installed")
            XCTAssertEqual(content.editToolbarController.toolPicker.selectedSegment, -1)
            content.editToolbarController.doneButton.performClick(nil)
            try await waitFor("clean Done finishes the edit session") {
                !content.isEditModeActive && !content.editModeController.isActive
            }
        }
    }

    // MARK: Own-drawn picker (macOS 26 toolbar paints system segments grey)

    /// The chosen segment draws the accent at platterAlpha; the others draw nothing.
    func testThePickerDrawsItsOwnAccentPlatter() throws {
        let picker = EditToolPicker()
        picker.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        picker.layoutSubtreeIfNeeded()
        picker.show(tool: .rotate)
        func alpha(_ seg: NSView) throws -> CGFloat {
            seg.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
            let rep = try XCTUnwrap(seg.bitmapImageRepForCachingDisplay(in: seg.bounds))
            seg.cacheDisplay(in: seg.bounds, to: rep)
            // Left edge of the platter is inside the 2 pt inset; sample a
            // point on the platter above the glyph (the bitmap may be 2x).
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 8)).alphaComponent
        }
        let segs = picker.segmentViewsForTesting
        XCTAssertEqual(try alpha(segs[0]), 0, accuracy: 0.01, "unchosen: nothing")
        XCTAssertEqual(try alpha(segs[1]), EditToolPicker.platterAlpha, accuracy: 0.03, "chosen: accent at platterAlpha")
        picker.show(tool: nil)
        XCTAssertEqual(try alpha(segs[1]), 0, accuracy: 0.01)
    }

    /// Hover draws the shared toolbar hover platter (white 14 % on dark).
    func testHoverDrawsTheSharedPlatter() throws {
        let picker = EditToolPicker()
        picker.appearance = NSAppearance(named: .darkAqua)
        picker.frame = NSRect(x: 0, y: 0, width: 160, height: 28)
        picker.layoutSubtreeIfNeeded()
        let seg = picker.segmentViewsForTesting[2] as! EditToolPicker.SegmentView
        seg.frame = NSRect(x: 0, y: 0, width: 32, height: 28)
        func alpha() throws -> CGFloat {
            let rep = try XCTUnwrap(seg.bitmapImageRepForCachingDisplay(in: seg.bounds))
            seg.cacheDisplay(in: seg.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: 8)).alphaComponent
        }
        XCTAssertEqual(try alpha(), 0, accuracy: 0.01)
        seg.isHoveredForTesting = true
        XCTAssertEqual(try alpha(), ToolbarHover.darkAlpha, accuracy: 0.03)
    }

    func testThePickerIsARadioGroupWithRadioButtons() {
        let picker = EditToolPicker()
        XCTAssertEqual(picker.accessibilityRole(), .radioGroup)
        XCTAssertEqual(picker.accessibilityLabel(), "Tool")
        let kids = picker.accessibilityChildren() as? [NSView] ?? []
        XCTAssertEqual(kids.count, 5)
        picker.show(tool: .resize)
        for (i, kid) in kids.enumerated() {
            XCTAssertEqual(kid.accessibilityRole(), .radioButton)
            XCTAssertEqual(kid.accessibilityLabel(), EditChromeTools.name(EditChromeTools.order[i]))
            XCTAssertEqual(kid.accessibilityValue() as? Int, i == 2 ? 1 : 0)
        }
        var picked: [EditTool] = []
        picker.onPick = { picked.append($0) }
        XCTAssertTrue(kids[3].accessibilityPerformPress())
        XCTAssertEqual(picked, [.color])
        XCTAssertEqual(picker.selectedSegment, 3)
        // Pressing the active tool again picks it again (select-one).
        XCTAssertTrue(kids[3].accessibilityPerformPress())
        XCTAssertEqual(picked, [.color, .color])
    }

    // MARK: Narrow canvas + inspector: the tool panel stays on screen

    func testNarrowCanvasWithInspectorCollapsesItWhileEditing() async throws {
        let savedPref = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = true
        defer { Prefs.viewerInspectorVisibleWindowed = savedPref }
        let viewer = try await makeViewer(size: NSSize(width: 480, height: 400))
        defer { viewer.close() }
        let split = try XCTUnwrap(viewer.splitController)
        XCTAssertTrue(split.isInspectorShown)
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        viewer.contentView?.layoutSubtreeIfNeeded()
        try await waitFor("inspector steps aside") { !split.isInspectorShown }
        viewer.contentView?.layoutSubtreeIfNeeded()
        let panel = content.editModeController.parameterPanel
        XCTAssertGreaterThanOrEqual(panel.frame.minX, 0, "panel fully inside the canvas")
        XCTAssertTrue(Prefs.viewerInspectorVisibleWindowed, "the pref is untouched")
        // ⌘I mid-edit on the narrow canvas: the next layout (the canvas is
        // 240 pt with the inspector open; offscreen the split does not resize
        // the canvas, so the width is passed in) sends it aside again.
        split.setInspectorShown(true, animated: false)
        XCTAssertTrue(split.isInspectorShown)
        split.editCanvasWidth(240)
        XCTAssertFalse(split.isInspectorShown)
        // A wide canvas never collapses it.
        split.setInspectorShown(true, animated: false)
        split.editCanvasWidth(900)
        XCTAssertTrue(split.isInspectorShown)
        content.editModeController.finalizeExit()
        try await waitFor("inspector returns") { split.isInspectorShown }
        XCTAssertTrue(Prefs.viewerInspectorVisibleWindowed)
    }
}

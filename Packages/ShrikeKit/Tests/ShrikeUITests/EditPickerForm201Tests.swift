//
//  EditPickerForm201Tests.swift
//  ShrikeUITests
//
//  Spec 28 §20.1 and §20.3: the tool picker shows words from 1120 pt of window width and
//  icons below (back to words at 1140), the capsule keeps words, the overflow order, and
//  the Edit button's names.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class EditPickerForm201Tests: XCTestCase {

    // MARK: The rule (pure)

    func testFreshChoiceHasNoHysteresis() {
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1200, current: nil), .words)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1120, current: nil), .words)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1119, current: nil), .icons)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 900, current: nil), .icons)
    }

    func testHysteresisGoingDownAndUp() {
        // Words stay words down to 1120; at 1119 icons.
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1120, current: .words), .words)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1119.5, current: .words), .icons)
        // Icons stay icons until 1140 (between 1120 and 1139 no flicker).
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1120, current: .icons), .icons)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1139, current: .icons), .icons)
        XCTAssertEqual(EditPickerFormRule.form(windowWidth: 1140, current: .icons), .words)
    }

    /// Each name fits its segment in full (no letter cut off), with the
    /// default and with the Larger Text setting, chosen or not.
    func testEveryNameFitsItsSegment() {
        let larger = Prefs.largerChrome
        defer { Prefs.largerChrome = larger }
        // The bare text widths the segments had before (each cut its last letter).
        let bare = EditChromeTools.order.map {
            ceil(40 + (EditChromeTools.name($0) as NSString).size(withAttributes: [.font: EditToolPicker.labelFont]).width)
        }.reduce(0, +)
        XCTAssertEqual(EditToolPicker.totalWidth - bare, EditPickerFormRule.wordsFromWidth - 1100, accuracy: 0.5,
                       "the words threshold rose by what the picker grew")
        for setting in [false, true] {
            Prefs.largerChrome = false
            let picker = EditToolPicker()
            ChromeTypography.register(picker)   // as the full-screen capsule's labels
            Prefs.largerChrome = setting
            ChromeTypography.update(picker)
            picker.form = .words
            picker.layoutSubtreeIfNeeded()
            picker.frame = NSRect(x: 0, y: 0, width: picker.intrinsicContentSize.width, height: EditToolPicker.height)
            for chosen in [-1, 0, 1, 2, 3, 4] {
                picker.show(tool: chosen < 0 ? nil : EditChromeTools.order[chosen])
                picker.layoutSubtreeIfNeeded()
                for (i, seg) in picker.segmentViewsForTesting.enumerated() {
                    seg.layoutSubtreeIfNeeded()
                    let label = seg.subviews.compactMap { $0 as? NSTextField }.first
                    let name = EditChromeTools.name(EditChromeTools.order[i])
                    XCTAssertEqual(label?.stringValue, name)
                    XCTAssertEqual(label?.font?.pointSize, setting ? 14 : 12, "\(name) draws the scaled font")
                    XCTAssertLessThanOrEqual(label?.fittingSize.width ?? .infinity, label?.frame.width ?? 0,
                                             "\(name) fits (larger text \(setting), chosen \(chosen))")
                }
            }
        }
        XCTAssertLessThanOrEqual(EditToolPicker.totalWidth, 5 * 90)
    }

    func testDragSequenceSwitchesOnceEachWay() {
        var form: EditPickerForm = .words
        var switches = 0
        for w in Array(stride(from: 1200.0, through: 900.0, by: -5)) + Array(stride(from: 900.0, through: 1200.0, by: 5)) {
            let next = EditPickerFormRule.form(windowWidth: CGFloat(w), current: form)
            if next != form { switches += 1 }
            form = next
        }
        XCTAssertEqual(switches, 2)
        XCTAssertEqual(form, .words)
    }

    func testMeasuredNumbers() {
        XCTAssertEqual(EditPickerFormRule.wordsFromWidth, 1120, "measured 1080 + 20, + 20 for the full label widths")
        XCTAssertEqual(EditPickerFormRule.hysteresis, 20)
        XCTAssertEqual(EditLayout.minCanvasWidth, 900, "measured 880 + 20")
    }

    // MARK: The picker's two forms

    func testIconFormIsFiveTimes32AndKeepsTheTool() {
        let picker = EditToolPicker()
        picker.show(tool: .resize)
        XCTAssertEqual(picker.currentTotalWidth, EditToolPicker.totalWidth)
        XCTAssertEqual(picker.label(forSegment: 0), "Crop")
        picker.form = .icons
        XCTAssertEqual(picker.currentTotalWidth, 160)
        XCTAssertEqual(picker.intrinsicContentSize.width, 160)
        XCTAssertEqual(picker.width(forSegment: 2), 32)
        XCTAssertNil(picker.label(forSegment: 0), "no words in the icons form")
        XCTAssertEqual(picker.selectedSegment, 2, "the chosen tool stays")
        // Name stays for VoiceOver and in the tooltip.
        let seg = picker.segmentViewsForTesting[0]
        XCTAssertEqual(seg.accessibilityLabel(), "Crop")
        XCTAssertTrue(picker.toolTip(forSegment: 0)?.hasPrefix("Crop") ?? false)
        picker.layoutSubtreeIfNeeded()
        picker.frame = NSRect(x: 0, y: 0, width: 160, height: EditToolPicker.height)
        picker.layoutSubtreeIfNeeded()
        XCTAssertEqual(picker.segmentViewsForTesting.map(\.frame.width), [32, 32, 32, 32, 32])
        picker.form = .words
        XCTAssertEqual(picker.currentTotalWidth, EditToolPicker.totalWidth)
    }

    func testCapsuleKeepsWordsOnEveryRealScreen() {
        XCTAssertEqual(EditCapsuleView.form(capsuleWordsWidth: 900, screenWidth: 1280), .words)
        XCTAssertEqual(EditCapsuleView.form(capsuleWordsWidth: 900, screenWidth: 940), .icons)
        let capsule = EditCapsuleView()
        capsule.chooseForm(screenWidth: 1280)
        XCTAssertEqual(capsule.toolPicker.form, .words)
    }

    // MARK: Overflow order and forms (rule 4)

    func testOverflowOrderResetThenSaveCopyThenUndoRedo() {
        let p = EditToolbarController.visibilityPriority
        typealias ID = EditToolbarController.ItemID
        XCTAssertLessThan(p(ID.reset).rawValue, p(ID.saveCopy).rawValue)
        XCTAssertLessThan(p(ID.saveCopy).rawValue, p(ID.undoRedo).rawValue)
        XCTAssertLessThan(p(ID.undoRedo).rawValue, p(ID.tools).rawValue)
        XCTAssertEqual(p(ID.tools), .standard)
        XCTAssertEqual(p(ID.cancel), .high)
        XCTAssertEqual(p(ID.done), .high)
    }

    func testUndoRedoNeverCollapsesIntoAnEmptyMenuButton() throws {
        let controller = EditToolbarController()
        let item = try XCTUnwrap(controller.toolbar(controller.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.undoRedo,
                                                    willBeInsertedIntoToolbar: true) as? NSToolbarItemGroup)
        XCTAssertEqual(item.controlRepresentation, .expanded)
    }

    // MARK: The window drives the form

    func testWindowWidthDrivesTheToolbarPicker() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("picker-\(UUID().uuidString.prefix(6)).jpg")
        XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
        defer { try? FileManager.default.removeItem(at: url) }
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 1200, height: 600))
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants()
        viewer.contentRootForTesting.animatesPanelFades = false
        viewer.contentRootForTesting.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: nil)
        let picker = viewer.contentRootForTesting.editToolbarController.toolPicker
        XCTAssertEqual(picker.form, .words, "1200 pt: words")
        var f = viewer.frame
        f.size.width = 1000
        viewer.setFrame(f, display: false)
        XCTAssertEqual(picker.form, .icons, "1000 pt: icons")
        f.size.width = 1130
        viewer.setFrame(f, display: false)
        XCTAssertEqual(picker.form, .icons, "hysteresis: still icons below 1140")
        f.size.width = 1140
        viewer.setFrame(f, display: false)
        XCTAssertEqual(picker.form, .words)
        viewer.contentRootForTesting.editModeController.finalizeExit()
    }

    // MARK: §20.3 Edit button names

    func testEditButtonNames() throws {
        let bar = ViewerWindowToolbar(host: nil)
        let item = try XCTUnwrap(bar.toolbar(bar.toolbar, itemForItemIdentifier: ViewerWindowToolbar.ID.edit,
                                             willBeInsertedIntoToolbar: true))
        XCTAssertEqual(item.title, "Edit", "visible title")
        XCTAssertEqual(item.label, "Edit Photo", "the accessibility name")
        XCTAssertEqual(item.paletteLabel, "Edit", "Customize label")
        XCTAssertTrue(item.toolTip?.hasPrefix("Edit Photo  ·  ") ?? false, item.toolTip ?? "nil")
    }
}

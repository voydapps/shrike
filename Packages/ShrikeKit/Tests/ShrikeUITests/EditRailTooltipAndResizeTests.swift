//
//  EditRailTooltipAndResizeTests.swift
//  ShrikeUITests
//
//  (rail tooltips from the resolver) and
//  (Resize W/H start at the full-resolution size, aspect lock on).
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class EditRailTooltipAndResizeTests: XCTestCase {

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    // The rail's Crop tooltip is "Crop  ·  <key>", the same key
    // the Shortcuts tab shows, and it follows a preset change.
    func testRailCropTooltip_matchesResolver_andFollowsPreset() {
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            Prefs.shortcutPreset = preset
            let rail = EditRail()
            let expected = LiveTooltips.text(.editCrop, context: .editMode, preset: preset)
            XCTAssertTrue(expected.hasPrefix("Crop"))
            let titles = rail.buttonTitlesForTesting()
            XCTAssertTrue(titles.contains(expected), "\(titles) lacks \(expected)")
            if let key = ShortcutTable.bindings(for: .editCrop, context: .editMode, preset: preset).first {
                XCTAssertEqual(expected, "Crop  ·  \(key.displayString)")
            }
        }
    }

    func testResizePanel_startsAtFullResolution_aspectLockOn() {
        let panel = ResizePanel()
        panel.sourcePixelSize = CGSize(width: 6000, height: 4000)
        XCTAssertEqual(panel._widthField.integerValue, 6000)
        XCTAssertEqual(panel._heightField.integerValue, 4000)
        XCTAssertEqual(panel._maintainCheckbox.state, .on)
        XCTAssertEqual(panel.currentSpec()?.width, 6000)
        XCTAssertEqual(panel.currentSpec()?.height, 4000)
    }
}

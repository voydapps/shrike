//
//  PresetTooltipsTests.swift
//  ShrikeUITests
//
//  Tooltips read their key from the shortcut table,
//  so switching the preset changes them. Covers a bound view (the edit
//  bar's buttons use the same binding), the "Cancel" title override and
//  the Rating toolbar item's key range.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PresetTooltipsTests: XCTestCase {

    private var saved: ShortcutPreset = .macNative

    override func setUp() async throws {
        saved = Prefs.shortcutPreset
        Prefs.shortcutPreset = .macNative
        LiveTooltips.shared.refreshIfPresetChanged()
    }

    override func tearDown() async throws {
        Prefs.shortcutPreset = saved
        LiveTooltips.shared.refreshIfPresetChanged()
    }

    func testSwitchingThePresetChangesABoundTooltip() {
        let button = NSButton()
        LiveTooltips.shared.bind(button, command: .moveToTrash, context: .viewer)
        let mac = button.toolTip
        XCTAssertEqual(mac, LiveTooltips.text(.moveToTrash, context: .viewer, preset: .macNative))

        Prefs.shortcutPreset = .fastStoneCompat
        LiveTooltips.shared.refreshIfPresetChanged()
        XCTAssertEqual(button.toolTip, LiveTooltips.text(.moveToTrash, context: .viewer, preset: .fastStoneCompat))
        XCTAssertNotEqual(button.toolTip, mac)
    }

    func testEditBarTooltipsComeFromTheTable() {
        XCTAssertEqual(LiveTooltips.text(.exitEditMode, context: .editMode, preset: .macNative, title: "Cancel"),
                       "Cancel  ·  \(ShortcutTable.bindings(for: .exitEditMode, context: .editMode, preset: .macNative)[0].displayString)")
        XCTAssertTrue(LiveTooltips.text(.undo, context: .editMode, preset: .macNative).hasPrefix("Undo  ·  "))
        XCTAssertTrue(LiveTooltips.text(.redo, context: .editMode, preset: .macNative).hasPrefix("Redo  ·  "))
        XCTAssertTrue(LiveTooltips.text(.editDone, context: .editMode, preset: .macNative).hasPrefix("Done  ·  "))
    }

    func testRatingKeysFollowThePreset() {
        XCTAssertEqual(ViewerWindowToolbar.ratingKeyText(.macNative), "0–5")
        XCTAssertEqual(ViewerWindowToolbar.ratingKeyText(.fastStoneCompat), "⌃0–⌃5")
    }
}

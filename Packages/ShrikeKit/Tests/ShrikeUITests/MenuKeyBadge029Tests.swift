//
//  MenuKeyBadge029Tests.swift
//  ShrikeUITests
//
//  Menu key hints are NSMenuItemBadge badges in the key column (the user chose
//  badges over the tab-stop column, 2026-10-13; spec 27 V2, spec 25 §13.1).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class MenuKeyBadge029Tests: XCTestCase {

    private var savedPreset: ShortcutPreset!

    override func setUp() async throws {
        savedPreset = Prefs.shortcutPreset
        Prefs.shortcutPreset = .macNative
    }

    override func tearDown() async throws {
        Prefs.shortcutPreset = savedPreset
    }

    private func hintItem(_ command: ShrikeCommand, in menu: NSMenu, submenu: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: command.title, action: ShrikeMainMenu.commandAction, keyEquivalent: "")
        item.representedObject = command.rawValue
        if submenu { item.submenu = NSMenu(title: command.title) }
        menu.addItem(item)
        return item
    }

    private func trashRow(in menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: "Move to Trash", action: nil, keyEquivalent: "\u{8}")
        item.keyEquivalentModifierMask = [.command]
        menu.addItem(item)
        return item
    }

    func testHintedRowsGetABadgeAndKeepTheirTitle() {
        let menu = NSMenu(title: "File")
        let trash = trashRow(in: menu)
        let flag = hintItem(.toggleFlag, in: menu)
        let rate = hintItem(.rate3, in: menu)
        MenuKeyHints.apply(to: menu, context: .browser)
        XCTAssertEqual(flag.badge?.stringValue, "Q")
        XCTAssertEqual(rate.badge?.stringValue, "3")
        XCTAssertEqual(flag.title, ShrikeCommand.toggleFlag.title, "the title is untouched")
        XCTAssertNil(flag.attributedTitle)
        XCTAssertNil(trash.badge, "a row with a real key gets no badge")
    }

    func testSubmenuRowGetsABadge() {
        let menu = NSMenu(title: "Image")
        let sub = hintItem(.rate3, in: menu, submenu: true)
        MenuKeyHints.apply(to: menu, context: .browser)
        XCTAssertEqual(sub.badge?.stringValue, "3")
    }

    func testDestinationRowsGetNoBadge() {
        let menu = NSMenu(title: ShrikeCommand.copyToFolder.title)
        let row = hintItem(.toggleFlag, in: menu)
        MenuKeyHints.apply(to: menu, context: .browser)
        XCTAssertNil(row.badge)
    }

    func testRunningAgainIsStableAndPresetSwitchUpdatesBadges() {
        let menu = NSMenu(title: "File")
        let flag = hintItem(.toggleFlag, in: menu)
        let rate = hintItem(.rate3, in: menu)
        MenuKeyHints.apply(to: menu, context: .browser)
        MenuKeyHints.apply(to: menu, context: .browser)
        XCTAssertEqual(flag.badge?.stringValue, "Q")
        MenuKeyHints.apply(to: menu, context: .browser, preset: .fastStoneCompat)
        XCTAssertNil(rate.badge, "FastStone rates with a modified key: no badge")
        MenuKeyHints.apply(to: menu, context: .browser, preset: .macNative)
        XCTAssertEqual(rate.badge?.stringValue, "3")
    }
}

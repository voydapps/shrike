//
//  DeadActionsTests.swift
//  ShrikeUITests
//
//  Curves, page navigation (multi-page TIFF / PDF) and
//  auto-rotate from EXIF have no entry point. The actions themselves are
//  gone from `ViewerAction`, so the key maps cannot reach them; these
//  tests check the menus, the Settings ▸ Shortcuts list and the old keys
//  (⌘↑/⌘↓ pages, ⌃⌘R auto-rotate; FastStone ⌃⇞/⌃⇟, ⌃⌥A).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class DeadActionsTests: XCTestCase {

    private let deadWords = ["curves", "previous page", "next page", "prev page", "auto-rotate", "auto rotate"]

    private func isDead(_ title: String) -> Bool {
        let lower = title.lowercased()
        return deadWords.contains { lower.contains($0) }
    }

    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems) ?? []) }
    }

    func testNoMenuItem() {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let titles = allItems(bar.menu).map(\.title)
        XCTAssertFalse(titles.isEmpty)
        XCTAssertEqual(titles.filter(isDead), [])
    }

    func testNoShortcutsListRow() {
        for preset in ShortcutPreset.allCases {
            let rows = ShortcutsTab.sections(for: preset).flatMap(\.rows)
            XCTAssertFalse(rows.isEmpty)
            XCTAssertEqual(rows.map(\.action).filter(isDead), [], "\(preset)")
        }
    }

    func testNoTableRowOrOldKey() {
        for preset in ShortcutPreset.allCases {
            XCTAssertEqual(ShortcutTable.rows(for: preset).map(\.command.title).filter(isDead), [])
        }
        let oldKeys: [(KeyEventSnapshot, ShortcutPreset)] = [
            (KeyEventSnapshot(key: SpecialKey.down, modifiers: [.command]), .macNative),     // next page
            (KeyEventSnapshot(key: "r", modifiers: [.command, .control]), .macNative),       // auto-rotate
            (KeyEventSnapshot(key: SpecialKey.pageUp, modifiers: [.control]), .fastStoneCompat),
            (KeyEventSnapshot(key: SpecialKey.pageDown, modifiers: [.control]), .fastStoneCompat),
            (KeyEventSnapshot(key: "a", modifiers: [.control, .option]), .fastStoneCompat),
        ]
        for (key, preset) in oldKeys {
            XCTAssertNil(ViewerKeyMap.action(for: key, context: .viewer, preset: preset),
                         "\(key.key) \(key.modifiers) in \(preset)")
        }
    }
}

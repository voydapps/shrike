//
//  MenuIcons028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-9: on macOS 26 the system puts icons on its own standard menu
//  items, so the Shrike items beside them get one too (one table); below 26
//  nothing has an icon. A menu is all icons or none.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class MenuIcons028Tests: XCTestCase {

    private var saved = false

    override func setUp() async throws { saved = ShrikeMainMenu.systemDrawsMenuIcons }
    override func tearDown() async throws { ShrikeMainMenu.systemDrawsMenuIcons = saved }

    private func bar() -> ShrikeMainMenu {
        ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
    }

    func testEverySymbolInTheTableExists() {
        for entry in ShrikeMainMenu.menuIconTable {
            XCTAssertNotNil(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil), entry.symbol)
        }
        for entry in ShrikeMainMenu.menuHolderIconTable {
            XCTAssertNotNil(NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil), entry.symbol)
        }
    }

    /// Rows AppKit draws its own icon on (or none): left out of the all-or-none count.
    private static let appKitSelectors: Set<String> = [
        "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
        "performMiniaturize:", "performZoom:", "arrangeInFront:",
        // macOS 26 puts these on by itself, on every run of it:
        "performClose:", "runToolbarCustomizationPalette:", "hide:", "hideOtherApplications:",
        "unhideAllApplications:", "terminate:", "orderFrontStandardAboutPanel:",
    ]

    /// The rows of a top-level menu that Shrike owns: not separators, not AppKit's own.
    private func ownRows(_ sub: NSMenu) -> [NSMenuItem] {
        sub.items.filter { item in
            !item.isSeparatorItem && !Self.appKitSelectors.contains(item.action.map(NSStringFromSelector) ?? "")
        }
    }

    /// Whole menus, every row (not only table items): all icons or none, and the menus that
    /// carry system icons (Shrike, File, Edit, View, Window) are all icons.
    func testEveryMenuIsAllOrNone() throws {
        ShrikeMainMenu.systemDrawsMenuIcons = true
        let bar = bar()
        bar.applyAllIconsForTesting()
        var sawIconed = Set<String>()
        for top in bar.menu.items {
            guard let sub = top.submenu else { continue }
            let rows = ownRows(sub)
            let iconed = rows.filter { $0.image != nil }
            XCTAssertTrue(iconed.isEmpty || iconed.count == rows.count,
                          "\(sub.title): all or none; no icon on \(rows.filter { $0.image == nil }.map(\.title))")
            if !iconed.isEmpty { sawIconed.insert(sub.title) }
        }
        XCTAssertTrue(sawIconed.isSuperset(of: ["Edit", "View", "Window", "File", "Shrike"]), "\(sawIconed)")
    }

    func testWhereTheSystemDrawsIconsEveryTableItemHasOne() throws {
        ShrikeMainMenu.systemDrawsMenuIcons = true
        let bar = bar()
        bar.applyAllIconsForTesting()
        for entry in ShrikeMainMenu.menuIconTable {
            let items = bar.items(for: entry.command)
            XCTAssertFalse(items.isEmpty, "\(entry.command)")
            for item in items { XCTAssertNotNil(item.image, "\(entry.command) has \(entry.symbol)") }
        }
        // Edit: every item that sends a Shrike command has one (Copy / Paste / Select All
        // are AppKit's own selectors; AppKit draws theirs).
        let edit = try XCTUnwrap(bar.menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
        let shrikeItems = edit.items.filter { $0.action == ShrikeMainMenu.commandAction }
        XCTAssertFalse(shrikeItems.isEmpty)
        XCTAssertTrue(shrikeItems.allSatisfy { $0.image != nil }, "Edit: all or none")
        // Each menu with table items is all icons (no mix within a menu's table items).
        for top in bar.menu.items {
            guard let sub = top.submenu else { continue }
            let table = Set(ShrikeMainMenu.menuIconTable.map(\.command.rawValue))
            let tabled = sub.items.filter { ($0.representedObject as? String).map(table.contains) ?? false }
            if tabled.isEmpty { continue }
            XCTAssertTrue(tabled.allSatisfy { $0.image != nil }, "\(sub.title): all")
        }
    }

    func testBelowTheSystemThatDrawsIconsNoItemHasOne() {
        ShrikeMainMenu.systemDrawsMenuIcons = false
        let bar = bar()
        bar.applyAllIconsForTesting()
        // (AppKit's own items, such as Bring All to Front, may carry system icons on 26.)
        for entry in ShrikeMainMenu.menuIconTable {
            for item in bar.items(for: entry.command) { XCTAssertNil(item.image, "\(entry.command)") }
        }
        for top in bar.menu.items {
            guard let sub = top.submenu else { continue }
            for item in ownRows(sub) { XCTAssertNil(item.image, "\(sub.title) / \(item.title)") }
        }
        // Every Shrike command row that sends the Shrike action has none.
        for item in bar.allItems where item.action == ShrikeMainMenu.commandAction {
            XCTAssertNil(item.image, item.title)
        }
    }

    func testIconsFollowTheTitleFlip() throws {
        ShrikeMainMenu.systemDrawsMenuIcons = true
        let bar = bar()
        bar.applyAllIconsForTesting()
        let sidebar = try XCTUnwrap(bar.items(for: .toggleSidebar).first)
        sidebar.title = "Show Sidebar"
        XCTAssertNotNil(sidebar.image, "the icon stays when the title flips")
    }
}

//
//  EditMenuLaunchCostTests.swift
//  ShrikeUITests
//
//  The Edit menu's Writing Tools items load WritingToolsUI
//  at launch. The Edit menu turns them off; Cut / Copy / Paste / Select
//  All stay. The timing only means something in a fresh process:
//
//    SHRIKE_WT_BENCH=off swift test --filter EditMenuLaunchCostTests/testInstallCost
//    SHRIKE_WT_BENCH=on  swift test --filter EditMenuLaunchCostTests/testInstallCost
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class EditMenuLaunchCostTests: XCTestCase {

    private func editMenu(_ bar: ShrikeMainMenu) -> NSMenu? {
        bar.menu.items.first { $0.submenu?.title == "Edit" }?.submenu
    }

    func testEditMenuKeepsItsItemsAndAddsNoWritingTools() throws {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let edit = try XCTUnwrap(editMenu(bar))
        if #available(macOS 15.2, *) {
            XCTAssertFalse(edit.automaticallyInsertsWritingToolsItems)
        }
        let actions = Set(edit.items.compactMap(\.action))
        for selector in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)),
                         #selector(NSText.paste(_:)), #selector(NSText.selectAll(_:))] {
            XCTAssertTrue(actions.contains(selector), "\(selector) stays")
        }
    }

    /// Prints the install cost (main menu set on NSApp + one update pass).
    func testInstallCost() throws {
        guard let mode = ProcessInfo.processInfo.environment["SHRIKE_WT_BENCH"] else {
            throw XCTSkip("set SHRIKE_WT_BENCH=on|off in a fresh process")
        }
        ShrikeMainMenu.insertsWritingToolsItems = mode == "on"
        defer { ShrikeMainMenu.insertsWritingToolsItems = false }
        let app = NSApplication.shared
        let start = CFAbsoluteTimeGetCurrent()
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        bar.install(in: app)
        bar.menu.update()
        editMenu(bar)?.update()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let titles = editMenu(bar)?.items.map(\.title) ?? []
        print("[edit menu] writing tools \(mode): install + update \(String(format: "%.1f", ms)) ms; "
              + "Edit menu: \(titles)")
    }
}

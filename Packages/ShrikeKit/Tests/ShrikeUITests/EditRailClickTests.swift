//
//  EditRailClickTests.swift
//  ShrikeUITests
//
//  User test 1 (2026-10-10): rail buttons did nothing because the rail
//  overwrote each button's own target. A real click (performClick, which
//  goes through target/action) must reach `actionDispatcher`.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class EditRailClickTests: XCTestCase {

    func testEveryRailButtonClickReachesTheDispatcher() {
        let rail = EditRail()
        var got: [ViewerAction] = []
        rail.actionDispatcher = { got.append($0) }
        let buttons = rail.buttonsForTesting
        XCTAssertEqual(buttons.count, 5)
        for button in buttons { button.performClick(nil) }
        XCTAssertEqual(got, rail.buttonActionsForTesting())
    }

    func testClickReachesTheDispatcherInWindowAndFullScreenRails() {
        for pinned in [false, true] {
            let rail = EditRail()
            rail.setPinned(pinned)
            var got: [ViewerAction] = []
            rail.actionDispatcher = { got.append($0) }
            rail.buttonsForTesting.first?.performClick(nil)
            XCTAssertEqual(got, [.crop], "pinned=\(pinned)")
        }
    }
}

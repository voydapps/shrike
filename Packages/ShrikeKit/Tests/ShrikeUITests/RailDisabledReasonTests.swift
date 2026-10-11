//
//  RailDisabledReasonTests.swift
//  ShrikeUITests
//
//  Spec 24 §4.5: a rail tool that is off says why in its tooltip.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class RailDisabledReasonTests: XCTestCase {

    private func makeContent() -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
        content.layoutSubtreeIfNeeded()
        return content
    }

    func testRAWShownGivesTheReasonInEveryToolTipAndComesBack() {
        let content = makeContent()
        let rail = content.editRailForTesting
        let original = rail.buttonTitlesForTesting()
        XCTAssertFalse(original.isEmpty)
        for title in original { XCTAssertFalse(title.contains(ViewerWindow.rawEditBlockedCopy)) }

        content.railToolsBlocked = true
        let blocked = rail.buttonTitlesForTesting()
        XCTAssertEqual(blocked.count, original.count)
        for (before, after) in zip(original, blocked) {
            XCTAssertEqual(after, before + "\n" + ViewerWindow.rawEditBlockedCopy, "tool name, then the reason")
        }

        content.railToolsBlocked = false
        XCTAssertEqual(rail.buttonTitlesForTesting(), original, "the plain tooltips are back")
    }

    func testAPresetChangeKeepsTheReason() {
        let content = makeContent()
        let rail = content.editRailForTesting
        content.railToolsBlocked = true
        guard let button = rail.buttonsForTesting.first else { return XCTFail("no rail button") }
        // LiveTooltips writes a fresh "Title  ·  key" text.
        button.toolTip = "Crop  ·  C"
        XCTAssertEqual(button.toolTip, "Crop  ·  C\n" + ViewerWindow.rawEditBlockedCopy)
        content.railToolsBlocked = false
        XCTAssertEqual(button.toolTip, "Crop  ·  C")
    }
}

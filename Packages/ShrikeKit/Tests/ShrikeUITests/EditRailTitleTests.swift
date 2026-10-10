//
//  EditRailTitleTests.swift
//  ShrikeUITests
//
//  The rail's buttons never draw a title (the word
//  "Button" showed over every icon), in labelled and compact mode.
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class EditRailTitleTests: XCTestCase {

    func testEveryRailButtonHasEmptyTitleInBothModes() {
        let rail = EditRail()
        for compact in [false, true] {
            rail.setCompact(compact)
            XCTAssertEqual(rail.buttonsForTesting.count, 5)
            for button in rail.buttonsForTesting {
                XCTAssertEqual(button.title, "", "compact=\(compact)")
                XCTAssertEqual(button.alternateTitle, "")
                XCTAssertEqual(button.imagePosition, .imageOnly, "compact=\(compact)")
            }
        }
    }

    func testCellSizes() {
        let rail = EditRail()
        rail.setCompact(false)
        for button in rail.buttonsForTesting {
            XCTAssertEqual(button.intrinsicContentSize, NSSize(width: 48, height: 50))
        }
    }

    func testActiveToolPlatterIsAccentAndGlyphIsLabelColor() {
        let rail = EditRail()
        rail.setActiveTool(.crop)
        let active = rail.buttonsForTesting.first { $0.isActiveTool }
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.contentTintColor, .labelColor)
        XCTAssertEqual(active?.platterOpacityForTesting ?? 0, 0.30, accuracy: 0.001)
    }
}

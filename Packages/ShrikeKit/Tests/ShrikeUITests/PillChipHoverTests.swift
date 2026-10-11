//
//  PillChipHoverTests.swift
//  ShrikeUITests
//
//  Spec 24 §4.3: the pair chip in the position pill lights on hover (a white
//  10 % platter) and shows the pointing hand; the rest of the pill stays
//  passive.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PillChipHoverTests: XCTestCase {

    private func makePill(pair: Bool) -> NavigationPositionOverlayView {
        let pill = NavigationPositionOverlayView()
        pill.frame = NSRect(x: 0, y: 0, width: 400, height: 28)
        pill.marks = PillMarks(hasRAW: true, pairKind: pair ? "JPG" : nil)
        pill.show(index: 3, total: 41, filename: "P1250331.JPG")
        pill.layoutSubtreeIfNeeded()
        return pill
    }

    func testHoverLightsThePlatterAndLeavingClearsIt() {
        let pill = makePill(pair: true)
        XCTAssertNotNil(pill.chipButtonFrameForTesting, "the chip has a hit area")
        XCTAssertEqual(pill.chipPlatterAlphaForTesting, 0, accuracy: 0.001)
        pill.setChipHoveredForTesting(true)
        XCTAssertEqual(pill.chipPlatterAlphaForTesting, 0.10, accuracy: 0.001)
        pill.setChipHoveredForTesting(false)
        XCTAssertEqual(pill.chipPlatterAlphaForTesting, 0, accuracy: 0.001)
    }

    func testMouseEnteredAndExitedDriveTheHover() {
        let pill = makePill(pair: true)
        let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                           userData: nil)!
        pill.chipButton.mouseEntered(with: event)
        XCTAssertTrue(pill.chipButton.isHovered)
        pill.chipButton.mouseExited(with: event)
        XCTAssertFalse(pill.chipButton.isHovered)
    }

    func testHidingTheChipClearsTheHover() {
        let pill = makePill(pair: true)
        pill.setChipHoveredForTesting(true)
        // The pair goes away: the chip hides and its hover with it.
        pill.marks = PillMarks()
        pill.layoutSubtreeIfNeeded()
        XCTAssertNil(pill.chipButtonFrameForTesting)
        XCTAssertEqual(pill.chipPlatterAlphaForTesting, 0, accuracy: 0.001)
    }

    func testSingleFileHasNoChipToHover() {
        let pill = makePill(pair: false)
        XCTAssertNil(pill.chipButtonFrameForTesting)
    }

    func testTheHitAreaIsAtLeast28By22() throws {
        let pill = makePill(pair: true)
        let frame = try XCTUnwrap(pill.chipButtonFrameForTesting)
        XCTAssertGreaterThanOrEqual(frame.width, 28)
        XCTAssertGreaterThanOrEqual(frame.height, 22)
    }
}

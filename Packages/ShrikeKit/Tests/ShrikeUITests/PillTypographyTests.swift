//
//  PillTypographyTests.swift
//  ShrikeUITests
//
//  The position pill reads
//  "43 / 180 · DSC_0042.jpg": counter 12 pt medium with monospaced
//  digits, a secondary "·" with 6 pt on each side, name 12 pt regular.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class PillTypographyTests: XCTestCase {

    func testCounterDotAndNameStyles() throws {
        let base = "43 / 180\(PillMarks.nameSeparator)DSC_0042.jpg"
        let text = PillMarks.baseText(base)
        XCTAssertEqual(text.string, "43 / 180\u{00B7}DSC_0042.jpg", "no em dash, one middle dot")

        let ns = text.string as NSString
        let counterFont = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(counterFont.pointSize, 12)
        XCTAssertEqual(counterFont, NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium))
        XCTAssertFalse(counterFont.isFixedPitch, "SF Pro with monospaced digits, not SF Mono")

        let dot = ns.range(of: "\u{00B7}").location
        XCTAssertEqual(text.attribute(.kern, at: dot - 1, effectiveRange: nil) as? CGFloat, 6, "6 pt before the dot")
        XCTAssertEqual(text.attribute(.kern, at: dot, effectiveRange: nil) as? CGFloat, 6, "6 pt after the dot")
        let dotColor = try XCTUnwrap(text.attribute(.foregroundColor, at: dot, effectiveRange: nil) as? NSColor)
        XCTAssertLessThan(dotColor.alphaComponent, 1, "the dot is secondary")

        let nameAt = ns.range(of: "DSC").location
        let nameFont = try XCTUnwrap(text.attribute(.font, at: nameAt, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(nameFont, NSFont.systemFont(ofSize: 12, weight: .regular))
        XCTAssertEqual(text.attribute(.foregroundColor, at: nameAt, effectiveRange: nil) as? NSColor, .white)
        XCTAssertNil(text.attribute(.kern, at: nameAt, effectiveRange: nil))
    }

    func testCounterOnlyWhenThereIsNoName() throws {
        let text = PillMarks.baseText("1 / 2")
        XCTAssertEqual(text.string, "1 / 2")
        let font = try XCTUnwrap(text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font, NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium))
    }

    func testOverlayShowUsesTheSeparator() {
        let overlay = NavigationPositionOverlayView()
        overlay.show(index: 42, total: 180, filename: "DSC_0042.jpg")
        XCTAssertEqual(overlay.labelTextForTesting.string, "43 / 180\u{00B7}DSC_0042.jpg")
    }
}

//
//  PillNameFitTests.swift
//  ShrikeUITests
//
//  Spec 25 §6.2: the position pill cuts a long file name with
//  `FileNameFit` (the last digit run and the extension stay), not with the
//  system's middle truncation. Narrow widths, a window and full screen.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PillNameFitTests: XCTestCase {

    private func makeContent(width: CGFloat, mode: ViewerContentView.WindowMode) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    private let longName = "Holiday-beach-sunset-with-the-whole-family-and-friends_4245_new.jpg"

    func testALongNameKeepsItsFrameNumberAndExtensionAtNarrowWidths() {
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            for width in [CGFloat(360), 480, 640] {
                let content = makeContent(width: width, mode: mode)
                let pill = content.navigationPositionOverlayForTesting
                pill.show(index: 31, total: 41, filename: longName)
                pill.alphaValue = 1
                content.layoutSubtreeIfNeeded()
                let drawn = pill.labelTextForTesting.string
                let label = "\(mode) \(Int(width)): \(drawn)"
                XCTAssertTrue(drawn.hasPrefix("32 / 41\u{00B7}"), "the counter stays whole, \(label)")
                XCTAssertTrue(drawn.hasSuffix("4245_new.jpg"), "frame number and extension stay, \(label)")
                XCTAssertTrue(drawn.contains("…"), "the head is cut, \(label)")
                XCTAssertFalse(drawn.contains("Holiday-beach-sunset-with-the-whole-family-and-friends"), label)
                // The cut text fits the label (nothing is clipped by the cell).
                XCTAssertLessThanOrEqual(pill.labelTextForTesting.size().width,
                                         pill.labelFrameForTesting.width + 0.5, label)
            }
        }
    }

    func testAWideCanvasShowsTheWholeName() {
        let content = makeContent(width: 1800, mode: .windowed)
        let pill = content.navigationPositionOverlayForTesting
        pill.show(index: 31, total: 41, filename: longName)
        pill.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(pill.labelTextForTesting.string.hasSuffix(longName), pill.labelTextForTesting.string)
        XCTAssertFalse(pill.labelTextForTesting.string.contains("…"))
    }

    func testTheNameComesBackWhenTheWindowGrowsAgain() {
        let content = makeContent(width: 360, mode: .windowed)
        let pill = content.navigationPositionOverlayForTesting
        pill.show(index: 0, total: 3, filename: longName)
        pill.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(pill.labelTextForTesting.string.contains("…"))
        content.frame = CGRect(x: 0, y: 0, width: 1800, height: 700)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(pill.labelTextForTesting.string.hasSuffix(longName), pill.labelTextForTesting.string)
    }

    func testFourSimilarNamesStayDistinctInANarrowPill() {
        let names = ["Holiday-beach-sunset-with-the-whole-family_IMG_4245_new.jpg",
                     "Holiday-beach-sunset-with-the-whole-family_IMG_4235_new.jpg",
                     "Holiday-beach-sunset-with-the-whole-family_IMG_4228_new.jpg",
                     "Holiday-beach-sunset-with-the-whole-family_IMG_4245.jpg"]
        let content = makeContent(width: 420, mode: .windowed)
        let pill = content.navigationPositionOverlayForTesting
        var shown = Set<String>()
        for name in names {
            pill.show(index: 0, total: 4, filename: name)
            pill.alphaValue = 1
            content.layoutSubtreeIfNeeded()
            shown.insert(pill.labelTextForTesting.string)
        }
        XCTAssertEqual(shown.count, 4, "\(shown)")
    }
}

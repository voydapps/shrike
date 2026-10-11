//
//  PillLayoutNoClipTests.swift
//  ShrikeUITests
//
//  User test 4 (2026-10-10): "32 / 41 · P1250331.JPG [RAW]" showed with its
//  first digit cut off. Not reproduced by hand. This pins the layout for the
//  cases listed in the brief: 41 items, 1/2/3-digit positions, the RAW chip,
//  flag, rating, tag dots, the edited pencil, narrow and wide canvases, in a
//  window and in full screen. The text label must sit inside the pill with
//  its 10 pt inset on both sides, the counter must never be truncated, and a
//  name that fits must not be truncated either.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PillLayoutNoClipTests: XCTestCase {

    private func makeContent(width: CGFloat, mode: ViewerContentView.WindowMode) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: width, height: 700)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    private let markSets: [(String, PillMarks)] = [
        ("none", PillMarks()),
        ("raw", PillMarks(hasRAW: true)),
        ("raw+flag", PillMarks(flagged: true, hasRAW: true)),
        ("stars+flag+raw", PillMarks(rating: 3, flagged: true, hasRAW: true)),
        ("everything", PillMarks(rating: 5, flagged: true, hasRAW: true, edited: true)),
    ]

    private func counterWidth(_ text: String) -> CGFloat {
        PillMarks.baseText(text).size().width
    }

    func testTheTextNeverClipsAtEitherEndForTheListedCases() {
        let names = ["P1250331.JPG", "IMG_4222.JPG", String(repeating: "LongName_", count: 7) + ".jpg"]
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            for width in [CGFloat(480), 640, 1440] {
                let content = makeContent(width: width, mode: mode)
                let pill = content.navigationPositionOverlayForTesting
                for (index, total) in [(0, 41), (8, 41), (31, 41), (40, 41), (99, 180), (431, 1200)] {
                    for (markName, marks) in markSets {
                        for name in names {
                            let label = "\(mode) \(Int(width)) \(index + 1)/\(total) \(markName) \(name.prefix(12))"
                            content.setPositionMarks(marks)
                            pill.show(index: index, total: total, filename: name)
                            pill.alphaValue = 1
                            content.layoutSubtreeIfNeeded()
                            let frame = content.pillFrameForTesting
                            let text = pill.labelFrameForTesting
                            XCTAssertGreaterThanOrEqual(frame.minX, 0, label)
                            XCTAssertLessThanOrEqual(frame.maxX, width, label)
                            // 10 pt inside the capsule on the left; marks end 10 pt before its right edge.
                            XCTAssertEqual(text.minX, 10, accuracy: 0.5, "label inset \(label)")
                            if let marksFrame = pill.marksFrameForTesting {
                                XCTAssertLessThanOrEqual(marksFrame.maxX, frame.width - 10 + 0.5, "marks \(label)")
                                XCTAssertGreaterThanOrEqual(marksFrame.minX, text.maxX - 0.5, "marks after text \(label)")
                                XCTAssertGreaterThanOrEqual(marksFrame.width, pill.marksTextWidthForTesting - 0.5,
                                                            "marks not squeezed \(label)")
                            } else {
                                XCTAssertLessThanOrEqual(text.maxX, frame.width - 10 + 0.5, "text \(label)")
                            }
                            // The counter ("32 / 41") is never truncated.
                            let counter = "\(index + 1) / \(total)"
                            XCTAssertGreaterThanOrEqual(text.width, counterWidth(counter) - 0.5,
                                                        "counter fits \(label)")
                            // A name that fits shows in full.
                            let full = pill.labelTextForTesting.size().width
                            if frame.width < width * 0.6 - 1 {
                                XCTAssertGreaterThanOrEqual(text.width, full - 1, "text fits \(label)")
                            }
                        }
                    }
                }
            }
        }
    }

    /// A clean 2-digit counter must be as wide as its digits: monospaced
    /// digits mean "32 / 41" and "11 / 41" take the same room.
    func testCounterWidthDoesNotDependOnTheDigits() {
        let a = counterWidth("11 / 41"), b = counterWidth("32 / 41"), c = counterWidth("99 / 41")
        XCTAssertEqual(a, b, accuracy: 0.5)
        XCTAssertEqual(b, c, accuracy: 0.5)
    }
}

//
//  Spec28TextsTests.swift
//  ShrikeUITests
//
//  Spec 28 §14: the texts that are pure wording (Slideshow broken file,
//  Shortcuts tab, Welcome home line, Histogram corner texts).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class Spec28TextsTests: XCTestCase {

    func testSlideshowBrokenFileTextAndShortWait() {
        XCTAssertEqual(SlideshowController.brokenFileText(name: "x.jpg"), "Can’t open “x.jpg”. Skipping to the next photo.")
        XCTAssertEqual(SlideshowController.advanceDelay(interval: 4, shownBroken: true), 1.5)
        XCTAssertEqual(SlideshowController.advanceDelay(interval: 1, shownBroken: true), 1, "the interval, when shorter")
        XCTAssertEqual(SlideshowController.advanceDelay(interval: 4, shownBroken: false), 4)
        XCTAssertEqual(SlideshowController.advanceDelay(interval: 1.5, shownBroken: true), 1.5)
    }

    func testShortcutsTabLines() {
        XCTAssertEqual(ShortcutsTab.presetHelp, "Choose a preset. Use Show All Shortcuts… to see every key.")
        XCTAssertEqual(ShortcutsTab.showAllTitle, "Show All Shortcuts…")
    }

    func testWelcomeHomeWord() {
        XCTAssertEqual(WelcomeWindowController.homeWord("~"), "Home")
        XCTAssertEqual(WelcomeWindowController.homeWord("~/Pictures"), "~/Pictures")
    }

    func testHistogramCornerTexts() {
        typealias P = HistogramPlot
        XCTAssertEqual(P.cornerText(.black, percent: 7.9, hudWidth: 320), "Black 7.9 %")
        XCTAssertEqual(P.cornerText(.white, percent: 19, hudWidth: 320), "White 19 %")
        XCTAssertEqual(P.cornerText(.white, percent: 19, hudWidth: 159), "19 %", "narrow: only the number")
        XCTAssertEqual(P.cornerText(.white, percent: 19, hudWidth: 160), "White 19 %")
        XCTAssertNil(P.cornerText(.black, percent: 0.5, hudWidth: 320))
        XCTAssertEqual(P.cornerTooltip(.black, percent: 7.9), "7.9 % of the pixels are pure black.")
        XCTAssertEqual(P.cornerTooltip(.white, percent: 19), "19 % of the pixels are pure white.")
        XCTAssertEqual(P.cornerAccessibilityLabel(.black, percent: 7.9), "Pure black pixels: 7.9 percent")
        XCTAssertEqual(P.cornerAccessibilityLabel(.white, percent: 19), "Pure white pixels: 19 percent")
    }
}

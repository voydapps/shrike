//
//  ExactProgressBarTests.swift
//  ShrikeUITests
//
//  The Copy / Move band's bar shows the counter's value at once (at 659 of
//  900 the system bar still drew about 59 %).
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class ExactProgressBarTests: XCTestCase {

    func testFillMatchesTheFractionAtOnce() {
        let bar = ExactProgressBar(frame: NSRect(x: 0, y: 0, width: 140, height: 6))
        bar.set(fraction: 659.0 / 900.0, label: "Copying 659 of 900…")
        XCTAssertEqual(bar.filledWidthForTesting, 140 * 659.0 / 900.0, accuracy: 0.01)
        bar.set(fraction: 870.0 / 900.0, label: "Copying 870 of 900…")
        XCTAssertEqual(bar.filledWidthForTesting, 140 * 870.0 / 900.0, accuracy: 0.01, "no glide: the next value is drawn now")
        XCTAssertEqual(bar.accessibilityLabel(), "Copying 870 of 900…")
        XCTAssertEqual((bar.accessibilityValue() as? NSNumber)?.doubleValue ?? -1, 870.0 / 900.0, accuracy: 0.0001)
        XCTAssertEqual(bar.accessibilityRole(), .progressIndicator)
    }

    func testNoFractionIsBusyAndFillIsHidden() {
        let bar = ExactProgressBar(frame: NSRect(x: 0, y: 0, width: 140, height: 6))
        bar.set(fraction: nil, label: "Copying…")
        XCTAssertNil(bar.fraction)
        XCTAssertEqual(bar.filledWidthForTesting, 0)
        bar.set(fraction: 2, label: "x")
        XCTAssertEqual(bar.fraction, 1, "clamped")
        bar.stopBusy()
    }

    func testBandUsesIt() {
        let notice = InlineNotice(fixedHeight: InlineNotice.fixedBandHeight)
        notice.showProgress("Copying 659 of 900…", fraction: 0.73)
        XCTAssertEqual(notice.progressFraction ?? -1, 0.73, accuracy: 0.0001)
        notice.showProgress("Copying 870 of 900…", fraction: nil)
        XCTAssertNil(notice.progressFraction)
    }

    func testViewerToastDrawsTheValueAtOnce() {
        let host = ToastHostView(placement: .browser)
        host.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        var content = ToastContent("Copying 659 of 900…")
        content.progress = 659.0 / 900.0
        let ticket = host.showProgress(content)
        host.layoutSubtreeIfNeeded()
        let bar = host.progressBarForTesting
        XCTAssertGreaterThan(bar.bounds.width, 0, "laid out, so the width checks below mean something")
        XCTAssertEqual(bar.fraction ?? -1, 659.0 / 900.0, accuracy: 0.0001)
        XCTAssertEqual(bar.accessibilityLabel(), "Copying 659 of 900…")
        XCTAssertEqual(bar.filledWidthForTesting, bar.bounds.width * 659.0 / 900.0, accuracy: 0.01)
        content.message = "Copying 870 of 900…"
        content.progress = 870.0 / 900.0
        let second = host.updateProgress(content, matching: ticket)
        XCTAssertEqual(bar.filledWidthForTesting, bar.bounds.width * 870.0 / 900.0, accuracy: 0.01)
        content.progress = 0
        content.progressIsIndeterminate = true
        _ = host.updateProgress(content, matching: try! XCTUnwrap(second))
        XCTAssertNil(bar.fraction, "busy stays the system bar")
        host.dismiss(animated: false)
    }
}

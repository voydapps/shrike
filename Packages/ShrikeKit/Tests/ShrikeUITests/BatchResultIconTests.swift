//
//  BatchResultIconTests.swift
//  ShrikeUITests
//
//  28a round 5: a green check sat beside `Batch stopped`. Round 8: the
//  result view with a per-photo list showed a warning triangle beside
//  `Batch stopped`. One icon rule for both views.
//

import XCTest
@testable import ShrikeUI

final class BatchResultIconTests: XCTestCase {
    private func icon(undone: Bool = false, stopped: Bool = false, reasons: Bool,
                      done: Int = 3) -> BatchModel.ResultIcon {
        BatchModel.resultIcon(isUndone: undone, isStopped: stopped, hasReasons: reasons, doneCount: done)
    }

    /// The view without a per-photo list.
    func testListlessView() {
        XCTAssertEqual(icon(reasons: false), .complete)
        XCTAssertEqual(icon(reasons: false).symbolName, "checkmark.circle.fill")
        XCTAssertTrue(icon(reasons: false).isGreen)
        XCTAssertEqual(icon(stopped: true, reasons: false), .stopped)
        XCTAssertEqual(icon(stopped: true, reasons: false).symbolName, "stop.circle")
        XCTAssertFalse(icon(stopped: true, reasons: false).isGreen)
        XCTAssertEqual(icon(undone: true, stopped: true, reasons: false).symbolName, "arrow.uturn.backward.circle")
    }

    /// The view with a per-photo list: a stopped run gets the stop sign, not the triangle.
    func testViewWithReasons() {
        XCTAssertEqual(icon(stopped: true, reasons: true), .stopped)
        XCTAssertEqual(icon(stopped: true, reasons: true).symbolName, "stop.circle")
        XCTAssertEqual(icon(stopped: true, reasons: true, done: 0), .stopped)
        XCTAssertEqual(icon(reasons: true), .issues)
        XCTAssertEqual(icon(reasons: true).symbolName, "exclamationmark.triangle")
        XCTAssertFalse(icon(reasons: true).isGreen)
        XCTAssertEqual(icon(reasons: true, done: 0).symbolName, "xmark.circle")
        XCTAssertEqual(icon(undone: true, reasons: true), .undone)
    }
}

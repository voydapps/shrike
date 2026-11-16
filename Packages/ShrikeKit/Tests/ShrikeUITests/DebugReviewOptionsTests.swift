//
//  DebugReviewOptionsTests.swift
//  ShrikeUITests
//
//  Debug launch options for on-screen reviewers (28a round 8).
//

import XCTest
@testable import ShrikeUI

final class DebugReviewOptionsTests: XCTestCase {
    func testParsesBothDelays() {
        let values = DebugReviewOptions.parse(["Shrike", "-ShrikeDebugPrintLoadDelay", "2.5",
                                                "-ShrikeDebugTransferDelay", "1"])
        XCTAssertEqual(values, .init(printLoadDelay: 2.5, transferDelay: 1))
    }

    func testMissingBadOrNegativeIsZeroAndLongIsCapped() {
        XCTAssertEqual(DebugReviewOptions.parse(["Shrike"]), .init())
        XCTAssertEqual(DebugReviewOptions.parse(["-ShrikeDebugTransferDelay"]).transferDelay, 0)
        XCTAssertEqual(DebugReviewOptions.parse(["-ShrikeDebugTransferDelay", "soon"]).transferDelay, 0)
        XCTAssertEqual(DebugReviewOptions.parse(["-ShrikeDebugPrintLoadDelay", "-3"]).printLoadDelay, 0)
        XCTAssertEqual(DebugReviewOptions.parse(["-ShrikeDebugPrintLoadDelay", "inf"]).printLoadDelay, 0)
        XCTAssertEqual(DebugReviewOptions.parse(["-ShrikeDebugPrintLoadDelay", "500"]).printLoadDelay,
                       DebugReviewOptions.maxDelay)
    }

    /// The test process passes no options: nothing is slowed down.
    func testThisProcessHasNoDelays() {
        XCTAssertEqual(DebugReviewOptions.current, .init())
    }
}

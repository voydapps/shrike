//
//  ToastErrorIconRuleTests.swift
//  ShrikeUITests
//
//  Spec 28 §18.2 "Look": error toasts carry the warning icon. Window-free.
//

import XCTest
@testable import ShrikeUI

final class ToastErrorIconRuleTests: XCTestCase {

    func testOnlyErrorToastsShowTheIcon() {
        XCTAssertTrue(ToastErrorIcon.shows(for: ToastContent("Couldn't rename “a.jpg”.", kind: .error)))
        XCTAssertFalse(ToastErrorIcon.shows(for: ToastContent("Renamed")))
        XCTAssertFalse(ToastErrorIcon.shows(for: ToastContent("★", kind: .glyph)))
        var progress = ToastContent("Copying 1 of 3", kind: .error)
        progress.progress = 0.3
        XCTAssertFalse(ToastErrorIcon.shows(for: progress), "a progress card never shows it")
        XCTAssertEqual(ToastErrorIcon.symbolName, "exclamationmark.triangle.fill")
        XCTAssertEqual(ToastErrorIcon.pointSize, 12)
    }
}

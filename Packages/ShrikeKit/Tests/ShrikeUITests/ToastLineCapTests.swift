//
//  ToastLineCapTests.swift
//  ShrikeUITests
//
//  Error toasts may use up to 4 lines; others 2; progress cards 1. Window-free.
//

import XCTest
@testable import ShrikeUI

final class ToastLineCapTests: XCTestCase {

    func testErrorToastsGetFourLines() {
        XCTAssertEqual(ToastContent("Couldn't move “a.jpg”.", kind: .error).maxLines, 4)
        XCTAssertEqual(BackupNotice.toast(ToastContent("Moved 8 items to “Trips”."), notSaved: 3, of: 8).maxLines, 4)
    }

    func testOtherToastsStayAtTwo() {
        XCTAssertEqual(ToastContent("Renamed").maxLines, 2)
        XCTAssertEqual(ToastContent("★", kind: .glyph).maxLines, 2)
        XCTAssertEqual(ToastContent.trashed("Moved 2 items to the Trash.").maxLines, 2)
        XCTAssertEqual(ToastContent.plainMaxLines, 2)
    }

    func testProgressCardIsOneLine() {
        var progress = ToastContent("Copying 1 of 3", kind: .error)
        progress.progress = 0.3
        XCTAssertEqual(progress.maxLines, 1)
    }

    func testLongErrorToastsKeepSixSeconds() {
        let content = BackupNotice.toast(ToastContent("Moved 8 items to “Trips”."), notSaved: 3, of: 8)
        XCTAssertEqual(content.duration, 6.0)
        XCTAssertEqual(BackupNotice.standaloneToast(lead: "Renamed.", notSaved: 1, of: 1)?.duration, 6.0)
    }
}

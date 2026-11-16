//
//  SettingsNoticeTextTests.swift
//  ShrikeUITests
//
//  B-11 (spec 28 §17.4) and C-2 (§18.3): the Settings lines. Window-free.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class SettingsNoticeTextTests: XCTestCase {

    private let tenGB: Int64 = 10 * 1024 * 1024 * 1024

    func testBackupUsageShowsTheLimit() {
        let limit = PreferencesByteFormat.string(fromBytes: tenGB)
        let used = PreferencesByteFormat.string(fromBytes: 111 * 1024 * 1024)
        XCTAssertEqual(EditingTab.usageLine(bytes: 111 * 1024 * 1024, limit: tenGB), "Backups use \(used) of \(limit).")
        XCTAssertEqual(EditingTab.usageLine(bytes: nil, limit: tenGB), "Backups use — of \(limit).")
        XCTAssertEqual(EditingTab.usageLine(bytes: nil, limit: 0), "Backups use —.")
    }

    func testHelpTextNamesTheLimit() {
        let limit = PreferencesByteFormat.string(fromBytes: tenGB)
        XCTAssertTrue(EditingTab.helpText(limit: tenGB).hasSuffix("after this period or when backups use more than \(limit)."))
        XCTAssertTrue(EditingTab.helpText(limit: 0).hasSuffix("or to meet the storage limit."))
    }

    func testOverLimitLine() {
        let limit = PreferencesByteFormat.string(fromBytes: tenGB)
        XCTAssertEqual(EditingTab.overLimitLine(limit: tenGB),
                       "Over the \(limit) limit. The rest are backups of photos that still exist, so Shrike keeps them.")
        XCTAssertNil(EditingTab.overLimitLine(limit: 0))
    }

    func testThumbnailsNotSavedLine() {
        XCTAssertNil(ThumbnailsTab.notSavedLine(isPersistent: true))
        XCTAssertEqual(ThumbnailsTab.notSavedLine(isPersistent: false),
                       "Shrike can't save thumbnails on this Mac right now. Photos still show, but the grid is slower each time you open Shrike.")
    }
}

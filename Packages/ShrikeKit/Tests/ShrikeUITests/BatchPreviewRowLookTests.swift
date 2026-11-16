//
//  BatchPreviewRowLookTests.swift
//  ShrikeUITests
//
//  L-4 (spec 28 §4) and B-9 in Batch (§18.5): skipped rows, summary lines,
//  the Run label. Window-free.
//

import XCTest
import ShrikeEdit
import ShrikeIO
@testable import ShrikeUI

final class BatchPreviewRowLookTests: XCTestCase {

    func testUnreadableRowGetsSkippedInFront() {
        XCTAssertEqual(BatchPreviewRowLook.skipText(.unreadable), "Skipped. Shrike can't read this file.")
        XCTAssertEqual(BatchPreviewRowLook.accessibilityLabel(name: "broken.jpg", skipText: "Skipped. Shrike can't read this file."),
                       "broken.jpg. Skipped. Shrike can't read this file.")
    }

    func testNameRowsUseTheMessageAsIs() {
        XCTAssertEqual(BatchPreviewRowLook.skipText(.invalidName(.trailingDot)), "The new name would end with a period — skipped.")
        XCTAssertEqual(BatchPreviewRowLook.skipText(.emptyName), "The new name would be empty — skipped.")
        XCTAssertEqual(BatchPreviewRowLook.accessibilityLabel(name: "IMG_0042.jpg", skipText: "The new name would end with a period — skipped."),
                       "IMG_0042.jpg. The new name would end with a period — skipped.")
    }

    func testOtherSkipsKeepTheArrowRow() {
        XCTAssertNil(BatchPreviewRowLook.skipText(nil))
        XCTAssertNil(BatchPreviewRowLook.skipText(.nameExists))
        XCTAssertNil(BatchPreviewRowLook.skipText(.cannotRotateLosslessly))
    }

    func testTemplateTextIs173() {
        XCTAssertEqual(BatchPreviewRowLook.templateText(firstNameSkip: .invalidName(.trailingDot)), "Names can't end with a period.")
        XCTAssertEqual(BatchPreviewRowLook.templateText(firstNameSkip: .invalidName(.edgeSpace)), "Names can't start or end with a space.")
        XCTAssertEqual(BatchPreviewRowLook.templateText(firstNameSkip: .emptyName), "The new name would be empty. Change the template.")
    }

    func testSummaryLinesAndRunLabel() {
        XCTAssertNil(BatchModel.Copy.invalidNameLine(0))
        XCTAssertEqual(BatchModel.Copy.invalidNameLine(1), "1 photo would get a name Shrike can't use and will be skipped.")
        XCTAssertEqual(BatchModel.Copy.invalidNameLine(3), "3 photos would get a name Shrike can't use and will be skipped.")
        XCTAssertEqual(BatchModel.Copy.runButton(0), "Run")
        XCTAssertEqual(BatchModel.Copy.runButton(1), "Run 1 Photo")
        XCTAssertEqual(BatchModel.Copy.runButton(2), "Run 2 Photos")
    }
}

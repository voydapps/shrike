//
//  BatchPass2cTests.swift
//  ShrikeUITests
//
//  Pass 2c tasks 2-3: where the template messages go, and the accessibility
//  label of skipped Batch rows.
//

import XCTest
import SwiftUI
import AppKit
import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeUI

final class BatchPass2cTemplateFeedbackTests: XCTestCase {

    private let nameText = "Names can't end with a period."

    func testAllSkippedForNameShowsUnderFieldNotInFooter() {
        let f = BatchModel.TemplateFeedback.decide(templateError: nil, queueIsEmpty: false,
                                                   nameTemplateLine: nameText, validationMessage: nil)
        XCTAssertEqual(f.underField, nameText)
        XCTAssertNil(f.footer)
        XCTAssertTrue(f.fieldOutlineRed)
        XCTAssertFalse(f.footerIsError)
    }

    func testSomeSkippedHasNoLineUnderTheField() {
        let f = BatchModel.TemplateFeedback.decide(templateError: nil, queueIsEmpty: false,
                                                   nameTemplateLine: nil, validationMessage: nil)
        XCTAssertNil(f.underField)
        XCTAssertNil(f.footer)
        XCTAssertFalse(f.fieldOutlineRed)
    }

    func testTemplateErrorStaysInTheFooterWithOutline() {
        let f = BatchModel.TemplateFeedback.decide(templateError: "Missing “}” in the name.", queueIsEmpty: false,
                                                   nameTemplateLine: nameText, validationMessage: "x")
        XCTAssertNil(f.underField)
        XCTAssertEqual(f.footer, "Missing “}” in the name.")
        XCTAssertTrue(f.footerIsError)
        XCTAssertTrue(f.fieldOutlineRed)
    }

    func testEmptyQueueAndEngineLineStayInTheFooter() {
        XCTAssertEqual(BatchModel.TemplateFeedback.decide(templateError: nil, queueIsEmpty: true,
                                                          nameTemplateLine: nil, validationMessage: "x").footer,
                       BatchModel.Copy.emptyQueue)
        let f = BatchModel.TemplateFeedback.decide(templateError: nil, queueIsEmpty: false,
                                                   nameTemplateLine: nil, validationMessage: "Choose at least one operation.")
        XCTAssertEqual(f.footer, "Choose at least one operation.")
        XCTAssertFalse(f.footerIsError)
    }

    func testHeadingAndLinesWhenEverythingIsSkippedForNames() {
        let skip = BatchModel.Copy.invalidNameLine(3)!
        let lines = BatchModel.whatWillHappen(summary: "Rename 0 files.", queued: 3, processable: 0,
                                              reviewing: false, skipLines: [skip])
        XCTAssertEqual(lines, ["3 photos would get a name Shrike can't use and will be skipped."])
        XCTAssertTrue(BatchModel.showsWhatWillHappenHeading(lines: lines, disclosures: []))
        XCTAssertFalse(BatchModel.showsWhatWillHappenHeading(lines: [], disclosures: []))
    }
}

@MainActor
final class BatchSkippedRowAccessibilityTests: XCTestCase {

    private func row(_ name: String, _ skip: BatchSkipReason?) -> BatchPreviewRow {
        BatchPreviewRow(source: ImageGroup(primary: URL(fileURLWithPath: "/tmp/\(name)")), outputName: name,
                        destination: URL(fileURLWithPath: "/tmp/out/\(name)"), outputSize: nil,
                        nameClash: false, skip: skip)
    }

    func testPureLabels() {
        XCTAssertEqual(BatchPreviewRowView.accessibilityText(for: row("broken.jpg", .unreadable)),
                       "broken.jpg. Skipped. Shrike can't read this file.")
        XCTAssertEqual(BatchPreviewRowView.accessibilityText(for: row("IMG_1.jpg", .emptyName)),
                       "IMG_1.jpg. The new name would be empty — skipped.")
        XCTAssertNil(BatchPreviewRowView.accessibilityText(for: row("ok.jpg", nil)))
    }
}

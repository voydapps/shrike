//
//  EditExitAlertTests.swift
//  ShrikeUITests
//
//  The edit-mode exit alert. Exactly one Save / Save Copy…
//  button, Cancel second, Don't Save third.
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class EditExitAlertTests: XCTestCase {

    func testWritableFileOffersSave() {
        let c = EditExitModal.content(fileName: "DSC_0042.jpg", writable: true)
        XCTAssertEqual(c.message, "Save changes to “DSC_0042.jpg”?")
        XCTAssertEqual(c.information,
                       "Shrike keeps a copy of the original. You can go back with File › Revert to Original.")
        XCTAssertEqual(c.buttons, ["Save", "Cancel", "Don't Save"])
        XCTAssertEqual(c.primary, .save)
    }

    func testRAWOffersOneSaveAs() {
        let c = EditExitModal.content(fileName: "DSC_0042.ORF", writable: false)
        XCTAssertEqual(c.message, "Save changes to “DSC_0042.ORF” as a new file?")
        XCTAssertEqual(c.information, "Shrike can't change this file. It saves a copy next to it.")
        XCTAssertEqual(c.buttons, ["Save Copy…", "Cancel", "Don't Save"])
        XCTAssertEqual(c.buttons.filter { $0.hasPrefix("Save") }.count, 1)
        XCTAssertEqual(c.primary, .saveAs)
    }

    func testResponsesMapToChoices() {
        let w = EditExitModal.content(fileName: "a.jpg", writable: true)
        let r = EditExitModal.content(fileName: "a.ORF", writable: false)
        XCTAssertEqual(EditExitModal.choice(for: .alertFirstButtonReturn, content: w), .save)
        XCTAssertEqual(EditExitModal.choice(for: .alertFirstButtonReturn, content: r), .saveAs)
        XCTAssertEqual(EditExitModal.choice(for: .alertSecondButtonReturn, content: w), .cancel)
        XCTAssertEqual(EditExitModal.choice(for: .alertThirdButtonReturn, content: r), .discard)
    }
}

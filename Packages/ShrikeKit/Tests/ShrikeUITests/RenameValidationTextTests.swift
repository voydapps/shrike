//
//  RenameValidationTextTests.swift
//  ShrikeUITests
//
//  B-9, spec 28 §17.3: the Rename sheet's texts word for word, and the
//  order of the checks. Window-free.
//

import XCTest
import ShrikeIO

final class RenameValidationTextTests: XCTestCase {

    func testTextsEqualSpec173() {
        XCTAssertEqual(RenameValidation.controlCharacters.message,
                       "Names can't contain line breaks or other hidden characters.")
        XCTAssertEqual(RenameValidation.invalidCharacters.message, "Names can't contain “/” or “:”.")
        XCTAssertEqual(RenameValidation.hidden.message, "Names starting with “.” are hidden. Choose another name.")
        XCTAssertEqual(RenameValidation.edgeSpace.message, "Names can't start or end with a space.")
        XCTAssertEqual(RenameValidation.trailingDot.message, "Names can't end with a period.")
    }

    func testEachCaseIsFound() {
        XCTAssertEqual(FileOps.nameProblem("a\nb"), .controlCharacters)
        XCTAssertEqual(FileOps.nameProblem("a\u{7}b"), .controlCharacters)
        XCTAssertEqual(FileOps.nameProblem("a/b"), .invalidCharacters)
        XCTAssertEqual(FileOps.nameProblem("a:b"), .invalidCharacters)
        XCTAssertEqual(FileOps.nameProblem(".a"), .hidden)
        XCTAssertEqual(FileOps.nameProblem(" a"), .edgeSpace)
        XCTAssertEqual(FileOps.nameProblem("a "), .edgeSpace)
        XCTAssertEqual(FileOps.nameProblem("a."), .trailingDot)
        XCTAssertNil(FileOps.nameProblem("IMG_0042"))
    }

    /// §17.3 order after `.empty`: control, “/” “:”, leading “.”, edge space, trailing period.
    func testOrder() {
        XCTAssertEqual(FileOps.nameProblem("a/\n"), .controlCharacters)
        XCTAssertEqual(FileOps.nameProblem(".a/"), .invalidCharacters)
        XCTAssertEqual(FileOps.nameProblem(".a "), .hidden)
        XCTAssertEqual(FileOps.nameProblem(" a."), .edgeSpace)
    }
}

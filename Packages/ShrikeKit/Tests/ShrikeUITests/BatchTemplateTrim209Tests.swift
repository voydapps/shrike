//
//  BatchTemplateTrim209Tests.swift
//  ShrikeUITests
//
//  Spec 28 §20.9: the template's outer spaces and line breaks are trimmed before parsing;
//  the field keeps what was typed. Window-free.
//

import XCTest
@testable import ShrikeUI

final class BatchTemplateTrim209Tests: XCTestCase {
    func testOuterSpacesAndLineBreaksAreTrimmed() {
        XCTAssertEqual(BatchModel.templateForRun("{name} "), "{name}")
        XCTAssertEqual(BatchModel.templateForRun("  {name}_{counter}\n"), "{name}_{counter}")
        XCTAssertEqual(BatchModel.templateForRun("{name} x"), "{name} x", "inner spaces stay")
    }
}

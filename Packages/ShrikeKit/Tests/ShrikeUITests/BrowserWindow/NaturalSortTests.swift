//
//  NaturalSortTests.swift
//  ShrikeUITests
//
//  `BrowserNaturalSort.compare` — matches Finder's numeric + case + diacritic
//  behaviour. This is what the folder tree and the thumbnail grid use when
//  sort is by name.
//

import XCTest
@testable import ShrikeUI

final class NaturalSortTests: XCTestCase {

    func testNumeric_Image2BeforeImage10() {
        XCTAssertEqual(
            BrowserNaturalSort.compare("image2.jpg", "image10.jpg"),
            .orderedAscending
        )
    }

    func testNumeric_Image100BeforeImage1000() {
        XCTAssertEqual(
            BrowserNaturalSort.compare("IMG_100.jpg", "IMG_1000.jpg"),
            .orderedAscending
        )
    }

    func testCaseInsensitive() {
        XCTAssertEqual(
            BrowserNaturalSort.compare("APPLE.JPG", "apple.jpg"),
            .orderedSame
        )
        XCTAssertEqual(
            BrowserNaturalSort.compare("banana.jpg", "APPLE.JPG"),
            .orderedDescending
        )
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(
            BrowserNaturalSort.compare("café.jpg", "cafe.jpg"),
            .orderedSame
        )
    }

    func testMixedAlphaNumeric() {
        let input = ["img10.jpg", "img2.jpg", "img1.jpg", "img20.jpg"]
        let sorted = input.sorted {
            BrowserNaturalSort.compare($0, $1) == .orderedAscending
        }
        XCTAssertEqual(sorted, ["img1.jpg", "img2.jpg", "img10.jpg", "img20.jpg"])
    }

    func testEmptyVsNonEmpty() {
        XCTAssertEqual(BrowserNaturalSort.compare("", "a"), .orderedAscending)
        XCTAssertEqual(BrowserNaturalSort.compare("a", ""), .orderedDescending)
        XCTAssertEqual(BrowserNaturalSort.compare("", ""), .orderedSame)
    }
}

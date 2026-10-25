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

    /// The sidebar sorts big folders through `sorted`; its order must be the
    /// order `compare` gives. Names come from a fixed seed: letters in both
    /// cases, digit runs without leading zeros, and punctuation.
    func testSortedMatchesCompareOnGeneratedNames() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next(_ n: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(n))
        }
        let pieces = ["a", "B", "c", "Z", "_", "-", " ", ".", "IMG", "image", "x", "1", "2", "10", "100", "7", "42", "0", "007", "01", "2026", "e\u{301}"]
        let names = (0..<4000).map { _ in (0..<(1 + next(5))).map { _ in pieces[next(pieces.count)] }.joined() }
        let expected = names.sorted { BrowserNaturalSort.compare($0, $1) == .orderedAscending }
        let actual = BrowserNaturalSort.sorted(names) { $0 }
        // Names that compare equal may come out in either order; compare the
        // keys position by position.
        for (e, a) in zip(expected, actual) {
            XCTAssertEqual(BrowserNaturalSort.compare(e, a), .orderedSame, "\(e) vs \(a)")
        }
    }

    func testSortedUsesNumbersForDigitRuns() {
        XCTAssertEqual(BrowserNaturalSort.sorted(["img10", "img2", "Img1"]) { $0 }, ["Img1", "img2", "img10"])
    }

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

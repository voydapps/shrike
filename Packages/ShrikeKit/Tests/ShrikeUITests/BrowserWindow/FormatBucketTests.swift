//
//  FormatBucketTests.swift
//  ShrikeUITests
//
//  Sanity-tests the UT → bucket mapping used in the format-filter popover
//  and cell format badges.
//

import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import ShrikeUI

final class FormatBucketTests: XCTestCase {

    func testJPEG() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .jpeg), .jpeg)
    }

    func testPNG() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .png), .png)
    }

    func testHEIC() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .heic), .heic)
    }

    func testTIFF() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .tiff), .tiff)
    }

    func testGIF() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .gif), .gif)
    }

    func testWebP() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .webP), .webp)
    }

    func testPDF() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .pdf), .pdf)
    }

    func testRawImage() {
        XCTAssertEqual(BrowserFormatBucket.bucket(for: .rawImage), .raw)
    }

    func testUnknownType_FallsBackToOther() {
        let fake = UTType("public.plain-text")!
        XCTAssertEqual(BrowserFormatBucket.bucket(for: fake), .other)
    }

    func testDisplayNames_AreStable() {
        XCTAssertEqual(BrowserFormatBucket.jpeg.displayName, "JPEG")
        XCTAssertEqual(BrowserFormatBucket.raw.displayName, "RAW")
        XCTAssertEqual(BrowserFormatBucket.other.displayName, "Other")
    }
}

//
//  InspectorDiffTests.swift
//  ShrikeUITests
//
//  `InspectorState.reduce` — collapses a multi-selection into the inspector's
//  view model. Tests the "nil when diverging" rule across the mutable fields.
//

import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import ShrikeUI

final class InspectorDiffTests: XCTestCase {

    private func makeItem(
        name: String,
        rating: Int = 0,
        flag: Bool = false,
        tags: [String] = [],
        size: Int64 = 1000,
        utType: UTType = .jpeg,
        width: Int? = 100,
        height: Int? = 100,
        modDate: Date = Date(timeIntervalSince1970: 1000)
    ) -> BrowserItem {
        BrowserItem(
            url: URL(fileURLWithPath: "/tmp/\(name)"),
            displayName: name,
            fileSize: size,
            modificationDate: modDate,
            creationDate: nil,
            captureDate: nil,
            utType: utType,
            pixelWidth: width,
            pixelHeight: height,
            rating: rating,
            isFlagged: flag,
            tags: tags
        )
    }

    func testEmptySelection_ReturnsEmpty() {
        let state = InspectorState.reduce([])
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.commonName)
        XCTAssertNil(state.commonRating)
        XCTAssertTrue(state.tagsUnion.isEmpty)
    }

    func testSingleSelection_PopulatesAllFields() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", rating: 4, flag: true, tags: ["x", "y"]),
        ])
        XCTAssertEqual(state.count, 1)
        XCTAssertEqual(state.commonName, "a.jpg")
        XCTAssertEqual(state.commonRating, 4)
        XCTAssertEqual(state.commonFlag, true)
        XCTAssertEqual(Set(state.tagsUnion), Set(["x", "y"]))
        XCTAssertEqual(Set(state.tagsCommon), Set(["x", "y"]))
    }

    func testDivergentRating_ShowsNil() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", rating: 4),
            makeItem(name: "b.jpg", rating: 5),
        ])
        XCTAssertEqual(state.count, 2)
        XCTAssertNil(state.commonRating)
    }

    func testCommonRating_ShowsValue() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", rating: 4),
            makeItem(name: "b.jpg", rating: 4),
        ])
        XCTAssertEqual(state.commonRating, 4)
    }

    func testDivergentFlag_ShowsNil() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", flag: true),
            makeItem(name: "b.jpg", flag: false),
        ])
        XCTAssertNil(state.commonFlag)
    }

    func testTags_UnionAndIntersection() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", tags: ["x", "y"]),
            makeItem(name: "b.jpg", tags: ["y", "z"]),
        ])
        XCTAssertEqual(Set(state.tagsUnion), Set(["x", "y", "z"]))
        XCTAssertEqual(Set(state.tagsCommon), Set(["y"]))
    }

    func testMultiSelection_HidesFilename() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg"),
            makeItem(name: "b.jpg"),
        ])
        // >1 items with divergent names → no common name.
        XCTAssertNil(state.commonName)
    }

    func testDivergentDimensions_ShowsNil() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", width: 100, height: 100),
            makeItem(name: "b.jpg", width: 200, height: 200),
        ])
        XCTAssertNil(state.commonWidth)
        XCTAssertNil(state.commonHeight)
    }

    func testCommonDimensions_ShowsValue() {
        let state = InspectorState.reduce([
            makeItem(name: "a.jpg", width: 100, height: 100),
            makeItem(name: "b.jpg", width: 100, height: 100),
        ])
        XCTAssertEqual(state.commonWidth, 100)
        XCTAssertEqual(state.commonHeight, 100)
    }

    /// 2+ selected show the sizes added up, the same number
    /// and form as the status bar ("3 selected · 48.2 MB").
    func testMultiSelection_TotalSizeMatchesTheStatusBar() {
        let items = [
            makeItem(name: "a.jpg", size: 7_000_000),
            makeItem(name: "b.jpg", size: 8_200_000),
            makeItem(name: "c.jpg", size: 7_000_000),
        ]
        let state = InspectorState.reduce(items)
        XCTAssertNil(state.commonFileSize, "sizes differ")
        XCTAssertEqual(state.totalFileSize, 22_200_000)
        let status = BrowserBottomBar.statusText(items)
        XCTAssertEqual(status, "3 selected · \(BrowserBottomBar.bytes(22_200_000))")
        XCTAssertTrue(status.hasSuffix(BrowserBottomBar.bytes(try XCTUnwrap(state.totalFileSize))))
        // One item keeps its own size row; nothing selected has neither.
        XCTAssertNil(InspectorState.reduce([items[0]]).totalFileSize)
        XCTAssertEqual(InspectorState.reduce([items[0]]).commonFileSize, 7_000_000)
        XCTAssertNil(InspectorState.reduce([]).totalFileSize)
    }

    func testPreviewURL_UsesFirstItem() {
        let state = InspectorState.reduce([
            makeItem(name: "first.jpg"),
            makeItem(name: "second.jpg"),
        ])
        XCTAssertEqual(state.previewURL?.lastPathComponent, "first.jpg")
    }
}

//
//  FilterPipelineTests.swift
//  ShrikeUITests
//
//  Exercises `BrowserPipeline.filterAndSort` and `BrowserFilter.matches`.
//  Pure: builds synthetic `BrowserItem`s in-memory.
//

import XCTest
import Foundation
import UniformTypeIdentifiers
@testable import ShrikeUI

final class FilterPipelineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeItem(
        name: String,
        utType: UTType = .jpeg,
        size: Int64 = 1_000_000,
        modDate: Date = Date(timeIntervalSince1970: 1_000_000),
        rating: Int = 0,
        flag: Bool = false,
        tags: [String] = [],
        width: Int? = 1000,
        height: Int? = 1000
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

    private lazy var fixtures: [BrowserItem] = [
        makeItem(name: "iceland_001.jpg", rating: 5, flag: true,
                 tags: ["iceland", "aurora"]),
        makeItem(name: "iceland_002.jpg", rating: 4, tags: ["iceland"]),
        makeItem(name: "beach_001.png", utType: .png, rating: 3),
        makeItem(name: "beach_002.jpg", rating: 0, tags: ["beach"]),
        makeItem(name: "raw_001.dng", utType: .rawImage, rating: 5),
        makeItem(name: "screen_recording.gif", utType: .gif, rating: 1),
    ]

    // MARK: - Empty filter

    func testEmptyFilter_PassesEverything() {
        let filter = BrowserFilter.none
        XCTAssertTrue(filter.isEmpty)
        let out = BrowserPipeline.filterAndSort(fixtures, filter: filter, sort: .defaultValue)
        XCTAssertEqual(out.count, fixtures.count)
    }

    // MARK: - Single-clause filters

    func testMinimumRating() {
        var f = BrowserFilter.none
        f.minimumRating = 4
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(Set(out.map(\.displayName)), Set([
            "iceland_001.jpg", "iceland_002.jpg", "raw_001.dng",
        ]))
    }

    func testFlaggedOnly() {
        var f = BrowserFilter.none
        f.flaggedOnly = true
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.displayName, "iceland_001.jpg")
    }

    func testFormatFilter_JPEGOnly() {
        var f = BrowserFilter.none
        f.formats = [.jpeg]
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(out.count, 3)
        XCTAssertTrue(out.allSatisfy {
            BrowserFormatBucket.bucket(for: $0.utType) == .jpeg
        })
    }

    func testFormatFilter_RawAndPng() {
        var f = BrowserFilter.none
        f.formats = [.raw, .png]
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(Set(out.map(\.displayName)), Set([
            "beach_001.png", "raw_001.dng",
        ]))
    }

    // MARK: - AND semantics

    func testCompoundFilter_AndsClauses() {
        var f = BrowserFilter.none
        f.minimumRating = 4
        f.flaggedOnly = true
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.displayName, "iceland_001.jpg")
    }

    // MARK: - Search

    func testSearch_MatchesDisplayName() {
        var f = BrowserFilter.none
        f.searchTerm = "iceland"
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(Set(out.map(\.displayName)), Set([
            "iceland_001.jpg", "iceland_002.jpg",
        ]))
    }

    func testSearch_CaseInsensitive() {
        var f = BrowserFilter.none
        f.searchTerm = "ICELAND"
        XCTAssertEqual(fixtures.filter(f.matches).count, 2)
    }

    func testSearch_DiacriticInsensitive() {
        var f = BrowserFilter.none
        f.searchTerm = "cafe"
        let cafe = makeItem(name: "Café.jpg")
        XCTAssertTrue(f.matches(cafe))
    }

    func testSearch_MatchesFileNameOnly() {
        // Search is a file-name match; tags are not searched.
        var f = BrowserFilter.none
        f.searchTerm = "aurora"
        XCTAssertTrue(fixtures.filter(f.matches).isEmpty)
    }

    // MARK: - Tag set

    func testTagMatch_RequiresIntersection() {
        var f = BrowserFilter.none
        f.tags = ["iceland"]
        let out = fixtures.filter(f.matches)
        XCTAssertEqual(Set(out.map(\.displayName)), Set([
            "iceland_001.jpg", "iceland_002.jpg",
        ]))
    }

    // MARK: - Date range

    func testDateRange_BoundedBelow() {
        var f = BrowserFilter.none
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        f.modifiedFrom = cutoff
        let older = makeItem(name: "old.jpg", modDate: Date(timeIntervalSince1970: 1))
        let newer = makeItem(name: "new.jpg", modDate: Date(timeIntervalSince1970: 3_000_000))
        XCTAssertFalse(f.matches(older))
        XCTAssertTrue(f.matches(newer))
    }

    func testDateRange_BoundedAbove() {
        var f = BrowserFilter.none
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        f.modifiedTo = cutoff
        let older = makeItem(name: "old.jpg", modDate: Date(timeIntervalSince1970: 1))
        let newer = makeItem(name: "new.jpg", modDate: Date(timeIntervalSince1970: 3_000_000))
        XCTAssertTrue(f.matches(older))
        XCTAssertFalse(f.matches(newer))
    }

    // MARK: - Sort

    func testSort_ByNameAscendingNatural() {
        let items = [
            makeItem(name: "img10.jpg"),
            makeItem(name: "img2.jpg"),
            makeItem(name: "img1.jpg"),
        ]
        let sort = BrowserSort(key: .name, direction: .ascending)
        let out = BrowserPipeline.apply(sort: sort, to: items)
        XCTAssertEqual(out.map(\.displayName), ["img1.jpg", "img2.jpg", "img10.jpg"])
    }

    func testSort_ByRatingDescending_TiesBreakByName() {
        let items = [
            makeItem(name: "b.jpg", rating: 3),
            makeItem(name: "a.jpg", rating: 3),
            makeItem(name: "c.jpg", rating: 5),
        ]
        let sort = BrowserSort(key: .rating, direction: .descending)
        let out = BrowserPipeline.apply(sort: sort, to: items)
        XCTAssertEqual(out.map(\.displayName), ["c.jpg", "a.jpg", "b.jpg"])
    }

    func testSort_BySizeAscending() {
        let items = [
            makeItem(name: "big.jpg", size: 1_000_000),
            makeItem(name: "tiny.jpg", size: 100),
            makeItem(name: "mid.jpg", size: 5_000),
        ]
        let sort = BrowserSort(key: .size, direction: .ascending)
        let out = BrowserPipeline.apply(sort: sort, to: items)
        XCTAssertEqual(out.map(\.displayName), ["tiny.jpg", "mid.jpg", "big.jpg"])
    }

    // MARK: - Pipeline integration (filter + sort)

    func testFilterAndSort_Composes() {
        var f = BrowserFilter.none
        f.minimumRating = 4
        let sort = BrowserSort(key: .name, direction: .ascending)
        let out = BrowserPipeline.filterAndSort(fixtures, filter: f, sort: sort)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.map(\.displayName),
                       ["iceland_001.jpg", "iceland_002.jpg", "raw_001.dng"])
    }
}

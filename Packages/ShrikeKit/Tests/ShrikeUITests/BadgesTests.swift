//
//  BadgesTests.swift
//  ShrikeUITests
//
//  Indicators: only set values are drawn, tag dots (max 3,
//  one grey dot for name-only tags), pill VoiceOver text, grid cell slots,
//  list sort by Flag. Headless; no files are touched.
//

import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ShrikeUI
import ShrikeCore
import ShrikeIO

@MainActor
final class BadgesTests: XCTestCase {

    func testDotColoursDistinctThenOneGreyMaxThree() {
        let tags = [FinderTag(name: "Red", color: .red), FinderTag(name: "Client"),
                    FinderTag(name: "Red 2", color: .red), FinderTag(name: "Venice")]
        XCTAssertEqual(Badges.dotColors(tags), [.red, .none])
        let many = [FinderTag(name: "a", color: .red), FinderTag(name: "b", color: .blue),
                    FinderTag(name: "c", color: .green), FinderTag(name: "d", color: .purple)]
        XCTAssertEqual(Badges.dotColors(many), [.red, .blue, .green])
        XCTAssertEqual(Badges.dotColors([]), [])
        XCTAssertNil(Badges.tagDotsImage([]))
        XCTAssertEqual(Badges.tagDotsImage([.red, .blue, .green])?.size.width, 25)  // 3×7 + 2×2
    }

    func testStarsDrawOnlySetValues() {
        XCTAssertEqual(Badges.stars(0), "")
        XCTAssertEqual(Badges.stars(3), "★★★")
        XCTAssertEqual(Badges.stars(9), "★★★★★")
        XCTAssertEqual(ThumbnailItem.makeRatingString(rating: 2, flagged: false), "★★")
        XCTAssertFalse(ThumbnailItem.makeRatingString(rating: 0, flagged: false).contains("☆"))
    }

    func testPillVoiceOverSuffixListsEveryMark() {
        let marks = PillMarks(rating: 3, flagged: true, hasRAW: true,
                              tags: [FinderTag(name: "Red", color: .red), FinderTag(name: "Client")],
                              edited: true)
        XCTAssertEqual(marks.accessibilitySuffix,
                       ", 3 stars, flagged, tags: Red, Client, with RAW file, edited, original kept")
        XCTAssertTrue(PillMarks().isEmpty)
        XCTAssertEqual(PillMarks.marksText(PillMarks()).length, 0)
        XCTAssertGreaterThan(PillMarks.marksText(marks).length, 0)
    }

    func testGridCellShowsBadgesInTheirSlots() {
        let cell = ThumbnailItem()
        cell.loadView()
        cell.applyBadges(ItemBadges())
        var state = cell.badgeStateForTesting
        XCTAssertFalse(state.flag || state.raw || state.live || state.pencil || state.dots)
        XCTAssertEqual(state.stars, "")

        cell.applyBadges(ItemBadges(rating: 4, flagged: true, tags: [FinderTag(name: "Red", color: .red)],
                                    hasRAW: true, isLivePhoto: true, edited: true))
        state = cell.badgeStateForTesting
        XCTAssertTrue(state.flag && state.raw && state.live && state.pencil && state.dots)
        XCTAssertEqual(state.stars, "★★★★")
    }

    func testBrowserItemBadgesComeFromGroup() {
        let dir = URL(fileURLWithPath: "/tmp/none")
        var item = BrowserItem(url: dir.appendingPathComponent("P1.JPG"), displayName: "P1.JPG",
                               fileSize: 1, modificationDate: Date(), utType: .jpeg, rating: 2, isFlagged: true)
        item.group = ImageGroup(primary: item.url,
                                companions: [.init(url: dir.appendingPathComponent("P1.ORF"), kind: .raw)])
        let badges = item.badges
        XCTAssertEqual(badges.rating, 2)
        XCTAssertTrue(badges.flagged)
        XCTAssertTrue(badges.hasRAW)
        XCTAssertFalse(badges.isLivePhoto)
    }
}

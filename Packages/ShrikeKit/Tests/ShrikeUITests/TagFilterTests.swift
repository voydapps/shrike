//
//  TagFilterTests.swift
//  ShrikeUITests
//
//  Spec 21b §3: the Tags row in the Filter popover.
//

import XCTest
import AppKit
import ShrikeIO
import UniformTypeIdentifiers
@testable import ShrikeUI

@MainActor
final class TagFilterTests: XCTestCase {

    private let tags = [
        FinderTag(name: "zebra"), FinderTag(name: "Client"),
        FinderTag(name: "Red", color: .red), FinderTag(name: "Green", color: .green),
        FinderTag(name: "Orange", color: .orange), FinderTag(name: "keeper"),
        FinderTag(name: "red")   // same name, other case: one entry
    ]

    private func titles(_ popover: BrowserFilterPopover) -> [String] {
        popover.tagPopup.menu!.items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    func testOrderIsColourTagsInFinderOrderThenOthersAtoZ() {
        let popover = BrowserFilterPopover(filter: .none)
        _ = popover.view
        popover.setTagSource(tags, reading: false)
        XCTAssertEqual(titles(popover), ["Any Tag", "Any Tag", "Red", "Orange", "Green", "Client", "keeper", "zebra"],
                       "item 0 is the closed control's title; then Any Tag; colours; others")
        XCTAssertTrue(popover.tagPopup.isEnabled)
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "Any Tag")
    }

    func testPicksToggleAndTheTitleFollows() {
        let popover = BrowserFilterPopover(filter: .none)
        _ = popover.view
        popover.setTagSource(tags, reading: false)
        var applied: [BrowserFilter] = []
        popover.onChange = { applied.append($0) }
        let items = popover.tagPopup.menu!.items
        popover.tagPicked(items.first { $0.title == "Red" })
        XCTAssertEqual(applied.last?.tags, ["Red"])
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "Red", "one tag: its name")
        popover.tagPicked(popover.tagPopup.menu!.items.first { $0.title == "keeper" })
        XCTAssertEqual(applied.last?.tags, ["Red", "keeper"])
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "2 Tags")
        XCTAssertEqual(popover.tagPopup.menu!.items.filter { $0.state == .on }.map(\.title).sorted(), ["Red", "keeper"])
        popover.tagPicked(popover.tagPopup.menu!.items.first { $0.title == "Red" })
        XCTAssertEqual(applied.last?.tags, ["keeper"], "a second pick on the same tag unticks it")
        popover.tagPicked(popover.tagPopup.menu!.items[1])   // Any Tag
        XCTAssertEqual(applied.last?.tags, [])
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "Any Tag")
    }

    func testReadingAndNoTagsStates() {
        let popover = BrowserFilterPopover(filter: .none)
        _ = popover.view
        popover.setTagSource([], reading: true)
        XCTAssertFalse(popover.tagPopup.isEnabled)
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "Reading Tags…")
        popover.setTagSource([], reading: false)
        XCTAssertFalse(popover.tagPopup.isEnabled)
        XCTAssertEqual(popover.tagPopup.menu!.items.first?.title, "No Tags in This Folder")
        popover.setTagSource(tags, reading: false)
        XCTAssertTrue(popover.tagPopup.isEnabled)
    }

    func testAnyOfTheChosenTagsPassesAndSectionsStayAnd() {
        func item(_ name: String, tags: [String], rating: Int = 0) -> BrowserItem {
            var i = BrowserItem(url: URL(fileURLWithPath: "/x/\(name)"), displayName: name, fileSize: 1,
                                modificationDate: Date(), creationDate: nil, captureDate: nil, utType: .jpeg,
                                pixelWidth: nil, pixelHeight: nil, rating: rating)
            i.tags = tags
            return i
        }
        var f = BrowserFilter.none
        f.tags = ["Red", "keeper"]
        XCTAssertTrue(f.matches(item("a.jpg", tags: ["Red"])))
        XCTAssertTrue(f.matches(item("b.jpg", tags: ["keeper", "x"])))
        XCTAssertFalse(f.matches(item("c.jpg", tags: ["Blue"])))
        XCTAssertFalse(f.matches(item("d.jpg", tags: [])))
        f.minimumRating = 3
        XCTAssertFalse(f.matches(item("e.jpg", tags: ["Red"], rating: 1)), "Rating AND Tags")
        XCTAssertTrue(f.matches(item("f.jpg", tags: ["Red"], rating: 4)))
    }

    func testChipAndClear() {
        var f = BrowserFilter.none
        f.tags = ["keeper", "Red"]
        f.searchTerm = "abc"
        let chip = f.conditions.first { $0.key == .tags }
        XCTAssertEqual(chip?.title, "Tags: keeper, Red")
        XCTAssertEqual(BrowserFilterCondition.Key.tags.accessibilityName, "tags")
        XCTAssertTrue(f.removing(.tags).tags.isEmpty)
        XCTAssertEqual(f.removing(.tags).searchTerm, "abc", "the chip clears only tags")
        let popover = BrowserFilterPopover(filter: f)
        _ = popover.view
        var applied: [BrowserFilter] = []
        popover.onChange = { applied.append($0) }
        popover.clearTapped(nil)
        XCTAssertTrue(applied.last?.tags.isEmpty ?? false)
        XCTAssertEqual(applied.last?.searchTerm, "abc", "Clear Filters keeps the search term")
    }

    func testFilterRowSitsAfterKind() {
        let popover = BrowserFilterPopover(filter: .none)
        popover.view.layoutSubtreeIfNeeded()
        let stack = popover.view.subviews.first as? NSStackView
        let rows = stack?.arrangedSubviews ?? []
        let tagRow = rows.firstIndex { ($0 as? NSStackView)?.arrangedSubviews.contains(popover.tagPopup) == true }
        XCTAssertEqual(tagRow, 3, "Rating, Flag, Kind, Tags, Clear")
        XCTAssertEqual(popover.tagPopup.frame.width, popover.ratingPopup.frame.width, accuracy: 0.5)
    }

    /// The popover opened from the toolbar gets the folder's tags (it was built before
    /// the window stored it, so the tag row stayed on "No Tags in This Folder").
    func testOpeningThePopoverFromTheWindowListsTheFoldersTags() async throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-tagpop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let file = dir.appendingPathComponent("a.jpg")
        let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try (file as NSURL).setResourceValue(["keeper"], forKey: .tagNamesKey)

        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        let deadline = Date().addingTimeInterval(5)
        while !hydrated, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(hydrated)
        browser.showFilterPopover(nil)
        let popover = try XCTUnwrap(browser.filterPopoverForTesting)
        XCTAssertEqual(popover.tagOptions.map(\.name), ["keeper"])
        XCTAssertTrue(popover.tagPopup.isEnabled)
    }
}

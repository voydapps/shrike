//
//  BrowserFilterPopoverTests.swift
//  ShrikeUITests
//
//  The filter popover (rating choices, Flagged only, Kind
//  boxes, Clear), pairs matching every kind they hold, the empty result
//  with "Clear Filter", and search (file name, 150 ms debounce, clear).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserFilterPopoverTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        dir = TestScratch.directory
            .appendingPathComponent("shrike-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ name: String, type: UTType = .jpeg, rating: Int = 0, rawPair: Bool = false, flagged: Bool = false) -> BrowserItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        var item = BrowserItem(url: url, displayName: name, fileSize: 1, modificationDate: Date(),
                               creationDate: nil, captureDate: nil, utType: type,
                               pixelWidth: nil, pixelHeight: nil, rating: rating)
        item.isFlagged = flagged
        if rawPair {
            item.group = ImageGroup(primary: url, companions: [
                .init(url: url.deletingPathExtension().appendingPathExtension("ORF"), kind: .raw),
            ])
        }
        return item
    }

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    // MARK: Popover

    func testPopoverLayoutAndControls() {
        let popover = BrowserFilterPopover(filter: .none)
        popover.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(popover.view.fittingSize.width, 280)
        let stack = popover.view.subviews.first as? NSStackView
        XCTAssertEqual(stack?.edgeInsets.left, 16)
        XCTAssertEqual(stack?.edgeInsets.top, 16)
        XCTAssertEqual(stack?.spacing, 12)
        XCTAssertEqual(popover.ratingPopup.itemTitles,
                       ["Any", "Unrated", "1 star or more", "2 stars or more", "3 stars or more",
                        "4 stars or more", "5 stars"])
        XCTAssertEqual(popover.flagPopup.itemTitles, ["Any", "Flagged", "Not flagged"])
        XCTAssertEqual(BrowserRatingChoice.menuOrder[1], .unrated)
        XCTAssertEqual(BrowserFilterKind.allCases.compactMap { popover.kindBoxes[$0]?.title },
                       ["JPEG", "HEIC", "PNG", "RAW", "Other"])
        XCTAssertTrue(popover.kindBoxes.values.allSatisfy { $0.state == .on }, "every kind ticked")
        XCTAssertFalse(popover.clearButton.isEnabled, "Clear is off when nothing is set")
    }

    func testChangesApplyAtOnceAndClearResetsEverything() {
        let popover = BrowserFilterPopover(filter: .none)
        _ = popover.view
        var applied: [BrowserFilter] = []
        popover.onChange = { applied.append($0) }

        popover.ratingPopup.selectItem(withTitle: "Unrated")
        popover.ratingChanged(popover.ratingPopup)
        XCTAssertEqual(applied.last?.ratingChoice, .unrated)
        XCTAssertTrue(popover.clearButton.isEnabled)

        popover.flagPopup.selectItem(withTitle: "Flagged")
        popover.flagChanged(popover.flagPopup)
        let png = popover.kindBoxes[.png]!
        png.state = .off
        popover.kindChanged(png)
        XCTAssertEqual(applied.last?.excludedKinds, [.png])
        XCTAssertEqual(applied.last?.flaggedOnly, true)

        popover.clearTapped(nil)
        XCTAssertTrue(applied.last?.isEmpty ?? false)
        XCTAssertFalse(popover.clearButton.isEnabled)
        XCTAssertEqual(png.state, .on)
        XCTAssertEqual(popover.ratingPopup.titleOfSelectedItem, "Any")
        XCTAssertEqual(popover.flagPopup.titleOfSelectedItem, "Any")
    }

    func testFlagChoicesExcludeEachOtherAndNotFlaggedMatches() {
        var f = BrowserFilter.none
        f.flagChoice = .flagged
        XCTAssertTrue(f.flaggedOnly)
        f.flagChoice = .notFlagged
        XCTAssertFalse(f.flaggedOnly)
        XCTAssertTrue(f.unflaggedOnly)
        XCTAssertFalse(f.popoverPartIsEmpty, "Clear enables for Not flagged")
        f.flagChoice = .flagged
        XCTAssertFalse(f.unflaggedOnly)

        let items = (0..<25).map { item("p\($0).jpg", rating: $0 < 5 ? 3 : 0, flagged: [0, 6, 7].contains($0)) }
        var review = BrowserFilter.none
        review.ratingChoice = .unrated
        review.flagChoice = .notFlagged
        // 5 rated (0-4), 3 flagged (0, 6, 7): union = 7 items.
        XCTAssertEqual(items.filter(review.matches).count, 25 - 7)
    }

    // MARK: Matching

    func testRatingChoices() {
        let items = (0...5).map { item("r\($0).jpg", rating: $0) }
        func names(_ choice: BrowserRatingChoice) -> [String] {
            var f = BrowserFilter.none
            f.ratingChoice = choice
            return items.filter(f.matches).map(\.displayName)
        }
        XCTAssertEqual(names(.any).count, 6)
        XCTAssertEqual(names(.atLeast(4)), ["r4.jpg", "r5.jpg"])
        XCTAssertEqual(names(.atLeast(5)), ["r5.jpg"])
        XCTAssertEqual(names(.unrated), ["r0.jpg"])
    }

    func testAPairMatchesEveryKindItHolds() {
        let pair = item("P1.jpg", rawPair: true)
        let lone = item("J1.jpg")
        let heic = item("H1.heic", type: .heic)
        var f = BrowserFilter.none
        f.excludedKinds = [.jpeg]
        XCTAssertTrue(f.matches(pair), "RAW is still ticked")
        XCTAssertFalse(f.matches(lone))
        XCTAssertTrue(f.matches(heic))
        f.excludedKinds = [.jpeg, .raw]
        XCTAssertFalse(f.matches(pair))
        f.excludedKinds = [.raw]
        XCTAssertTrue(f.matches(pair), "JPEG is still ticked")
        XCTAssertEqual(BrowserFilterKind.kinds(of: item("x.gif", type: .gif)), [.other])
        // The older format set follows the same rule.
        var g = BrowserFilter.none
        g.formats = [.raw]
        XCTAssertTrue(g.matches(pair))
    }

    // MARK: Window

    func testEmptyResultOffersClearFilter() async throws {
        try writeJPEG("a.jpg")
        try writeJPEG("b.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let ready = await waitUntil { content.visibleItems.count == 2 && !content.isHydratingMarks }
        XCTAssertTrue(ready, "rating metadata is ready before applying a metadata-dependent filter")
        var f = BrowserFilter.none
        f.ratingChoice = .atLeast(5)
        browser.showFilterPopover(nil)
        browser.filterPopoverForTesting?.filter = f
        browser.filterPopoverForTesting?.ratingChanged(browser.filterPopoverForTesting!.ratingPopup)
        XCTAssertEqual(content.visibleItems.count, 0)
        let empty = try XCTUnwrap(content.emptyStateForTesting)
        XCTAssertEqual(empty.titleText, "No Matching Photos")
        XCTAssertEqual(empty.buttonTitle, "Clear Filters")
        XCTAssertEqual(browser.window?.subtitle, WindowTitles.browserSubtitle(visible: 0, total: 2))

        browser.searchField.stringValue = "a"
        browser.searchField.sendAction(browser.searchField.action, to: browser.searchField.target)
        let searched = await waitUntil { browser.currentFilterForTesting.searchTerm == "a" }
        XCTAssertTrue(searched, "the real debounced search has applied")
        XCTAssertEqual(empty.buttonTitle, "Clear Search and Filters")
        empty.button.performClick(nil)
        XCTAssertTrue(browser.currentFilterForTesting.isEmpty, "filter and search cleared")
        XCTAssertEqual(browser.searchField.stringValue, "")
        XCTAssertEqual(content.visibleItems.count, 2)
        XCTAssertNil(content.emptyStateForTesting)
    }

    func testSearchWaitsOneHundredFiftyMillisecondsAndClearsAtOnce() async throws {
        try writeJPEG("Café.jpg")
        try writeJPEG("beach.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        _ = await waitUntil { content.visibleItems.count == 2 }
        XCTAssertEqual(BrowserWindowController.searchDebounceDelay, .milliseconds(150))
        XCTAssertTrue(browser.searchField.sendsSearchStringImmediately, "our own debounce, not the field's")

        browser.searchField.stringValue = "CAFE"
        browser.searchField.sendAction(browser.searchField.action, to: browser.searchField.target)
        XCTAssertEqual(content.visibleItems.count, 2, "not yet: debounced")
        let applied = await waitUntil(1) { content.visibleItems.count == 1 }
        XCTAssertTrue(applied)
        XCTAssertEqual(content.visibleItems.first?.displayName, "Café.jpg", "case- and diacritic-insensitive")

        // Esc / the clear button empty the field: applied at once.
        browser.searchField.stringValue = ""
        browser.searchField.sendAction(browser.searchField.action, to: browser.searchField.target)
        XCTAssertEqual(content.visibleItems.count, 2)
    }
}

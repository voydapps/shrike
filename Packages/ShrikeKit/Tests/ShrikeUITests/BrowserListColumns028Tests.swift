//
//  BrowserListColumns028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-14: list header text, compact Rating (56 pt) and Flag (36 pt)
//  columns, and the header menu that hides or shows Rating, Flag, Tags and
//  Dimensions (kept in the Shrike preferences store, not NSTableView's autosave).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserListColumns028Tests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0
    private var savedHidden: [String] = []

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        savedHidden = Prefs.browserListHiddenColumns
        Prefs.browserListHiddenColumns = []
        BrowserWindowController.restoresViewModeUnderTests = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-listcols-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<5 {
            try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("P000\(i).jpg"))
        }
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        Prefs.browserListHiddenColumns = savedHidden
        BrowserWindowController.restoresViewModeUnderTests = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func openList() async throws -> BrowserWindowController {
        Prefs.browserViewMode = BrowserViewMode.list.rawValue
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        await browser.listingTask?.value
        XCTAssertEqual(browser.contentController.allItems.count, 5, "the listing finished with all five photos")
        browser.window?.setContentSize(NSSize(width: 1100, height: 600))
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    private func column(_ browser: BrowserWindowController, _ id: String) throws -> NSTableColumn {
        try XCTUnwrap(browser.contentController.tableViewForTesting
            .tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id)))
    }

    func testColumnWidthsAndHeaderFont() async throws {
        let browser = try await openList()
        defer { browser.close() }
        let rating = try column(browser, "col.rating")
        let flag = try column(browser, "col.flag")
        XCTAssertEqual(rating.width, 56, accuracy: 0.5)
        XCTAssertEqual(rating.minWidth, 44)
        XCTAssertEqual(flag.width, 36, accuracy: 0.5)
        for col in browser.contentController.tableViewForTesting.tableColumns where !col.title.isEmpty {
            let attrs = col.headerCell.attributedStringValue.attributes(at: 0, effectiveRange: nil)
            let font = try XCTUnwrap(attrs[.font] as? NSFont, col.title)
            XCTAssertEqual(font.pointSize, 12, col.title)
            XCTAssertGreaterThanOrEqual(NSFontManager.shared.weight(of: font), 8, "semibold or heavier: \(col.title)")
            XCTAssertEqual(attrs[.foregroundColor] as? NSColor, ShrikeTokens.textSecondary, col.title)
        }
    }

    /// 12 pt semibold header text is at least 4.5:1 in both appearances, on the window
    /// background and on the base surface (the system secondary label is ~3.9:1 in light).
    func testHeaderTextContrastInBothAppearances() {
        for appearance in [Contrast.dark, Contrast.light] {
            for background in [NSColor.windowBackgroundColor, ShrikeTokens.surfaceBase] {
                let ratio = Contrast.ratio(ShrikeTokens.textSecondary, on: background, in: appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.6, "\(appearance.name) \(ratio)")
            }
        }
    }

    /// Spec 27 P3-14: rows are 13 pt; the row height still holds a line.
    func testRowsAre13Point() async throws {
        XCTAssertEqual(BrowserContentViewController.listFont.pointSize, 13)
        let browser = try await openList()
        defer { browser.close() }
        let table = browser.contentController.tableViewForTesting
        XCTAssertGreaterThanOrEqual(table.rowHeight, ceil(BrowserContentViewController.listFont.boundingRectForFont.height) + 4)
    }

    func testCompactRatingText() {
        XCTAssertEqual(Badges.compactStars(0), "")
        XCTAssertEqual(Badges.compactStars(3), "★3")
        XCTAssertEqual(Badges.compactStars(9), "★5")
        XCTAssertEqual(Badges.stars(3), "★★★", "the grid keeps the full row")
    }

    func testHeaderMenuHidesAndRestoresColumns() async throws {
        let browser = try await openList()
        let menu = try XCTUnwrap(browser.contentController.headerMenuForTesting)
        XCTAssertEqual(menu.items.map(\.title), ["Rating", "Flag", "Tags", "Dimensions"])
        browser.contentController.refreshHeaderMenuForTesting()
        XCTAssertTrue(menu.items.allSatisfy { $0.state == .on })

        let item = try XCTUnwrap(menu.items.first { $0.title == "Rating" })
        _ = NSApp.sendAction(item.action!, to: item.target, from: item)
        XCTAssertTrue(try column(browser, "col.rating").isHidden)
        XCTAssertEqual(Prefs.browserListHiddenColumns, ["col.rating"])
        browser.contentController.refreshHeaderMenuForTesting()
        XCTAssertEqual(item.state, .off)
        browser.close()

        // A new list starts with Rating hidden.
        let second = try await openList()
        defer { second.close() }
        XCTAssertTrue(try column(second, "col.rating").isHidden)
        XCTAssertFalse(try column(second, "col.flag").isHidden)

        // Showing it again clears the entry.
        let again = try XCTUnwrap(second.contentController.headerMenuForTesting?.items.first { $0.title == "Rating" })
        _ = NSApp.sendAction(again.action!, to: again.target, from: again)
        XCTAssertFalse(try column(second, "col.rating").isHidden)
        XCTAssertEqual(Prefs.browserListHiddenColumns, [])
    }

    func testRatedAndUnratedRowCells() async throws {
        let browser = try await openList()
        defer { browser.close() }
        let table = browser.contentController.tableViewForTesting
        let ratingIndex = table.column(withIdentifier: NSUserInterfaceItemIdentifier("col.rating"))
        let cell = table.view(atColumn: ratingIndex, row: 0, makeIfNecessary: true) as? NSTableCellView
        let text = cell?.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertEqual(text?.stringValue, "", "unrated rows show nothing")
    }
}

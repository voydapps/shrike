//
//  BrowserSelectionFollow028Tests.swift
//  ShrikeUITests
//
//  Spec 27 N7: after a sort or a filter, in the list and in the grid, the
//  selected item is on screen; one that was already visible does not make
//  the view scroll. (No pointer or scroll events: headless.)
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserSelectionFollow028Tests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0
    private var savedSortKey = "name"
    private var savedSortAscending = true

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        savedSortKey = Prefs.browserSortKey
        savedSortAscending = Prefs.browserSortAscending
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        BrowserWindowController.restoresViewModeUnderTests = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-selfollow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<1000 {
            try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent(String(format: "P%04d.jpg", i)))
        }
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        Prefs.browserSortKey = savedSortKey
        Prefs.browserSortAscending = savedSortAscending
        BrowserWindowController.restoresViewModeUnderTests = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func open(_ mode: BrowserViewMode) async throws -> BrowserWindowController {
        Prefs.browserViewMode = mode.rawValue
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let deadline = Date().addingTimeInterval(15)
        while browser.contentController.allItems.count < 1000, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(browser.contentController.allItems.count, 1000)
        browser.window?.setContentSize(NSSize(width: 1100, height: 700))
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    /// The first selected item's index in the shown order, and whether it is on screen.
    private func selectedState(_ c: BrowserContentViewController, mode: BrowserViewMode) -> (index: Int, onScreen: Bool)? {
        switch mode {
        case .list:
            let table = c.tableViewForTesting
            table.layoutSubtreeIfNeeded()
            guard let row = table.selectedRowIndexes.first else { return nil }
            return (row, NSLocationInRange(row, table.rows(in: table.visibleRect)))
        default:
            let grid = c.collectionViewForTesting
            grid.layoutSubtreeIfNeeded()
            guard let ip = grid.selectionIndexPaths.min(),
                  let frame = grid.layoutAttributesForItem(at: ip)?.frame else { return nil }
            return (ip.item, grid.visibleRect.intersects(frame))
        }
    }

    private func scrollOffset(_ c: BrowserContentViewController, mode: BrowserViewMode) -> CGFloat {
        mode == .list ? c.tableViewForTesting.enclosingScrollView!.contentView.bounds.origin.y
                      : c.collectionViewForTesting.enclosingScrollView!.contentView.bounds.origin.y
    }

    private func check(_ mode: BrowserViewMode) async throws {
        let browser = try await open(mode)
        defer { browser.close() }
        let c = browser.contentController

        // Select row 3 at the top, sort descending: it moves to the far end and the view follows.
        XCTAssertTrue(c.select(url: dir.appendingPathComponent("P0003.jpg")))
        let before = try XCTUnwrap(selectedState(c, mode: mode))
        XCTAssertEqual(before.index, 3)
        XCTAssertTrue(before.onScreen)
        c.sort = BrowserSort(key: .name, direction: .descending)
        let after = try XCTUnwrap(selectedState(c, mode: mode))
        XCTAssertEqual(after.index, 996, "\(mode) the item moved with the sort")
        XCTAssertTrue(after.onScreen, "\(mode) the selected item is on screen after the sort")

        // Ties keep the order: an item on screen does not move the view.
        XCTAssertTrue(c.select(url: dir.appendingPathComponent("P0500.jpg")))
        let offset = scrollOffset(c, mode: mode)
        c.sort = BrowserSort(key: .size, direction: .ascending)   // every file is 3 bytes
        let stillOn = try XCTUnwrap(selectedState(c, mode: mode))
        XCTAssertTrue(stillOn.onScreen)
        XCTAssertEqual(scrollOffset(c, mode: mode), offset, accuracy: 0.5, "\(mode) a visible item does not scroll")

        // A filter that keeps the item keeps it on screen.
        XCTAssertTrue(c.select(url: dir.appendingPathComponent("P0950.jpg")))
        var filter = BrowserFilter.none
        filter.searchTerm = "P09"
        c.filter = filter
        let filtered = try XCTUnwrap(selectedState(c, mode: mode))
        XCTAssertTrue(filtered.onScreen, "\(mode) the selected item is on screen after the filter")
    }

    func testListFollowsTheSelectionAfterSortAndFilter() async throws { try await check(.list) }
    func testGridFollowsTheSelectionAfterSortAndFilter() async throws { try await check(.grid) }
}

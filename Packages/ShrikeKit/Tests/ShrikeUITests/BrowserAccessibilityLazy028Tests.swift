//
//  BrowserAccessibilityLazy028Tests.swift
//  ShrikeUITests
//
//  Spec 27 B3: an accessibility query on a 1000-photo folder reports only the
//  rows / items near the screen, fast, and builds no row view for the rest.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserAccessibilityLazy028Tests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        BrowserWindowController.restoresViewModeUnderTests = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-axlazy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<1000 {
            try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent(String(format: "P%04d.jpg", i)))
        }
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
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

    func testListChildrenAreLazyAndFast() async throws {
        let browser = try await open(.list)
        defer { browser.close() }
        let table = try XCTUnwrap(browser.contentController.tableViewForTesting as? BrowserTableView)
        table.layoutSubtreeIfNeeded()
        let visible = table.rows(in: table.visibleRect).length
        let start = Date()
        let children = table.accessibilityChildren() ?? []
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "under 100 ms")
        XCTAssertLessThanOrEqual(children.count, visible + 20 + 1 /* header */)
        XCTAssertEqual(table.accessibleRowCount, 1000)
        // Built row views stay near the screen.
        let built = (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }
        XCTAssertLessThanOrEqual(built.count, visible + 40, "no row view was built for the rest")

        // At the end of the list: still fast and small.
        table.accessibilityScroll(toRow: 999)
        table.layoutSubtreeIfNeeded()
        let start2 = Date()
        let again = table.accessibilityChildren() ?? []
        XCTAssertLessThan(Date().timeIntervalSince(start2), 0.1)
        XCTAssertLessThanOrEqual(again.count, visible + 20 + 1)

        // VoiceOver asks for an off-screen row: the table scrolls to it.
        table.scrollRowToVisible(0)
        table.accessibilityScroll(toRow: 900)
        let range = table.rows(in: table.visibleRect)
        XCTAssertTrue(NSLocationInRange(900, range), "row 900 is visible after the scroll")
    }

    func testGridChildrenAreLazyAndFast() async throws {
        let browser = try await open(.grid)
        defer { browser.close() }
        let grid = browser.contentController.collectionViewForTesting
        grid.layoutSubtreeIfNeeded()
        let visibleCount = grid.indexPathsForVisibleItems().count
        let start = Date()
        let children = grid.accessibilityChildren() ?? []
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertLessThanOrEqual(children.count, visibleCount + 2 * BrowserCollectionView.accessibilityOverscan)
        XCTAssertLessThanOrEqual((grid.accessibilityVisibleChildren() ?? []).count, visibleCount)
        XCTAssertGreaterThan(grid.accessibleColumnCount, 0)
        XCTAssertGreaterThanOrEqual(grid.accessibleRowCount * grid.accessibleColumnCount, 1000)
        grid.accessibilityScroll(toItem: 950)
        grid.layoutSubtreeIfNeeded()
        let frame = try XCTUnwrap(grid.layoutAttributesForItem(at: IndexPath(item: 950, section: 0))?.frame)
        XCTAssertTrue(grid.visibleRect.intersects(frame), "item 950 is on screen after the scroll")
    }
}

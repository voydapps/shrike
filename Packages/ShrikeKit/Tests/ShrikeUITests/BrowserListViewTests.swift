//
//  BrowserListViewTests.swift
//  ShrikeUITests
//
//  The Browser's list view:
//  - Dimensions shows the size for JPEG / PNG (the listing has none):
//    from the header cache, else a header read off the main thread;
//  - every column, Flag and Tags included, fits the list's width;
//  - Esc in the search field clears it and gives focus to the list.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserListViewTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func browser(count: Int, services: ShrikeServices? = nil) async throws -> BrowserWindowController {
        let browser = BrowserWindowController(services: services ?? ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists")
        return browser
    }

    /// The text of the list cell in `column` on `row`.
    private func cellText(_ table: NSTableView, column id: String, row: Int) -> String? {
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == id }),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) else { return nil }
        return cell.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
    }

    // MARK: Dimensions

    func testDimensionsComeFromTheFileHeadersOffTheMainThread() async throws {
        try writeJPEG("a.jpg", width: 64, height: 48)
        try writeJPEG("b.jpg", width: 30, height: 90)
        let browser = try await browser(count: 2)
        defer { browser.close() }
        let content = browser.contentController
        XCTAssertNil(content.visibleItems.first?.pixelWidth, "the listing has no size for JPEG")
        content.setMode(.list)
        await content.waitForListDimensions()
        let table = content.tableViewForTesting
        let texts = (0..<2).compactMap { cellText(table, column: "col.dim", row: $0) }
        XCTAssertEqual(Set(texts), ["64 × 48", "30 × 90"])
        // The reads went into the header cache (a later sort reads nothing).
        let dates = Dictionary(uniqueKeysWithValues: content.visibleItems.map { ($0.url, $0.modificationDate) })
        let cached = await browser.contentController.services.metadataStore.cachedHeaders(for: dates)
        XCTAssertEqual(cached.count, 2)
    }

    func testDimensionsUseTheHeaderCacheFirst() async throws {
        let url = try writeJPEG("a.jpg", width: 64, height: 48)
        let services = ShrikeServices.makeDefault()
        let modified = try XCTUnwrap(URL(fileURLWithPath: url.path)
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        // A value only the cache can have: the cache is read, the file isn't.
        await services.metadataStore.storeHeaders([
            url: (modified, ImageHeaderInfo(pixelWidth: 111, pixelHeight: 222)),
        ])
        let browser = try await browser(count: 1, services: services)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.list)
        await content.waitForListDimensions()
        XCTAssertEqual(cellText(content.tableViewForTesting, column: "col.dim", row: 0), "111 × 222")
        XCTAssertEqual(content.listDimensionsText(try XCTUnwrap(content.visibleItems.first)), "111 × 222")
    }

    func testNothingIsReadInTheGrid() async throws {
        try writeJPEG("a.jpg")
        let browser = try await browser(count: 1)
        defer { browser.close() }
        let content = browser.contentController
        XCTAssertEqual(content.mode, .grid)
        await content.waitForListDimensions()
        XCTAssertEqual(content.listDimensionsText(try XCTUnwrap(content.visibleItems.first)), "—")
    }

    // MARK: Columns

    func testEveryColumnFitsTheListWidth() async throws {
        try writeJPEG("a.jpg")
        let browser = try await browser(count: 1)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let content = browser.contentController
        let table = content.tableViewForTesting
        // First show at 1280 pt (the Browser's usual size), then wider.
        for (step, width) in [1280.0, 1400.0].enumerated() {
            window.setContentSize(NSSize(width: width, height: 800))
            if step == 0 { content.setMode(.list) }
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            let clip = try XCTUnwrap(table.enclosingScrollView?.contentView)
            XCTAssertGreaterThan(clip.bounds.width, 400, "the list has its width")
            let ids = table.tableColumns.map(\.identifier.rawValue)
            XCTAssertTrue(ids.contains("col.flag") && ids.contains("col.tags"))
            for (index, id) in ids.enumerated() {
                let rect = table.rect(ofColumn: index)
                XCTAssertLessThanOrEqual(rect.maxX, clip.bounds.width + 1, "\(id) runs past the right edge at \(width) pt")
            }
            XCTAssertGreaterThan(table.rect(ofColumn: ids.count - 1).maxX, clip.bounds.width - 30, "the columns fill the width")
        }
        let flag = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "col.flag" })
        XCTAssertEqual(flag.width, 36, "Flag keeps its width")
        // Narrow (1000 pt with both side panes): the columns stop at their
        // minimum and the list scrolls sideways to Flag and Tags.
        window.setContentSize(NSSize(width: 1000, height: 800))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertTrue(scroll.hasHorizontalScroller)
        for column in table.tableColumns { XCTAssertGreaterThanOrEqual(column.width, column.minWidth) }
        XCTAssertLessThanOrEqual(table.rect(ofColumn: table.numberOfColumns - 1).maxX, table.frame.width + 1,
                                 "Tags is inside the scrollable list")
    }

    /// At the default 1280 pt with the
    /// inspector open, and at the 990 pt minimum, Dimensions and Modified
    /// show their whole text ("5184 × 3456", the locale's longest date).
    func testDimensionsAndModifiedAreNeverCutAtTheDefaultOrMinimumWidth() async throws {
        // The month whose Modified text is widest in this locale.
        let samples = BrowserContentViewController.longestDateSamples()
        let probe = NSTextField(labelWithString: "")
        probe.font = BrowserContentViewController.listFont
        let widths = samples.map { sample -> CGFloat in probe.stringValue = sample; return probe.intrinsicContentSize.width }
        let month = try XCTUnwrap(widths.indices.max { widths[$0] < widths[$1] }) + 1
        let longest = try XCTUnwrap(Calendar(identifier: .gregorian).date(
            from: DateComponents(year: 2026, month: month, day: 28, hour: 22, minute: 58)))

        let services = ShrikeServices.makeDefault()
        var store: [URL: (modified: Date, info: ImageHeaderInfo)] = [:]
        for name in ["a.jpg", "b.jpg"] {
            let url = try writeJPEG(name)
            try FileManager.default.setAttributes([.modificationDate: longest], ofItemAtPath: url.path)
            // A 5184 × 3456 camera size, from the header cache.
            store[URL(fileURLWithPath: url.path)] = (longest, ImageHeaderInfo(pixelWidth: 5184, pixelHeight: 3456))
        }
        await services.metadataStore.storeHeaders(store)
        let browser = try await browser(count: 2, services: services)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let content = browser.contentController
        let table = content.tableViewForTesting
        let panes = browser.splitController.splitViewItems
        panes[0].isCollapsed = false
        panes[2].isCollapsed = false
        content.setMode(.list)
        await content.waitForListDimensions()

        for width in [1280.0, BrowserWindowController.minimumWindowWidth] {
            window.setContentSize(NSSize(width: width, height: 800))
            for _ in 0..<2 { window.contentView?.superview?.layoutSubtreeIfNeeded() }
            XCTAssertFalse(panes[2].isCollapsed, "the inspector is open")
            for id in ["col.dim", "col.date"] {
                let column = try XCTUnwrap(table.tableColumns.firstIndex { $0.identifier.rawValue == id })
                for row in 0..<2 {
                    let cell = try XCTUnwrap(table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)
                    cell.layoutSubtreeIfNeeded()
                    let field = try XCTUnwrap(cell.textField)
                    if id == "col.dim" { XCTAssertEqual(field.stringValue, "5184 × 3456") }
                    XCTAssertGreaterThanOrEqual(field.frame.width + 0.5, field.intrinsicContentSize.width,
                                                "\(id) “\(field.stringValue)” is cut at \(width) pt")
                }
            }
        }
        // Name, Rating and Tags gave up room first: the fitted columns
        // kept their width.
        let date = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "col.date" })
        XCTAssertEqual(date.width, date.minWidth)
    }

    // MARK: Grid shift-click

    func testShiftClickInTheGridSelectsARangeFromTheAnchor() async throws {
        for i in 0..<8 { try writeJPEG(String(format: "p%02d.jpg", i)) }
        let browser = try await browser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        XCTAssertEqual(content.mode, .grid)
        let grid = content.collectionViewForTesting
        func ip(_ i: Int) -> IndexPath { IndexPath(item: i, section: 0) }
        func items(_ set: Set<IndexPath>) -> [Int] { set.map(\.item).sorted() }

        // A plain click on item 2 (AppKit selects it; the anchor follows).
        grid.selectionIndexPaths = [ip(2)]
        grid.noteClick(on: ip(2), command: false)
        grid.extendSelection(to: ip(5))
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5], "a range, not one more item")
        XCTAssertEqual(content.selectedItems.count, 4, "the Browser hears it (status bar, inspector)")
        // A second shift-click on the other side replaces the range.
        grid.extendSelection(to: ip(0))
        XCTAssertEqual(items(grid.selectionIndexPaths), [0, 1, 2])
        XCTAssertEqual(grid.selectionAnchor, ip(2))

        // ⌘-click item 6 adds it and moves the anchor; shift-click keeps
        // the earlier items beside the new range.
        grid.selectionIndexPaths.insert(ip(6))
        grid.noteClick(on: ip(6), command: true)
        grid.extendSelection(to: ip(7))
        XCTAssertEqual(items(grid.selectionIndexPaths), [0, 1, 2, 6, 7])

        // The keys moved the selection away from the anchor: the first
        // selected item anchors the range.
        grid.selectionIndexPaths = [ip(4)]
        grid.extendSelection(to: ip(1))
        XCTAssertEqual(items(grid.selectionIndexPaths), [1, 2, 3, 4])

        // Nothing selected: a shift-click selects just that item.
        grid.selectionIndexPaths = []
        grid.extendSelection(to: ip(3))
        XCTAssertEqual(items(grid.selectionIndexPaths), [3])

        // New contents drop the anchor.
        grid.reloadData()
        XCTAssertNil(grid.selectionAnchor)
    }

    /// The list view keeps NSTableView's own clicks (it ranges already).
    func testTheListKeepsTheTableViewsOwnShiftClick() {
        let click = #selector(NSResponder.mouseDown(with:))
        XCTAssertEqual(BrowserTableView.instanceMethod(for: click), NSTableView.instanceMethod(for: click),
                       "no mouseDown override in the list")
    }

    // MARK: Search field

    func testEscInTheSearchFieldClearsItAndFocusesTheList() async throws {
        try writeJPEG("IMG_0001.jpg")
        try writeJPEG("DSC_0002.jpg")
        let browser = try await browser(count: 2)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let content = browser.contentController
        content.setMode(.list)
        XCTAssertTrue(window.makeFirstResponder(browser.searchField))
        let editor = try XCTUnwrap(browser.searchField.currentEditor() as? NSTextView, "the field is editing")
        browser.searchField.stringValue = "IMG"
        browser.endSearchWithEscape()
        XCTAssertEqual(browser.searchField.stringValue, "")
        XCTAssertEqual(browser.currentFilterForTesting.searchTerm, "")
        XCTAssertTrue(window.firstResponder === content.tableViewForTesting, "the list takes the keys")
        XCTAssertNil(browser.searchField.currentEditor(), "no focus ring on the field")
        XCTAssertEqual(content.visibleItems.count, 2)

        // The real key path: the field editor's cancelOperation reaches the
        // delegate, which ends the search the same way (grid this time).
        content.setMode(.grid)
        XCTAssertTrue(window.makeFirstResponder(browser.searchField))
        let editor2 = try XCTUnwrap(browser.searchField.currentEditor() as? NSTextView)
        editor2.insertText("DSC", replacementRange: editor2.selectedRange())
        editor2.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(browser.searchField.stringValue, "")
        XCTAssertTrue(window.firstResponder === content.focusView, "the grid takes the keys")
        _ = editor
    }
}

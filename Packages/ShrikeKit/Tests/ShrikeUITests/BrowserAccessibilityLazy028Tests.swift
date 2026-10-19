//
//  BrowserAccessibilityLazy028Tests.swift
//  ShrikeUITests
//
//  Native semantic List rows remain reachable; actual rendered rows/cells and
//  thumbnail work stay bounded near the viewport. Grid checks retain spec27 B3.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserAccessibilityLazy028Tests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0
    private var root: URL!
    private var services: ShrikeServices!
    private var resources: ImageResourceBudget!
    private var savedPreset = ShortcutPreset.macNative

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        BrowserWindowController.restoresViewModeUnderTests = true
        savedPreset = Prefs.shortcutPreset; Prefs.shortcutPreset = .macNative
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-axlazy-\(UUID())")
        dir = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 64, height: 48), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        for i in 0..<1000 {
            try (data as Data).write(to: dir.appendingPathComponent(String(format: "P%04d.jpg", i)))
        }
        resources = ImageResourceBudget(configuration: .init(monitorSystemPressure: false))
        services = ShrikeServices(thumbnailCache: try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs"), resources: resources),
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        BrowserWindowController.restoresViewModeUnderTests = false
        Prefs.shortcutPreset = savedPreset
        await drainThumbnailWork()
        await services.thumbnailCache.evictMemory()
        try? FileManager.default.removeItem(at: root)
    }

    private func open(_ mode: BrowserViewMode, stats: BrowserListMaterializationStats? = nil) async throws -> BrowserWindowController {
        Prefs.browserViewMode = mode.rawValue
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        browser.contentController.listMaterializationStatsForTesting = stats
        let deadline = Date().addingTimeInterval(15)
        while browser.contentController.allItems.count < 1000, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(browser.contentController.allItems.count, 1000)
        browser.window?.setContentSize(NSSize(width: 1100, height: 700))
        browser.window?.alphaValue = 0
        browser.window?.ignoresMouseEvents = true
        browser.window?.orderFront(nil)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        await browser.listingTask?.value
        await browser.contentController.waitForListDimensions()
        return browser
    }

    private func drainThumbnailWork() async {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            await Task.yield()
            if await services.thumbnailCache.jobCountForTesting() == 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        } while Date() < deadline
        let pending = await services.thumbnailCache.jobCountForTesting()
        XCTAssertEqual(pending, 0, "Owned thumbnail work finishes before inspecting cache stats/removing fixtures")
        await services.thumbnailCache.waitForPendingDiskWrites()
    }

    /// Public Objective-C properties avoid the imported protocol-typed native row arrays.
    /// These are in-process semantic checks, not a substitute for QA's remote AX probe.
    private func ax(_ element: Any, _ key: String) -> Any? {
        guard let object = element as? NSObject else { return nil }
        let selector = key == "accessibilitySelected" ? "isAccessibilitySelected" : key
        if object.responds(to: NSSelectorFromString(selector)), let value = object.value(forKey: key) { return value }
        // AppKit's native semantic proxies expose the public informal AX interface.
        let attributes = ["accessibilityRole": "AXRole", "accessibilityIndex": "AXIndex",
            "accessibilityParent": "AXParent", "accessibilitySelected": "AXSelected",
            "accessibilityChildren": "AXChildren", "accessibilityValue": "AXValue",
            "accessibilityTitle": "AXTitle", "accessibilityLabel": "AXDescription"]
        guard let attribute = attributes[key], object.responds(to: NSSelectorFromString("accessibilityAttributeValue:")) else { return nil }
        return object.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: attribute))
    }
    private func texts(_ element: Any, depth: Int = 0) -> [String] {
        guard depth < 5 else { return [] }
        let own = ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"].compactMap { ax(element, $0) as? String }
        return own + ((ax(element, "accessibilityChildren") as? [Any]) ?? []).prefix(16).flatMap { texts($0, depth: depth + 1) }
    }
    private func builtRows(_ table: NSTableView) -> Int {
        (0..<table.numberOfRows).filter { table.rowView(atRow: $0, makeIfNecessary: false) != nil }.count
    }

    @discardableResult
    private func queryNativeList(_ table: BrowserTableView, selected: Int) throws -> (rows: Int, children: Int, seconds: Double) {
        let start = Date()
        let rows = try XCTUnwrap(ax(table, "accessibilityRows") as? [Any])
        let visible = try XCTUnwrap(ax(table, "accessibilityVisibleRows") as? [Any])
        let selection = try XCTUnwrap(ax(table, "accessibilitySelectedRows") as? [Any])
        let children = try XCTUnwrap(table.accessibilityChildren())
        let row = try XCTUnwrap(rows.indices.contains(selected) ? rows[selected] : nil)
        let role = ax(row, "accessibilityRole") as? String
        let index = ax(row, "accessibilityIndex") as? Int
        let parent = ax(row, "accessibilityParent") as? NSTableView
        let isSelected = ax(row, "accessibilitySelected") as? Bool
        let selectedIndices = selection.compactMap { ax($0, "accessibilityIndex") as? Int }
        let rowTexts = texts(row)
        // Measure native reads/traversal, never XCTest assertion-reporting work.
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(rows.count, 1000, "Semantic offscreen rows stay reachable")
        XCTAssertFalse(visible.isEmpty); XCTAssertFalse(children.isEmpty)
        XCTAssertEqual(selection.count, 1)
        XCTAssertEqual(role, NSAccessibility.Role.row.rawValue)
        XCTAssertEqual(index, selected)
        XCTAssertTrue(parent === table)
        XCTAssertEqual(isSelected, true)
        XCTAssertEqual(selectedIndices, [selected])
        XCTAssertTrue(rowTexts.contains(String(format: "P%04d.jpg", selected)), "Visible selected row exports its actual filename")
        XCTAssertLessThan(elapsed, 0.1, "Native rows/children and bounded visible-cell traversal: under100ms")
        return (rows.count, children.count, elapsed)
    }

    func testListChildrenAreLazyAndFast() async throws {
        let stats = BrowserListMaterializationStats()
        let browser = try await open(.list, stats: stats)
        defer { browser.close() }
        let content = browser.contentController
        let table = try XCTUnwrap(content.tableViewForTesting as? BrowserTableView)
        XCTAssertTrue(browser.window?.isVisible == true)
        table.layoutSubtreeIfNeeded()
        let initialVisible = table.rows(in: table.visibleRect).length
        XCTAssertGreaterThan(initialVisible, 0)
        XCTAssertGreaterThan(builtRows(table), 0, "An empty hidden table cannot pass this regression")
        XCTAssertGreaterThan(stats.rowViews, 0); XCTAssertGreaterThan(stats.cells, 0)
        XCTAssertGreaterThan(stats.thumbnailRequests, 0)
        XCTAssertLessThanOrEqual(builtRows(table), initialVisible + 20)
        XCTAssertLessThanOrEqual(stats.rowViews, initialVisible + 20)
        XCTAssertLessThanOrEqual(stats.cells, (initialVisible + 20) * table.tableColumns.count)
        let unseen = dir.appendingPathComponent("P0500.jpg")
        XCTAssertFalse(stats.thumbnailURLs.contains(unseen))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        for selected in [0, 900, 999] {
            if selected != 0 { table.accessibilityScroll(toRow: selected) }
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.layoutSubtreeIfNeeded()
            let visible = table.rows(in: table.visibleRect).length
            let before = (rows: stats.rowViews, cells: stats.cells, thumbnails: stats.thumbnailRequests)
            let result = try autoreleasepool { try queryNativeList(table, selected: selected) }
            XCTAssertLessThanOrEqual(builtRows(table), visible + 20)
            XCTAssertEqual(stats.rowViews - before.rows, 0, "Semantic AX queries do not create rendered row views")
            XCTAssertEqual(stats.cells - before.cells, 0, "Semantic AX queries do not create rendered cells")
            XCTAssertEqual(stats.thumbnailRequests - before.thumbnails, 0, "Semantic AX queries do not request thumbnails")
            print("LIST_AX phase=\(selected) rows=\(result.rows) children=\(result.children) ms=\(result.seconds * 1000) visible=\(visible) built=\(builtRows(table)) rowCreations=\(stats.rowViews) cellCreations=\(stats.cells) thumbRequests=\(stats.thumbnailRequests) AXdeltaRows=\(stats.rowViews-before.rows) AXdeltaCells=\(stats.cells-before.cells) AXdeltaThumbs=\(stats.thumbnailRequests-before.thumbnails)")
        }
        XCTAssertEqual(table.accessibleRowCount, 1000)
        XCTAssertFalse(stats.thumbnailURLs.contains(unseen), "AX semantic enumeration did not request an unvisited offscreen thumbnail")
        XCTAssertLessThanOrEqual(stats.thumbnailURLs.count, 3 * (initialVisible + 20))
        await drainThumbnailWork()
        let cacheStats = await services.thumbnailCache.statistics()
        // Whole-cache misses also include Inspector previews at a different pixel size.
        print("LIST_AX cacheMisses=\(cacheStats.misses) requestedUnique=\(stats.thumbnailURLs.count)")

        // Native keyboard movement still follows the selected source near the end.
        table.accessibilityScroll(toRow: 900); table.selectRowIndexes(IndexSet(integer: 900), byExtendingSelection: false)
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: 0,
            windowNumber: browser.window?.windowNumber ?? 0, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: down); table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: 901))
        try queryNativeList(table, selected: 901)
        table.scrollRowToVisible(0)
        table.accessibilityScroll(toRow: 900)
        XCTAssertTrue(NSLocationInRange(900, table.rows(in: table.visibleRect)))
    }

    func testNativeListAccessibilityReferencesReleaseAfterClose() async throws {
        var browser: BrowserWindowController? = try await open(.list)
        weak var closedBrowser = browser
        weak var closedContent = browser?.contentController
        weak var closedTable = browser?.contentController.tableViewForTesting
        try autoreleasepool {
            let table = try XCTUnwrap(browser?.contentController.tableViewForTesting as? BrowserTableView)
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            try queryNativeList(table, selected: 0)
        }
        // Disable the native close fade on this transparent shown fixture so
        // release checks measure AX ownership rather than animation lifetime.
        browser?.window?.animationBehavior = .none
        browser?.close(); browser = nil
        let deadline = Date().addingTimeInterval(12)
        while (closedBrowser != nil || closedContent != nil || closedTable != nil), Date() < deadline {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(closedBrowser); XCTAssertNil(closedContent); XCTAssertNil(closedTable)
        await drainThumbnailWork()
        await services.thumbnailCache.evictMemory()
        XCTAssertEqual(resources.snapshot().uniqueRetainedBytes, 0)
        XCTAssertEqual(resources.snapshot().reservedEstimatedBytes, 0)
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

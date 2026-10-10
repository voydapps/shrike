//
//  BrowserToolbarTests.swift
//  ShrikeUITests
//
//  The Browser toolbar's items and order, the tracking
//  separators, Sort / Filter / Search / Inspector, the one-time layout
//  reset, the title and subtitle, and a narrow window.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserToolbarTests: XCTestCase {

    private var root: URL!
    private var dir: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-toolbar-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJPEG(_ name: String, in folder: URL? = nil) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = (folder ?? dir).appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
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

    private func browser(images: Int) async throws -> BrowserWindowController {
        for i in 0..<images { try writeJPEG(String(format: "IMG_%04d.jpg", i)) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == images && browser.window?.subtitle != "" }
        XCTAssertTrue(ok, "the folder lists")
        return browser
    }

    // MARK: Items and order

    func testDefaultItemsAreInSpecOrder() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let toolbar = try XCTUnwrap(browser.window?.toolbar)
        let expected: [NSToolbarItem.Identifier] = [
            .toggleSidebar, .sidebarTrackingSeparator, BrowserToolbarID.backForward, .flexibleSpace,
            BrowserToolbarID.viewMode, BrowserToolbarID.sort, BrowserToolbarID.filter, BrowserToolbarID.search,
            .inspectorTrackingSeparator, BrowserToolbarID.inspector,
        ]
        XCTAssertEqual(browser.toolbarDefaultItemIdentifiers(toolbar), expected)
        XCTAssertEqual(toolbar.items.map(\.itemIdentifier), expected)
        XCTAssertEqual(toolbar.displayMode, .iconOnly)
        XCTAssertEqual(browser.window?.toolbarStyle, .unified)
        XCTAssertTrue(toolbar.allowsUserCustomization)
        XCTAssertTrue(toolbar.autosavesConfiguration)
        // Removed: breadcrumbs and the slider; Open in Viewer stays optional.
        let allowed = browser.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue)
        XCTAssertFalse(allowed.contains("shrike.browser.breadcrumbs"))
        XCTAssertFalse(allowed.contains("shrike.browser.thumbSize"))
        XCTAssertTrue(allowed.contains(BrowserToolbarID.openInViewer.rawValue))
        XCTAssertFalse(expected.contains(BrowserToolbarID.openInViewer))
    }

    func testTrackingSeparatorsFollowTheSplitDividers() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let items = try XCTUnwrap(browser.window?.toolbar?.items)
        let sidebar = try XCTUnwrap(items.first { $0.itemIdentifier == .sidebarTrackingSeparator } as? NSTrackingSeparatorToolbarItem)
        let inspector = try XCTUnwrap(items.first { $0.itemIdentifier == .inspectorTrackingSeparator } as? NSTrackingSeparatorToolbarItem)
        XCTAssertTrue(sidebar.splitView === browser.splitController.splitView)
        XCTAssertEqual(sidebar.dividerIndex, 0)
        XCTAssertTrue(inspector.splitView === browser.splitController.splitView)
        XCTAssertEqual(inspector.dividerIndex, 1)
    }

    func testBackForwardIsANavigationalMomentaryGroupThatFollowsHistory() async throws {
        let sub = dir.appendingPathComponent("Day 2", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try writeJPEG("a.jpg", in: sub)
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let group = try XCTUnwrap(browser.historyGroup)
        XCTAssertTrue(group.isNavigational)
        XCTAssertEqual(group.selectionMode, .momentary)
        XCTAssertEqual(group.subitems.count, 2)
        XCTAssertFalse(group.subitems[0].isEnabled, "no history yet")
        XCTAssertFalse(group.subitems[1].isEnabled)
        XCTAssertTrue(group.subitems[0].toolTip?.hasPrefix("Back") ?? false, group.subitems[0].toolTip ?? "")
        XCTAssertTrue(group.subitems[0].toolTip?.contains("⌘[") ?? false, group.subitems[0].toolTip ?? "")

        browser.navigate(to: sub)
        XCTAssertTrue(group.subitems[0].isEnabled)
        XCTAssertTrue(browser.validateToolbarItem(group.subitems[0]))
        XCTAssertFalse(browser.validateToolbarItem(group.subitems[1]))
        browser.toolbarHistory(group.subitems[0])
        XCTAssertEqual(browser.currentFolder, dir.standardizedFileURL)
        XCTAssertTrue(group.subitems[1].isEnabled, "Forward after Back")
        browser.toolbarHistory(group.subitems[1])
        XCTAssertEqual(browser.currentFolder, sub.standardizedFileURL)
    }

    func testViewModeIsASelectOneGroupWithTheSpecSymbols() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let group = try XCTUnwrap(browser.viewModeGroup)
        XCTAssertEqual(group.selectionMode, .selectOne)
        XCTAssertEqual(group.subitems.count, 3)
        XCTAssertEqual(BrowserToolbarLayout.viewModeSymbols,
                       ["square.grid.2x2", "rectangle.bottomthird.inset.filled", "list.bullet"])
        for name in BrowserToolbarLayout.viewModeSymbols {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
        browser.setMode(.list)
        XCTAssertEqual(group.selectedIndex, 2)
        group.selectedIndex = 1
        browser.toolbarViewMode(group)
        XCTAssertEqual(browser.contentController.mode, .filmstrip)
    }

    func testSortItemIsAMenuItemWithTheViewSortByMenu() async throws {
        let browser = try await browser(images: 1)
        defer {
            browser.close()
            Prefs.browserSortKey = "name"
            Prefs.browserSortAscending = true
        }
        let sort = try XCTUnwrap(browser.sortToolbarItem)
        XCTAssertTrue(sort.showsIndicator)
        XCTAssertNotNil(sort.image)
        XCTAssertNotNil(NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: nil))
        let titles = sort.menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        XCTAssertEqual(titles, ["Name", "Date Captured", "Date Modified", "Size", "Rating", "Kind", "Dimensions",
                                "—", "Ascending", "Descending"])
        // Picking "Size" sorts by size; the check marks follow.
        let size = sort.menu.items[3]
        browser.performShrikeCommand(size)
        XCTAssertEqual(browser.contentController.sort.key, .size)
        XCTAssertTrue(browser.validateMenuItem(size))
        XCTAssertEqual(size.state, .on)
        let descending = sort.menu.items[9]
        browser.setSortDirection(descending)
        XCTAssertEqual(browser.contentController.sort.direction, .descending)
        XCTAssertTrue(browser.validateMenuItem(descending))
        XCTAssertEqual(descending.state, .on)
    }

    func testFilterSearchAndInspectorItems() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let filter = try XCTUnwrap(browser.filterToolbarItem)
        XCTAssertTrue(filter.view === browser.filterButton)
        XCTAssertNotNil(filter.menuFormRepresentation, "Filter works from the overflow menu")
        XCTAssertNil(browser.filterButton.contentTintColor, "no tint without a filter")

        let search = try XCTUnwrap(browser.searchToolbarItem)
        XCTAssertTrue(search.view === browser.searchField, "a plain item holding the field")
        XCTAssertEqual(browser.searchField.placeholderString, "Search")
        for item in [browser.sortToolbarItem, browser.filterToolbarItem, browser.viewModeGroup, browser.historyGroup] {
            XCTAssertEqual(item?.visibilityPriority, .high, "Search gives way first")
        }

        let inspector = try XCTUnwrap(browser.window?.toolbar?.items.first { $0.itemIdentifier == BrowserToolbarID.inspector })
        XCTAssertNotNil(inspector.image)
        XCTAssertTrue(inspector.toolTip?.contains("⌘I") ?? false, inspector.toolTip ?? "")
        let item = try XCTUnwrap(browser.splitController.splitViewItems.last)
        let before = item.isCollapsed
        browser.toolbarToggleInspector(inspector)
        let flipped = await waitUntil(2) { item.isCollapsed != before }
        XCTAssertTrue(flipped, "the Inspector item toggles the inspector")
    }

    func testCommandFShowsAHiddenToolbar() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let toolbar = try XCTUnwrap(browser.window?.toolbar)
        toolbar.isVisible = false
        browser.dispatch(.focusSearch)
        XCTAssertTrue(toolbar.isVisible, "⌘F shows a hidden toolbar")
    }

    // MARK: Title and subtitle

    func testTitleIsTheFolderAndSubtitleCountsImages() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(window.title, "Holiday")
        XCTAssertEqual(window.representedURL?.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(window.subtitle, "1 image")
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 252, total: 252), "252 images")
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 47, total: 252), "47 of 252 images")
    }

    func testSubtitleIsEmptyThenLoadingAfter150ms() async throws {
        let browser = try await browser(images: 2)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        XCTAssertEqual(window.subtitle, "2 images")
        browser.beginSubtitleLoading()
        XCTAssertEqual(window.subtitle, "", "empty before the count is known")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(window.subtitle, "", "still empty under 150 ms")
        let loading = await waitUntil(2) { window.subtitle == "Loading…" }
        XCTAssertTrue(loading)
    }

    // MARK: Migration

    func testToolbarLayoutResetsOnceOnly() throws {
        let defaults = makeTestDefaults()
        let key = BrowserToolbarLayout.configurationKey
        XCTAssertEqual(key, "NSToolbar Configuration shrike.browser.toolbar")
        defaults.set(["TB Item Identifiers": ["shrike.browser.breadcrumbs"]], forKey: key)
        XCTAssertTrue(BrowserToolbarLayout.migrate(defaults), "the old layout is dropped")
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertEqual(defaults.integer(forKey: BrowserToolbarLayout.layoutVersionKey), BrowserToolbarLayout.layoutVersion)
        // A layout the user saves afterwards is kept.
        defaults.set(["TB Item Identifiers": ["shrike.browser.search"]], forKey: key)
        XCTAssertFalse(BrowserToolbarLayout.migrate(defaults))
        XCTAssertNotNil(defaults.object(forKey: key))
    }

    // MARK: Narrow window

    /// Lays out the whole window, titlebar included (the toolbar decides
    /// what goes into » there), a few times so the result settles.
    private func layOutTitlebar(_ window: NSWindow) {
        for _ in 0..<3 {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
    }

    /// Items in the » menu (Search may give way; separators never count).
    private func overflowed(_ toolbar: NSToolbar) -> [String] {
        let shown = Set((toolbar.visibleItems ?? []).map(\.itemIdentifier))
        return toolbar.items.map(\.itemIdentifier).filter {
            !shown.contains($0)
                && ![.flexibleSpace, .sidebarTrackingSeparator, .inspectorTrackingSeparator, BrowserToolbarID.search].contains($0)
        }.map(\.rawValue)
    }

    private func setSearch(open: Bool, in browser: BrowserWindowController) {
        if open {
            browser.focusSearch()
            browser.searchField.stringValue = "IMG"
        } else {
            browser.searchField.stringValue = ""
            browser.window?.makeFirstResponder(nil)
        }
    }

    func testTheMinimumWidthLeavesRoomForAnOpenSearchField() {
        XCTAssertEqual(BrowserWindowController.minimumWindowWidth, 1030)   // sidebar 200
        XCTAssertEqual(BrowserWindowController.contentMinimumWidth, BrowserToolbarRoom.contentMinimumWidth)
        // The narrow layout (View pop-up, open 110 pt field) plus 40 pt.
        XCTAssertEqual(BrowserToolbarRoom.contentMinimumWidth, 574)
        XCTAssertEqual(BrowserToolbarRoom.searchFieldWidth, 110)
        XCTAssertEqual(BrowserToolbarRoom.threeSegmentsFrom, 637)
        XCTAssertEqual(BrowserToolbarRoom.viewRepresentation(room: 574), .collapsed)
        XCTAssertEqual(BrowserToolbarRoom.viewRepresentation(room: 636), .collapsed)
        XCTAssertEqual(BrowserToolbarRoom.viewRepresentation(room: 637), .automatic)
        XCTAssertEqual(BrowserToolbarRoom.room(contentWidth: 750, sidebarShown: false, inspectorShown: true), 620)
    }

    /// Back/Forward, View, Sort and Filter never go into »,
    /// with Search closed or open, at the minimum width, with the side
    /// panes shown or hidden, arriving there in steps or in one jump.
    func testAtTheMinimumWidthViewSortAndFilterStayWithSearchClosedOrOpen() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let items = browser.splitController.splitViewItems
        window.subtitle = "19 images"
        let minimum = window.minSize.width
        XCTAssertEqual(minimum, BrowserWindowController.minimumWindowWidth)
        XCTAssertEqual(BrowserToolbarRoom.fieldWidth(room: BrowserToolbarRoom.contentMinimumWidth),
                       BrowserToolbarRoom.searchFieldWidth, "the narrow field at the minimum")
        for (sidebar, inspector) in [(true, true), (false, true), (true, false), (false, false)] {
            items[0].isCollapsed = !sidebar
            items[2].isCollapsed = !inspector
            for open in [false, true] {
                let tag = "sidebar \(sidebar), inspector \(inspector), search open \(open)"
                // Opened wide, then narrowed in steps: an open field
                // keeps its width, so it must open narrow.
                window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 800), display: false)
                layOutTitlebar(window)
                setSearch(open: open, in: browser)
                layOutTitlebar(window)
                XCTAssertEqual(overflowed(toolbar), [], "1500 pt, \(tag)")
                for width in stride(from: 1480, through: minimum, by: -20) {
                    window.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: false)
                    layOutTitlebar(window)
                    XCTAssertEqual(overflowed(toolbar), [], "\(Int(width)) pt, \(tag)")
                }
                window.setFrame(NSRect(x: 0, y: 0, width: minimum, height: 800), display: false)
                layOutTitlebar(window)
                XCTAssertEqual(overflowed(toolbar), [], "minimum, \(tag)")
                // In one jump from wide to the minimum.
                window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 800), display: false)
                layOutTitlebar(window)
                window.setFrame(NSRect(x: 0, y: 0, width: minimum, height: 800), display: false)
                layOutTitlebar(window)
                XCTAssertEqual(overflowed(toolbar), [], "jump to the minimum, \(tag)")
            }
        }
        // Both panes shown at the minimum: the View group is its pop-up.
        items[0].isCollapsed = false
        items[2].isCollapsed = false
        layOutTitlebar(window)
        XCTAssertEqual(browser.viewModeGroup?.controlRepresentation, .collapsed)
        // A wide window has room for the three segments.
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
        layOutTitlebar(window)
        XCTAssertEqual(browser.viewModeGroup?.controlRepresentation, .automatic)
        XCTAssertEqual(overflowed(toolbar), [])
    }

    // MARK: ⌘F with the inspector open

    /// ⌘F, Edit ▸ Find ▸ Find… and the Search button open the field in
    /// every layout down to the minimum width, the field has the keys,
    /// and Esc gives them back to the grid / list.
    func testCommandFOpensSearchWithTheInspectorOpenAtEveryWidth() async throws {
        let browser = try await browser(images: 2)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let items = browser.splitController.splitViewItems
        let field = browser.searchField
        func fieldHasKeys() -> Bool {
            guard let editor = window.firstResponder as? NSText else { return false }
            return editor.delegate === field
        }
        for (sidebar, inspector) in [(true, true), (false, true), (true, false), (false, false)] {
            items[0].isCollapsed = !sidebar
            items[2].isCollapsed = !inspector
            for width in [1280, 1100, BrowserWindowController.minimumWindowWidth] {
                let tag = "sidebar \(sidebar), inspector \(inspector), \(Int(width)) pt"
                window.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: false)
                layOutTitlebar(window)
                for mode in [BrowserViewMode.grid, .list] {
                    browser.setMode(mode)
                    XCTAssertTrue(window.makeFirstResponder(browser.contentController.focusView))
                    browser.dispatch(.focusSearch)
                    layOutTitlebar(window)
                    XCTAssertNotNil(field.window, "the field is in the window, \(tag)")
                    XCTAssertFalse(field.isHiddenOrHasHiddenAncestor, tag)
                    XCTAssertGreaterThanOrEqual(field.frame.width, BrowserToolbarRoom.searchFieldWidth - 1,
                                                "the field is open, \(tag)")
                    XCTAssertTrue(fieldHasKeys(), "the field has the keys, \(tag), \(mode)")
                    browser.endSearchWithEscape()
                    XCTAssertTrue(window.firstResponder === browser.contentController.focusView,
                                  "Esc gives the keys back, \(tag), \(mode)")
                }
            }
        }
    }

    /// Wide side panes (dragged by the user) give way at the minimum: the
    /// content pane keeps its room and nothing goes into ».
    func testWideSidePanesGiveWayAtTheMinimumWidth() async throws {
        let browser = try await browser(images: 1)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let toolbar = try XCTUnwrap(window.toolbar)
        let items = browser.splitController.splitViewItems
        items[0].isCollapsed = false
        items[2].isCollapsed = false
        window.setFrame(NSRect(x: 0, y: 0, width: 1500, height: 800), display: false)
        layOutTitlebar(window)
        browser.splitController.splitView.setPosition(320, ofDividerAt: 0)
        browser.splitController.splitView.setPosition(1500 - 360, ofDividerAt: 1)
        layOutTitlebar(window)
        setSearch(open: true, in: browser)
        window.setFrame(NSRect(x: 0, y: 0, width: window.minSize.width, height: 800), display: false)
        layOutTitlebar(window)
        XCTAssertGreaterThanOrEqual(items[1].viewController.view.frame.width, BrowserWindowController.contentMinimumWidth - 1)
        XCTAssertEqual(overflowed(toolbar), [])
    }
}

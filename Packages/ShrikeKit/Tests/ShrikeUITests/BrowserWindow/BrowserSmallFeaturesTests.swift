//
//  BrowserSmallFeaturesTests.swift
//  ShrikeUITests
//
//  The small Browser items. Inspector header for 2+
//  items, no-selection inspector, Next / Previous Folder,
//  ⌘F with a hidden toolbar, JPEG dimensions from the
//  header, the paired viewer's cascade, no window tabs, a filter that
//  hides the selection, the list's sort arrow, no repeated sidebar
//  places, and the toolbar room at the 880 pt minimum. Temp folders,
//  offscreen windows.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class BrowserSmallFeaturesTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var savedSortKey = ""
    private var savedSortAscending = true

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-browser-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Holiday", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedSortKey = Prefs.browserSortKey
        savedSortAscending = Prefs.browserSortAscending
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
    }

    override func tearDown() async throws {
        Prefs.browserSortKey = savedSortKey
        Prefs.browserSortAscending = savedSortAscending
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

    private func browser(_ names: [String], in folder: URL? = nil) async throws -> BrowserWindowController {
        for name in names { try writeJPEG(name, in: folder) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: folder ?? dir)
        let ok = await waitUntil { browser.contentController.allItems.count == names.count }
        XCTAssertTrue(ok, "the folder lists")
        return browser
    }

    // MARK: (a) (e) Inspector

    func testInspectorHeaderForSeveralItemsAndFolderWithNone() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg"])
        defer { browser.close() }
        XCTAssertEqual(InspectorState.multipleHeader(3), "3 items selected")

        // Nothing selected: the folder, never the first photo.
        browser.contentController.deselectAll()
        browser.updateInspectorFromSelection()
        var state = browser.inspectorStateForTesting
        XCTAssertEqual(state.count, 0)
        XCTAssertNil(state.previewURL, "no photo preview without a selection")
        XCTAssertEqual(state.commonName, "Holiday")
        XCTAssertEqual(state.folderSummary, "3 images")
        XCTAssertNil(state.commonRating)

        let urls = browser.contentController.visibleItems.map(\.url)
        browser.contentController.select(urls: Array(urls.prefix(2)))
        state = browser.inspectorStateForTesting
        XCTAssertEqual(state.count, 2)
        XCTAssertNil(state.folderSummary)
        XCTAssertTrue(state.capture.isEmpty, "no EXIF rows for 2+ items")
    }

    func testAStarClickWithNothingSelectedRatesNothing() async throws {
        let browser = try await browser(["a.jpg", "b.jpg"])
        defer { browser.close() }
        browser.contentController.deselectAll()
        browser.updateInspectorFromSelection()
        // The inspector's star row calls onRate; with no selection it
        // must not rate the first photo.
        let pane = try XCTUnwrap(browser.inspectorControllerForTesting)
        pane.onRate?(4)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(browser.contentController.allItems.map(\.rating), [0, 0])
    }

    // MARK: (f) Dimensions from the header

    func testJPEGDimensionsComeFromTheHeaderRead() async throws {
        let browser = try await browser(["a.jpg"])
        defer { browser.close() }
        let url = try XCTUnwrap(browser.contentController.visibleItems.first?.url)
        XCTAssertTrue(browser.contentController.select(url: url))
        // The saved values landing re-reads the header; wait for the last.
        _ = await waitUntil { browser.inspectorStateForTesting.commonWidth != nil }
        await browser.waitForInspectorInfo()
        let state = browser.inspectorStateForTesting
        XCTAssertEqual(state.commonWidth, 64)
        XCTAssertEqual(state.commonHeight, 48)
        XCTAssertTrue(browser.statusTextForTesting.contains("64 × 48"), browser.statusTextForTesting)
    }

    // MARK: (c) Next / Previous Folder

    func testNextAndPreviousFolderInTheBrowser() async throws {
        let a = root.appendingPathComponent("A", isDirectory: true)
        let b = root.appendingPathComponent("B", isDirectory: true)
        let c = root.appendingPathComponent("C", isDirectory: true)
        for folder in [a, b, c] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        try writeJPEG("c.jpg", in: c)
        let browser = try await browser(["a.jpg"], in: a)
        defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.nextFolder))
        XCTAssertTrue(browser.canPerform(.previousFolder))

        browser.perform(.previousFolder)
        await browser.adjacentFolderTask?.value
        XCTAssertEqual(browser.toastHost.content?.message, "No previous folder.")

        browser.perform(.nextFolder)
        await browser.adjacentFolderTask?.value
        XCTAssertEqual(browser.currentFolder, c.standardizedFileURL, "B has no image: skipped")
        let shown = await waitUntil { browser.contentController.visibleItems.map(\.displayName) == ["c.jpg"] }
        XCTAssertTrue(shown)
    }

    // MARK: (d) Find with a hidden toolbar

    func testFindShowsAHiddenToolbarThenFocusesSearch() async throws {
        let browser = try await browser(["a.jpg"])
        defer { browser.close() }
        let toolbar = try XCTUnwrap(browser.window?.toolbar)
        toolbar.isVisible = false
        browser.perform(.find)
        XCTAssertTrue(toolbar.isVisible)
        await browser.focusSearchTask?.value
        XCTAssertNotNil(browser.searchField.currentEditor(), "the search field is being edited")
    }

    // MARK: (g) Paired viewer frame

    func testPairedViewerCascadesFromTheBrowser() {
        let browserFrame = NSRect(x: 100, y: 100, width: 1280, height: 800)
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let frame = WindowCoordinator.pairedViewerFrame(over: browserFrame, visible: visible)
        XCTAssertEqual(frame, NSRect(x: 124, y: 76, width: 1280, height: 800))
        XCTAssertNotEqual(frame, browserFrame, "never exactly on the Browser")

        // A Browser that fills the screen: the viewer gives up 24 pt.
        let full = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let inset = WindowCoordinator.pairedViewerFrame(over: full, visible: full)
        XCTAssertEqual(inset, NSRect(x: 24, y: 0, width: 1416, height: 851))
        XCTAssertTrue(full.contains(inset))
    }

    /// A short or narrow Browser (1986 x 580 in the check) does not give
    /// its size to the viewer: the 1200 x 800 default, centred on it.
    func testPairedViewerNeverTakesATooSmallBrowserFrame() {
        let visible = NSRect(x: 0, y: 0, width: 2560, height: 1415)
        let short = NSRect(x: 100, y: 600, width: 1986, height: 480)
        let frame = WindowCoordinator.pairedViewerFrame(over: short, visible: visible)
        XCTAssertEqual(frame.size, NSSize(width: 1200, height: 800))
        XCTAssertEqual(frame.midX, short.midX, accuracy: 0.5)
        XCTAssertEqual(frame.midY, short.midY, accuracy: 0.5)
        XCTAssertTrue(visible.contains(frame))

        let narrow = NSRect(x: 50, y: 50, width: 700, height: 900)
        let second = WindowCoordinator.pairedViewerFrame(over: narrow, visible: visible)
        XCTAssertEqual(second.size, NSSize(width: 1200, height: 800))
        XCTAssertTrue(visible.contains(second), "pushed back on the screen: \(second)")

        // Exactly the floor still cascades like any other Browser.
        let floor = NSRect(x: 100, y: 100, width: 800, height: 500)
        XCTAssertEqual(WindowCoordinator.pairedViewerFrame(over: floor, visible: visible),
                       NSRect(x: 124, y: 76, width: 800, height: 500))
        // A small screen limits the default size.
        let tiny = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let fitted = WindowCoordinator.pairedViewerFrame(over: NSRect(x: 0, y: 0, width: 600, height: 400), visible: tiny)
        XCTAssertTrue(tiny.contains(fitted))
    }

    // MARK: (h) No window tabs

    func testNoWindowTabs() async throws {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let before = NSApplication.shared.mainMenu
        bar.install(in: NSApplication.shared)
        defer { NSApplication.shared.mainMenu = before }
        XCTAssertFalse(NSWindow.allowsAutomaticWindowTabbing)
        let browser = try await browser(["a.jpg"])
        defer { browser.close() }
        XCTAssertEqual(browser.window?.tabbingMode, .disallowed)
    }

    // MARK: (i) A filter that hides the selection

    func testAFilterThatHidesTheSelectionClearsInspectorAndStatus() async throws {
        let browser = try await browser(["apple.jpg", "berry.jpg"])
        defer { browser.close() }
        let content = browser.contentController
        let berry = try XCTUnwrap(content.visibleItems.first { $0.displayName == "berry.jpg" })
        XCTAssertTrue(content.select(url: berry.url))
        // A new photo's status waits for its header read.
        await browser.waitForInspectorInfo()
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("berry.jpg"))

        browser.searchField.stringValue = "apple"
        var filter = BrowserFilter.none
        filter.searchTerm = "apple"
        content.filter = filter
        XCTAssertEqual(content.visibleItems.map(\.displayName), ["apple.jpg"])
        XCTAssertTrue(content.selectedItems.isEmpty, "the hidden photo is no longer selected")
        XCTAssertEqual(browser.statusTextForTesting, "")
        XCTAssertEqual(browser.inspectorStateForTesting.count, 0)
        XCTAssertEqual(browser.inspectorStateForTesting.folderSummary, "1 of 2 images")

        browser.clearFilterAndSearch()
        XCTAssertEqual(content.visibleItems.count, 2)
        XCTAssertTrue(content.selectedItems.isEmpty)
        XCTAssertEqual(browser.statusTextForTesting, "")
        XCTAssertNil(browser.inspectorStateForTesting.previewURL)
        XCTAssertEqual(browser.inspectorStateForTesting.folderSummary, "2 images")
    }

    func testAFilterKeepsASelectedPhotoItStillShows() async throws {
        let browser = try await browser(["apple.jpg", "berry.jpg"])
        defer { browser.close() }
        let content = browser.contentController
        let apple = try XCTUnwrap(content.visibleItems.first { $0.displayName == "apple.jpg" })
        XCTAssertTrue(content.select(url: apple.url))
        // A new photo's inspector waits for its header read;
        // after that the filter's re-select fills from the cache.
        await browser.waitForInspectorInfo()
        var filter = BrowserFilter.none
        filter.searchTerm = "apple"
        content.filter = filter
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["apple.jpg"])
        XCTAssertEqual(browser.inspectorStateForTesting.count, 1)
    }

    // MARK: (j) List sort arrow

    func testListShowsTheSortArrowAndAHeaderClickSorts() throws {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        content.setMode(.list)
        let table = content.tableViewForTesting
        func column(_ key: String) -> NSTableColumn? {
            table.tableColumns.first { $0.sortDescriptorPrototype?.key == key }
        }
        XCTAssertEqual(table.sortDescriptors.first?.key, "name", "the saved sort shows at once")
        XCTAssertNotNil(table.indicatorImage(in: try XCTUnwrap(column("name"))))

        content.sort = BrowserSort(key: .size, direction: .descending)
        XCTAssertEqual(table.sortDescriptors.first?.key, "size")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, false)
        let size = try XCTUnwrap(column("size"))
        XCTAssertNotNil(table.indicatorImage(in: size))
        XCTAssertNil(table.indicatorImage(in: try XCTUnwrap(column("name"))))
        XCTAssertTrue(table.highlightedTableColumn === size)

        // A header click sets the table's descriptors: the grid follows.
        table.sortDescriptors = [NSSortDescriptor(key: "rating", ascending: false)]
        XCTAssertEqual(content.sort, BrowserSort(key: .rating, direction: .descending))
        XCTAssertNotNil(table.indicatorImage(in: try XCTUnwrap(column("rating"))))

        // A key with no column: no arrow anywhere.
        content.sort = BrowserSort(key: .kind, direction: .ascending)
        XCTAssertTrue(table.sortDescriptors.isEmpty)
        XCTAssertTrue(table.tableColumns.allSatisfy { table.indicatorImage(in: $0) == nil })
        XCTAssertNil(column("flag"), "Flag is not a sort key")
    }

    // MARK: (k) Sidebar places once

    func testAPlaceInFavoritesIsNotRepeatedUnderFolders() throws {
        let fm = FileManager.default
        let pictures = try XCTUnwrap(fm.urls(for: .picturesDirectory, in: .userDomainMask).first)
        let desktop = try XCTUnwrap(fm.urls(for: .desktopDirectory, in: .userDomainMask).first)
        let downloads = try XCTUnwrap(fm.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        let source = FolderTreeDataSource()
        source.rebuildRoots(favorites: [pictures, desktop, downloads].map { SidebarFavoriteRow(url: $0, isMissing: false) },
                            volumes: [])
        let folders = try XCTUnwrap(source.roots.first { $0.section == .folders })
        XCTAssertEqual(folders.children.map(\.title), ["Home", "Documents"])
        let favorites = try XCTUnwrap(source.roots.first { $0.section == .favorites })
        XCTAssertEqual(favorites.children.count, 3)

        source.rebuildRoots(favorites: [], volumes: [])
        XCTAssertEqual(source.roots.first { $0.section == .folders }?.children.map(\.title),
                       ["Home", "Desktop", "Documents", "Pictures", "Downloads"])
    }

    // MARK: (l) Toolbar room at the minimum width

    func testContentPaneKeepsRoomForTheToolbarAtTheMinimumWidth() async throws {
        let browser = try await browser(["a.jpg"])
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        // Raised the minimum from 880 pt (room for an open
        // search field beside View, Sort and Filter).
        XCTAssertEqual(window.minSize.width, BrowserWindowController.minimumWindowWidth)
        let items = browser.splitController.splitViewItems
        XCTAssertEqual(items[1].minimumThickness, BrowserWindowController.contentMinimumWidth)
        XCTAssertGreaterThanOrEqual(BrowserWindowController.contentMinimumWidth, 460)
        // Sidebar and inspector minimums plus the content minimum fit.
        XCTAssertLessThanOrEqual(items[0].minimumThickness + items[1].minimumThickness + items[2].minimumThickness + 2,
                                 window.minSize.width)
        XCTAssertFalse(items[2].canCollapseFromWindowResize, "a narrow window keeps the inspector")
        items[2].isCollapsed = false
        items[0].isCollapsed = false
        window.setFrame(NSRect(x: 0, y: 0, width: 1280, height: 800), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.setFrame(NSRect(x: 0, y: 0, width: window.minSize.width, height: 600), display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        browser.splitController.splitView.adjustSubviews()
        window.contentView?.layoutSubtreeIfNeeded()
        let widths = items.map { $0.isCollapsed ? 0 : $0.viewController.view.frame.width }
        XCTAssertGreaterThanOrEqual(widths[1], BrowserWindowController.contentMinimumWidth - 1, "content \(widths)")
        XCTAssertGreaterThanOrEqual(widths[2], 239, "inspector \(widths)")
        XCTAssertLessThanOrEqual(widths[2], 361, "inspector \(widths)")
    }
}

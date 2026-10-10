//
//  OverflowMenuFormTests.swift
//  ShrikeUITests
//
//  In the toolbar's » overflow menu every row has an icon,
//  and a toggle that is on shows a check mark, in the viewer and the
//  Browser. The mark follows the state on every validation pass and when
//  the menu opens (`validateMenuItem`, which also covers a copy of the
//  row that AppKit may show).
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class OverflowMenuFormTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false
    private var savedAutoHide = false
    private var savedFilmstrip = false
    private var savedHistogram = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-overflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedAutoHide = Prefs.viewerToolbarAutoHide
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        savedHistogram = Prefs.viewerHistogramVisible
        Prefs.viewerInspectorVisibleWindowed = false
        Prefs.viewerToolbarAutoHide = false
        Prefs.filmstripVisibleInWindowed = false
        Prefs.viewerHistogramVisible = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        Prefs.viewerToolbarAutoHide = savedAutoHide
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
        Prefs.viewerHistogramVisible = savedHistogram
    }

    // MARK: Helpers

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
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
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    /// An offscreen viewer with every item the palette offers in its
    /// toolbar (the toolbar stops autosaving first).
    private func makeViewer() async throws -> (ViewerWindow, ViewerWindowToolbar) {
        let url = try writeJPEG("p.jpg", width: 1200, height: 900)
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        let bar = try XCTUnwrap(window.toolbarController)
        bar.toolbar.autosavesConfiguration = false
        let view = window.imageViewForTesting
        let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
        XCTAssertTrue(shown, "photo never reached the canvas")
        for (id, _, _, _) in ViewerWindowToolbar.optionalButtons {
            bar.toolbar.insertItem(withItemIdentifier: id, at: bar.toolbar.items.count)
        }
        bar.validate()
        return (window, bar)
    }

    /// The icon the » row shows: its menu form's image, or (with no menu
    /// form) the image AppKit copies from the item.
    private func rowImage(_ item: NSToolbarItem) -> NSImage? {
        item.menuFormRepresentation?.image ?? item.image
    }

    /// The state the » row shows when the menu opens: a fresh copy of
    /// the row, validated by its target the way AppKit does.
    private func stateWhenOpened(_ row: NSMenuItem) -> NSControl.StateValue {
        guard let copy = row.copy() as? NSMenuItem else { return .mixed }
        copy.state = .mixed
        _ = (copy.target as? NSMenuItemValidation)?.validateMenuItem(copy)
        return copy.state
    }

    // MARK: Viewer

    func testEveryViewerOverflowRowHasAnIcon() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        XCTAssertEqual(bar.toolbar.items.count,
                       ViewerWindowToolbar.defaultItems.count + ViewerWindowToolbar.optionalButtons.count)
        for item in bar.toolbar.items {
            let id = item.itemIdentifier
            // Spaces and the tracking separator never list; Share's row
            // comes from AppKit's own sharing item (it has its icon).
            if [.flexibleSpace, .space, .inspectorTrackingSeparator, ViewerWindowToolbar.ID.share].contains(id) { continue }
            XCTAssertNotNil(rowImage(item), "\(id.rawValue): the » row has no icon")
            for sub in item.menuFormRepresentation?.submenu?.items ?? [] where sub.action != nil {
                XCTAssertNotNil(sub.image, "\(id.rawValue) ▸ \(sub.title): no icon")
            }
        }
    }

    func testViewerGroupsListBothButtonsInTheirRow() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        let rotate = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.rotate)?.menuFormRepresentation?.submenu)
        XCTAssertEqual(rotate.items.compactMap(\.shrikeCommand), [.rotateLeft, .rotateRight])
        let nav = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.nav)?.menuFormRepresentation?.submenu)
        XCTAssertEqual(nav.items.compactMap(\.shrikeCommand), [.previousImage, .nextImage])
        // One photo: nothing to go to, so the rows are off (menu rule).
        for row in nav.items {
            XCTAssertEqual(bar.validateMenuItem(row), window.canPerform(try XCTUnwrap(row.shrikeCommand)))
        }
        XCTAssertTrue(bar.validateMenuItem(try XCTUnwrap(rotate.items.first)))
    }

    func testViewerTogglesShowACheckMarkWhileOn() async throws {
        let (window, bar) = try await makeViewer()
        defer { window.close() }
        let histogram = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.histogram)?.menuFormRepresentation)
        let filmstrip = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.filmstrip)?.menuFormRepresentation)
        let inspector = try XCTUnwrap(bar.item(ViewerWindowToolbar.ID.inspector)?.menuFormRepresentation)
        XCTAssertEqual(histogram.state, .off)
        XCTAssertEqual(stateWhenOpened(histogram), .off)
        XCTAssertEqual(stateWhenOpened(filmstrip), .off)
        XCTAssertEqual(stateWhenOpened(inspector), .off)

        window.dispatch(.toggleHistogram)
        window.dispatch(.toggleFilmstrip)
        // Before the next validation pass: the row asks when it opens.
        XCTAssertEqual(stateWhenOpened(histogram), .on)
        XCTAssertEqual(stateWhenOpened(filmstrip), .on)
        bar.validate()
        XCTAssertEqual(histogram.state, .on, "the stored row follows too")
        XCTAssertEqual(filmstrip.state, .on)
        XCTAssertEqual(inspector.state, .off)

        window.dispatch(.toggleInspector)
        bar.validate()
        XCTAssertEqual(inspector.state, .on)
        XCTAssertEqual(stateWhenOpened(inspector), .on)

        window.dispatch(.toggleHistogram)
        bar.validate()
        XCTAssertEqual(histogram.state, .off)
        XCTAssertEqual(stateWhenOpened(histogram), .off)
        window.dispatch(.toggleInspector)
    }

    // MARK: Browser

    private func browser(images: Int) async throws -> BrowserWindowController {
        for i in 0..<images { try writeJPEG(String(format: "IMG_%04d.jpg", i)) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        browser.window?.toolbar?.autosavesConfiguration = false
        let ok = await waitUntil { browser.contentController.allItems.count == images }
        XCTAssertTrue(ok, "the folder lists")
        return browser
    }

    func testEveryBrowserOverflowRowHasAnIcon() async throws {
        let browser = try await browser(images: 2)
        defer { browser.close() }
        let toolbar = try XCTUnwrap(browser.window?.toolbar)
        toolbar.insertItem(withItemIdentifier: BrowserToolbarID.openInViewer, at: toolbar.items.count)
        for item in toolbar.items {
            let id = item.itemIdentifier
            // System items and the search field (it shrinks to a button of
            // its own; it never lists in ») are AppKit's.
            if [.flexibleSpace, .space, .sidebarTrackingSeparator, .inspectorTrackingSeparator,
                .toggleSidebar, BrowserToolbarID.search].contains(id) { continue }
            XCTAssertNotNil(rowImage(item), "\(id.rawValue): the » row has no icon")
            // A group's submenu lists its buttons, each with its glyph
            // (Sort's submenu is the Sort By list, text only like the menu).
            guard item is NSToolbarItemGroup else { continue }
            for sub in item.menuFormRepresentation?.submenu?.items ?? [] where sub.shrikeCommand != nil {
                XCTAssertNotNil(sub.image, "\(id.rawValue) ▸ \(sub.title): no icon")
            }
        }
    }

    func testBrowserRowsCheckTheCurrentModeSortAndInspector() async throws {
        let browser = try await browser(images: 2)
        defer { browser.close() }
        let view = try XCTUnwrap(browser.viewModeGroup?.menuFormRepresentation?.submenu)
        XCTAssertEqual(view.items.compactMap(\.shrikeCommand), [.viewAsGrid, .viewAsFilmstrip, .viewAsList])
        browser.setMode(.list)
        XCTAssertEqual(view.items.map(stateWhenOpened), [.off, .off, .on])
        browser.setMode(.grid)
        XCTAssertEqual(view.items.map(stateWhenOpened), [.on, .off, .off])

        let sort = try XCTUnwrap(browser.sortToolbarItem?.menuFormRepresentation)
        XCTAssertNotNil(sort.image)
        let sortRows = try XCTUnwrap(sort.submenu?.items)
        XCTAssertFalse(sortRows.isEmpty)
        let checked = sortRows.filter { stateWhenOpened($0) == .on }.map(\.title)
        XCTAssertEqual(checked.count, 2, "one sort key and one direction: \(checked)")

        let back = try XCTUnwrap(browser.historyGroup?.menuFormRepresentation?.submenu)
        XCTAssertEqual(back.items.compactMap(\.shrikeCommand), [.back, .forward])
        XCTAssertFalse(browser.validateMenuItem(back.items[0]), "no history yet")

        let inspectorItem = try XCTUnwrap(browser.window?.toolbar?.items.first { $0.itemIdentifier == BrowserToolbarID.inspector })
        let inspector = try XCTUnwrap(inspectorItem.menuFormRepresentation)
        let split = browser.splitController.splitViewItems
        let shown = !(split.last?.isCollapsed ?? true)
        XCTAssertEqual(stateWhenOpened(inspector), shown ? .on : .off)
        split.last?.isCollapsed = shown
        XCTAssertEqual(stateWhenOpened(inspector), shown ? .off : .on)
        split.last?.isCollapsed = !shown
    }

    func testBrowserFilterRowShowsTheFilterGlyph() async throws {
        let browser = try await browser(images: 2)
        defer { browser.close() }
        let filter = try XCTUnwrap(browser.filterToolbarItem?.menuFormRepresentation)
        XCTAssertNotNil(filter.image)
        XCTAssertTrue(filter.image === browser.filterButton.image, "the same glyph as the button")
    }
}

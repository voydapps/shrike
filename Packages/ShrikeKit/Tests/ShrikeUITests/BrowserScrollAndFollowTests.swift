//
//  BrowserScrollAndFollowTests.swift
//  ShrikeUITests
//
//  User tests 2026-10-10: (3) a viewer's delete must leave the Browser's
//  views at once (Shrike's own trash is ignored by the folder watcher);
//  (4) the Browser filmstrip centres the selected cell; (5) one mouse
//  wheel notch moves the grid by a third of a row, scaled with the
//  thumbnail size.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ShrikeRendering
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserScrollAndFollowTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var fakeTrash: URL!
    private var savedReduceMotion: Bool?
    private var savedFollowSchedule: TrailingDebouncer.Schedule?

    override func setUp() async throws {
        savedReduceMotion = ReduceMotion.overrideForTesting
        // Hidden test windows do not service NSClipView's scroll animator.
        // Assert final scroll geometry here; native QA covers normal motion.
        ReduceMotion.overrideForTesting = true
        // The paired viewer's "Browser follows the viewer" runs 150 ms after a photo change on
        // the real clock; the delete tests assert the selection the delete leaves, and on a slow
        // runner the follow can fire between the awaits of a mode loop. The follow itself:
        // BrowserFollowsViewerTests.
        savedFollowSchedule = ViewerWindow.browserFollowSchedule
        ViewerWindow.browserFollowSchedule = { _, _ in {} }
        root = TestScratch.directory
            .appendingPathComponent("shrike-bscroll-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Folder", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ReduceMotion.overrideForTesting = savedReduceMotion
        if let savedFollowSchedule { ViewerWindow.browserFollowSchedule = savedFollowSchedule }
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func makeBrowser(count: Int) async throws -> BrowserWindowController {
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i)) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists")
        browser.window?.setContentSize(NSSize(width: 1000, height: 700))
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    private func fakeOps() -> FileOps {
        let trash = fakeTrash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
    }

    // MARK: 3 - a viewer's delete reaches the Browser

    func testViewerDeleteDropsTheItemFromEveryBrowserView_undoBringsItBack() async throws {
        let browser = try await makeBrowser(count: 6)
        defer { browser.close() }
        let content = browser.contentController
        let urls = content.visibleItems.map(\.url)
        let viewer = ViewerWindow(groups: content.visibleItems.map(\.group), startIndex: 2,
                                  services: ShrikeServices.makeDefault())
        viewer.fileOps = fakeOps()
        viewer.pairedBrowser = browser
        defer { viewer.close() }
        viewer.markDisplayedForTesting(2)
        _ = content.select(url: urls[4])

        for mode in [BrowserViewMode.grid, .filmstrip, .list] {
            content.setMode(mode)
            viewer.markDisplayedForTesting(2)
            viewer.dispatch(.deleteToTrash)                       // p002
            // At once, in the same turn: no waiting for a re-list.
            XCTAssertEqual(content.visibleItems.count, 5, "\(mode)")
            XCTAssertFalse(content.visibleItems.contains { $0.url == urls[2] }, "\(mode)")
            switch mode {
            case .grid, .filmstrip:
                XCTAssertEqual(content.collectionViewForTesting.numberOfItems(inSection: 0), 5, "\(mode)")
            case .list:
                XCTAssertEqual(content.tableViewForTesting.numberOfRows, 5)
            }
            XCTAssertEqual(content.selectedItems.map(\.url), [urls[4]], "selection not in the removed set is kept")
            await viewer.waitForPendingTrash()

            viewer.performUndo()
            let back = await waitUntil { content.visibleItems.count == 6 && viewer.groups.count == 6 }
            XCTAssertTrue(back, "undo in \(mode)")
        }
    }

    func testViewerDeleteOfTheSelectedItemSelectsTheNextOne() async throws {
        let browser = try await makeBrowser(count: 5)
        defer { browser.close() }
        let content = browser.contentController
        let urls = content.visibleItems.map(\.url)
        let viewer = ViewerWindow(groups: content.visibleItems.map(\.group), startIndex: 1,
                                  services: ShrikeServices.makeDefault())
        viewer.fileOps = fakeOps()
        viewer.pairedBrowser = browser
        defer { viewer.close() }
        _ = content.select(url: urls[1])
        viewer.markDisplayedForTesting(1)
        viewer.dispatch(.deleteToTrash)
        XCTAssertEqual(content.selectedItems.map(\.url), [urls[2]])
        await viewer.waitForPendingTrash()
    }

    // MARK: 4 - the Browser filmstrip centres the selection

    func testFilmstripScrollsToCentreTheSelectedCell() async throws {
        let browser = try await makeBrowser(count: 60)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let scroll = content.gridScrollViewForTesting
        let items = content.visibleItems

        func assertCentred(_ index: Int, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
            let cv = content.collectionViewForTesting
            let frame = cv.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.frame
            let ok = await waitUntil {
                let visible = scroll.contentView.bounds
                return visible.contains(frame) && abs(visible.midX - frame.midX) < 2
            }
            XCTAssertTrue(ok, "\(what): visible \(scroll.contentView.bounds), cell \(frame)", file: file, line: line)
        }

        _ = content.select(url: items[50].url)                     // far off screen
        await assertCentred(50, "select far item")

        content.moveSelection(-1)                                  // arrow key path
        await assertCentred(49, "move selection")

        // A click-style change (selection set, then reported).
        content.collectionViewForTesting.selectionIndexPaths = [IndexPath(item: 10, section: 0)]
        content.collectionViewForTesting.delegate?.collectionView?(
            content.collectionViewForTesting, didSelectItemsAt: [IndexPath(item: 10, section: 0)])
        await assertCentred(10, "click near the edge")
    }

    // MARK: 6 - extending the selection keeps the moving end in view

    private static func shiftKey(_ keyCode: UInt16) -> NSEvent {
        let chars: String
        switch keyCode {
        case 123: chars = "\u{F702}"
        case 124: chars = "\u{F703}"
        case 126: chars = "\u{F700}"
        default: chars = "\u{F701}"
        }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode)!
    }

    func testFilmstripShiftRightFollowsTheMovingEnd() async throws {
        let browser = try await makeBrowser(count: 60)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cv = content.collectionViewForTesting
        let scroll = content.gridScrollViewForTesting
        _ = content.select(url: content.visibleItems[0].url)
        for _ in 0..<15 { cv.keyDown(with: Self.shiftKey(124)) }
        XCTAssertEqual(cv.selectionIndexPaths.count, 16)
        let frame = cv.layoutAttributesForItem(at: IndexPath(item: 15, section: 0))!.frame
        let ok = await waitUntil {
            let v = scroll.contentView.bounds
            return v.contains(frame) && abs(v.midX - frame.midX) < 2
        }
        XCTAssertTrue(ok, "visible \(scroll.contentView.bounds), lead cell \(frame)")

        // Back the other way: the removed end is the moving end.
        for _ in 0..<10 { cv.keyDown(with: Self.shiftKey(123)) }
        let back = cv.layoutAttributesForItem(at: IndexPath(item: 5, section: 0))!.frame
        let ok2 = await waitUntil {
            let v = scroll.contentView.bounds
            return v.contains(back) && abs(v.midX - back.midX) < 2
        }
        XCTAssertTrue(ok2, "visible \(scroll.contentView.bounds), lead cell \(back)")
    }

    func testFilmstripShiftClickFarAwayFollows() async throws {
        let browser = try await makeBrowser(count: 60)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cv = content.collectionViewForTesting
        let scroll = content.gridScrollViewForTesting
        _ = content.select(url: content.visibleItems[0].url)
        cv.extendSelection(to: IndexPath(item: 40, section: 0))
        let frame = cv.layoutAttributesForItem(at: IndexPath(item: 40, section: 0))!.frame
        let ok = await waitUntil { scroll.contentView.bounds.contains(frame) }
        XCTAssertTrue(ok, "visible \(scroll.contentView.bounds), clicked cell \(frame)")
    }

    func testGridShiftDownFollowsTheMovingEnd() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.grid)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cv = content.collectionViewForTesting
        let scroll = content.gridScrollViewForTesting
        _ = content.select(url: content.visibleItems[0].url)
        for _ in 0..<15 { cv.keyDown(with: Self.shiftKey(125)) }
        let lead = try XCTUnwrap(cv.keyRange?.lead)
        XCTAssertGreaterThan(lead.item, 15)
        let frame = cv.layoutAttributesForItem(at: lead)!.frame
        let ok = await waitUntil { scroll.contentView.bounds.contains(frame) }
        XCTAssertTrue(ok, "visible \(scroll.contentView.bounds), lead cell \(frame)")
        for _ in 0..<12 { cv.keyDown(with: Self.shiftKey(126)) }
        let lead2 = try XCTUnwrap(cv.keyRange?.lead)
        let frame2 = cv.layoutAttributesForItem(at: lead2)!.frame
        let ok2 = await waitUntil { scroll.contentView.bounds.contains(frame2) }
        XCTAssertTrue(ok2, "visible \(scroll.contentView.bounds), lead cell \(frame2)")
    }

    // MARK: pass 2zc - a thumbnail size change keeps the selected photo in view

    /// A grid at 100 pt with the top at y = 0; returns the last item whose
    /// cell is fully on screen.
    private func gridAtSmallSize(_ browser: BrowserWindowController) -> Int {
        let content = browser.contentController
        content.setMode(.grid)
        content.thumbnailPixelSize = 100
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cv = content.collectionViewForTesting
        let scroll = content.gridScrollViewForTesting
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let visible = scroll.contentView.bounds
        return (0..<content.visibleItems.count).last {
            visible.contains(cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))!.frame)
        } ?? 0
    }

    func testLargerThumbnailsKeepAVisibleSelectionInView() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let last = gridAtSmallSize(browser)
        XCTAssertGreaterThan(last, 10)
        let cv = content.collectionViewForTesting
        let scroll = content.gridScrollViewForTesting
        cv.selectionIndexPaths = [IndexPath(item: last, section: 0)]
        content.thumbnailPixelSize = 300
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let frame = cv.layoutAttributesForItem(at: IndexPath(item: last, section: 0))!.frame
        XCTAssertTrue(scroll.contentView.bounds.intersects(frame),
                      "visible \(scroll.contentView.bounds), selected cell \(frame)")
    }

    // MARK: pass 3b - a size change with the selection out of view keeps the top row

    private func frames(_ content: BrowserContentViewController) -> [CGRect] {
        let cv = content.collectionViewForTesting
        return (0..<content.visibleItems.count).map { cv.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))!.frame }
    }

    /// Worked out from the frames alone (not through the production picker):
    /// the lowest index of the first row showing at least a third of its height.
    private func expectedTopItem(_ content: BrowserContentViewController) -> Int? {
        let visible = content.gridScrollViewForTesting.contentView.bounds
        let all = frames(content)
        guard let row = all.first(where: {
            min($0.maxY, visible.maxY) - max($0.minY, visible.minY) >= $0.height / 3
        }) else { return nil }
        return all.firstIndex { abs($0.minY - row.minY) < 0.5 }
    }

    private func columns(_ content: BrowserContentViewController) -> Int {
        let all = frames(content)
        return all.filter { abs($0.minY - all[0].minY) < 0.5 }.count
    }

    private func scrollGrid(_ content: BrowserContentViewController, to y: CGFloat) {
        let scroll = content.gridScrollViewForTesting
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func topEdge(_ content: BrowserContentViewController, of item: Int) -> (item: CGFloat, origin: CGFloat) {
        (frames(content)[item].minY, content.gridScrollViewForTesting.contentView.bounds.origin.y)
    }

    private func setSize(_ browser: BrowserWindowController, _ size: Int) {
        browser.contentController.thumbnailPixelSize = size
        browser.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// Grid at 100 pt, scrolled so row 5 is the top row; returns that row's first item.
    private func gridScrolledToRow5(_ browser: BrowserWindowController) -> Int {
        let content = browser.contentController
        _ = gridAtSmallSize(browser)
        let first = 5 * columns(content)
        scrollGrid(content, to: frames(content)[first].minY)
        return first
    }

    func testLargerThumbnailsKeepTheTopRowWhenTheSelectionIsOffScreen() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let anchor = gridScrolledToRow5(browser)
        content.collectionViewForTesting.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        XCTAssertFalse(content.gridScrollViewForTesting.contentView.bounds.intersects(frames(content)[0]))
        XCTAssertEqual(expectedTopItem(content), anchor)
        setSize(browser, 140)
        let edge = topEdge(content, of: anchor)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5, "the anchor photo is at the top")
        XCTAssertEqual(content.collectionViewForTesting.selectionIndexPaths, [IndexPath(item: 0, section: 0)], "selection untouched")
    }

    func testLargerThumbnailsKeepTheTopRowWithNoSelection() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let anchor = gridScrolledToRow5(browser)
        content.collectionViewForTesting.selectionIndexPaths = []
        setSize(browser, 140)
        let edge = topEdge(content, of: anchor)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5)
        XCTAssertTrue(content.collectionViewForTesting.selectionIndexPaths.isEmpty, "nothing gets selected")
    }

    func testARowShowingLessThanAThirdDoesNotCountAsTheTopRow() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let row5 = gridScrolledToRow5(browser)
        let cols = columns(content)
        let f = frames(content)[row5]
        scrollGrid(content, to: f.minY + f.height - 20)   // 20 pt of row 5 shows
        content.collectionViewForTesting.selectionIndexPaths = []
        XCTAssertEqual(expectedTopItem(content), row5 + cols, "the next row is the top row")
        setSize(browser, 140)
        let edge = topEdge(content, of: row5 + cols)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5)
    }

    func testLargerThenSmallerReturnsToTheSameTopPhoto() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let anchor = gridScrolledToRow5(browser)
        content.collectionViewForTesting.selectionIndexPaths = []
        setSize(browser, 140)
        // Precondition: at 140 pt the anchor is NOT first in its row, so
        // picking afresh would give another photo.
        XCTAssertNotEqual(anchor % columns(content), 0, "anchor \(anchor), \(columns(content)) columns")
        setSize(browser, 100)
        let edge = topEdge(content, of: anchor)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5, "the same photo is at the top again")
    }

    func testAScrollBetweenTwoSizeStepsPicksANewAnchor() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let anchor = gridScrolledToRow5(browser)
        content.collectionViewForTesting.selectionIndexPaths = []
        setSize(browser, 140)
        scrollGrid(content, to: content.gridScrollViewForTesting.contentView.bounds.origin.y + 700)   // the user scrolls
        let expected = try XCTUnwrap(expectedTopItem(content))
        XCTAssertNotEqual(expected, anchor)
        setSize(browser, 100)
        let edge = topEdge(content, of: expected)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5, "the photo that was on top after the scroll")
    }

    func testAFolderChangeForgetsTheAnchor() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        let anchor = gridScrolledToRow5(browser)
        content.collectionViewForTesting.selectionIndexPaths = []
        setSize(browser, 140)
        content.setItems(content.allItems)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        content.collectionViewForTesting.selectionIndexPaths = []
        let expected = try XCTUnwrap(expectedTopItem(content))
        XCTAssertNotEqual(expected, anchor, "a fresh pick differs from the old anchor here")
        setSize(browser, 100)
        let edge = topEdge(content, of: expected)
        XCTAssertEqual(edge.origin, edge.item, accuracy: 0.5)
    }

    func testLargerThumbnailsNearTheEndClampToTheContent() async throws {
        let browser = try await makeBrowser(count: 120)
        defer { browser.close() }
        let content = browser.contentController
        _ = gridAtSmallSize(browser)
        content.collectionViewForTesting.selectionIndexPaths = []
        let scroll = content.gridScrollViewForTesting
        scrollGrid(content, to: 1_000_000)   // clamps to the end
        setSize(browser, 140)
        let docHeight = content.collectionViewForTesting.frame.height
        let y = scroll.contentView.bounds.origin.y
        XCTAssertLessThanOrEqual(y, docHeight - scroll.contentView.bounds.height + 0.5)
        XCTAssertGreaterThanOrEqual(y, 0)
    }

    func testLargerThumbnailsInAnEmptyFolderDoNothing() async throws {
        let browser = try await makeBrowser(count: 0)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.grid)
        setSize(browser, 140)
        XCTAssertEqual(content.gridScrollViewForTesting.contentView.bounds.origin.y, 0, accuracy: 0.5)
    }

    func testListShiftDownFollowsTheMovingEnd() async throws {
        let browser = try await makeBrowser(count: 80)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.list)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let table = content.tableViewForTesting
        _ = content.select(url: content.visibleItems[0].url)
        for _ in 0..<40 { table.keyDown(with: Self.shiftKey(125)) }
        let last = table.selectedRowIndexes.max() ?? 0
        XCTAssertEqual(last, 40)
        let rect = table.rect(ofRow: last)
        let ok = await waitUntil { table.visibleRect.minY <= rect.minY && table.visibleRect.maxY >= rect.maxY }
        XCTAssertTrue(ok, "visible \(table.visibleRect), row \(rect)")
    }

    // MARK: 5 - a wheel notch moves a third of a row

    func testWheelStepIsAThirdOfARowAtTwoThumbnailSizes() async throws {
        let browser = try await makeBrowser(count: 40)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.grid)
        let scroll = content.gridScrollViewForTesting
        for size in [100, 200] {
            content.thumbnailPixelSize = size
            browser.window?.contentView?.layoutSubtreeIfNeeded()
            let row = CGFloat(size + 40 + 16)
            XCTAssertEqual(scroll.verticalLineScroll, (row / 3).rounded(), accuracy: 0.5, "size \(size)")
            XCTAssertGreaterThan(scroll.verticalLineScroll, 10, "was AppKit's 10 pt default")

            // A real non-precise wheel event through the scroll view.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                             wheel1: -1, wheel2: 0, wheel3: 0)!
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            XCTAssertFalse(event.hasPreciseScrollingDeltas)
            scroll.scrollWheel(with: event)
            let moved = scroll.contentView.bounds.origin.y
            XCTAssertEqual(moved, scroll.verticalLineScroll, accuracy: 1, "one notch at size \(size)")
        }
    }

    func testListKeepsItsDefaultLineScroll() async throws {
        let browser = try await makeBrowser(count: 10)
        defer { browser.close() }
        let content = browser.contentController
        let before = content.tableViewForTesting.enclosingScrollView?.verticalLineScroll
        content.setMode(.list)
        XCTAssertEqual(content.tableViewForTesting.enclosingScrollView?.verticalLineScroll, before)
        XCTAssertEqual(BrowserContentViewController.wheelStep(mode: .list, thumbnailSize: 150, rowHeight: 28),
                       28.0 / 3, accuracy: 0.01)
    }
}

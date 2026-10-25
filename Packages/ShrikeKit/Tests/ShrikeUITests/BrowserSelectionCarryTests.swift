//
//  BrowserSelectionCarryTests.swift
//  ShrikeUITests
//
//  The Browser's selection:
//  * Grid ↔ List carries the selection, its anchor and
//    the keys into the other view, so Compare acts on what is shown;
//  * a plain click on a photo inside a multi-selection
//    selects just that photo on mouse-up; a drag still drags them all;
//  * ⇧→ after a rating or Q grows the selection.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class BrowserSelectionCarryTests: XCTestCase {

    private var dir: URL!
    private var savedMotion: Bool?

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-selection-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CompareWindow.presentsWindows = false
        // The filmstrip centres the ⇧-clicked photo with a 0.12 s animated
        // scroll. That animation kept running while the next test click
        // scrolled the strip, and snapped it back: the click then hit no
        // cell (6 of 20 runs). Reduce Motion makes the scroll immediate.
        savedMotion = ReduceMotion.overrideForTesting
        ReduceMotion.overrideForTesting = true
    }

    override func tearDown() async throws {
        ReduceMotion.overrideForTesting = savedMotion
        CompareWindow.current?.close()
        CompareWindow.presentsWindows = true
        clearCurrentEvent()
        await CullingUndo.waitForPendingWrites()
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    // MARK: Helpers

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
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

    private func browser(count: Int) async throws -> BrowserWindowController {
        for i in 0..<count { try writeJPEG(String(format: "p%02d.jpg", i)) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == count }
        XCTAssertTrue(listed)
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    private func ip(_ i: Int) -> IndexPath { IndexPath(item: i, section: 0) }
    private func items(_ set: Set<IndexPath>) -> [Int] { set.map(\.item).sorted() }
    private func names(_ browser: BrowserWindowController) -> [String] {
        browser.contentController.selectedItems.map(\.url.lastPathComponent).sorted()
    }

    /// The photos Compare opened with, by file name.
    private func compareNames() -> [String]? {
        guard let compare = CompareWindow.current else { return nil }
        return compare.panes.map { compare.list[$0.index].primary.lastPathComponent }.sorted()
    }

    // MARK: Grid ↔ List keeps one selection

    func testGridToListAndBackKeepsTheSelectionAnchorAndKeysAndCompareUsesIt() async throws {
        let browser = try await browser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        let grid = content.collectionViewForTesting
        let table = content.tableViewForTesting
        let window = try XCTUnwrap(browser.window)
        XCTAssertTrue(window.makeFirstResponder(grid))
        // Click p02, shift-click p04.
        grid.selectionIndexPaths = [ip(2)]
        grid.noteClick(on: ip(2), command: false)
        grid.extendSelection(to: ip(4))
        XCTAssertEqual(names(browser), ["p02.jpg", "p03.jpg", "p04.jpg"])
        let publishes = browser.inspectorForTesting.publishCount

        // View ▸ as List.
        browser.perform(.viewAsList)
        XCTAssertEqual(content.mode, .list)
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([2, 3, 4]), "the list shows the same three rows")
        XCTAssertEqual(names(browser), ["p02.jpg", "p03.jpg", "p04.jpg"])
        XCTAssertTrue(window.firstResponder === table, "the list takes the keys")
        XCTAssertEqual(content.selectionAnchorURL?.lastPathComponent, "p02.jpg")
        XCTAssertEqual(browser.inspectorStateForTesting.count, 3)
        XCTAssertEqual(browser.inspectorForTesting.publishCount, publishes, "the same selection: no new inspector publish")
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: 2)), "the first selected row is in view")

        // Compare opens with those three.
        browser.perform(.compare)
        XCTAssertEqual(compareNames(), ["p02.jpg", "p03.jpg", "p04.jpg"])
        CompareWindow.current?.close()

        // Back to the grid: the same three, the same anchor, the keys.
        window.makeFirstResponder(table)
        browser.perform(.viewAsGrid)
        XCTAssertEqual(content.mode, .grid)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4])
        XCTAssertEqual(grid.selectionAnchor, ip(2), "the shift-click anchor stays")
        XCTAssertTrue(window.firstResponder === grid)
        // A shift-click still ranges from the anchor.
        grid.extendSelection(to: ip(5))
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5])
        browser.perform(.compare)
        XCTAssertEqual(compareNames(), ["p02.jpg", "p03.jpg", "p04.jpg", "p05.jpg"])
        CompareWindow.current?.close()

        // A selection made in the list comes back to the grid too.
        browser.perform(.viewAsList)
        table.selectRowIndexes(IndexSet([0, 6]), byExtendingSelection: false)
        XCTAssertEqual(names(browser), ["p00.jpg", "p06.jpg"])
        browser.perform(.viewAsFilmstrip)
        XCTAssertEqual(items(grid.selectionIndexPaths), [0, 6])
        browser.perform(.viewAsGrid)
        XCTAssertEqual(items(grid.selectionIndexPaths), [0, 6], "filmstrip → grid keeps it too")
        browser.perform(.compare)
        XCTAssertEqual(compareNames(), ["p00.jpg", "p06.jpg"])
    }

    func testAnEmptySelectionStaysEmptyAcrossTheSwitch() async throws {
        let browser = try await browser(count: 3)
        defer { browser.close() }
        let content = browser.contentController
        content.deselectAll()
        browser.perform(.viewAsList)
        XCTAssertEqual(content.tableViewForTesting.selectedRowIndexes.count, 0)
        browser.perform(.viewAsGrid)
        XCTAssertEqual(content.collectionViewForTesting.selectionIndexPaths.count, 0)
        XCTAssertEqual(browser.inspectorStateForTesting.count, 0)
    }

    // MARK: A plain click inside a multi-selection

    private func mouse(_ type: NSEvent.EventType, at item: Int, in grid: BrowserCollectionView,
                       mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let frame = try XCTUnwrap(grid.layoutAttributesForItem(at: ip(item))?.frame)
        let point = grid.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: grid.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func drainMouseEvents() {
        while NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged],
                              until: .distantPast, inMode: .default, dequeue: true) != nil {}
    }

    /// A dequeued mouse-up stays `NSApp.currentEvent` until the next event;
    /// later code reads it (the colour sliders end a drag on a mouse-up),
    /// so a harmless event takes its place.
    private func clearCurrentEvent() {
        guard let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: true)
        _ = NSApp.nextEvent(matching: .applicationDefined, until: .distantPast, inMode: .default, dequeue: true)
    }

    /// A press and release on `item`. The mouse-up waits in the queue:
    /// AppKit's own press tracking takes it, else the window would send
    /// it to the grid (done here).
    private func click(_ item: Int, in grid: BrowserCollectionView, mods: NSEvent.ModifierFlags = []) throws {
        // A click can only target a cell in the filmstrip's visible
        // horizontal viewport. Hosted runners are narrower than the local
        // development monitor, so reveal each test target before clicking.
        let position: NSCollectionView.ScrollPosition =
            (grid.collectionViewLayout as? NSCollectionViewFlowLayout)?.scrollDirection == .horizontal
                ? .centeredHorizontally : .centeredVertically
        grid.scrollToItems(at: [ip(item)], scrollPosition: position)
        grid.layoutSubtreeIfNeeded()
        drainMouseEvents()
        grid.window?.postEvent(try mouse(.leftMouseUp, at: item, in: grid, mods: mods), atStart: false)
        grid.mouseDown(with: try mouse(.leftMouseDown, at: item, in: grid, mods: mods))
        if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            grid.mouseUp(with: up)
        }
        drainMouseEvents()
        clearCurrentEvent()
    }

    func testAPlainClickInsideAMultiSelectionSelectsJustThatPhotoOnMouseUp() async throws {
        let browser = try await browser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        let grid = content.collectionViewForTesting
        let window = try XCTUnwrap(browser.window)
        XCTAssertTrue(window.makeFirstResponder(grid))
        func selectTwoToFour() {
            grid.selectionIndexPaths = [ip(2)]
            grid.noteClick(on: ip(2), command: false)
            grid.extendSelection(to: ip(4))
            XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4])
        }

        // Click p03 (selected, with p02 and p04): p03 alone on mouse-up.
        selectTwoToFour()
        try click(3, in: grid)
        XCTAssertEqual(items(grid.selectionIndexPaths), [3], "select one")
        XCTAssertEqual(grid.selectionAnchor, ip(3), "the click moves the anchor")
        XCTAssertEqual(names(browser), ["p03.jpg"])
        let heard = await waitUntil { browser.inspectorStateForTesting.count == 1 }
        XCTAssertTrue(heard, "the inspector hears it")
        // A shift-click then ranges from the clicked photo.
        grid.extendSelection(to: ip(5))
        XCTAssertEqual(items(grid.selectionIndexPaths), [3, 4, 5])

        // A drag of the selection keeps all of them: AppKit asks the
        // Browser whether the items can be dragged when the drag starts.
        selectTwoToFour()
        grid.mouseTrackingForTesting = { [unowned grid, unowned content] event in
            XCTAssertTrue(content.collectionView(grid, canDragItemsAt: grid.selectionIndexPaths, with: event))
        }
        grid.mouseDown(with: try mouse(.leftMouseDown, at: 3, in: grid))
        grid.mouseUp(with: try mouse(.leftMouseUp, at: 3, in: grid))
        grid.mouseTrackingForTesting = nil
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4], "the drag takes all three")
        let three = await waitUntil { browser.inspectorStateForTesting.count == 3 }
        XCTAssertTrue(three)

        // AppKit returned at once (no tracking loop): the mouse-up narrows.
        selectTwoToFour()
        grid.mouseTrackingForTesting = { _ in }
        grid.mouseDown(with: try mouse(.leftMouseDown, at: 4, in: grid))
        grid.mouseUp(with: try mouse(.leftMouseUp, at: 4, in: grid))
        grid.mouseTrackingForTesting = nil
        XCTAssertEqual(items(grid.selectionIndexPaths), [4])

        // Shift-click on a selected photo ranges; it never narrows.
        selectTwoToFour()
        try click(3, in: grid, mods: .shift)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3])

        // A click on the only selected photo changes nothing.
        grid.selectionIndexPaths = [ip(6)]
        grid.noteClick(on: ip(6), command: false)
        try click(6, in: grid)
        XCTAssertEqual(items(grid.selectionIndexPaths), [6])
    }

    // MARK: Plain, ⌘ and ⇧ clicks in every view

    func testPlainCommandAndShiftClicksInGridAndFilmstrip() async throws {
        let browser = try await browser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        let grid = content.collectionViewForTesting
        let window = try XCTUnwrap(browser.window)
        for command in [ShrikeCommand.viewAsGrid, .viewAsFilmstrip] {
            browser.perform(command)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertTrue(window.makeFirstResponder(grid))
            let label = "\(command)"
            grid.selectionIndexPaths = []
            // Plain clicks on three different photos: one selected each time.
            for item in [1, 2, 4] {
                try click(item, in: grid)
                XCTAssertEqual(items(grid.selectionIndexPaths), [item], "\(label): plain click selects only it")
                XCTAssertEqual(names(browser).count, 1, label)
            }
            // A plain click on an unselected photo while a range is selected.
            grid.selectionIndexPaths = [ip(2), ip(3)]
            grid.noteClick(on: ip(2), command: false)
            try click(4, in: grid)
            XCTAssertEqual(items(grid.selectionIndexPaths), [4], "\(label): replaces a multi-selection")
            // ⌘-click toggles.
            try click(1, in: grid, mods: .command)
            XCTAssertEqual(items(grid.selectionIndexPaths), [1, 4], "\(label): ⌘ adds")
            try click(4, in: grid, mods: .command)
            XCTAssertEqual(items(grid.selectionIndexPaths), [1], "\(label): ⌘ removes")
            // ⇧-click extends from the last clicked photo.
            try click(2, in: grid)
            try click(4, in: grid, mods: .shift)
            XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4], "\(label): ⇧ ranges")
            // A plain click afterwards starts over.
            try click(0, in: grid)
            XCTAssertEqual(items(grid.selectionIndexPaths), [0], "\(label): plain click after a range")
        }
    }

    // MARK: ⇧→ after a rating or Q

    private static func key(_ chars: String, keyCode: UInt16, mods: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    private static let shiftRight = key("\u{F703}", keyCode: 124, mods: [.shift, .numericPad, .function])
    private static let shiftLeft = key("\u{F702}", keyCode: 123, mods: [.shift, .numericPad, .function])
    private static let right = key("\u{F703}", keyCode: 124, mods: [.numericPad, .function])
    private static let q = key("q", keyCode: 12)
    private static let three = key("3", keyCode: 20)

    /// A selection changed while a re-list is still on its way (a rating,
    /// then a click or ⇧→ before the folder is listed again) is kept; the
    /// copy taken when the re-list started must not win.
    func testSelectionChangedDuringAReListSurvivesIt() async throws {
        let browser = try await browser(count: 10)
        defer { browser.close() }
        let content = browser.contentController
        let grid = content.collectionViewForTesting
        grid.selectionIndexPaths = [ip(2), ip(3)]
        grid.noteClick(on: ip(2), command: false)
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        browser.reloadCurrentFolder()
        // Before the listing lands:
        grid.selectionIndexPaths = [ip(7)]
        grid.noteClick(on: ip(7), command: false)
        let relisted = await waitUntil { hydrated }
        XCTAssertTrue(relisted)
        XCTAssertEqual(items(grid.selectionIndexPaths), [7], "the newer selection wins over the one from the start of the re-list")
    }

    func testShiftRightAfterARatingOrQGrowsTheSelection() async throws {
        let browser = try await browser(count: 10)
        defer { browser.close() }
        let grid = browser.contentController.collectionViewForTesting
        let window = try XCTUnwrap(browser.window)
        XCTAssertTrue(window.makeFirstResponder(grid))

        // Click p02, ⇧→ ⇧→: p02–p04.
        try click(2, in: grid)
        grid.selectionIndexPaths = [ip(2)]
        grid.noteClick(on: ip(2), command: false)
        grid.keyDown(with: Self.shiftRight)
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4])

        // A rating, then ⇧→ adds p05.
        grid.keyDown(with: Self.three)
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4])
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5], "⇧→ after a rating grows the selection")

        // Q, then ⇧→ adds p06; ⇧← takes it back.
        grid.keyDown(with: Self.q)
        await CullingUndo.waitForPendingWrites()
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5, 6], "⇧→ after Q grows the selection")
        grid.keyDown(with: Self.shiftLeft)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5])

        // The folder listed again (an outside change): the same items stay
        // selected, and ⇧→ still grows from the same end.
        // (Wait for the listing itself: the selection already reads
        // [2, 3, 4, 5] before it lands, so that alone proves nothing.)
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        browser.reloadCurrentFolder()
        let relisted = await waitUntil { hydrated }
        XCTAssertTrue(relisted)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5], "the re-list keeps the selection")
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5, 6], "⇧→ after a re-list grows the selection")

        // A rating made in Compare (four photos), then ⇧→.
        grid.keyDown(with: Self.shiftLeft)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5])
        browser.perform(.compare)
        XCTAssertEqual(compareNames(), ["p02.jpg", "p03.jpg", "p04.jpg", "p05.jpg"])
        let compare = try XCTUnwrap(CompareWindow.current)
        compare.focus(0)
        compare.keyDown(with: Self.three)
        await compare.waitForCullingWrites()
        compare.close()
        window.makeFirstResponder(grid)
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [2, 3, 4, 5, 6], "⇧→ after a rating in Compare")

        // A range made leftwards grows leftwards.
        grid.selectionIndexPaths = [ip(7)]
        grid.noteClick(on: ip(7), command: false)
        grid.keyDown(with: Self.shiftLeft)
        grid.keyDown(with: Self.shiftLeft)
        XCTAssertEqual(items(grid.selectionIndexPaths), [5, 6, 7])
        grid.keyDown(with: Self.three)
        await CullingUndo.waitForPendingWrites()
        grid.keyDown(with: Self.shiftLeft)
        XCTAssertEqual(items(grid.selectionIndexPaths), [4, 5, 6, 7])
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [5, 6, 7], "⇧→ shrinks a leftward range from its start")

        // A plain → after a range starts again from one photo.
        grid.keyDown(with: Self.right)
        XCTAssertEqual(grid.selectionIndexPaths.count, 1)
        let one = try XCTUnwrap(grid.selectionIndexPaths.first?.item)
        grid.keyDown(with: Self.shiftRight)
        XCTAssertEqual(items(grid.selectionIndexPaths), [one, one + 1])

        // ⇧↓ adds a row, ⇧↑ takes it back.
        grid.layoutSubtreeIfNeeded()
        let top = try XCTUnwrap(grid.layoutAttributesForItem(at: ip(0))?.frame.minY)
        let perRow = (0..<10).filter { grid.layoutAttributesForItem(at: ip($0))?.frame.minY == top }.count
        XCTAssertLessThan(perRow, 10, "the test window has two rows")
        grid.selectionIndexPaths = [ip(1)]
        grid.noteClick(on: ip(1), command: false)
        grid.keyDown(with: Self.key("\u{F701}", keyCode: 125, mods: [.shift, .numericPad, .function]))
        XCTAssertEqual(items(grid.selectionIndexPaths), Array(1...min(1 + perRow, 9)))
        grid.keyDown(with: Self.key("\u{F700}", keyCode: 126, mods: [.shift, .numericPad, .function]))
        XCTAssertEqual(items(grid.selectionIndexPaths), [1])
    }

    // MARK: Context menus use the real pointer hit in Grid and Filmstrip

    private func contextEvent(at item: Int?, in grid: BrowserCollectionView,
                              controlClick: Bool = false, mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        grid.window?.contentView?.layoutSubtreeIfNeeded(); grid.layoutSubtreeIfNeeded()
        let point: NSPoint
        if let item {
            let path = ip(item)
            let frame = try XCTUnwrap(grid.layoutAttributesForItem(at: path)?.frame)
            grid.scrollToVisible(frame)
            point = NSPoint(x: frame.midX, y: frame.midY)
            XCTAssertTrue(grid.visibleRect.contains(point), "actual context hit must be inside the visible collection")
            XCTAssertEqual(grid.indexPathForItem(at: point), path)
        } else {
            let visible = grid.visibleRect
            let candidates = [NSPoint(x: visible.minX + 1, y: visible.minY + 1),
                              NSPoint(x: visible.maxX - 1, y: visible.minY + 1),
                              NSPoint(x: visible.minX + 1, y: visible.maxY - 1),
                              NSPoint(x: visible.maxX - 1, y: visible.maxY - 1)]
            point = try XCTUnwrap(candidates.first { grid.indexPathForItem(at: $0) == nil },
                                  "an actual empty point in the visible collection")
        }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: controlClick ? .leftMouseDown : .rightMouseDown,
            location: grid.convert(point, to: nil), modifierFlags: controlClick ? mods.union(.control) : mods,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: grid.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertEqual(grid.indexPathForItem(at: grid.convert(event.locationInWindow, from: nil)), item.map(ip))
        return event
    }

    private func rateFromActualContextMenu(_ menu: NSMenu, browser: BrowserWindowController,
                                           rating: Int, expected: [Int]) async throws {
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Rating" }?.submenu)
        let position = try XCTUnwrap(submenu.items.firstIndex { $0.tag == rating && $0.action == NSSelectorFromString("menuRate:") })
        XCTAssertTrue(submenu.items[position].target === browser.contentController)
        let manager = try XCTUnwrap(browser.window?.undoManager)
        manager.groupsByEvent = false; manager.beginUndoGrouping()
        submenu.performActionForItem(at: position)
        manager.endUndoGrouping(); await CullingUndo.waitForPendingWrites()
        let urls = (0..<6).map { dir.appendingPathComponent(String(format: "p%02d.jpg", $0)) }
        let records = await browser.services.metadataStore.records(for: urls)
        XCTAssertEqual(browser.contentController.visibleItems.map(\.rating), expected)
        XCTAssertEqual(urls.map { records[$0]?.rating ?? 0 }, expected, "actual menu target reaches the private test store")
        XCTAssertEqual(manager.undoActionName, "Rating")
        manager.undo(); await CullingUndo.waitForPendingWrites()
        let restored = await browser.services.metadataStore.records(for: urls)
        XCTAssertEqual(browser.contentController.visibleItems.map(\.rating), Array(repeating: 0, count: 6))
        XCTAssertEqual(urls.map { restored[$0]?.rating ?? 0 }, Array(repeating: 0, count: 6), "Undo restores every file's rating")
    }

    /// Component menu boundary with positioned NSEvents and actual layout;
    /// normal-production pointer/menu interaction remains separate native QA.
    func testContextHitSelectsBeforeMenuAndActualRatingUndoTargetsItInBothLayouts() async throws {
        let browser = try await browser(count: 6)
        defer { browser.close() }
        let content = browser.contentController, grid = content.collectionViewForTesting
        for mode in [BrowserViewMode.grid, .filmstrip] {
            browser.setMode(mode)
            XCTAssertTrue(content.select(url: dir.appendingPathComponent("p05.jpg")))
            grid.noteClick(on: ip(5), command: false)
            let event = try contextEvent(at: 1, in: grid)
            let menu = try XCTUnwrap(grid.menu(for: event))
            XCTAssertTrue(menu === grid.menu)
            XCTAssertEqual(items(grid.selectionIndexPaths), [1], "selection is correct before the menu is returned")
            XCTAssertEqual(names(browser), ["p01.jpg"])
            XCTAssertEqual(grid.selectionAnchor, ip(1))
            XCTAssertEqual(browser.inspectorStateForTesting.count, 1, "existing selection delegates update the inspector")
            XCTAssertFalse(content.firstOnOpenPending)
            try await rateFromActualContextMenu(menu, browser: browser, rating: 2, expected: [0, 2, 0, 0, 0, 0])
            if mode == .filmstrip {
                let followed = await waitUntil { content.filmstripPreviewURL == self.dir.appendingPathComponent("p01.jpg") }
                XCTAssertTrue(followed, "the Browser preview follows the contextual selection")
            }
        }
    }

    func testContextPreservesSelectedMultiAndEmptyAreaThenControlHitResetsRangeInBothLayouts() async throws {
        let browser = try await browser(count: 6)
        defer { browser.close() }
        let content = browser.contentController, grid = content.collectionViewForTesting
        for mode in [BrowserViewMode.grid, .filmstrip] {
            browser.setMode(mode)
            XCTAssertTrue(content.select(urls: [1, 2].map { dir.appendingPathComponent(String(format: "p%02d.jpg", $0)) }))
            grid.noteClick(on: ip(1), command: false); grid.extendSelection(to: ip(2))
            let selectedMenu = try XCTUnwrap(grid.menu(for: contextEvent(at: 2, in: grid, mods: [.shift, .command])))
            XCTAssertEqual(items(grid.selectionIndexPaths), [1, 2])
            XCTAssertEqual(grid.selectionAnchor, ip(1), "context inside a selection preserves its range anchor")
            try await rateFromActualContextMenu(selectedMenu, browser: browser, rating: 3, expected: [0, 3, 3, 0, 0, 0])
            let emptyMenu = try XCTUnwrap(grid.menu(for: contextEvent(at: nil, in: grid)))
            XCTAssertTrue(emptyMenu === grid.menu)
            XCTAssertEqual(items(grid.selectionIndexPaths), [1, 2], "empty-area context preserves the existing selection policy")
            XCTAssertEqual(grid.selectionAnchor, ip(1))
            _ = try XCTUnwrap(grid.menu(for: contextEvent(at: 4, in: grid, controlClick: true)))
            XCTAssertEqual(items(grid.selectionIndexPaths), [4], "Control-click outside the selection uses its real hit")
            XCTAssertEqual(grid.selectionAnchor, ip(4), "a new contextual singleton drops the stale range anchor")
            let shiftFrame = try XCTUnwrap(grid.layoutAttributesForItem(at: ip(5))?.frame)
            grid.scrollToVisible(shiftFrame)
            XCTAssertTrue(grid.visibleRect.contains(NSPoint(x: shiftFrame.midX, y: shiftFrame.midY)))
            grid.mouseDown(with: try mouse(.leftMouseDown, at: 5, in: grid, mods: .shift))
            XCTAssertEqual(items(grid.selectionIndexPaths), [4, 5], "the next real Shift-click extends from the contextual target")
        }
    }

    func testContextEndsAutomaticFirstSelectionAndCancelsStaleMouseUpNarrowing() async throws {
        let browser = try await browser(count: 6)
        defer { browser.close() }
        let content = browser.contentController, grid = content.collectionViewForTesting
        for mode in [BrowserViewMode.grid, .filmstrip] {
            browser.setMode(mode)
            content.deselectAll(); content.selectFirstOnOpen()
            XCTAssertTrue(content.firstOnOpenPending)
            _ = try XCTUnwrap(grid.menu(for: contextEvent(at: nil, in: grid)))
            XCTAssertTrue(content.firstOnOpenPending, "empty-area contextual policy remains unchanged")
            let anchor = grid.selectionAnchor
            _ = try XCTUnwrap(grid.menu(for: contextEvent(at: 0, in: grid)))
            XCTAssertFalse(content.firstOnOpenPending, "a contextual click on the automatic selection is a user choice")
            XCTAssertEqual(grid.selectionAnchor, anchor)
            XCTAssertEqual(items(grid.selectionIndexPaths), [0])
            XCTAssertTrue(content.select(urls: [1, 2, 3].map { dir.appendingPathComponent(String(format: "p%02d.jpg", $0)) }))
            grid.noteClick(on: ip(1), command: false)
            clearCurrentEvent()
            grid.mouseTrackingForTesting = { _ in }
            defer { grid.mouseTrackingForTesting = nil }
            grid.mouseDown(with: try mouse(.leftMouseDown, at: 2, in: grid))
            let clickedAnchor = grid.selectionAnchor
            _ = try XCTUnwrap(grid.menu(for: contextEvent(at: 3, in: grid)))
            grid.mouseUp(with: try mouse(.leftMouseUp, at: 2, in: grid))
            grid.mouseTrackingForTesting = nil
            XCTAssertEqual(items(grid.selectionIndexPaths), [1, 2, 3], "a context menu must not inherit a prior left-click narrowing")
            XCTAssertEqual(grid.selectionAnchor, clickedAnchor)
        }
    }

}

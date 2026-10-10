//
//  BrowserCullingSelectionTests.swift
//  ShrikeUITests
//
//  Q or a rating key in the Browser
//  must keep the selection, so a second Q acts on the same
//  items, and a rating made in Compare reaches the Browser without
//  changing its selection. Grid and list, through
//  the real key path (the grid / list `keyDown`).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserCullingSelectionTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-cullsel-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CompareWindow.presentsWindows = false
    }

    override func tearDown() async throws {
        CompareWindow.current?.close()
        CompareWindow.presentsWindows = true
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

    private func browser(_ names: [String]) async throws -> BrowserWindowController {
        for name in names { try writeJPEG(name) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == names.count }
        XCTAssertTrue(listed)
        // The first-paint read of saved values lands before the keys.
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    private static func key(_ chars: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    private static let q = key("q", keyCode: 12)
    private static let three = key("3", keyCode: 20)

    private func selectedNames(_ browser: BrowserWindowController) -> [String] {
        browser.contentController.selectedItems.map(\.url.lastPathComponent).sorted()
    }

    private func item(_ browser: BrowserWindowController, _ name: String) -> BrowserItem? {
        browser.contentController.visibleItems.first { $0.url.lastPathComponent == name }
    }

    private func assertKeepsSelection(_ browser: BrowserWindowController, _ names: [String],
                                      _ message: String, line: UInt = #line) {
        XCTAssertEqual(selectedNames(browser), names, message, line: line)
        XCTAssertEqual(browser.inspectorStateForTesting.count, names.count, message, line: line)
        XCTAssertEqual(InspectorState.multipleHeader(browser.inspectorStateForTesting.count),
                       "\(names.count) items selected", line: line)
    }

    // MARK: Grid

    func testGridQAndRatingKeepTheSelectionAndASecondQUnflags() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        let grid = browser.contentController.collectionViewForTesting
        let window = try XCTUnwrap(browser.window)
        XCTAssertTrue(window.makeFirstResponder(grid))
        let picked = ["b.jpg", "c.jpg", "d.jpg"]
        XCTAssertTrue(browser.contentController.select(urls: picked.map { dir.appendingPathComponent($0) }))
        grid.noteClick(on: IndexPath(item: 1, section: 0), command: false)
        grid.layoutSubtreeIfNeeded()
        let scroll = grid.enclosingScrollView?.contentView.bounds.origin
        let cell = try XCTUnwrap(grid.item(at: IndexPath(item: 2, section: 0)) as? ThumbnailItem)
        XCTAssertFalse(cell.badgeStateForTesting.flag)

        // Q flags all three; the selection, the anchor, the first
        // responder and the scroll position stay.
        grid.keyDown(with: Self.q)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "Q keeps the selection")
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.isFlagged == true })
        XCTAssertEqual(item(browser, "a.jpg")?.isFlagged, false)
        XCTAssertEqual(grid.selectionAnchor, IndexPath(item: 1, section: 0))
        XCTAssertTrue(window.firstResponder === grid)
        XCTAssertEqual(grid.enclosingScrollView?.contentView.bounds.origin, scroll)
        XCTAssertTrue(grid.item(at: IndexPath(item: 2, section: 0)) === cell, "the cell is not reloaded")
        XCTAssertTrue(cell.badgeStateForTesting.flag, "the flag is drawn in place")
        XCTAssertTrue(cell.isSelected)

        // A second Q unflags the same three.
        grid.keyDown(with: Self.q)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "a second Q keeps it too")
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.isFlagged == false })
        XCTAssertFalse(cell.badgeStateForTesting.flag)

        // 3 rates all three.
        grid.keyDown(with: Self.three)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "a rating keeps the selection")
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.rating == 3 })
        XCTAssertEqual(cell.badgeStateForTesting.stars, "★★★")
        let records = await browser.services.metadataStore.records(for: picked.map { dir.appendingPathComponent($0) })
        XCTAssertTrue(records.values.allSatisfy { $0.rating == 3 && !$0.flagged })
        XCTAssertEqual(records.count, 3)
    }

    // MARK: List

    func testListQAndRatingKeepTheSelection() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        defer { browser.close() }
        browser.setMode(.list)
        let table = browser.contentController.tableViewForTesting
        let window = try XCTUnwrap(browser.window)
        XCTAssertTrue(window.makeFirstResponder(table))
        let picked = ["a.jpg", "c.jpg", "e.jpg"]
        XCTAssertTrue(browser.contentController.select(urls: picked.map { dir.appendingPathComponent($0) }))
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2, 4]))

        table.keyDown(with: Self.q)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "Q keeps the list selection")
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2, 4]))
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.isFlagged == true })
        XCTAssertTrue(window.firstResponder === table)

        table.keyDown(with: Self.q)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "a second Q keeps it")
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.isFlagged == false })

        table.keyDown(with: Self.three)
        await CullingUndo.waitForPendingWrites()
        assertKeepsSelection(browser, picked, "a rating keeps it")
        XCTAssertTrue(picked.allSatisfy { item(browser, $0)?.rating == 3 })
        XCTAssertEqual(table.selectedRowIndexes, IndexSet([0, 2, 4]))
    }

    // MARK: Compare → Browser

    func testARatingInCompareReachesTheBrowserWithoutChangingItsSelection() async throws {
        let browser = try await browser(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        defer { browser.close() }
        let picked = ["a.jpg", "b.jpg", "c.jpg"]
        XCTAssertTrue(browser.contentController.select(urls: picked.map { dir.appendingPathComponent($0) }))
        browser.perform(.compare)
        let compare = try XCTUnwrap(CompareWindow.current)
        compare.focus(0)
        compare.keyDown(with: Self.three)
        await compare.waitForCullingWrites()
        XCTAssertEqual(item(browser, "a.jpg")?.rating, 3, "the rating reaches the Browser")
        XCTAssertEqual(item(browser, "b.jpg")?.rating, 0)
        assertKeepsSelection(browser, picked, "the Browser selection is unchanged")
        compare.close()
        assertKeepsSelection(browser, picked, "still after Compare closes")
    }
}

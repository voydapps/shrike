//
//  BrowserFirstOnOpenSortTests.swift
//  ShrikeUITests
//
//  The first photo is selected when a folder opens. With a capture-date
//  sort the order is only known after the files are read, so the selection
//  follows the re-sort to the first photo on screen, until the user
//  selects something themselves (seen on screen 2026-10-11: IMG_4220 was
//  selected, IMG_4222 was the first cell).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserFirstOnOpenSortTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        Prefs.browserSortKey = "dateCaptured"
        Prefs.browserSortAscending = false
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-firstopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The newest photo is in the MIDDLE of the file-name order, so the
        // order before and after the date read differs at the first cell.
        try jpeg("a.jpg", taken: "2021:01:01 10:00:00")
        try jpeg("b.jpg", taken: "2022:01:01 10:00:00")
        try jpeg("c.jpg", taken: "2020:01:01 10:00:00")
    }

    override func tearDown() async throws {
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String, taken: String) throws {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: taken]]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
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

    private func names(_ items: [BrowserItem]) -> [String] { items.map(\.displayName) }

    private func loadedController() throws -> BrowserContentViewController {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        content.loadViewIfNeeded()
        content.view.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        // As the folder listing makes them: no capture date yet (read after
        // the first paint).
        let items = try ["a.jpg", "b.jpg", "c.jpg"].map { name -> BrowserItem in
            var item = try BrowserItem.make(from: dir.appendingPathComponent(name))
            item.captureDate = nil
            return item
        }
        content.setItems(items)
        return content
    }

    /// The real path: a window opens the folder; the selected photo ends
    /// as the first cell after the capture-date sort.
    func testOpenSelectsTheFirstCellAfterTheDateSort() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let sorted = await waitUntil { self.names(content.visibleItems) == ["b.jpg", "a.jpg", "c.jpg"] }
        XCTAssertTrue(sorted, "capture order, newest first: \(names(content.visibleItems))")
        let selected = await waitUntil { content.selectedItems.map(\.displayName) == ["b.jpg"] }
        XCTAssertTrue(selected, "selected: \(content.selectedItems.map(\.displayName))")
    }

    func testTheSelectionFollowsTheResortWhileNobodyChoseAnything() async throws {
        let second = try loadedController()   // sort is date captured, newest first
        second.selectFirstOnOpen()
        XCTAssertNotEqual(second.selectedItems.map(\.displayName), ["b.jpg"], "not yet sorted by date")
        XCTAssertTrue(second.firstOnOpenPending)
        await second.waitForSortRead()
        XCTAssertEqual(names(second.visibleItems), ["b.jpg", "a.jpg", "c.jpg"])
        XCTAssertEqual(second.selectedItems.map(\.displayName), ["b.jpg"], "the first cell is selected")
        XCTAssertTrue(second.firstOnOpenPending, "still the automatic selection")
    }

    func testChoosingAnotherSortOrderEndsTheAutomaticSelection() throws {
        let content = try loadedController()
        content.selectFirstOnOpen()
        XCTAssertTrue(content.firstOnOpenPending)
        content.sort = BrowserSort(key: .size)
        XCTAssertFalse(content.firstOnOpenPending)
    }

    func testAUserSelectionBeforeTheResortIsKept() async throws {
        let content = try loadedController()
        content.selectFirstOnOpen()
        XCTAssertTrue(content.firstOnOpenPending)
        content.select(url: dir.appendingPathComponent("c.jpg"))   // the user picks
        XCTAssertFalse(content.firstOnOpenPending)
        await content.waitForSortRead()
        XCTAssertEqual(names(content.visibleItems), ["b.jpg", "a.jpg", "c.jpg"])
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["c.jpg"], "the user's choice stays")
    }
}

//
//  BrowserSelectionFlickerTests.swift
//  ShrikeUITests
//
//  User test of 0.2.2: moving through photos made the filmstrip preview and
//  the inspector blink. A step from one photo to the next must never show a
//  blank preview or the folder state in between.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserSelectionFlickerTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-bflick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, shade: Double) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: shade, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
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
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i), shade: Double(i) / Double(count)) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists")
        browser.window?.setContentSize(NSSize(width: 1000, height: 700))
        return browser
    }

    /// Arrow steps through the strip: the inspector never publishes the
    /// folder state (count 0) and the preview never loses its picture.
    func testArrowStepsNeverShowAnEmptyInspectorOrPreview() async throws {
        let browser = try await makeBrowser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        content.view.layoutSubtreeIfNeeded()
        let collection = content.collectionViewForTesting
        collection.selectionIndexPaths = [IndexPath(item: 0, section: 0)]
        let first = content.selectedItems.first?.url
        let loaded = await waitUntil(20) { content.filmstripPreviewURL == first && content.filmstripPreviewForTesting.image != nil }
        XCTAssertTrue(loaded, "the first picture is shown before the walk")
        await browser.waitForInspectorInfo()

        var publishedCounts: [Int] = []
        browser.inspectorControllerForTesting?.onPublishForTesting = { publishedCounts.append($0.count) }
        var blankPreviewSeen = false
        for _ in 0..<5 {
            collection.moveRight(nil)
            if content.filmstripPreviewForTesting.image == nil { blankPreviewSeen = true }
            // Let the main loop turn like it does between key presses.
            try? await Task.sleep(for: .milliseconds(30))
            if content.filmstripPreviewForTesting.image == nil { blankPreviewSeen = true }
        }
        await browser.waitForInspectorInfo()
        XCTAssertFalse(blankPreviewSeen, "the preview keeps a picture while moving")
        XCTAssertFalse(publishedCounts.contains(0), "the inspector never shows the folder between photos: \(publishedCounts)")
    }

    /// 0.2.3: Filmstrip with nothing selected is an empty box above the
    /// strip; entering it selects the first photo.
    func testEnteringFilmstripSelectsTheFirstPhoto() async throws {
        let browser = try await makeBrowser(count: 4)
        defer { browser.close() }
        let content = browser.contentController
        // A folder opens with its first photo selected; with nothing
        // selected, entering the Filmstrip selects it.
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p000.jpg"], "selected on open")
        content.deselectAll()
        XCTAssertTrue(content.selectedItems.isEmpty)
        content.setMode(.filmstrip)
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p000.jpg"])
        let ok = await waitUntil(20) { content.filmstripPreviewForTesting.image != nil }
        XCTAssertTrue(ok, "the big picture shows it")
        // Leaving and coming back keeps a chosen photo.
        content.collectionViewForTesting.selectionIndexPaths = [IndexPath(item: 2, section: 0)]
        content.setMode(.grid)
        content.setMode(.filmstrip)
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p002.jpg"])
    }

    /// A real deselect (click on nothing) still reaches the inspector, one
    /// event later.
    func testARealDeselectStillClearsTheSelection() async throws {
        let browser = try await makeBrowser(count: 4)
        defer { browser.close() }
        let content = browser.contentController
        content.collectionViewForTesting.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        content.collectionView(content.collectionViewForTesting, didSelectItemsAt: [IndexPath(item: 1, section: 0)])
        await browser.waitForInspectorInfo()
        XCTAssertEqual(browser.inspectorStateForTesting.count, 1)
        var counts: [Int] = []
        browser.inspectorControllerForTesting?.onPublishForTesting = { counts.append($0.count) }
        let ip = IndexPath(item: 1, section: 0)
        content.collectionViewForTesting.selectionIndexPaths = []
        // What AppKit reports after a click on nothing.
        content.collectionView(content.collectionViewForTesting, didDeselectItemsAt: [ip])
        let ok = await waitUntil { counts.contains(0) }
        XCTAssertTrue(ok, "the folder state comes back after a real deselect: \(counts)")
    }
}

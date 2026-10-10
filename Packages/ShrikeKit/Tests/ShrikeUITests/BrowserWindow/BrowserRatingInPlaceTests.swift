//
//  BrowserRatingInPlaceTests.swift
//  ShrikeUITests
//
//  A rating or a flag (by key, by the inspector's
//  stars, and their undo) changes the marks in place: no grid reload, no
//  cell configured again, no thumbnail request, no split resize, one
//  inspector publish, no status change. The files' extended attributes
//  change, so the folder watcher runs for real. Temp folders, windows
//  never shown.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class BrowserRatingInPlaceTests: XCTestCase {

    private var dir: URL!
    private var savedSortKey = ""
    private var savedSortAscending = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-rate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedSortKey = Prefs.browserSortKey
        savedSortAscending = Prefs.browserSortAscending
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
    }

    override func tearDown() async throws {
        await CullingUndo.waitForPendingWrites()
        Prefs.browserSortKey = savedSortKey
        Prefs.browserSortAscending = savedSortAscending
        try? FileManager.default.removeItem(at: dir)
    }

    /// A JPEG with camera EXIF (so it has Capture rows).
    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Shrike",
                kCGImagePropertyTIFFModel: "Test Camera",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifDateTimeOriginal: "2026:09:25 14:02:31",
            ],
        ]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }

    /// A Browser on `dir` whose listing and saved values have landed.
    private func makeBrowser(count: Int) async throws -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        let ok = await waitUntil { hydrated && browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists and hydrates")
        // A loaded test run must not hit the slow-read path by accident.
        browser.headerWait = .seconds(5)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    /// What a click on a cell does: AppKit changes the selection, then
    /// tells the delegate about the deselected and the selected items.
    private func click(_ url: URL, in browser: BrowserWindowController) throws {
        let content = browser.contentController
        let cv = content.collectionViewForTesting
        let index = try XCTUnwrap(content.visibleItems.firstIndex { $0.url == url })
        let old = cv.selectionIndexPaths
        let ip = IndexPath(item: index, section: 0)
        cv.selectionIndexPaths = [ip]
        if !old.isEmpty { content.collectionView(cv, didDeselectItemsAt: old) }
        content.collectionView(cv, didSelectItemsAt: [ip])
    }

    private struct Snapshot: Equatable {
        var reloads: Int
        var configures: Int
        var thumbRequests: Int
        var splitFrames: [NSRect]
    }

    private func snapshot(_ browser: BrowserWindowController) async -> Snapshot {
        let stats = await browser.services.thumbnailCache.statistics()
        return Snapshot(
            reloads: browser.contentController.reloadCount,
            configures: browser.contentController.configureCount,
            thumbRequests: stats.memoryHits + stats.diskHits + stats.misses,
            splitFrames: browser.splitController.splitView.subviews.map(\.frame)
        )
    }

    private static func key(_ chars: String, keyCode: UInt16) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    func testARatingOrAFlagChangesOnlyTheMarks() async throws {
        let a = try writeJPEG("a.jpg")
        try writeJPEG("b.jpg")
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        try click(a, in: browser)
        await browser.waitForInspectorInfo()
        // Let the watcher settle after the listing.
        try await Task.sleep(for: .milliseconds(400))
        let before = await snapshot(browser)
        let pane = browser.inspectorForTesting
        let publishes = pane.publishCount
        let status = browser.bottomBar.statusChanges

        // The key path ("3"), then the inspector's star, then a flag (Q).
        XCTAssertTrue(browser.handleKey(Self.key("3", keyCode: 20)))
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(browser.contentController.allItems.first { $0.url == a }?.rating, 3)
        pane.onRate?(5)
        await CullingUndo.waitForPendingWrites()
        XCTAssertTrue(browser.handleKey(Self.key("q", keyCode: 12)))
        await CullingUndo.waitForPendingWrites()
        let item = try XCTUnwrap(browser.contentController.allItems.first { $0.url == a })
        XCTAssertEqual(item.rating, 5)
        XCTAssertTrue(item.isFlagged)
        // Undo the flag and the last rating.
        browser.window?.undoManager?.undo()
        await CullingUndo.waitForPendingWrites()
        browser.window?.undoManager?.undo()
        await CullingUndo.waitForPendingWrites()

        // The folder watcher has had time to report the xattr writes.
        try await Task.sleep(for: .milliseconds(1200))
        let after = await snapshot(browser)
        XCTAssertEqual(after.reloads, before.reloads, "no grid reload")
        XCTAssertEqual(after.configures, before.configures, "no cell configured again")
        XCTAssertEqual(after.thumbRequests, before.thumbRequests, "no thumbnail asked again")
        XCTAssertEqual(after.splitFrames, before.splitFrames, "no split resize")
        let state = browser.inspectorStateForTesting
        XCTAssertFalse(state.capture.isEmpty, "the Capture section stays")
        XCTAssertEqual(pane.publishCount - publishes, 5, "one publish per change (3, 5, flag, 2 undos)")
        XCTAssertEqual(browser.bottomBar.statusChanges, status, "the status text did not change")
    }
}

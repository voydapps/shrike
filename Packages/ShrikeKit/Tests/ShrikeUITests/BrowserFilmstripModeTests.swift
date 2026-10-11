//
//  BrowserFilmstripModeTests.swift
//  ShrikeUITests
//
//  User test 2 (2026-10-10): "as Filmstrip" in the Browser stacked the
//  thumbnails in columns. It is now a large preview of the selected photo
//  on top and ONE horizontal row of thumbnails in a fixed-height strip.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserFilmstripModeTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-bfilm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
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
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i)) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists")
        browser.window?.setContentSize(NSSize(width: 1000, height: 700))
        return browser
    }

    func testFilmstripIsOnePreviewOnTopAndOneFixedHeightRowBelow() async throws {
        let browser = try await makeBrowser(count: 41)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        content.view.layoutSubtreeIfNeeded()

        let layout = try XCTUnwrap(content.collectionViewForTesting.collectionViewLayout as? NSCollectionViewFlowLayout)
        XCTAssertEqual(layout.scrollDirection, .horizontal)

        let strip = content.filmstripStripFrameForTesting
        XCTAssertEqual(strip.height, BrowserContentViewController.filmstripStripHeight, accuracy: 0.5,
                       "a fixed height, not the whole content area")
        XCTAssertEqual(strip.minY, 0, accuracy: 0.5, "the strip sits at the bottom")
        let preview = content.filmstripPreviewFrameForTesting
        XCTAssertEqual(preview.minY, strip.maxY, accuracy: 0.5, "the preview is right above the strip")
        XCTAssertEqual(preview.maxY, content.view.bounds.maxY, accuracy: 0.5)
        XCTAssertGreaterThan(preview.height, strip.height, "the preview is the big part")

        // One row: every laid-out cell shares one y.
        let collection = content.collectionViewForTesting
        let attributes = (0..<41).compactMap {
            layout.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
        XCTAssertEqual(attributes.count, 41)
        XCTAssertEqual(Set(attributes.map { $0.frame.minY }).count, 1, "all in a single row")
        XCTAssertEqual(attributes[0].frame.height, BrowserContentViewController.filmstripItemSize.height, accuracy: 0.5)
        XCTAssertGreaterThan(collection.frame.width, strip.width, "the row scrolls horizontally")
        XCTAssertLessThanOrEqual(collection.frame.height, strip.height + 0.5, "no vertical scrolling")
    }

    func testArrowKeysMoveTheSelectionAndThePreviewFollows() async throws {
        let browser = try await makeBrowser(count: 6)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        content.view.layoutSubtreeIfNeeded()
        let collection = content.collectionViewForTesting
        collection.selectionIndexPaths = [IndexPath(item: 1, section: 0)]
        collection.moveRight(nil)
        XCTAssertEqual(collection.selectionIndexPaths, [IndexPath(item: 2, section: 0)])
        // The same selection is what Grid and List show (one selection).
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p002.jpg"])
        let url = content.selectedItems.first?.url
        let ok = await waitUntil { content.filmstripPreviewURL == url && content.filmstripPreviewForTesting.image != nil }
        XCTAssertTrue(ok, "the big picture shows the selected photo")
        content.setMode(.grid)
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p002.jpg"], "selection synced to Grid")
        XCTAssertNil(content.filmstripPreviewForTesting.superview, "no preview outside Filmstrip")
    }

    /// UX-02 P3-3: the selected cell's file name hung below the 120 pt cell and
    /// the always-visible scroller cut it off.
    func testSelectedCellNameClearsTheScroller() async throws {
        let browser = try await makeBrowser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.filmstrip)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let scroll = content.gridScrollViewForTesting
        scroll.scrollerStyle = .legacy          // a mouse is attached: the scroller takes room
        content.view.layoutSubtreeIfNeeded()
        let collection = content.collectionViewForTesting
        collection.selectionIndexPaths = [IndexPath(item: 2, section: 0)]
        collection.layoutSubtreeIfNeeded()
        let item = try XCTUnwrap(collection.item(at: IndexPath(item: 2, section: 0)) as? ThumbnailItem)
        XCTAssertFalse(item.view.isHidden)
        let capsule = item.nameCapsuleFrameForTesting
        XCTAssertGreaterThan(capsule.height, 0)
        let inClip = item.view.convert(capsule, to: scroll.contentView)
        let visible = scroll.contentView.bounds
        XCTAssertTrue(visible.contains(inClip), "name \(inClip) inside the visible strip \(visible)")
        if let scroller = scroll.horizontalScroller, scroller.scrollerStyle == .legacy, !scroller.isHidden {
            let scrollerFrame = scroll.convert(scroller.frame, to: scroll.contentView)
            XCTAssertFalse(inClip.intersects(scrollerFrame), "name \(inClip) vs scroller \(scrollerFrame)")
        }
    }
}

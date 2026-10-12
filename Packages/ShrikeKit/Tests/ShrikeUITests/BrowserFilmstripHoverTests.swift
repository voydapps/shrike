//
//  BrowserFilmstripHoverTests.swift
//  ShrikeUITests
//
//  Spec 24 §2 in the Browser: the strip of "as Filmstrip" shows the same
//  hover look as the viewer's strip; Grid keeps its plain look.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ShrikeRendering
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserFilmstripHoverTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        ReduceMotion.overrideForTesting = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-bhover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ReduceMotion.overrideForTesting = nil
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

    private func item(_ collection: BrowserCollectionView, _ i: Int) -> ThumbnailItem? {
        collection.item(at: IndexPath(item: i, section: 0)) as? ThumbnailItem
    }

    private func windowPoint(_ collection: BrowserCollectionView, _ i: Int) -> NSPoint {
        let frame = collection.frameForItem(at: i)
        return collection.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
    }

    private func filmstrip(_ browser: BrowserWindowController) -> (BrowserContentViewController, BrowserCollectionView) {
        let content = browser.contentController
        content.setMode(.filmstrip)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        content.view.layoutSubtreeIfNeeded()
        return (content, content.collectionViewForTesting)
    }

    func testHoveringAStripCellShowsTheLookAndMovingOnClearsIt() async throws {
        let browser = try await makeBrowser(count: 8)
        defer { browser.close() }
        let (_, collection) = filmstrip(browser)
        XCTAssertTrue(collection.hoverEnabled)
        collection.hoverPointer(atWindowPoint: windowPoint(collection, 2))
        XCTAssertEqual(collection.hoveredIndexPath, IndexPath(item: 2, section: 0))
        let on = try XCTUnwrap(item(collection, 2)).hoverLookForTesting
        XCTAssertEqual(on.ringOpacity, 1)
        XCTAssertEqual(on.ringWidth, 1.5, accuracy: 0.01)
        XCTAssertEqual(on.overlayAlpha, 0.10, accuracy: 0.001)

        collection.hoverPointer(atWindowPoint: windowPoint(collection, 4))
        XCTAssertEqual(collection.hoveredIndexPath, IndexPath(item: 4, section: 0))
        XCTAssertEqual(try XCTUnwrap(item(collection, 2)).hoverLookForTesting.ringOpacity, 0)
        XCTAssertEqual(try XCTUnwrap(item(collection, 4)).hoverLookForTesting.ringOpacity, 1)

        let exit = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil))
        collection.mouseExited(with: exit)
        XCTAssertNil(collection.hoveredIndexPath)
        XCTAssertEqual(try XCTUnwrap(item(collection, 4)).hoverLookForTesting.ringOpacity, 0)
    }

    func testTheSelectedCellShowsNoHover() async throws {
        let browser = try await makeBrowser(count: 8)
        defer { browser.close() }
        let (_, collection) = filmstrip(browser)
        collection.selectionIndexPaths = [IndexPath(item: 3, section: 0)]
        collection.hoverPointer(atWindowPoint: windowPoint(collection, 3))
        let look = try XCTUnwrap(item(collection, 3)).hoverLookForTesting
        XCTAssertEqual(look.ringOpacity, 0)
        XCTAssertEqual(look.overlayAlpha, 0)
        // Select another: the hovered one lights up.
        collection.selectionIndexPaths = [IndexPath(item: 5, section: 0)]
        XCTAssertEqual(try XCTUnwrap(item(collection, 3)).hoverLookForTesting.ringOpacity, 1)
    }

    func testScrollingMovesTheHoverUnderAStillPointer() async throws {
        let browser = try await makeBrowser(count: 40)
        defer { browser.close() }
        let (_, collection) = filmstrip(browser)
        let point = windowPoint(collection, 2)
        collection.hoverPointer(atWindowPoint: point)
        let before = try XCTUnwrap(collection.hoveredIndexPath)
        let clip = try XCTUnwrap(collection.superview as? NSClipView)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x + 260, y: clip.bounds.origin.y))
        collection.enclosingScrollView?.reflectScrolledClipView(clip)
        let moved = await waitUntil { collection.hoveredIndexPath != before }
        XCTAssertTrue(moved, "another cell is under the pointer now")
        let hovered = (0..<40).filter { (item(collection, $0)?.hoverLookForTesting.ringOpacity ?? 0) > 0 }
        XCTAssertEqual(hovered.count, 1, "exactly one cell hovered")
    }

    func testGridKeepsItsPlainLook() async throws {
        let browser = try await makeBrowser(count: 8)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.grid)
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        content.view.layoutSubtreeIfNeeded()
        let collection = content.collectionViewForTesting
        XCTAssertFalse(collection.hoverEnabled)
        collection.hoverPointer(atWindowPoint: windowPoint(collection, 1))
        XCTAssertNil(collection.hoveredIndexPath)
        // Switching to Filmstrip turns it on, and back off clears it.
        content.setMode(.filmstrip)
        content.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(collection.hoverEnabled)
        collection.hoverPointer(atWindowPoint: windowPoint(collection, 1))
        XCTAssertNotNil(collection.hoveredIndexPath)
        content.setMode(.grid)
        XCTAssertNil(collection.hoveredIndexPath)
    }

    func testTheStripAndGridCellTooltipIsTheFullFileName() async throws {
        let browser = try await makeBrowser(count: 4)
        defer { browser.close() }
        let (content, collection) = filmstrip(browser)
        XCTAssertEqual(try XCTUnwrap(item(collection, 1)).view.toolTip, "p001.jpg")
        content.setMode(.grid)
        content.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(item(collection, 1)?.view.toolTip, "p001.jpg", "spec 25 §6.3: the grid has it too")
    }
}

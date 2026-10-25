//
//  BrowserFilmstripInspectorTests.swift
//  ShrikeUITests
//
//  The Browser filmstrip (⌘2) and its preview stay left of the inspector,
//  and the selected cell stays in the strip's visible rect.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserFilmstripInspectorTests: XCTestCase {

    private var root: URL!
    private var dir: URL!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-fsinsp-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
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

    func testFilmstripStaysLeftOfTheInspector() async throws {
        let count = 40
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i)) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        let listed = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(listed)
        browser.window?.setContentSize(NSSize(width: 1280, height: 700))
        let content = browser.contentController
        let panes = browser.splitController.splitViewItems
        panes[0].isCollapsed = true
        panes[2].isCollapsed = false
        // The real order: select in the grid, then switch to the filmstrip.
        content.setMode(.grid)
        _ = content.select(url: content.visibleItems[20].url)
        content.setMode(.filmstrip)

        func check(_ what: String, file: StaticString = #filePath, line: UInt = #line) async {
            for _ in 0..<3 { browser.window?.contentView?.superview?.layoutSubtreeIfNeeded() }
            let inspector = panes[2].viewController.view
            let inspectorFrame = inspector.convert(inspector.bounds, to: nil)
            let strip = content.gridScrollViewForTesting
            let stripFrame = strip.convert(strip.bounds, to: nil)
            let preview = content.filmstripPreviewForTesting
            let previewFrame = preview.convert(preview.bounds, to: nil)
            if !panes[2].isCollapsed {
                XCTAssertLessThanOrEqual(stripFrame.maxX, inspectorFrame.minX + 0.5,
                                         "\(what): strip \(stripFrame) vs \(inspectorFrame)", file: file, line: line)
                XCTAssertLessThanOrEqual(previewFrame.maxX, inspectorFrame.minX + 0.5,
                                         "\(what): preview \(previewFrame) vs \(inspectorFrame)", file: file, line: line)
            }
            let cv = content.collectionViewForTesting
            let cell = cv.layoutAttributesForItem(at: IndexPath(item: 20, section: 0))!.frame
            let ok = await waitUntil { strip.contentView.bounds.contains(cell) }
            XCTAssertTrue(ok, "\(what): visible \(strip.contentView.bounds), cell \(cell)", file: file, line: line)
        }

        await check("inspector open, switched to filmstrip")
        panes[2].isCollapsed = true
        await check("inspector closed")
        panes[2].isCollapsed = false
        await check("inspector reopened")
        browser.window?.setContentSize(NSSize(width: 1100, height: 700))
        await check("window resized")
    }

    /// After ⌘A there is no moving end: a strip width change keeps the
    /// scroll position (it used to jump to the last item).
    func testSelectAllKeepsTheStripWhereItIsWhenTheWidthChanges() async throws {
        let count = 40
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i)) }
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        let listed = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(listed)
        browser.window?.setContentSize(NSSize(width: 1280, height: 700))
        let content = browser.contentController
        let panes = browser.splitController.splitViewItems
        panes[0].isCollapsed = true
        panes[2].isCollapsed = false
        content.setMode(.filmstrip)
        func layout() { for _ in 0..<3 { browser.window?.contentView?.superview?.layoutSubtreeIfNeeded() } }
        layout()
        _ = content.select(url: content.visibleItems[10].url)
        content.selectAll()
        let strip = content.gridScrollViewForTesting
        let cv = content.collectionViewForTesting
        XCTAssertEqual(cv.selectionIndexPaths.count, count)
        let mid = cv.layoutAttributesForItem(at: IndexPath(item: 12, section: 0))!.frame
        strip.contentView.setBoundsOrigin(NSPoint(x: mid.minX, y: 0))
        strip.reflectScrolledClipView(strip.contentView)
        let before = strip.contentView.bounds.origin.x
        let widthBefore = strip.contentView.bounds.width
        panes[2].isCollapsed = true
        layout()
        XCTAssertNotEqual(strip.contentView.bounds.width, widthBefore, "the strip changed width")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(strip.contentView.bounds.origin.x, before, accuracy: 1, "select-all: the strip stays")
        panes[2].isCollapsed = false
        layout()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(strip.contentView.bounds.origin.x, before, accuracy: 1, "select-all: the strip stays (reopened)")
    }
}

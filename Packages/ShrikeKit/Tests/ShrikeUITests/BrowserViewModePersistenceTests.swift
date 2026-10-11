//
//  BrowserViewModePersistenceTests.swift
//  ShrikeUITests
//
//  User test of 0.2.2: "as Filmstrip", quit, reopen: the Browser was back in
//  Grid. The view mode is saved per app (like the sort) and a new Browser
//  window starts in it.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserViewModePersistenceTests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        BrowserWindowController.restoresViewModeUnderTests = true
        Prefs.browserViewMode = 0
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-bvm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<6 {
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let url = dir.appendingPathComponent(String(format: "p%03d.jpg", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        BrowserWindowController.restoresViewModeUnderTests = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func makeBrowser() async -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        _ = await waitUntil { browser.contentController.allItems.count == 6 }
        return browser
    }

    func testTheChosenModeIsSavedAndANewWindowStartsInIt() async throws {
        let first = await makeBrowser()
        XCTAssertEqual(first.contentController.mode, .grid, "the default is Grid")
        first.chooseMode(.filmstrip)
        XCTAssertEqual(Prefs.browserViewMode, BrowserViewMode.filmstrip.rawValue)
        first.close()

        let second = await makeBrowser()
        defer { second.close() }
        XCTAssertEqual(second.contentController.mode, .filmstrip, "the next window starts in Filmstrip")
        XCTAssertEqual(second.viewModeGroup?.selectedIndex, BrowserViewMode.filmstrip.rawValue,
                       "the toolbar shows it")
        XCTAssertTrue(second.thumbSizeSlider.isHidden, "no thumbnail slider outside Grid")
        // The picture above the strip is there from the start.
        let content = second.contentController
        XCTAssertNotNil(content.filmstripPreviewForTesting.superview)
        let selected = await waitUntil { content.selectedItems.count == 1 }
        XCTAssertTrue(selected, "the first photo is selected")
        XCTAssertEqual(content.selectedItems.map { $0.url.lastPathComponent }, ["p000.jpg"])
        let shown = await waitUntil { content.filmstripPreviewForTesting.image != nil }
        XCTAssertTrue(shown, "and shown large")
    }

    /// Menu and key commands choose a mode the same way the toolbar does.
    func testAViewCommandIsSavedButAPlainSetModeIsNot() async throws {
        let browser = await makeBrowser()
        defer { browser.close() }
        browser.setMode(.list)
        XCTAssertEqual(Prefs.browserViewMode, 0, "a programmatic switch saves nothing")
        browser.perform(.viewAsFilmstrip)
        XCTAssertEqual(Prefs.browserViewMode, BrowserViewMode.filmstrip.rawValue)
    }

    func testListModeIsSavedToo() async throws {
        let first = await makeBrowser()
        first.chooseMode(.list)
        first.close()
        let second = await makeBrowser()
        defer { second.close() }
        XCTAssertEqual(second.contentController.mode, .list)
    }

    /// 0.2.3 real window path: with the window at 2000 pt the strip and the
    /// large picture end where the inspector starts, in window coordinates.
    func testFilmstripEndsAtTheInspectorInTheRealWindow() async throws {
        Prefs.browserViewMode = BrowserViewMode.filmstrip.rawValue
        let browser = await makeBrowser()
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 2000, height: 1200))
        window.contentView?.layoutSubtreeIfNeeded()
        let content = browser.contentController
        let strip = content.gridScrollViewForTesting
        let stripInWindow = strip.convert(strip.bounds, to: nil)
        let previewInWindow = content.filmstripPreviewForTesting.convert(content.filmstripPreviewForTesting.bounds, to: nil)
        let inspector = try XCTUnwrap(browser.inspectorControllerForTesting?.view)
        let inspectorInWindow = inspector.convert(inspector.bounds, to: nil)
        XCTAssertGreaterThan(inspectorInWindow.width, 100)
        XCTAssertLessThanOrEqual(stripInWindow.maxX, inspectorInWindow.minX + 0.5,
                                 "strip \(stripInWindow) vs inspector \(inspectorInWindow)")
        XCTAssertLessThanOrEqual(previewInWindow.maxX, inspectorInWindow.minX + 0.5,
                                 "preview \(previewInWindow) vs inspector \(inspectorInWindow)")
        XCTAssertLessThanOrEqual(content.view.convert(content.view.bounds, to: nil).maxX, inspectorInWindow.minX + 0.5)
        // The scroller the strip draws ends with the strip.
        if let scroller = strip.horizontalScroller {
            XCTAssertLessThanOrEqual(scroller.convert(scroller.bounds, to: nil).maxX, inspectorInWindow.minX + 0.5)
        }
    }
}

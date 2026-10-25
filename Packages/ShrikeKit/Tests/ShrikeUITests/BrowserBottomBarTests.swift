//
//  BrowserBottomBarTests.swift
//  ShrikeUITests
//
//  The Browser's bottom bar on the window's content border:
//  status strings, the path control, the thumbnail slider.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserBottomBarTests: XCTestCase {

    private var root: URL!
    private var dir: URL!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-bottombar-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Shoot", isDirectory: true)
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

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func item(_ name: String, bytes: Int64, width: Int? = nil, height: Int? = nil) -> BrowserItem {
        let url = URL(fileURLWithPath: "/tmp/\(name)")
        return BrowserItem(url: url, displayName: name, fileSize: bytes, modificationDate: Date(),
                           creationDate: nil, captureDate: nil, utType: .jpeg,
                           pixelWidth: width, pixelHeight: height, rating: 0, isFlagged: false, tags: [])
    }

    // MARK: Strings

    func testStatusStrings() {
        let mb = ByteCountFormatter.string(fromByteCount: 12_400_000, countStyle: .file)
        XCTAssertEqual(BrowserBottomBar.statusText([]), "", "none selected: empty")
        XCTAssertEqual(BrowserBottomBar.statusText([item("DSC_0042.jpg", bytes: 12_400_000, width: 6000, height: 4000)]),
                       "DSC_0042.jpg · 6000 × 4000 · \(mb)")
        XCTAssertEqual(BrowserBottomBar.statusText([item("DSC_0042.jpg", bytes: 12_400_000)]),
                       "DSC_0042.jpg · \(mb)", "dimensions only when known")
        let three = [item("a.jpg", bytes: 16_000_000), item("b.jpg", bytes: 16_000_000), item("c.jpg", bytes: 16_200_000)]
        let total = ByteCountFormatter.string(fromByteCount: 48_200_000, countStyle: .file)
        XCTAssertEqual(BrowserBottomBar.statusText(three), "3 selected · \(total)")
        XCTAssertEqual(BrowserBottomBar.sortingText(key: "Date Captured", done: 1500, total: 5000),
                       "Sorting by Date Captured… \(1500.formatted()) of \(5000.formatted())")
    }

    func testPathEntriesRunFromTheRootToTheFolder() {
        let entries = BrowserBottomBar.quickEntries(for: URL(fileURLWithPath: "/Users/me/Pictures/Shoot", isDirectory: true))
        XCTAssertEqual(entries.map(\.title), ["/", "Users", "me", "Pictures", "Shoot"])
        XCTAssertEqual(entries.last?.url.path, "/Users/me/Pictures/Shoot")
        XCTAssertTrue(entries[0].isVolume)
        let finder = BrowserBottomBar.finderEntries(for: dir)
        XCTAssertEqual(finder.last?.url.standardizedFileURL, dir.standardizedFileURL)
        XCTAssertTrue(finder.first?.isVolume ?? false, "starts at the volume")
    }

    // MARK: In the Browser

    func testBarSitsOnTheWindowsContentBorder() async throws {
        try writeJPEG("a.jpg")
        try writeJPEG("b.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        XCTAssertEqual(window.contentBorderThickness(for: .minY), 24)
        XCTAssertFalse(window.autorecalculatesContentBorderThickness(for: .minY))
        _ = await waitUntil { browser.contentController.visibleItems.count == 2 }
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()

        let bar = browser.bottomBar
        XCTAssertEqual(bar.frame.height, 24)
        XCTAssertEqual(bar.frame.minY, 0)
        let statusX = bar.statusField.alignmentRect(forFrame: bar.statusField.frame).minX
        if #available(macOS 26.0, *) {
            // Clear of the large rounded corners: at
            // least 16 pt, more when the system's corner guide asks for it.
            XCTAssertGreaterThanOrEqual(statusX, 16 - 0.5, "clear of the bottom-left corner")
            XCTAssertLessThanOrEqual(bar.slider.frame.maxX, bar.bounds.maxX - 16 + 0.5)
        } else {
            XCTAssertEqual(statusX, 8, accuracy: 0.5, "8 pt inset to the text")
            XCTAssertEqual(bar.slider.frame.maxX, bar.bounds.maxX - 8, accuracy: 0.5)
        }
        XCTAssertEqual(bar.slider.frame.width, 96, accuracy: 0.5)
        XCTAssertEqual(bar.slider.controlSize, .small)
        XCTAssertEqual(bar.slider.toolTip, "Thumbnail Size")
        XCTAssertEqual(bar.pathControl.pathStyle, .standard)
        XCTAssertEqual(bar.pathControl.controlSize, .small)
        XCTAssertEqual(bar.statusField.font, NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        XCTAssertEqual(bar.statusField.textColor, .secondaryLabelColor)
        XCTAssertNil(bar.subviews.first { $0 is NSVisualEffectView }, "no custom grey strip")

        // Status follows the selection.
        // The first photo is selected when the folder opens, at once. Its
        // status text comes once the header read (JPEG listings have no
        // pixel size) ends or times out, so wait for it.
        XCTAssertEqual(browser.contentController.selectedItems.map(\.displayName), ["a.jpg"],
                       "first photo is selected when the folder opens")
        _ = await waitUntil { browser.statusTextForTesting.hasPrefix("a.jpg") }
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("a.jpg"), browser.statusTextForTesting)
        browser.contentController.selectAll()
        browser.browserContentDidSelect(browser.contentController.selectedItems)
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("2 selected · "), browser.statusTextForTesting)
        browser.sortProgressText = BrowserBottomBar.sortingText(key: "Size", done: 1, total: 2)
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("Sorting by Size…"))
        browser.sortProgressText = nil
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("2 selected"))

        // The slider shows in Grid only.
        browser.setMode(.list)
        XCTAssertTrue(bar.slider.isHidden)
        browser.setMode(.filmstrip)
        XCTAssertTrue(bar.slider.isHidden)
        browser.setMode(.grid)
        XCTAssertFalse(bar.slider.isHidden)
    }

    func testClickingAPathPartGoesThere() async throws {
        try writeJPEG("a.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 1 }
        let bar = browser.bottomBar
        let ready = await waitUntil { bar.pathURLs.last?.standardizedFileURL == self.dir.standardizedFileURL }
        XCTAssertTrue(ready)
        XCTAssertEqual(bar.pathControl.pathItems.count, bar.pathURLs.count)
        XCTAssertEqual(bar.pathControl.pathItems.last?.title, "Shoot")
        let parentIndex = bar.pathURLs.count - 2
        bar.navigate(toPathIndex: parentIndex)
        XCTAssertEqual(browser.currentFolder, root.standardizedFileURL)
        XCTAssertEqual(browser.backStack.last, dir.standardizedFileURL, "a path click is a normal navigation")
    }
}

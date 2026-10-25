//
//  BrowserDrawnSizeTests.swift
//  ShrikeUITests
//
//  Spec 25 §1.2: the Browser's list Dimensions column, the Dimensions
//  sort and the inspector show the size of the file as it is now, right
//  after a rotate, a save, an undo or an outside change. Temp folders only.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserDrawnSizeTests: XCTestCase {

    private var dir: URL!
    private var clock = Date().addingTimeInterval(-3600)
    private var savedSort = BrowserSort.saved

    override func setUp() async throws {
        savedSort = BrowserSort.saved
        dir = TestScratch.directory
            .appendingPathComponent("shrike-drawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        savedSort.save()   // the Dimensions sort test changes the saved sort
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes (or overwrites) a JPEG; every write gets a later file date,
    /// as a real rotate or save does.
    @discardableResult
    private func writeJPEG(_ name: String, width: Int, height: Int) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        clock = clock.addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: clock], ofItemAtPath: url.path)
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func browser(count: Int) async -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists")
        return browser
    }

    private func dimensionsCell(_ content: BrowserContentViewController, row: Int) -> String? {
        let table = content.tableViewForTesting
        guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "col.dim" }),
              let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) else { return nil }
        return cell.subviews.compactMap { $0 as? NSTextField }.first?.stringValue
    }

    func testListDimensionsFollowAFileThatWasRotated() async throws {
        let url = try writeJPEG("a.jpg", width: 64, height: 48)
        let browser = await browser(count: 1)
        defer { browser.close() }
        let content = browser.contentController
        content.setMode(.list)
        await content.waitForListDimensions()
        XCTAssertEqual(dimensionsCell(content, row: 0), "64 × 48")

        // The rotate lands: the file is now 48 × 64.
        try writeJPEG("a.jpg", width: 48, height: 64)
        browser.fileContentsChanged([url])
        let shown = await waitUntil {
            self.dimensionsCell(content, row: 0) == "48 × 64"
        }
        XCTAssertTrue(shown, dimensionsCell(content, row: 0) ?? "nil")
    }

    func testDimensionsSortFollowsAFileThatChanged() async throws {
        try writeJPEG("a.jpg", width: 64, height: 48)          // 3072 px
        let b = try writeJPEG("b.jpg", width: 30, height: 90)  // 2700 px
        let browser = await browser(count: 2)
        defer { browser.close() }
        let content = browser.contentController
        content.sort = BrowserSort(key: .dimensions)
        await content.waitForSortRead()
        XCTAssertEqual(content.visibleItems.map(\.displayName), ["b.jpg", "a.jpg"])

        try writeJPEG("b.jpg", width: 100, height: 100)        // 10000 px
        browser.fileContentsChanged([b])
        let resorted = await waitUntil { content.visibleItems.map(\.displayName) == ["a.jpg", "b.jpg"] }
        XCTAssertTrue(resorted, "the sort read the new size: \(content.visibleItems.map(\.displayName))")
    }

    /// A change reported for either member of a JPG+ORF pair drops what the
    /// Browser keeps under the primary. The primary's file date does not
    /// move when only the RAW companion is written, so the date check in
    /// the caches cannot rescue a stale entry.
    func testGroupMembersShareTheirCacheRefresh() async throws {
        let a = try writeJPEG("a.jpg", width: 64, height: 48)
        let orf = dir.appendingPathComponent("a.orf")
        try Data([0]).write(to: orf)
        let b = try writeJPEG("b.jpg", width: 50, height: 50)
        let browser = await browser(count: 2)
        defer { browser.close() }
        let item = try XCTUnwrap(browser.contentController.allItems.first { $0.displayName == "a.jpg" })
        XCTAssertEqual(item.group.rawURL?.lastPathComponent, "a.orf", "the pair is grouped")

        // Every member maps to the whole group; other photos stay out.
        for member in [a, orf] {
            let mapped = Set(browser.withGroupMembers(of: [member]).map(\.lastPathComponent))
            XCTAssertEqual(mapped, ["a.jpg", "a.orf"], "\(member.lastPathComponent) maps to its group")
            XCTAssertFalse(mapped.contains(b.lastPathComponent))
        }

        // The list size and the Dimensions sort value are kept per primary.
        let content = browser.contentController
        for member in [a, orf] {
            content.setMode(.list)
            content.sort = BrowserSort(key: .dimensions)
            await content.waitForSortRead()
            await content.waitForListDimensions()
            // The previous change re-listed the folder; wait for the sort read after it.
            let read = await waitUntil { content.keepsSortValueForTesting(a) }
            XCTAssertTrue(read, "\(member.lastPathComponent): sort value read")
            let hadListSize = content.keepsListDimensionsForTesting(a)
            browser.fileContentsChanged([member])   // drops synchronously; the re-read is async
            XCTAssertFalse(content.keepsSortValueForTesting(a),
                           "a change on \(member.lastPathComponent) drops the primary's sort value")
            if hadListSize {
                XCTAssertFalse(content.keepsListDimensionsForTesting(a),
                               "a change on \(member.lastPathComponent) drops the primary's list size")
            }
        }

        for member in [a, orf] {
            // nil = "this file has no readable header", kept like any read.
            browser.photoInfoCache.store(nil, for: item)
            XCTAssertEqual(browser.photoInfoCache.lookup(item), .hit(nil))
            browser.fileContentsChanged([member])
            XCTAssertEqual(browser.photoInfoCache.lookup(item), .miss,
                           "a change on \(member.lastPathComponent) drops the primary's header read")
        }
    }

    func testInspectorFollowsAFileThatWasRotated() async throws {
        let url = try writeJPEG("a.jpg", width: 64, height: 48)
        let browser = await browser(count: 1)
        defer { browser.close() }
        XCTAssertTrue(browser.contentController.select(url: url))
        let first = await waitUntil {
            browser.inspectorStateForTesting.commonWidth == 64 && browser.inspectorStateForTesting.commonHeight == 48
        }
        XCTAssertTrue(first, "\(String(describing: browser.inspectorStateForTesting.commonWidth))")

        try writeJPEG("a.jpg", width: 48, height: 64)
        browser.fileContentsChanged([url])
        let second = await waitUntil {
            browser.inspectorStateForTesting.commonWidth == 48 && browser.inspectorStateForTesting.commonHeight == 64
        }
        XCTAssertTrue(second, "\(String(describing: browser.inspectorStateForTesting.commonWidth))")
    }
}

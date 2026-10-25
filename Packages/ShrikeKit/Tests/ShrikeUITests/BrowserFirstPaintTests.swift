//
//  BrowserFirstPaintTests.swift
//  ShrikeUITests
//
//  The grid shows a folder's listing before the saved
//  values (rating, flag, tags, edit marks) are read; they land in place,
//  keeping the selection.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserFirstPaintTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        dir = TestScratch.directory
            .appendingPathComponent("shrike-firstpaint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    func testGridPaintsBeforeSavedValuesAndTheyLandInPlace() async throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try writeJPEG(name) }
        let services = ShrikeServices.makeDefault()
        let rated = dir.appendingPathComponent("b.jpg").standardizedFileURL
        try await services.metadataStore.setRating(4, for: rated)

        var paintedRatings: [Int]?
        var hydrated = false
        // Hooks are set before the listing task can hop back to the main actor.
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        browser.onFolderPaintedForTesting = {
            guard paintedRatings == nil else { return }
            paintedRatings = content.visibleItems.map(\.rating)
            // A selection made before the values land must survive them.
            content.select(url: rated)
        }
        browser.onHydratedForTesting = { hydrated = true }

        let deadline = Date().addingTimeInterval(5)
        while !hydrated, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(hydrated)
        XCTAssertEqual(paintedRatings, [0, 0, 0], "first paint shows the listing before saved values")
        XCTAssertEqual(content.visibleItems.map(\.rating), [0, 4, 0], "values land in place")
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["b.jpg"], "selection kept")
    }

    func testALateHydrateNeverUndoesANewerRating() {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let url = URL(fileURLWithPath: "/tmp/x.jpg")
        let item = BrowserItem(url: url, displayName: "x.jpg", fileSize: 1, modificationDate: Date(),
                               creationDate: nil, captureDate: nil, utType: .jpeg,
                               pixelWidth: nil, pixelHeight: nil, rating: 0)
        content.setItems([item])
        var record = FileRecord()
        record.rating = 5
        content.applyCulling([url: record])
        var stale = item
        stale.rating = 2
        content.applyHydrated([stale])
        XCTAssertEqual(content.visibleItems.first?.rating, 5)
    }

    /// A file rated before the hydrate lands keeps the
    /// newer rating but still gets its tags and edit mark from the hydrate.
    func testALateHydrateStillBringsTagsOfARatedFile() {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let url = URL(fileURLWithPath: "/tmp/y.jpg")
        let item = BrowserItem(url: url, displayName: "y.jpg", fileSize: 1, modificationDate: Date(),
                               creationDate: nil, captureDate: nil, utType: .jpeg,
                               pixelWidth: nil, pixelHeight: nil, rating: 0)
        content.setItems([item])
        var record = FileRecord()
        record.rating = 4
        content.applyCulling([url: record])
        var late = item
        late.rating = 1
        late.tags = ["Red"]
        late.edited = true
        content.applyHydrated([late])
        XCTAssertEqual(content.visibleItems.first?.rating, 4, "the newer rating stays")
        XCTAssertEqual(content.visibleItems.first?.tags, ["Red"], "tags still land")
        XCTAssertEqual(content.visibleItems.first?.edited, true, "edit mark still lands")
    }
}

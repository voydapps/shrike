//
//  ThumbnailGridSpeedTests.swift
//  ShrikeUITests
//
//  0.2.6 grid thumbnails: a cell shows a thumbnail that is already in
//  memory in the same frame (no task, no fade); the grid asks the cache
//  for the cell's pixels (points x screen scale), and tells it when rows
//  leave the prefetch window.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ThumbnailGridSpeedTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-tgrid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func writeJPEG(_ name: String) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 256, height: 192, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
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

    // MARK: Synchronous memory hit

    func testCellShowsAMemoryHitAtOnceWithoutFade() async throws {
        let url = try writeJPEG("a.jpg")
        let cache = try ThumbnailCache(diskURL: dir.appendingPathComponent("cache"))
        _ = try await cache.thumbnail(for: FileImageSource(url: url), maxPixelSize: 64)

        let item = ThumbnailItem()
        _ = item.view
        let model = try BrowserItem.make(from: url)
        item.configure(with: model, pixelSize: 64, cache: cache)

        // No await between configure and the check: same frame.
        XCTAssertTrue(item.hasThumbnailForTesting, "a thumbnail in memory shows in the same turn")
        XCTAssertNil(item.thumbnailFadeForTesting, "no fade for a hit")
    }

    func testCellWithoutAHitStillLoadsAndFades() async throws {
        let url = try writeJPEG("b.jpg")
        let cache = try ThumbnailCache(diskURL: dir.appendingPathComponent("cache2"))
        let item = ThumbnailItem()
        _ = item.view
        item.configure(with: try BrowserItem.make(from: url), pixelSize: 64, cache: cache)
        XCTAssertFalse(item.hasThumbnailForTesting, "a miss is empty until the decode lands")
        let ok = await waitUntil { item.hasThumbnailForTesting }
        XCTAssertTrue(ok)
    }

    // MARK: Request size
    //
    // These use the content controller alone (no Browser window): a test
    // window left behind changes what later window tests see.

    private func makeContent(count: Int) throws -> BrowserContentViewController {
        for i in 0..<count { try writeJPEG(String(format: "p%03d.jpg", i)) }
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        content.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let items = try (0..<count).map { try BrowserItem.make(from: dir.appendingPathComponent(String(format: "p%03d.jpg", $0))) }
        content.setItems(items)
        return content
    }

    func testGridAsksForPointsTimesScreenScale() async throws {
        let content = try makeContent(count: 6)
        content.setMode(.grid)
        content.thumbnailPixelSize = 180
        content.view.layoutSubtreeIfNeeded()

        let scale = content.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let expected = ThumbnailSizing.requestPixels(points: 180, scale: scale)
        XCTAssertEqual(content.cellRequestPixelSize, expected)
        XCTAssertGreaterThanOrEqual(content.cellRequestPixelSize, Int(180 * scale),
                                    "never smaller than the cell's own pixels")

        // A cell made by the data source really asks the cache for that size.
        let cache = ShrikeServices.makeDefault().thumbnailCache
        let item = ThumbnailItem()
        _ = item.view
        let model = content.visibleItems[0]
        item.configure(with: model, pixelSize: content.cellRequestPixelSize, cache: cache)
        let ok = await waitUntil { cache.cachedThumbnail(for: model.imageSource, maxPixelSize: expected) != nil }
        XCTAssertTrue(ok, "the thumbnail lands in the cache at \(expected) px")
        item.cancelLoad()
    }

    func testFilmstripModeAsksForItsFixedCellAtScale() throws {
        let content = try makeContent(count: 3)
        content.setMode(.filmstrip)
        let scale = content.view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        XCTAssertEqual(content.cellRequestPixelSize, ThumbnailSizing.requestPixels(points: 120, scale: scale))
    }

    // MARK: Cancel

    func testRowsLeavingThePrefetchWindowAreWithdrawn() throws {
        let content = try makeContent(count: 6)
        content.setMode(.grid)
        var seen: [(Int, Int)] = []
        content.cancelPrefetchObserverForTesting = { sources, size in seen.append((sources.count, size)) }

        let paths = [IndexPath(item: 2, section: 0), IndexPath(item: 3, section: 0),
                     IndexPath(item: 99, section: 0)]   // 99: out of range, ignored
        content.collectionView(content.collectionViewForTesting, cancelPrefetchingForItemsAt: paths)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, 2)
        XCTAssertEqual(seen.first?.1, content.cellRequestPixelSize)
        content.cancelPrefetchObserverForTesting = nil
    }
}

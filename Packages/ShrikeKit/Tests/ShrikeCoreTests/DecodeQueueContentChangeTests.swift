//
//  DecodeQueueContentChangeTests.swift
//  ShrikeCoreTests
//
//  A rating / flag / tag write is an extended attribute: the folder watcher
//  reports "modified", but the decoded picture is still right. Only a
//  changed size or content date drops it.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class DecodeQueueContentChangeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-contentchange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, width: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 48))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testAttributeWriteKeepsTheDecodeAndAContentRewriteDropsIt() async throws {
        let url = try writeJPEG("a.jpg", width: 64)
        let source = FileImageSource(url: url)
        let q = DecodeQueue(windowRadius: 0)
        await q.setNavigation(list: [source], currentIndex: 0)
        let ready = await eventually { q.readyEntry(sourceID: source.id) != nil }
        XCTAssertTrue(ready)
        let decodes = await q.spawnedIndicesForTesting().count

        // A rating write (extended attribute): nothing is dropped or decoded again.
        FileAttributes.setRating(4, at: url)
        let evictedByRating = await q.evictIfContentChanged(url: url)
        XCTAssertFalse(evictedByRating)
        XCTAssertNotNil(q.readyEntry(sourceID: source.id))
        let afterRating = await q.spawnedIndicesForTesting().count
        XCTAssertEqual(afterRating, decodes, "no second decode for an attribute write")

        // Rewritten in place (new size): dropped, decoded again.
        _ = try writeJPEG("a.jpg", width: 96)
        let evictedByRewrite = await q.evictIfContentChanged(url: url)
        XCTAssertTrue(evictedByRewrite)
        let again = await eventually { q.readyEntry(sourceID: source.id)?.image.width == 96 }
        XCTAssertTrue(again, "the rewritten file is decoded again")
        await q.purge()
    }

    func testStampTellsContentFromAttributes() throws {
        let url = try writeJPEG("b.jpg", width: 64)
        let stamp = try XCTUnwrap(FileContentStamp.read(url))
        FileAttributes.setFlag(true, at: url)
        XCTAssertFalse(stamp.differs(from: url))
        _ = try writeJPEG("b.jpg", width: 80)
        XCTAssertTrue(stamp.differs(from: url))
        XCTAssertTrue(stamp.differs(from: dir.appendingPathComponent("missing.jpg")))
    }
}

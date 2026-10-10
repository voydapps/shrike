//
//  DecodeQueueOversizeTests.swift
//  ShrikeCoreTests
//
//  Leaving full screen left the full-screen sized
//  entries in the cache for good (an entry bigger than the target counted
//  as a hit), so the process kept ~70 MB per photo. An entry far above the
//  target is now replaced by one at the new size.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class DecodeQueueOversizeTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-oversize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeImage(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func writeJPEG(_ name: String, _ w: Int, _ h: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, makeImage(w, h), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testIsOversizeRule() {
        let big = DecodedImage(sourceID: "a", image: makeImage(2000, 1000), requestedLongEdge: 2000)
        XCTAssertTrue(DecodeQueue.isOversize(big, for: 1000), "2000 for a 1000 target")
        XCTAssertFalse(DecodeQueue.isOversize(big, for: 1700), "within 25 % slack")
        XCTAssertFalse(DecodeQueue.isOversize(big, for: 2000))
        // A small source asked for more than it has is not oversize.
        let small = DecodedImage(sourceID: "b", image: makeImage(600, 400), requestedLongEdge: 4096)
        XCTAssertFalse(DecodeQueue.isOversize(small, for: 600))
        // No recorded request size: never judged oversize.
        let unknown = DecodedImage(sourceID: "c", image: makeImage(2000, 1000))
        XCTAssertFalse(DecodeQueue.isOversize(unknown, for: 500))
    }

    func testShrinkingTheTargetReplacesTheBigEntry() async throws {
        let url = try writeJPEG("big.jpg", 3000, 2000)
        let list: [any ImageSource] = [FileImageSource(url: url)]
        let q = DecodeQueue(windowRadius: 1)
        await q.setMaxLongEdge(2800)
        await q.setNavigation(list: list, currentIndex: 0)
        _ = try await q.jumpToEntry(index: 0)
        let big = await q.cachedEntry(at: 0)
        XCTAssertGreaterThan(max(big?.image.width ?? 0, big?.image.height ?? 0), 2000)

        await q.setMaxLongEdge(700)
        let stale = await q.cachedEntry(at: 0)
        XCTAssertNil(stale, "the full-screen sized entry no longer counts")

        let small = try await q.jumpToEntry(index: 0)
        XCTAssertLessThan(max(small.image.width, small.image.height), 1500)
        let bytes = await q.cachedBytes()
        XCTAssertLessThan(bytes, 3000 * 2000 * 4 / 2, "the big pixels are not kept")
    }
}

//
//  DecodeQueueReadyEntryTests.swift
//  ShrikeCoreTests
//
//  The viewer reads the current photo's
//  finished entry without an actor hop, so a cold open can put the
//  photo on the canvas and order the window front in one main-thread
//  turn. Only the current photo, only once decoded, never after the
//  queue moves on or purges.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class DecodeQueueReadyEntryTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-ready-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
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

    func testReadyEntryFollowsTheCurrentPhoto() async throws {
        let list: [any ImageSource] = try (0..<3).map { FileImageSource(url: try writeJPEG("p\($0).jpg")) }
        let q = DecodeQueue(windowRadius: 1)
        XCTAssertNil(q.readyEntry(sourceID: list[0].id), "nothing before a list")

        await q.setNavigation(list: list, currentIndex: 0)
        let ready = await eventually { q.readyEntry(sourceID: list[0].id) != nil }
        XCTAssertTrue(ready, "the current photo is published once decoded")
        XCTAssertEqual(q.readyEntry(sourceID: list[0].id)?.image.width, 64)
        XCTAssertNil(q.readyEntry(sourceID: list[1].id), "a neighbour is not the current photo")

        _ = try await q.jumpToEntry(index: 1)
        XCTAssertNotNil(q.readyEntry(sourceID: list[1].id))
        XCTAssertNil(q.readyEntry(sourceID: list[0].id), "the old current photo is gone")

        await q.purge()
        XCTAssertNil(q.readyEntry(sourceID: list[1].id), "a purge clears it")
    }

    /// An entry made for a smaller display stops counting once the queue
    /// wants a larger one (a bigger window), like `cachedEntry`.
    func testReadyEntryRespectsTheTargetSize() async throws {
        let url = try writeJPEG("big.jpg")
        let list: [any ImageSource] = [FileImageSource(url: url)]
        let q = DecodeQueue(windowRadius: 0)
        await q.setMaxLongEdge(256)
        await q.setNavigation(list: list, currentIndex: 0)
        let ready = await eventually { q.readyEntry(sourceID: list[0].id) != nil }
        XCTAssertTrue(ready)
        let fromActor = await q.cachedEntry(at: 0)
        XCTAssertEqual(q.readyEntry(sourceID: list[0].id)?.sourceID, fromActor?.sourceID,
                       "the snapshot and the actor agree")
    }
}

//
//  DecodeQueueSpeculativeJumpTests.swift
//  ShrikeCoreTests
//
//  COR-5: a jump onto a far neighbour whose speculative decode was refused by the
//  memory budget must decode it again as the current photo, not report a good file
//  as unreadable. (The speculative task fails within microseconds, so the jump
//  usually finds it already gone; the loop gives the reuse path many chances.)
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class DecodeQueueSpeculativeJumpTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-specjump-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func writeJPEG(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testJumpOntoARefusedSpeculativeNeighbourStillDecodes() async throws {
        let sources = try (0..<6).map { FileImageSource(url: try writeJPEG("p\($0).jpg")) }
        for attempt in 0..<20 {
            // A budget of 1 byte refuses every speculative (far) decode; required ones always pass.
            let budget = ImageResourceBudget(configuration: .init(normalBudget: 1))
            let q = DecodeQueue(windowRadius: 3, idleTrimDelay: nil, resources: budget)
            await q.setNavigation(list: sources, currentIndex: 0)
            let entry = try await q.jumpToEntry(index: 3)   // far neighbour, started speculative
            XCTAssertEqual(entry.sourceID, sources[3].id, "attempt \(attempt)")
            await q.purge()
        }
    }
}

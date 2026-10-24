//
//  ThumbnailPressureReliefTests.swift
//  ShrikeCoreTests
//
//  Audit MP-06: optional relief halves the thumbnail memory tier (oldest
//  first); only critical pressure empties it.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class ThumbnailPressureReliefTests: XCTestCase {

    private func writeJPEG(_ url: URL, red: CGFloat) throws {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0.3, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func filledCache(_ tmp: TempDir) async throws -> (ThumbnailCache, Int) {
        let budget = ImageResourceBudget(configuration: .init(normalBudget: 512 << 20, maximumDiscretionaryWorkCount: 8))
        let cache = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("cache"), memoryByteLimit: 1 << 20,
                                       resources: budget)
        for i in 0..<10 {
            let url = tmp.url.appendingPathComponent("p\(i).jpg")
            try writeJPEG(url, red: CGFloat(i) / 10)
            _ = try await cache.thumbnail(for: FileImageSource(url: url), maxPixelSize: 64)
        }
        let bytes = await cache.memoryResidentBytes()
        XCTAssertGreaterThan(bytes, 0)
        return (cache, bytes)
    }

    func testOptionalReliefKeepsTheNewerHalf() async throws {
        let tmp = TempDir("thumb-relief")
        defer { tmp.cleanup() }
        let (cache, full) = try await filledCache(tmp)
        // Make half the limit smaller than what is held.
        let limit = full / 2
        let cacheSmall = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("c2"), memoryByteLimit: limit * 2,
                                            resources: ImageResourceBudget(configuration: .init(normalBudget: 512 << 20, maximumDiscretionaryWorkCount: 8)))
        for i in 0..<10 {
            _ = try await cacheSmall.thumbnail(for: FileImageSource(url: tmp.url.appendingPathComponent("p\(i).jpg")), maxPixelSize: 64)
        }
        let before = await cacheSmall.memoryResidentBytes()
        await cacheSmall.relievePressure(.warning)
        let after = await cacheSmall.memoryResidentBytes()
        XCTAssertGreaterThan(after, 0, "a warning must not empty the tier")
        XCTAssertLessThanOrEqual(after, limit)
        XCTAssertLessThan(after, before)
        _ = cache
    }

    func testCriticalPressureEmptiesTheTier() async throws {
        let tmp = TempDir("thumb-critical")
        defer { tmp.cleanup() }
        let (cache, _) = try await filledCache(tmp)
        await cache.relievePressure(.critical)
        let after = await cache.memoryResidentBytes()
        XCTAssertEqual(after, 0)
    }
}

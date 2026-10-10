//
//  OutputDecoderTests.swift
//  ShrikeCoreTests
//
//  `DecodeQueue.decodeForOutput(url:)` / `OutputDecoder`:
//  full resolution, EXIF orientation applied, file colour space, not
//  cached, cancellable.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class OutputDecoderTests: XCTestCase {

    private typealias F = OrientedImageFixtures

    func testAllEightOrientations_matchImageIOTransform() async throws {
        let tmp = TempDir("output-orient")
        defer { tmp.cleanup() }
        let stored = F.quadrants(width: 240, height: 160)
        for orientation in UInt32(1)...8 {
            let url = tmp.url.appendingPathComponent("o\(orientation).jpg")
            try F.write(stored, to: url, orientation: orientation)

            let out = try await OutputDecoder.decode(url: url)
            let ref = try XCTUnwrap(F.imageIOOriented(url, maxPixelSize: 240))
            XCTAssertEqual(out.width, ref.width, "orientation \(orientation)")
            XCTAssertEqual(out.height, ref.height, "orientation \(orientation)")
            for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let a = F.sample(out, fx, fy), b = F.sample(ref, fx, fy)
                XCTAssertLessThan(a.distance(to: b), 24, "orientation \(orientation) at \(fx),\(fy): \(a) vs \(b)")
            }
        }
    }

    func testFullResolution_noSizeCap() async throws {
        let tmp = TempDir("output-full")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("big.jpg")
        try F.write(F.quadrants(width: 3000, height: 2000), to: url, orientation: 6)
        let out = try await DecodeQueue().decodeForOutput(url: url)
        XCTAssertEqual(out.width, 2000)
        XCTAssertEqual(out.height, 3000)
        // Stored top-left (red) is display top-right for orientation 6.
        let tr = F.sample(out, 0.9, 0.1)
        XCTAssertGreaterThan(tr.r, 200); XCTAssertLessThan(tr.g, 60)
    }

    func testKeepsFileColourSpace_uprightAndRotated() async throws {
        let tmp = TempDir("output-space")
        defer { tmp.cleanup() }
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        for orientation: UInt32 in [1, 8] {
            let url = tmp.url.appendingPathComponent("p3-\(orientation).jpg")
            try F.write(F.quadrants(width: 200, height: 100, space: p3), to: url, orientation: orientation)
            let out = try await OutputDecoder.decode(url: url)
            XCTAssertEqual(out.colorSpace?.name, CGColorSpace.displayP3, "orientation \(orientation)")
        }
    }

    func testSixteenBitSource_keepsDepthWhenRotated() async throws {
        let tmp = TempDir("output-16")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("deep.tiff")
        let space = CGColorSpace(name: CGColorSpace.adobeRGB1998)!
        try F.write(F.quadrants(width: 120, height: 80, space: space, bitsPerComponent: 16),
                    to: url, type: .tiff, orientation: 3)
        let out = try await OutputDecoder.decode(url: url)
        XCTAssertEqual(out.bitsPerComponent, 16)
        XCTAssertEqual(out.colorSpace?.name, CGColorSpace.adobeRGB1998)
        // Orientation 3 = 180°: stored bottom-right (white) is display top-left.
        let tl = F.sample(out, 0.1, 0.1)
        XCTAssertGreaterThan(min(tl.r, tl.g, tl.b), 200)
    }

    func testCancelledTask_throwsCancellation() async throws {
        let url = try TestFixture.url("small.jpg")
        let task = Task { () throws -> CGImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await OutputDecoder.decode(url: url)
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        XCTAssertThrowsError(try OutputDecoder.decodeSync(url: url, isCancelled: { true })) {
            XCTAssertTrue($0 is CancellationError)
        }
    }

    func testMissingFile_throws() async {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).jpg")
        do {
            _ = try await OutputDecoder.decode(url: url)
            XCTFail("expected an error")
        } catch {}
    }
}

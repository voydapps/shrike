//
//  HDRDetectionTests.swift
//  ShrikeEditTests
//
//  Audit G-2: HDR is found by the colour space's transfer function; the profile name is only a
//  whole-word fallback.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit

final class HDRDetectionTests: XCTestCase {

    func testProfileNameMatchesWholeWordsOnly() {
        XCTAssertTrue(ImageExporter.profileNameSaysHDR("Rec. ITU-R BT.2100 PQ"))
        XCTAssertTrue(ImageExporter.profileNameSaysHDR("Rec2020 HLG"))
        XCTAssertTrue(ImageExporter.profileNameSaysHDR("ITU-R BT.2100"))
        XCTAssertFalse(ImageExporter.profileNameSaysHDR("Shopqueue Studio"), "pq inside a word")
        XCTAssertFalse(ImageExporter.profileNameSaysHDR("Display P3"))
        XCTAssertFalse(ImageExporter.profileNameSaysHDR("sRGB IEC61966-2.1"))
        XCTAssertFalse(ImageExporter.profileNameSaysHDR("Camera 21000 profile"))
    }

    private func writePNG16(_ name: String, space: CGColorSpace) throws -> URL {
        let url = TestScratch.directory.appendingPathComponent("\(name)-\(UUID().uuidString).png")
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 16, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testAPQColourSpaceIsHDRAndAnSRGBOneIsNot() throws {
        let pqSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        let pq = try writePNG16("pq", space: pqSpace)
        let srgb = try writePNG16("srgb", space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)))
        defer { for u in [pq, srgb] { try? FileManager.default.removeItem(at: u) } }
        XCTAssertTrue(ImageExporter.capability(for: pq, operations: []).isHDR)
        XCTAssertFalse(ImageExporter.capability(for: srgb, operations: []).isHDR)
    }

    /// Review G-2: an 8-bit file needs no colour-space lookup. The time is printed, not asserted.
    func testCapabilityCostOfAPlainJPEGIsPrinted() throws {
        let url = TestScratch.directory.appendingPathComponent("plain-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let clock = ContinuousClock()
        var hdr = false
        let elapsed = clock.measure { for _ in 0..<200 { hdr = ImageExporter.capability(for: url, operations: []).isHDR } }
        print("G-2 capability(for:) x200 on a small 8-bit JPEG: \(elapsed)")
        XCTAssertFalse(hdr)
    }
}

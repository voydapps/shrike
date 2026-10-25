//
//  FastUprightDecodeTests.swift
//  ShrikeCoreTests
//
//  The display decode fast path (CreateImageAtIndex + SubsampleFactor)
//  skips EXIF orientation, so it must refuse rotated images and must not
//  return oversized output for codecs that ignore SubsampleFactor.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore

final class FastUprightDecodeTests: XCTestCase {

    private func encode(width: Int, height: Int, type: UTType, orientation: Int = 1) throws -> CGImageSource {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try XCTUnwrap(CGImageSourceCreateWithData(data, nil))
    }

    func testUprightJPEGSubsamplesToTheSmallestSizeAtOrAboveTarget() throws {
        let src = try encode(width: 2000, height: 1000, type: .jpeg)
        let image = try XCTUnwrap(FileImageSource.fastUprightDecode(src, target: 500))
        XCTAssertEqual(image.width, 500, "2000 / 4 = 500 >= target; / 8 would undershoot")
        XCTAssertEqual(image.height, 250)
    }

    func testUprightJPEGBelowTargetDecodesFullSize() throws {
        let src = try encode(width: 1200, height: 800, type: .jpeg)
        let image = try XCTUnwrap(FileImageSource.fastUprightDecode(src, target: 4096))
        XCTAssertEqual(image.width, 1200)
    }

    func testRotatedJPEGIsRefused() throws {
        let src = try encode(width: 2000, height: 1000, type: .jpeg, orientation: 6)
        XCTAssertNil(FileImageSource.fastUprightDecode(src, target: 500),
                     "orientation 6 needs the WithTransform thumbnail path")
    }

    func testPNGMoreThanTwiceTheTargetIsRefused() throws {
        let src = try encode(width: 2000, height: 1000, type: .png)
        XCTAssertNil(FileImageSource.fastUprightDecode(src, target: 500))
    }

    /// Thumbnail callers (ThumbnailCache) rely on `loadCGImage`'s strict
    /// cap; only `loadDisplayCGImage` may overshoot via subsampling.
    func testThumbnailPathKeepsStrictCapAndDisplayPathSubsamples() async throws {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: 2000, height: 1000, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let url = TestScratch.directory
            .appendingPathComponent("fast-upright-\(UUID().uuidString).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        defer { try? FileManager.default.removeItem(at: url) }

        let source = FileImageSource(url: url)
        let thumb = try await source.loadCGImage(maxPixelSize: 300)
        XCTAssertLessThanOrEqual(max(thumb.width, thumb.height), 300)
        let display = try await source.loadDisplayCGImage(targetLongEdge: 300)
        XCTAssertEqual(display.width, 500, "2000 / 4 — smallest power-of-two subsample >= 300")
    }

    func testPNGWithinTwiceTheTargetIsDecoded() throws {
        let src = try encode(width: 800, height: 400, type: .png)
        XCTAssertEqual(FileImageSource.fastUprightDecode(src, target: 500)?.width, 800)
    }
}

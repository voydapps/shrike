//
//  RotatedUploadTests.swift
//  ShrikeRenderingTests
//
//  A rotated JPEG's texture is built from its
//  stored pixels with the EXIF orientation applied on the GPU. It must
//  hold the same picture, the same way up, in the same colours as the old
//  texture built from ImageIO's CPU-rotated decode.
//

import XCTest
import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeRendering

final class RotatedUploadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "no Metal device")
        dir = TestScratch.directory
            .appendingPathComponent("rotated-upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    /// Quadrants: red top-left, green top-right, blue bottom-left, white
    /// bottom-right (stored frame).
    private func quadrantJPEG(orientation: UInt32, space: CGColorSpace) throws -> FileImageSource {
        let w = 400, h = 240
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        func fill(_ c: [CGFloat], _ r: CGRect) {
            ctx.setFillColor(CGColor(colorSpace: space, components: c + [1])!)
            ctx.fill(r)
        }
        fill([0.9, 0.1, 0.1], CGRect(x: 0, y: 120, width: 200, height: 120))
        fill([0.1, 0.8, 0.2], CGRect(x: 200, y: 120, width: 200, height: 120))
        fill([0.2, 0.2, 0.9], CGRect(x: 0, y: 0, width: 200, height: 120))
        fill([0.95, 0.95, 0.95], CGRect(x: 200, y: 0, width: 200, height: 120))
        let url = dir.appendingPathComponent("q\(orientation)-\(UUID().uuidString).jpg")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return FileImageSource(url: url)
    }

    private func readBack(_ texture: DisplayTexture) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let t = texture.storage
        let device = try XCTUnwrap(DisplayTextureFactory.device)
        let bpr = t.width * 4
        let buf = try XCTUnwrap(device.makeBuffer(length: bpr * t.height, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(cb.makeBlitCommandEncoder())
        blit.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: t.width, height: t.height, depth: 1), to: buf,
                  destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * t.height)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let p = buf.contents().assumingMemoryBound(to: UInt8.self)
        return (Array(UnsafeBufferPointer(start: p, count: bpr * t.height)), t.width, t.height)
    }

    private func compare(space: CGColorSpace, encoding: DisplayTextureEncoding) throws {
        for orientation: UInt32 in 2...8 {
            let file = try quadrantJPEG(orientation: orientation, space: space)
            let target = 300
            let oldImage = try file.decodeDisplayImage(targetLongEdge: target)
            let old = try XCTUnwrap(DisplayTextureFactory.make(
                from: oldImage, commandQueue: nil, waitUntilCompleted: true, maxLongEdge: target))
            let frame = try XCTUnwrap(file.decodeRotatedStoredFrame(targetLongEdge: target))
            let twin = try XCTUnwrap(file.lazyOrientedDisplayImage(frame: frame, targetLongEdge: target))
            let new = try XCTUnwrap(DisplayTextureFactory.make(
                from: frame.image, orientation: frame.orientation, sourceSize: (twin.width, twin.height),
                commandQueue: nil, waitUntilCompleted: true, maxLongEdge: target))

            XCTAssertEqual(new.encoding, encoding)
            XCTAssertEqual(new.encoding, old.encoding)
            XCTAssertEqual(new.storage.width, old.storage.width, "orientation \(orientation)")
            XCTAssertEqual(new.storage.height, old.storage.height, "orientation \(orientation)")
            XCTAssertTrue(new.matches(twin), "texture reports the twin's size")
            XCTAssertTrue(new.matches(oldImage), "same source size as the old texture")

            let a = try readBack(old), b = try readBack(new)
            // Same picture the same way up: every quadrant's centre matches.
            for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                let x = Int(fx * Double(a.width)), y = Int(fy * Double(a.height))
                let i = (y * a.width + x) * 4
                for c in 0..<3 {
                    XCTAssertLessThanOrEqual(abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c])), 3,
                                             "orientation \(orientation) at \(fx),\(fy) channel \(c)")
                }
            }
            // Same colours overall (only the resample filter differs).
            var sumA = [0, 0, 0], sumB = [0, 0, 0], diff = 0
            for i in stride(from: 0, to: a.bytes.count, by: 4) {
                for c in 0..<3 {
                    sumA[c] += Int(a.bytes[i + c]); sumB[c] += Int(b.bytes[i + c])
                    diff += abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))
                }
            }
            let n = Double(a.bytes.count / 4)
            for c in 0..<3 {
                XCTAssertEqual(Double(sumA[c]) / n, Double(sumB[c]) / n, accuracy: 0.6,
                               "orientation \(orientation) channel \(c) mean")
            }
            XCTAssertLessThan(Double(diff) / (n * 3), 1.5, "orientation \(orientation) mean abs diff")
        }
    }

    func testRotatedSRGBTextureMatchesTheOldPath() throws {
        try compare(space: CGColorSpace(name: CGColorSpace.sRGB)!, encoding: .srgb8)
    }

    func testRotatedDisplayP3TextureMatchesTheOldPath() throws {
        try compare(space: CGColorSpace(name: CGColorSpace.displayP3)!, encoding: .displayP3_8)
    }

    func testUprightGraphIsUnchanged() throws {
        // `.up` with no size: the flip only (what every upload did before).
        let image = try XCTUnwrap(DisplayTextureFactory.warmUpImage())
        let ci = DisplayTextureFactory.uploadImage(image, orientation: .up, scaledTo: nil)
        XCTAssertEqual(ci.extent, CGRect(x: 0, y: 0, width: 16, height: 16))
        let scaled = DisplayTextureFactory.uploadImage(image, orientation: .right, scaledTo: (4, 8))
        XCTAssertEqual(scaled.extent.isInfinite, true, "clamped for the resample")
    }

    func testPreparerBuildsRotatedTexturesThroughTheOrientedPath() throws {
        XCTAssertNotNil(DisplayTextureFactory.preparer.prepareOriented)
        let file = try quadrantJPEG(orientation: 6, space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let frame = try XCTUnwrap(file.decodeRotatedStoredFrame(targetLongEdge: 200))
        let made = DisplayTextureFactory.preparer.prepareOriented?(frame.image, frame.orientation, (120, 200), 200)
        let texture = try XCTUnwrap(made as? DisplayTexture)
        XCTAssertEqual(texture.storage.width, 120)
        XCTAssertEqual(texture.storage.height, 200)
        XCTAssertEqual(texture.sourceWidth, 120)
        XCTAssertEqual(texture.sourceHeight, 200)
    }
}

//
//  DisplayTextureTests.swift
//  ShrikeRenderingTests
//
//  Next/prev under 50 ms: SDR photos use 8-bit textures
//  built off the main thread; only 16-bit / float / wider-than-P3 photos
//  keep the linear rgba16Float path. These tests pin:
//    * the encoding choice per colour space and bit depth;
//    * sRGB bytes land in the texture EXACTLY (no colour drift from the
//      new path), and the shader's linear-P3 output matches the old
//      Core Image conversion;
//    * a prepared texture is used as-is (no main-thread upload);
//    * the drawable format follows the photo (8-bit for SDR, float for 16F).
//

import XCTest
import CoreGraphics
import Metal
@testable import ShrikeRendering

final class DisplayTextureTests: XCTestCase {

    private func solid(
        _ rgba: [UInt8], space: CGColorSpace, width: Int = 4, height: Int = 4
    ) -> CGImage {
        var bytes: [UInt8] = []
        for _ in 0..<(width * height) { bytes += rgba }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func sixteenBit(space: CGColorSpace) -> CGImage {
        let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 16, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return ctx.makeImage()!
    }

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let adobe = CGColorSpace(name: CGColorSpace.adobeRGB1998)!

    func testEncodingChoice() {
        XCTAssertEqual(DisplayTextureFactory.encoding(for: solid([1, 2, 3, 255], space: srgb)), .srgb8)
        XCTAssertEqual(DisplayTextureFactory.encoding(for: solid([1, 2, 3, 255], space: p3)), .displayP3_8)
        XCTAssertEqual(DisplayTextureFactory.encoding(for: solid([1, 2, 3, 255], space: adobe)), .linearP3Half,
                       "Adobe RGB is wider than P3 in places; keep the float path")
        XCTAssertEqual(DisplayTextureFactory.encoding(for: sixteenBit(space: srgb)), .linearP3Half,
                       "16-bit sources keep their precision")
    }

    @MainActor
    func testSRGBBytesLandExactlyAndMatchOldConversion() throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let image = solid([200, 100, 50, 255], space: srgb)
        view.image = image

        XCTAssertEqual(view.currentEncodingForTesting, .srgb8)
        XCTAssertEqual(view.layerPixelFormatForTesting, .bgra8Unorm_srgb)
        #if DEBUG
        let bytes = try XCTUnwrap(view.lastUploadedBytesForTesting)
        XCTAssertEqual(bytes, SIMD4<UInt8>(200, 100, 50, 255), "sRGB bytes must be copied unchanged")

        // What the shader outputs (linear P3) must match the old Core
        // Image sRGB → linear-P3 conversion.
        let sample = try XCTUnwrap(view.lastUploadedSampleForTesting)
        let old = try XCTUnwrap(ColorPipeline.convertSRGBToWorking(
            r: 200.0 / 255, g: 100.0 / 255, b: 50.0 / 255
        ))
        XCTAssertEqual(Double(sample.x), old.r, accuracy: 0.01)
        XCTAssertEqual(Double(sample.y), old.g, accuracy: 0.01)
        XCTAssertEqual(Double(sample.z), old.b, accuracy: 0.01)
        #endif
    }

    @MainActor
    func testDisplayP3BytesLandExactly() throws {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.image = solid([10, 250, 30, 255], space: p3)
        XCTAssertEqual(view.currentEncodingForTesting, .displayP3_8)
        #if DEBUG
        XCTAssertEqual(view.lastUploadedBytesForTesting, SIMD4<UInt8>(10, 250, 30, 255))
        #endif
    }

    @MainActor
    func testPreparedTextureIsUsedWithoutMainThreadUpload() async throws {
        let image = solid([90, 90, 90, 255], space: srgb, width: 32, height: 16)
        // Built off the main actor, like the decode lane does.
        let prepared = await Task.detached {
            DisplayTextureFactory.preparer(image, nil) as? DisplayTexture
        }.value
        let texture = try XCTUnwrap(prepared)
        XCTAssertEqual(texture.byteCount, 32 * 16 * 4, "SDR textures are 4 bytes per pixel, not 8")

        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        let before = view.mainThreadUploadCountForTesting
        view.setImage(image, sourceID: "file:///x.jpg", prepared: texture)
        XCTAssertEqual(view.mainThreadUploadCountForTesting, before,
                       "a prepared texture must not be rebuilt on the main thread")
        XCTAssertEqual(view.sourceID, "file:///x.jpg")

        // A prepared texture of the wrong size (another image) is ignored.
        let other = solid([1, 1, 1, 255], space: srgb, width: 8, height: 8)
        view.setImage(other, sourceID: "file:///y.jpg", prepared: texture)
        XCTAssertEqual(view.mainThreadUploadCountForTesting, before + 1)
    }

    @MainActor
    func testLayerKeepsTwoDrawablesNotThree() {
        // A drawable is the window's pixels x 4 bytes (70 MB each on a 5K
        // full screen). The viewer draws on demand, so two are enough.
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(view.maximumDrawableCountForTesting, 2)
    }

    @MainActor
    func testDrawableFormatFollowsThePhoto() {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.image = sixteenBit(space: srgb)
        XCTAssertEqual(view.currentEncodingForTesting, .linearP3Half)
        XCTAssertEqual(view.layerPixelFormatForTesting, .rgba16Float)
        view.image = solid([5, 6, 7, 255], space: srgb)
        XCTAssertEqual(view.layerPixelFormatForTesting, .bgra8Unorm_srgb)
        view.allowsHDR = true
        XCTAssertEqual(view.layerPixelFormatForTesting, .rgba16Float, "HDR output needs the float drawable")
    }
}

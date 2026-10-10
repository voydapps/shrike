//
//  MetalImageViewUploadTests.swift
//  ShrikeRenderingTests
//
//  Regression coverage for the "image renders as solid black" bug
//  reported against PNG. The viewer's full-res upload path was:
//    1. `ColorPipeline.normalized(image)` — convert source ICC → linear
//       Display-P3 and emit an `rgba16Float` CGImage.
//    2. `MTKTextureLoader.newTexture(cgImage:)` — upload to GPU.
//
//  Step 2 throws "Image decoding failed" for the half-float CGImage that
//  step 1 produces. `MTKTextureLoader.newTexture(cgImage:)` is documented
//  to accept "any CGImage" but in practice only handles 8-bit-per-component
//  inputs cleanly; the 16-bit-float path is a known gap in MetalKit
//  (rdar-class issue, no public fix). The `handleImageChange` catch block
//  swallowed the throw and only emitted a signpost, so `currentTexture`
//  stayed at its previous value (or nil for a freshly opened window) and
//  the renderer painted only the clear colour: black.
//
//  The user surfaced this as "PNG renders black", but the failure mode is
//  format-agnostic given the right combination of CGImage layout and
//  GPU/MetalKit version — JPEGs only happened to escape on some hardware.
//  Filmstrip thumbnails were unaffected because `ThumbCellView` paints
//  CGImages through Core Graphics directly, not through this Metal upload.
//
//  The fix replaces the `normalized → MTKTextureLoader` two-step with a
//  single `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` call
//  that owns the texture write end-to-end. CIContext can target a
//  pre-allocated `rgba16Float` MTLTexture and applies the colour
//  conversion in the same GPU pass, removing both the broken intermediate
//  CGImage allocation and the loader hop.
//

import Foundation
import XCTest
import CoreGraphics
import ImageIO
@testable import ShrikeRendering

final class MetalImageViewUploadTests: XCTestCase {

    // MARK: - Fixture loading

    /// Load a CGImage fixture from the test bundle by base name (without
    /// extension) and `ext` (e.g. "png", "jpg"). Returns `nil` if the
    /// fixture is missing or ImageIO refuses it.
    private func loadFixture(name: String, ext: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(
            src, 0,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
    }

    // MARK: - Black-screen regression

    /// Loads `small.png`, pushes it through `MetalImageView`'s real upload
    /// path, and asserts a non-zero texture lands. Before the fix this
    /// test fails: the upload throws inside
    /// `MTKTextureLoader.newTexture(cgImage:)` (which can't decode the
    /// half-float CGImage produced by `ColorPipeline.normalized`) and the
    /// catch block leaves `currentTexture` at nil → the view paints solid
    /// black.
    @MainActor
    func testPNGUpload_ProducesNonZeroTexture() throws {
        guard let png = loadFixture(name: "small", ext: "png") else {
            throw XCTSkip("small.png fixture missing")
        }
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
        view.image = png

        #if !DEBUG
        // The read-back sample is DEBUG-only (it would cost cached-nav time
        // in Release); `swift test -c release` checks the texture exists.
        XCTAssertNotNil(view.textureSizeForTesting, "PNG upload produced no texture")
        throw XCTSkip("pixel read-back is DEBUG-only")
        #endif
        guard let sample = view.lastUploadedSampleForTesting else {
            XCTFail(
                "PNG upload produced no texture — handleImageChange swallowed the "
                + "MTKTextureLoader 'Image decoding failed' error and left currentTexture nil"
            )
            return
        }

        // The fixture's first pixel is sRGB blue (20, 20, 220). After
        // sRGB → linear-P3 conversion the red and green channels are tiny
        // (<0.02) but the blue channel is large (~0.65). The simplest
        // invariant we can assert without coupling to exact half-float
        // bits is "at least one colour channel is materially non-zero",
        // which is the assertion that fails when the upload path is broken.
        let maxChannel = max(sample.x, max(sample.y, sample.z))
        XCTAssertGreaterThan(
            maxChannel, 0.05,
            "Expected at least one colour channel to be materially non-zero "
            + "after upload; got \(sample). All channels near zero indicates the "
            + "PNG-renders-black regression is back."
        )
    }

    /// Companion test that proves JPEGs continue to upload correctly.
    /// Guards against an over-correction that breaks the JPEG path while
    /// fixing PNG.
    @MainActor
    func testJPEGUpload_ProducesNonZeroTexture() throws {
        guard let jpg = loadFixture(name: "small", ext: "jpg") else {
            throw XCTSkip("small.jpg fixture missing")
        }
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 256, height: 256))
        view.image = jpg

        #if !DEBUG
        XCTAssertNotNil(view.textureSizeForTesting, "JPEG upload produced no texture")
        throw XCTSkip("pixel read-back is DEBUG-only")
        #endif
        guard let sample = view.lastUploadedSampleForTesting else {
            XCTFail("JPEG upload produced no texture")
            return
        }
        let maxChannel = max(sample.x, max(sample.y, sample.z))
        XCTAssertGreaterThan(
            maxChannel, 0.05,
            "JPEG upload regressed: sample \(sample) is near-black"
        )
    }
}

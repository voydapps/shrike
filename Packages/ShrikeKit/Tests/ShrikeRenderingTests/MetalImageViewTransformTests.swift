//
//  MetalImageViewTransformTests.swift
//  ShrikeRenderingTests
//
//  Pure-math tests for MetalImageView.clipSpaceTransform. No GPU required:
//  we call the static factored-out pure function and assert on the returned
//  simd_float4x4. Keeps the viewer's geometry math verified across content
//  modes without needing a drawable or display device.
//

import Foundation
import XCTest
import simd
@testable import ShrikeRendering

final class MetalImageViewTransformTests: XCTestCase {

    // MARK: - Bestfit scaling

    func testBestFit_LandscapeImage_LandscapeView_FitsWidth() {
        // 2000x1000 image into 400x400 view → long edge caps at 400 → scale 0.2
        // final on-screen size = 400 x 200.
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 2000,
            textureHeight: 1000,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 0.2,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        // Clip-space scale = effSize / viewSize = 400/400, 200/400 = 1.0, 0.5.
        XCTAssertEqual(m.columns.0.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 0.5, accuracy: 1e-5)
    }

    func testBestFit_PortraitImage_LandscapeView_FitsHeight() {
        // 500x1000 image into 800x400 view → fit by height → scale = 0.4
        // on-screen = 200 x 400.  clip scale = 200/800=0.25, 400/400=1.0.
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 500,
            textureHeight: 1000,
            viewSize: CGSize(width: 800, height: 400),
            zoom: 0.4,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m.columns.0.x, 0.25, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 1.0, accuracy: 1e-5)
    }

    // MARK: - Actual size / zoom

    func testActualSize_ImageSmallerThanView_CentersUnscaled() {
        // 100x100 image, 400x400 view, zoom 1.0 → on-screen 100x100 → clip
        // scale = 0.25, 0.25.
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 100,
            textureHeight: 100,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 1.0,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m.columns.0.x, 0.25, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 0.25, accuracy: 1e-5)
        // No translation when pan is zero.
        XCTAssertEqual(m.columns.3.x, 0, accuracy: 1e-6)
        XCTAssertEqual(m.columns.3.y, 0, accuracy: 1e-6)
    }

    func testZoom200Percent_EnlargesQuad() {
        // 100x100 image in a 400x400 view at 2x zoom → on-screen 200x200
        // → clip scale 0.5, 0.5.
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 100,
            textureHeight: 100,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 2.0,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m.columns.0.x, 0.5, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 0.5, accuracy: 1e-5)
    }

    // MARK: - Pan translation

    func testPan_TranslatesByViewFractionInClipSpace() {
        // pan.x = 200 pts in a 400-pt view → clip tx = 200 * 2 / 400 = 1.0
        // pan.y = -100 in a 400-pt view → clip ty = -100 * 2 / 400 = -0.5
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 400,
            textureHeight: 400,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 1.0,
            pan: CGPoint(x: 200, y: -100),
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m.columns.3.x, 1.0, accuracy: 1e-5)
        XCTAssertEqual(m.columns.3.y, -0.5, accuracy: 1e-5)
    }

    // MARK: - Rotation

    func testRotation90_SwapsEffectiveDimensions() {
        // 800x400 image rotated 90° → effective 400w x 800h.
        // View 400x400, zoom 1.0 → clip scale = effW/viewW = 400/400 = 1 for x,
        // but remember that simd matrix multiplication order means the final
        // `columns.0.x` includes the rotation factor.
        //
        // So just check the determinant: rotation preserves area, so the
        // product of singular values should equal (effW*effH)/(viewW*viewH).
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 800,
            textureHeight: 400,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 1.0,
            pan: .zero,
            rotationDegrees: 90,
            flippedH: false,
            flippedV: false
        )
        // Linear block is the top-left 3x3; determinant for a 2D affine is
        // det(M) of the 2x2 top-left.
        let a = m.columns.0.x
        let b = m.columns.0.y
        let c = m.columns.1.x
        let d = m.columns.1.y
        let det = a * d - b * c
        let expected: Float = (400 * 800) / (400 * 400)   // = 2.0
        XCTAssertEqual(abs(det), expected, accuracy: 1e-4)
    }

    // MARK: - Flip

    func testFlipHorizontal_NegatesX() {
        // With rotation 0 and flip horizontal, the x scale should be negated.
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 200,
            textureHeight: 200,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 1.0,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: true,
            flippedV: false
        )
        // image_size / view_size = 0.5; flipped → -0.5
        XCTAssertEqual(m.columns.0.x, -0.5, accuracy: 1e-5)
        XCTAssertEqual(m.columns.1.y, 0.5, accuracy: 1e-5)
    }

    // MARK: - Edge cases

    func testZeroViewSize_ReturnsIdentity() {
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 100,
            textureHeight: 100,
            viewSize: CGSize(width: 0, height: 0),
            zoom: 1.0,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m, matrix_identity_float4x4)
    }

    func testZeroTextureSize_ReturnsIdentity() {
        let m = MetalImageView.clipSpaceTransform(
            textureWidth: 0,
            textureHeight: 0,
            viewSize: CGSize(width: 400, height: 400),
            zoom: 1.0,
            pan: .zero,
            rotationDegrees: 0,
            flippedH: false,
            flippedV: false
        )
        XCTAssertEqual(m, matrix_identity_float4x4)
    }
}

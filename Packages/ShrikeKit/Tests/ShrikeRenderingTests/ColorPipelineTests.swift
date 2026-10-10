//
//  ColorPipelineTests.swift
//  ShrikeRenderingTests
//
//  Regression coverage for the "blue/purple cast" bug. The
//  Metal layer is configured as rgba16Float / extendedLinearDisplayP3 — i.e.
//  linear-light samples in wide-gamut primaries. Before the fix, incoming
//  sRGB JPEGs were uploaded without any gamma or primary conversion, so the
//  gamma-encoded bytes were interpreted as if they were already linear P3.
//  Blacks stayed black (0 maps to 0) but mid-tones and highlights shifted
//  heavily toward blue.
//
//  These tests verify `ColorPipeline` normalisation without requiring a
//  drawable or screen. They run a known sRGB colour through the shared
//  CIContext and assert the output approximates the expected linear-P3
//  value.
//

import Foundation
import XCTest
@testable import ShrikeRendering

final class ColorPipelineTests: XCTestCase {

    // MARK: - Transfer function

    func testSRGBToLinear_Zero() {
        XCTAssertEqual(ColorPipeline.srgbToLinear(0), 0, accuracy: 1e-9)
    }

    func testSRGBToLinear_One() {
        XCTAssertEqual(ColorPipeline.srgbToLinear(1), 1, accuracy: 1e-6)
    }

    func testSRGBToLinear_MidGrey() {
        // 0.5 sRGB ≈ 0.214 linear (well-known reference value).
        XCTAssertEqual(
            ColorPipeline.srgbToLinear(0.5),
            0.2140, accuracy: 0.001
        )
    }

    // MARK: - End-to-end colour conversion

    /// 50 % sRGB grey (no blue tint) must stay grey after normalisation —
    /// the bug was exactly this case coming out blue because the gamma and
    /// primary conversion were being skipped.
    func testSRGBGrey_StaysGrey_AndDropsIntoLinearRange() throws {
        guard let (r, g, b) = ColorPipeline.convertSRGBToWorking(
            r: 0.5, g: 0.5, b: 0.5
        ) else {
            throw XCTSkip("CoreImage conversion unavailable on this host")
        }

        // Linear value for 50 % sRGB ≈ 0.214. P3 and sRGB share the D65
        // white point, so a neutral sRGB grey stays neutral in P3 (to
        // within 1 % tolerance given half-float precision and the slight
        // matrix rounding through CIContext).
        XCTAssertEqual(r, 0.214, accuracy: 0.02,
                       "red should fall in linear range, not gamma-encoded ~0.5")
        XCTAssertEqual(g, 0.214, accuracy: 0.02)
        XCTAssertEqual(b, 0.214, accuracy: 0.02)

        // The heart of the regression: before the fix, the uploaded byte
        // 0x80 was interpreted directly as a linear float ~0.5. Assert
        // that's no longer the case.
        XCTAssertLessThan(r, 0.35, "value must have been gamma-decoded")
        XCTAssertLessThan(g, 0.35)
        XCTAssertLessThan(b, 0.35)
    }

    /// Pure sRGB red (1, 0, 0) converted into linear Display-P3 should:
    ///   * Have a dominant red component. Display-P3 red is *wider* than
    ///     sRGB red, so sRGB(1,0,0) doesn't reach P3(1,0,0); it sits at
    ///     roughly (0.92, 0.20, 0) in gamma-encoded P3, ≈ (0.82, 0.03, 0)
    ///     after the linearisation step. The important invariant for this
    ///     regression is "red dominates and blue stays near zero."
    ///   * Have blue very close to zero — this is the failure mode. In
    ///     the shipped bug, sRGB red samples acquired a blue component
    ///     because the primary-conversion matrix wasn't applied.
    func testSRGBRed_StaysRedInLinearP3_NoBlueLeak() throws {
        guard let (r, g, b) = ColorPipeline.convertSRGBToWorking(
            r: 1.0, g: 0.0, b: 0.0
        ) else {
            throw XCTSkip("CoreImage conversion unavailable on this host")
        }
        XCTAssertGreaterThan(r, 0.7, "red component should dominate")
        XCTAssertGreaterThan(r, max(g, b) * 3,
                             "red must dominate green and blue by >3x")
        XCTAssertLessThan(b, 0.05, "blue component must be near zero")
        XCTAssertLessThan(g, 0.1, "green component must be near zero")
    }

    func testSRGBBlack_StaysBlack() throws {
        guard let (r, g, b) = ColorPipeline.convertSRGBToWorking(
            r: 0, g: 0, b: 0
        ) else {
            throw XCTSkip("CoreImage conversion unavailable on this host")
        }
        XCTAssertEqual(r, 0, accuracy: 0.005)
        XCTAssertEqual(g, 0, accuracy: 0.005)
        XCTAssertEqual(b, 0, accuracy: 0.005)
    }

    func testSRGBWhite_StaysNearOne() throws {
        guard let (r, g, b) = ColorPipeline.convertSRGBToWorking(
            r: 1, g: 1, b: 1
        ) else {
            throw XCTSkip("CoreImage conversion unavailable on this host")
        }
        // sRGB and Display-P3 share D65 — white maps to ~1 in all channels.
        XCTAssertEqual(r, 1.0, accuracy: 0.03)
        XCTAssertEqual(g, 1.0, accuracy: 0.03)
        XCTAssertEqual(b, 1.0, accuracy: 0.03)
    }
}

//
//  RecipeToolParamsTests.swift
//  ShrikeEditTests
//
//  Covers the latest-wins drop plus the pure-tool params happy-path
//  sanity checks that catch obvious regressions in `Crop` / `Resize` /
//  `Rotate90` dimensions.
//

import XCTest
import CoreGraphics
@testable import ShrikeEdit

final class RecipeToolParamsTests: XCTestCase {

    // MARK: Latest-wins drops intermediate renders.

    /// Queue 10 rapid `render` calls against the same renderer. The
    /// generation guard inside `EditRenderer` should drop all but the
    /// first (which completes before the bursts arrive) and the last
    /// (which claims the final generation). The intermediate 8 return
    /// `nil` (dropped).
    ///
    /// This asserts the shape of the drop contract — the UI
    /// tosses `nil` results on the floor, which is what the design expects.
    func test_render_dropsIntermediateRequests_whenBursted() async {
        let renderer = EditRenderer()
        let source = EditFixture.solidRGB(width: 128, height: 128, red: 0.2, green: 0.4, blue: 0.6)
        let recipe = EditRecipe()
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.1)))

        // Fire 10 renders in a tight loop without awaiting. Every call
        // bumps `latestGen` before the yield in the prior one resumes.
        async let r0 = renderer.render(recipe: recipe, from: source)
        async let r1 = renderer.render(recipe: recipe, from: source)
        async let r2 = renderer.render(recipe: recipe, from: source)
        async let r3 = renderer.render(recipe: recipe, from: source)
        async let r4 = renderer.render(recipe: recipe, from: source)
        async let r5 = renderer.render(recipe: recipe, from: source)
        async let r6 = renderer.render(recipe: recipe, from: source)
        async let r7 = renderer.render(recipe: recipe, from: source)
        async let r8 = renderer.render(recipe: recipe, from: source)
        async let r9 = renderer.render(recipe: recipe, from: source)

        let results = await [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9]
        let survivors = results.compactMap { $0 }

        // At least one result must survive (the final call is guaranteed
        // to win its generation check). At most two ("at
        // most 2 actual Core Image passes executed — the first and the
        // last"). The actor serialises, so in practice the first entry
        // runs to completion before any later one arrives; the generic
        // upper bound we enforce here is "< total fires".
        XCTAssertGreaterThanOrEqual(survivors.count, 1,
                                    "at least one render must survive (the latest one)")
        XCTAssertLessThan(survivors.count, results.count,
                          "intermediate renders must be dropped — latest-wins")
    }

    func test_renderFinal_neverDrops() async {
        // renderFinal is unconditional — no generation gate. Even when
        // peer renders bump the generation, renderFinal must return.
        let renderer = EditRenderer()
        let source = EditFixture.solidRGB(width: 32, height: 32, red: 0.1, green: 0.2, blue: 0.3)
        let recipe = EditRecipe()
        await recipe.append(.rotate90(quarters: 1))

        async let peer0 = renderer.render(recipe: recipe, from: source)
        async let peer1 = renderer.render(recipe: recipe, from: source)
        let result = await renderer.renderFinal(recipe: recipe, from: source)
        _ = await (peer0, peer1)

        XCTAssertEqual(result.width, 32)
        XCTAssertEqual(result.height, 32)
    }

    // MARK: Tool param sanity checks.

    func test_cropTool_fullRect_isIdentity() {
        let source = EditFixture.solidRGB(width: 16, height: 16, red: 1, green: 0, blue: 0)
        let out = CropTool.apply(.full, to: source)
        XCTAssertEqual(out.width, 16)
        XCTAssertEqual(out.height, 16)
    }

    func test_cropTool_halfRect_halvesEachDimension() {
        let source = EditFixture.solidRGB(width: 20, height: 10, red: 0, green: 1, blue: 0)
        let rect = CropRect(originX: 0, originY: 0, width: 0.5, height: 0.5)
        let out = CropTool.apply(rect, to: source)
        XCTAssertEqual(out.width, 10)
        XCTAssertEqual(out.height, 5)
    }

    func test_cropRect_isValidRejectsOutOfRange() {
        XCTAssertFalse(CropRect(originX: -0.1, originY: 0, width: 1, height: 1).isValid)
        XCTAssertFalse(CropRect(originX: 0.6, originY: 0, width: 0.5, height: 1).isValid,
                       "0.6 + 0.5 = 1.1 — rect leaks off the right edge")
        XCTAssertFalse(CropRect(originX: 0, originY: 0, width: 0, height: 1).isValid)
        XCTAssertTrue(CropRect(originX: 0, originY: 0, width: 1, height: 1).isValid)
    }

    func test_rotate90_quarters_normalisesModFour() {
        let source = EditFixture.solidRGB(width: 10, height: 6, red: 0, green: 0, blue: 1)
        let a = RotateTool.apply90(quarters: 1, to: source)
        let b = RotateTool.apply90(quarters: 5, to: source)   // 5 mod 4 = 1
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)

        // quarters=0 is identity.
        let c = RotateTool.apply90(quarters: 0, to: source)
        XCTAssertEqual(c.width, source.width)
        XCTAssertEqual(c.height, source.height)

        // Negative quarters work too (-1 == +3).
        let d = RotateTool.apply90(quarters: -1, to: source)
        XCTAssertEqual(d.width, 6)
        XCTAssertEqual(d.height, 10)
    }

    func test_resize_preventUpscale_clampsToSource() {
        let source = EditFixture.solidRGB(width: 32, height: 16, red: 0.3, green: 0.3, blue: 0.3)
        let spec = ResizeSpec(width: 999, height: 999, interpolation: .lanczos, preventUpscale: true)
        let out = ResizeTool.apply(spec, to: source)
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 16, "preventUpscale must clamp to source dims")
    }

    func test_resize_noop_whenTargetMatchesSource() {
        let source = EditFixture.solidRGB(width: 32, height: 16, red: 0.3, green: 0.3, blue: 0.3)
        let spec = ResizeSpec(width: 32, height: 16, interpolation: .lanczos, preventUpscale: false)
        let out = ResizeTool.apply(spec, to: source)
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 16)
    }

    func test_resize_downsampleLanczos_producesRequestedDims() {
        let source = EditFixture.solidRGB(width: 128, height: 64, red: 0.7, green: 0.2, blue: 0.5)
        let spec = ResizeSpec(width: 32, height: 16, interpolation: .lanczos, preventUpscale: false)
        let out = ResizeTool.apply(spec, to: source)
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 16)
    }

    func test_colorAdjust_identityIsPassthrough() {
        let source = EditFixture.solidRGB(width: 16, height: 16, red: 0.25, green: 0.5, blue: 0.75)
        let out = ColorAdjustTool.apply(.identity, to: source)
        // Identity short-circuit: same object returned (byte hash equal).
        let a = ImageHash.bytes(of: source)
        let b = ImageHash.bytes(of: out)
        XCTAssertEqual(a, b, "identity params must not mutate pixels")
    }

    func test_colorAdjustParams_isIdentity_afterV1_1SlotsSet() {
        var p = ColorAdjustParams()
        XCTAssertTrue(p.isIdentity)
        p.exposure = 0.0
        XCTAssertFalse(p.isIdentity,
                       "any reserved slot set (even to 0) makes params non-identity")
    }

    func test_editOperation_codableRoundtrip() throws {
        // Proves the public types survive JSON — a prerequisite for any
        // recipe sidecar file.
        let recipe: [EditOperation] = [
            .crop(CropRect(originX: 0.1, originY: 0.2, width: 0.3, height: 0.4)),
            .rotate(degrees: 12.5),
            .rotate90(quarters: 2),
            .resize(ResizeSpec(width: 1600, height: 1067, interpolation: .lanczos, preventUpscale: true)),
            .colorAdjust(ColorAdjustParams(brightness: 0.1, contrast: -0.2, saturation: 0.05,
                                           exposure: 0.5)),
        ]
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode([EditOperation].self, from: data)
        XCTAssertEqual(recipe, decoded)
    }
}

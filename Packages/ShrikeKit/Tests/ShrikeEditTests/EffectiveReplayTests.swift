//
//  EffectiveReplayTests.swift
//  ShrikeEditTests
//
//  Colour and Levels ops are whole-state: the last one of each kind wins,
//  geometry keeps its order, Levels runs after Color Adjust
//  (`EditRecipe.effectiveOperations`). Covers the render, undo, export
//  and Auto-input (`renderLevelsInput`) paths. Temp folders only.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeEdit

final class EffectiveReplayTests: XCTestCase {

    private var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("EffectiveReplayTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    // MARK: Fixtures

    private let a = ColorAdjustParams(brightness: 0.15, contrast: 0.2)
    private let b = ColorAdjustParams(brightness: -0.1, saturation: 0.4)
    private let crop = CropRect(originX: 0.25, originY: 0.1, width: 0.5, height: 0.6)
    private let lv = LevelsParams(master: LevelsChannel(inBlack: 60, gamma: 1.3))

    /// 64 × 48 sRGB gradient: R follows x, G follows y, B fixed.
    private func gradient(width: Int = 64, height: Int = 48) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[i + 2] = 110
            }
        }
        let data = CFDataCreate(nil, bytes, bytes.count)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// 256 × 1 sRGB ramp: pixel x has R = G = B = x.
    private func ramp() -> CGImage {
        var bytes = [UInt8](repeating: 255, count: 256 * 4)
        for x in 0..<256 { bytes[x * 4] = UInt8(x); bytes[x * 4 + 1] = UInt8(x); bytes[x * 4 + 2] = UInt8(x) }
        let data = CFDataCreate(nil, bytes, bytes.count)!
        return CGImage(width: 256, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 256 * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// RGBX bytes in sRGB.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    /// Largest per-byte difference; `Int.max` when the sizes differ.
    private func maxDiff(_ x: CGImage, _ y: CGImage) -> Int {
        guard x.width == y.width, x.height == y.height else { return .max }
        return zip(pixels(x), pixels(y)).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }

    /// The reference: apply `ops` with the tools directly, in this order.
    private func manual(_ ops: [EditOperation], to image: CGImage) -> CGImage {
        ops.reduce(image) { img, op in
            switch op {
            case .crop(let r): return CropTool.apply(r, to: img)
            case .rotate(let d): return RotateTool.apply(degrees: d, to: img, autocrop: false)
            case .rotate90(let q): return RotateTool.apply90(quarters: q, to: img)
            case .resize(let s): return ResizeTool.apply(s, to: img)
            case .colorAdjust(let p): return ColorAdjustTool.apply(p, to: img)
            case .levels(let p): return LevelsTool.apply(p, to: img)
            }
        }
    }

    private func render(_ ops: [EditOperation], _ image: CGImage) async -> CGImage {
        await EditRenderer().renderFinal(recipe: EditRecipe(operations: ops), from: image)
    }

    private func readPNG(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    private func writePNG(_ image: CGImage, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // MARK: The pure list

    func testEffectiveOperations_geometryInOrderThenLastColourThenLastLevels() {
        let ops: [EditOperation] = [
            .levels(lv), .colorAdjust(a), .rotate90(quarters: 1), .crop(crop),
            .colorAdjust(b), .rotate(degrees: 3),
        ]
        XCTAssertEqual(EditRecipe.effectiveOperations(ops),
                       [.rotate90(quarters: 1), .crop(crop), .rotate(degrees: 3), .colorAdjust(b), .levels(lv)])
        XCTAssertEqual(EditRecipe.levelsInputOperations(ops),
                       [.rotate90(quarters: 1), .crop(crop), .rotate(degrees: 3), .colorAdjust(b)])
        XCTAssertEqual(EditRecipe.effectiveOperations([]), [])
    }

    func testEffectiveValues_lastWinsOrIdentity() {
        XCTAssertEqual(EditRecipe.effectiveColorAdjust([]), .identity)
        XCTAssertEqual(EditRecipe.effectiveLevels([.crop(crop)]), .identity)
        let ops: [EditOperation] = [.colorAdjust(a), .levels(lv), .crop(crop), .colorAdjust(b)]
        XCTAssertEqual(EditRecipe.effectiveColorAdjust(ops), b)
        XCTAssertEqual(EditRecipe.effectiveLevels(ops), lv)
        XCTAssertEqual(EditRecipe.effectiveColorAdjust(Array(ops.dropLast())), a)
        XCTAssertTrue([EditOperation.crop(crop), .rotate(degrees: 1), .rotate90(quarters: 2),
                       .resize(ResizeSpec(width: 4, height: 4, interpolation: .lanczos, preventUpscale: false))]
            .allSatisfy(\.isGeometry))
        XCTAssertFalse(EditOperation.colorAdjust(a).isGeometry)
        XCTAssertFalse(EditOperation.levels(lv).isGeometry)
    }

    // MARK: (1) crop, then colour: both survive

    func testCropThenColour_rendersCroppedAndColoured() async {
        let img = gradient()
        let out = await render([.crop(crop), .colorAdjust(a)], img)
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 29)
        XCTAssertEqual(maxDiff(out, manual([.crop(crop), .colorAdjust(a)], to: img)), 0)
        XCTAssertGreaterThan(maxDiff(out, manual([.crop(crop)], to: img)), 5, "colour applied")
    }

    // MARK: (2) two colour ops: the last wins; undo brings the first back

    func testTwoColourOps_lastWins_undoRestoresFirst() async {
        let img = gradient()
        let recipe = EditRecipe(operations: [.colorAdjust(a), .colorAdjust(b)])
        let renderer = EditRenderer()

        let both = await renderer.renderFinal(recipe: recipe, from: img)
        XCTAssertEqual(maxDiff(both, manual([.colorAdjust(b)], to: img)), 0, "b only")
        XCTAssertGreaterThan(maxDiff(both, manual([.colorAdjust(a), .colorAdjust(b)], to: img)), 5,
                             "not a then b")

        await recipe.undo()
        let afterUndo = await renderer.render(recipe: recipe, from: img)
        XCTAssertEqual(afterUndo.map { maxDiff($0, manual([.colorAdjust(a)], to: img)) }, 0, "a again")
        let ops = await recipe.snapshot()
        XCTAssertEqual(EditRecipe.effectiveColorAdjust(ops), a)

        await recipe.redo()
        let afterRedo = await renderer.renderFinal(recipe: recipe, from: img)
        XCTAssertEqual(maxDiff(afterRedo, both), 0)
    }

    // MARK: (3) levels listed first still runs after colour

    func testLevelsBeforeColour_rendersColourThenLevels() async {
        let img = gradient()
        let out = await render([.levels(lv), .colorAdjust(a)], img)
        XCTAssertEqual(maxDiff(out, manual([.colorAdjust(a), .levels(lv)], to: img)), 0)
        XCTAssertGreaterThan(maxDiff(out, manual([.levels(lv), .colorAdjust(a)], to: img)), 2,
                             "list order is not render order for whole-state ops")
    }

    // MARK: (4) colour, crop, colour

    func testColourCropColour_equalsCropThenLastColour() async {
        let img = gradient()
        let out = await render([.colorAdjust(a), .crop(crop), .colorAdjust(b)], img)
        XCTAssertEqual(maxDiff(out, manual([.crop(crop), .colorAdjust(b)], to: img)), 0)
    }

    // MARK: (5) identity whole-state ops change nothing

    func testIdentityOps_byteIdenticalToGeometryOnly() async throws {
        let img = gradient()
        let cropped = await render([.crop(crop)], img)
        let geometryOnly = try XCTUnwrap(ImageHash.bytes(of: cropped))
        let cases: [[EditOperation]] = [
            [.crop(crop), .colorAdjust(.identity), .levels(.identity)],
            [.colorAdjust(.identity), .crop(crop)],
            // Sliders reset to zero: the newest (identity) state wins.
            [.colorAdjust(a), .crop(crop), .colorAdjust(.identity)],
            [.levels(lv), .crop(crop), .levels(.identity)],
        ]
        for ops in cases {
            XCTAssertEqual(EditRecipe.effectiveOperations(ops), [.crop(crop)], "\(ops)")
            let rendered = await render(ops, img)
            let bytes = try XCTUnwrap(ImageHash.bytes(of: rendered))
            XCTAssertEqual(bytes, geometryOnly, "\(ops)")
        }
    }

    // MARK: (6) export matches the full-quality preview

    func testExport_matchesFullQualityPreview() async throws {
        let source = try writePNG(gradient(width: 120, height: 90), "in.png")
        let dest = tmp.url.appendingPathComponent("out.png")
        let ops: [EditOperation] = [.crop(crop), .colorAdjust(a), .colorAdjust(b)]

        try await ImageExporter(backupStore: nil).export(
            recipe: EditRecipe(operations: ops), from: source, to: dest, format: .png)
        let saved = try readPNG(dest)

        let decoded = try readPNG(source)
        let preview = await EditRenderer().render(recipe: EditRecipe(operations: ops), from: decoded,
                                                  qualityHint: .full)
        let shown = try XCTUnwrap(preview)
        XCTAssertEqual(saved.width, 60)
        XCTAssertEqual(saved.height, 54)
        XCTAssertLessThanOrEqual(maxDiff(saved, shown), 1, "saved file = what the preview showed")
        XCTAssertGreaterThan(maxDiff(saved, manual(ops, to: decoded)), 5, "colour applied once, not twice")
    }

    // MARK: (8) Levels in the saved file

    func testExport_levelsInputBlack20_clipsInSavedFile() async throws {
        let source = try writePNG(ramp(), "ramp.png")
        let dest = tmp.url.appendingPathComponent("ramp-out.png")
        let recipe = EditRecipe(operations: [.levels(LevelsParams(master: LevelsChannel(inBlack: 20)))])
        try await ImageExporter(backupStore: nil).export(recipe: recipe, from: source, to: dest, format: .png)

        let out = pixels(try readPNG(dest))
        for x in 0...20 {
            XCTAssertEqual(out[x * 4], 0, "R at \(x)")
            XCTAssertEqual(out[x * 4 + 1], 0, "G at \(x)")
            XCTAssertEqual(out[x * 4 + 2], 0, "B at \(x)")
        }
        XCTAssertGreaterThan(out[21 * 4], 0)
        XCTAssertEqual(out[255 * 4], 255)
    }

    // MARK: (9) Auto input: no levels op, never drops a live render

    func testRenderLevelsInput_ignoresLevels() async {
        let img = gradient()
        let recipe = EditRecipe(operations: [.levels(lv), .crop(crop), .colorAdjust(a), .colorAdjust(b)])
        let input = await EditRenderer().renderLevelsInput(recipe: recipe, from: img, maxEdge: 0)
        XCTAssertEqual(maxDiff(input, manual([.crop(crop), .colorAdjust(b)], to: img)), 0)

        // Default: shrunk for the histogram.
        let big = gradient(width: 2000, height: 1000)
        let small = await EditRenderer().renderLevelsInput(
            recipe: EditRecipe(operations: [.levels(lv), .colorAdjust(a)]), from: big)
        XCTAssertEqual(max(small.width, small.height), 512)
        XCTAssertEqual(small.width, 512)
        XCTAssertEqual(small.height, 256)
    }

    func testRenderLevelsInput_doesNotDropAConcurrentRender() async {
        let img = gradient(width: 400, height: 300)
        let recipe = EditRecipe(operations: [.crop(crop), .colorAdjust(a), .levels(lv)])
        let renderer = EditRenderer()
        for i in 0..<20 {
            let live = Task { await renderer.render(recipe: recipe, from: img, qualityHint: .draft) }
            _ = await renderer.renderLevelsInput(recipe: recipe, from: img)
            _ = await renderer.renderLevelsInput(recipe: recipe, from: img)
            let shown = await live.value
            XCTAssertNotNil(shown, "live render \(i) was dropped")
        }
    }
}

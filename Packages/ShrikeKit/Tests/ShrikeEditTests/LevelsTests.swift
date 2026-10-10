//
//  LevelsTests.swift
//  ShrikeEditTests
//

import ShrikeCore
import XCTest
import CoreGraphics
@testable import ShrikeEdit

final class LevelsTests: XCTestCase {

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

    private func pixels(_ image: CGImage) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let ctx = CGContext(data: &out, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return out
    }

    func testIdentity() {
        XCTAssertTrue(LevelsParams.identity.isIdentity)
        XCTAssertEqual(LevelsChannel.identity.lut(), (0..<256).map { UInt8($0) })
        let img = ramp()
        XCTAssertTrue(LevelsTool.apply(.identity, to: img) === img)
    }

    /// Input black 20 → every pixel ≤ 20 becomes 0.
    func testInputBlack20_clipsToZero() {
        let p = LevelsParams(master: LevelsChannel(inBlack: 20))
        let out = pixels(LevelsTool.apply(p, to: ramp()))
        for x in 0...20 {
            XCTAssertEqual(out[x * 4], 0, "R at \(x)")
            XCTAssertEqual(out[x * 4 + 1], 0, "G at \(x)")
            XCTAssertEqual(out[x * 4 + 2], 0, "B at \(x)")
        }
        XCTAssertGreaterThan(out[21 * 4], 0)
        XCTAssertEqual(out[255 * 4], 255)
    }

    func testMasterThenChannel_composes() {
        // Master: out white 128 halves everything. Red: in white 128 doubles.
        let p = LevelsParams(master: LevelsChannel(outWhite: 128), red: LevelsChannel(inWhite: 128))
        let t = p.composedLUTs()
        XCTAssertEqual(t.red[255], 255, "red undoes the master halving")
        XCTAssertEqual(t.green[255], 128)
        XCTAssertEqual(t.blue[0], 0)
        let out = pixels(LevelsTool.apply(p, to: ramp()))
        XCTAssertEqual(out[255 * 4], 255)
        XCTAssertEqual(out[255 * 4 + 1], 128)
        let tex = p.lutTextureBytes()
        XCTAssertEqual(tex.count, 1024)
        XCTAssertEqual(Array(tex[1020..<1024]), [255, 128, 128, 255])
    }

    func testGammaBrightensMidtones() {
        let lut = LevelsChannel(gamma: 2.0).lut()
        XCTAssertEqual(lut[0], 0)
        XCTAssertEqual(lut[255], 255)
        XCTAssertEqual(Int(lut[64]), Int((pow(64.0 / 255, 0.5) * 255).rounded()))
        XCTAssertGreaterThan(lut[128], 128)
    }

    func testNormalizedClampsRanges() {
        let c = LevelsChannel(inBlack: 200, inWhite: 100, gamma: 50).normalized()
        XCTAssertEqual(c.inWhite, 202)
        XCTAssertEqual(c.gamma, 9.99)
        XCTAssertEqual(LevelsChannel(gamma: .nan).normalized().gamma, 1)
        XCTAssertEqual(LevelsChannel(inBlack: 255).normalized().inBlack, 253)
    }

    private func hist(red: [UInt32], green: [UInt32], blue: [UInt32]) -> HistogramData {
        let n = Int(red.reduce(0, +))
        return HistogramData(red: red, green: green, blue: blue, luminance: green,
                             pixelCount: n, sampleWidth: max(n, 1), sampleHeight: 1)
    }

    func testAutoColor_clipsPointOnePercent() {
        var r = [UInt32](repeating: 0, count: 256)
        for v in 30...220 { r[v] = 100 }   // 19 100 samples
        r[0] = 5; r[255] = 5              // outliers under 0.1 %
        let flat = [UInt32](repeating: 10, count: 256)
        let p = LevelsParams.autoColor(from: hist(red: r, green: flat, blue: flat))
        // One below / above the first kept bin: only the outliers clip.
        XCTAssertEqual(p.red.inBlack, 29)
        XCTAssertEqual(p.red.inWhite, 221)
        XCTAssertEqual(p.red.gamma, 1)
        XCTAssertEqual(p.green.inBlack, 0, "flat histogram: 0.1 % is under one bin")
        XCTAssertEqual(p.green.inWhite, 255)
        XCTAssertTrue(p.master.isIdentity)
        let empty = [UInt32](repeating: 0, count: 256)
        XCTAssertTrue(LevelsParams.autoColor(from: hist(red: empty, green: empty, blue: empty)).isIdentity)
    }

    /// Blue-tinted, low-contrast: R 60…140, G 70…150, B 110…200.
    private func tinted() -> HistogramData {
        func band(_ lo: Int, _ hi: Int) -> [UInt32] {
            var bins = [UInt32](repeating: 0, count: 256)
            for v in lo...hi { bins[v] = 50 }
            return bins
        }
        return hist(red: band(60, 140), green: band(70, 150), blue: band(110, 200))
    }

    private func pixel(r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        p[0] = r; p[1] = g; p[2] = b; p[3] = 255
        return ctx.makeImage()!
    }

    private func rgb(_ image: CGImage) -> [UInt8] {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return [p[0], p[1], p[2]]
    }

    func testAutoContrast_stretchesMasterOnly_keepsGreyNeutral() {
        let p = LevelsParams.autoContrast(from: tinted())
        XCTAssertTrue(p.red.isIdentity && p.green.isIdentity && p.blue.isIdentity)
        XCTAssertFalse(p.master.isIdentity)
        XCTAssertEqual(p.master.gamma, 1)
        XCTAssertEqual(p.master.inBlack, 59, "just under the darkest of all channels")
        XCTAssertEqual(p.master.inWhite, 201, "just over the brightest of all channels")
        let out = rgb(LevelsTool.apply(p, to: pixel(r: 128, g: 128, b: 128)))
        XCTAssertEqual(out[0], out[1])
        XCTAssertEqual(out[1], out[2], "mid grey stays grey")
        XCTAssertNotEqual(out[0], 128, "but it moved")
    }

    func testAutoColor_givesChannelsTheirOwnPoints() {
        let p = LevelsParams.autoColor(from: tinted())
        XCTAssertTrue(p.master.isIdentity)
        XCTAssertEqual([p.red.inBlack, p.green.inBlack, p.blue.inBlack], [59, 69, 109])
        XCTAssertEqual([p.red.inWhite, p.green.inWhite, p.blue.inWhite], [141, 151, 201])
    }

    func testAutos_identityForEmptyAndSingleValue() {
        let empty = [UInt32](repeating: 0, count: 256)
        var single = empty
        single[128] = 10_000
        for h in [hist(red: empty, green: empty, blue: empty), hist(red: single, green: single, blue: single)] {
            XCTAssertEqual(LevelsParams.autoContrast(from: h), .identity)
            XCTAssertEqual(LevelsParams.autoColor(from: h), .identity)
        }
    }

    func testAutoContrast_honoursClipLimit() {
        // 100 000 samples per channel spread 20…230, plus outliers at the ends.
        var bins = [UInt32](repeating: 0, count: 256)
        for v in 20...230 { bins[v] = 470 }
        bins[5] = 60; bins[250] = 60
        let h = hist(red: bins, green: bins, blue: bins)
        for p in [LevelsParams.autoContrast(from: h), LevelsParams.autoColor(from: h)] {
            let (r, g, b) = p.composedLUTs()
            var total = 0, toBlack = 0, toWhite = 0
            for (lut, channel) in [(r, bins), (g, bins), (b, bins)] {
                for v in 0..<256 {
                    total += Int(channel[v])
                    if lut[v] == 0 { toBlack += Int(channel[v]) }
                    if lut[v] == 255 { toWhite += Int(channel[v]) }
                }
            }
            // `clip` is per side: at most 0.1 % end at 0, and at most 0.1 % at 255.
            XCTAssertLessThanOrEqual(Double(toBlack) / Double(total), 0.001 + 1e-9)
            XCTAssertLessThanOrEqual(Double(toWhite) / Double(total), 0.001 + 1e-9)
            XCTAssertGreaterThan(toBlack, 0, "the outliers did clip")
        }
    }

    func testCodableRoundTrip_inRecipe() throws {
        let op = EditOperation.levels(LevelsParams(master: LevelsChannel(inBlack: 12, gamma: 1.25),
                                                   blue: LevelsChannel(outWhite: 240)))
        let data = try JSONEncoder().encode([op, .colorAdjust(.identity)])
        let back = try JSONDecoder().decode([EditOperation].self, from: data)
        XCTAssertEqual(back.first, op)
        XCTAssertEqual(back.count, 2)
    }

    func testRendererAppliesLevels() async throws {
        let renderer = EditRenderer()
        let recipe = EditRecipe(operations: [.levels(LevelsParams(master: LevelsChannel(inBlack: 20)))])
        let out = await renderer.renderFinal(recipe: recipe, from: ramp())
        XCTAssertEqual(pixels(out)[10 * 4], 0)
        XCTAssertEqual(pixels(out)[200 * 4 + 1], LevelsChannel(inBlack: 20).lut()[200])
    }
}

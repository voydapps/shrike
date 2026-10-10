//
//  HueAdjustTests.swift
//  ShrikeEditTests
//
//  `ColorAdjustParams.hue`, −180°…+180°, 0 = identity.
//

import XCTest
import CoreGraphics
@testable import ShrikeEdit

final class HueAdjustTests: XCTestCase {

    private func solid(r: UInt8, g: UInt8, b: UInt8, size: Int = 8) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [CGFloat(r) / 255, CGFloat(g) / 255, CGFloat(b) / 255, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()!
    }

    private func centre(_ image: CGImage) -> (r: Int, g: Int, b: Int) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }

    func testHueZero_isIdentity() {
        let img = solid(r: 200, g: 60, b: 30)
        XCTAssertTrue(ColorAdjustParams(hue: 0).isIdentity)
        XCTAssertTrue(ColorAdjustTool.apply(ColorAdjustParams(hue: 0), to: img) === img)
        XCTAssertTrue(ColorAdjustTool.apply(ColorAdjustParams(hue: nil), to: img) === img)
        XCTAssertFalse(ColorAdjustParams(hue: 12).isIdentity)
    }

    func testHuePlus180_turnsRedIntoCyan() {
        let out = ColorAdjustTool.apply(ColorAdjustParams(hue: 180), to: solid(r: 255, g: 0, b: 0))
        let c = centre(out)
        XCTAssertLessThan(c.r, 60, "\(c)")
        XCTAssertGreaterThan(c.g, 100, "\(c)")
        XCTAssertGreaterThan(c.b, 100, "\(c)")
        XCTAssertLessThan(abs(c.g - c.b), 40, "cyan: green and blue about equal \(c)")
    }

    func testHueMinus180_equalsPlus180() {
        let red = solid(r: 255, g: 0, b: 0)
        let a = centre(ColorAdjustTool.apply(ColorAdjustParams(hue: 180), to: red))
        let b = centre(ColorAdjustTool.apply(ColorAdjustParams(hue: -180), to: red))
        XCTAssertLessThan(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b), 6)
    }

    func testHueWithSaturation_bothApplied() {
        // Saturation −1 makes grey; a hue turn of grey stays grey.
        let out = ColorAdjustTool.apply(ColorAdjustParams(saturation: -1, hue: 90), to: solid(r: 255, g: 0, b: 0))
        let c = centre(out)
        XCTAssertLessThan(max(abs(c.r - c.g), abs(c.g - c.b)), 8, "\(c)")
    }

    func testRecipe_roundTripsHue_andOldRecipesDecode() throws {
        let ops: [EditOperation] = [.colorAdjust(ColorAdjustParams(brightness: 0.1, hue: -45))]
        let data = try JSONEncoder().encode(ops)
        let back = try JSONDecoder().decode([EditOperation].self, from: data)
        XCTAssertEqual(back, ops)

        // A params blob written before hue existed (no "hue" key).
        let old = #"{"brightness":0.2,"contrast":0,"saturation":0.1}"#
        let params = try JSONDecoder().decode(ColorAdjustParams.self, from: Data(old.utf8))
        XCTAssertNil(params.hue)
        XCTAssertEqual(params.brightness, 0.2)
    }
}

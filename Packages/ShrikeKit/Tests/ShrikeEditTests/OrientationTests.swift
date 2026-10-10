//
//  OrientationTests.swift
//  ShrikeEditTests
//
//  ExifOrientation: pixel transform vs ImageIO's own transform (the one
//  the viewer uses), the D4 composition table for every orientation ×
//  user op, and the regression where export ignored the source orientation.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit

// MARK: - Shared pixel helpers (used by LosslessRotatorTests too)

enum PixelTestKit {

    /// 3×2 image, every pixel a distinct colour. Asymmetric in both axes
    /// so any wrong rotation/mirror shows up.
    static func distinctImage(width: Int = 3, height: Int = 2) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(40 * x + 10)
                bytes[i + 1] = UInt8(100 * y + 20)
                bytes[i + 2] = UInt8((x * 7 + y * 13) * 9 % 256)
                bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// Image split into four solid quadrants (y-down: TL red, TR green,
    /// BL blue, BR yellow). Big blocks so JPEG artefacts don't matter.
    static func quadrantImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        // CG is y-up: the "top" half is y ∈ [h/2, h].
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        ctx.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, type: UTType,
                      orientation: UInt32, quality: Double = 1.0) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PixelTestKit", code: 1)
        }
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        if type == .jpeg || type == .heic {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "PixelTestKit", code: 2)
        }
    }

    /// What the viewer shows: ImageIO decode with the EXIF transform.
    static func displayed(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ] as CFDictionary)
    }

    static func stored(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func orientation(_ url: URL) -> UInt32 {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    }

    /// Row-major RGBA8 grid (y-down) as `[[UInt32]]`, alpha forced to 255.
    static func grid(_ image: CGImage) -> [[UInt32]] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: w * 4, space: cs,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var rows: [[UInt32]] = []
        for y in 0..<h {
            var row: [UInt32] = []
            for x in 0..<w {
                let i = (y * w + x) * 4
                row.append(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
            }
            rows.append(row)
        }
        return rows
    }

    // Independent reference ops on a y-down grid.
    static func rotateCW(_ g: [[UInt32]]) -> [[UInt32]] {
        let h = g.count, w = g.first?.count ?? 0
        return (0..<w).map { x in (0..<h).map { y in g[h - 1 - y][x] } }
    }
    static func flipH(_ g: [[UInt32]]) -> [[UInt32]] { g.map { $0.reversed() } }
    static func flipV(_ g: [[UInt32]]) -> [[UInt32]] { g.reversed() }
    static func apply(_ op: OrientationOp, _ g: [[UInt32]]) -> [[UInt32]] {
        switch op {
        case .rotate(let q):
            var out = g
            for _ in 0..<(((q % 4) + 4) % 4) { out = rotateCW(out) }
            return out
        case .flipHorizontal: return flipH(g)
        case .flipVertical: return flipV(g)
        }
    }

    /// Mean colour of a y-down pixel rect, as (r, g, b) in 0…255.
    static func meanColor(_ g: [[UInt32]], x0: Int, y0: Int, x1: Int, y1: Int) -> (Int, Int, Int) {
        var r = 0, gg = 0, b = 0, n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = g[y][x]
                r += Int((p >> 16) & 0xFF); gg += Int((p >> 8) & 0xFF); b += Int(p & 0xFF); n += 1
            }
        }
        return (r / max(n, 1), gg / max(n, 1), b / max(n, 1))
    }

    static let allOps: [OrientationOp] = [
        .rotate(quarters: 1), .rotate(quarters: -1), .rotate(quarters: 2),
        .rotate(quarters: 3), .flipHorizontal, .flipVertical,
    ]
}

final class OrientationTests: XCTestCase {

    var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("OrientationTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    // MARK: Pixel transform matches ImageIO for all 8 orientations.

    func test_apply_matchesImageIOTransform_allEight() throws {
        let base = PixelTestKit.distinctImage()
        for o in ExifOrientation.allCases {
            let url = tmp.url.appendingPathComponent("o\(o.rawValue).tiff")
            try PixelTestKit.write(base, to: url, type: .tiff, orientation: o.rawValue)
            let oracle = try XCTUnwrap(PixelTestKit.displayed(url))
            let stored = try XCTUnwrap(PixelTestKit.stored(url))
            let mine = ExifOrientation.apply(o, to: stored)
            XCTAssertEqual(PixelTestKit.grid(mine), PixelTestKit.grid(oracle),
                           "orientation \(o.rawValue): pixel transform disagrees with ImageIO")
        }
    }

    // MARK: D4 composition — 8 orientations × 6 ops = 48 cases.

    func test_composition_allOrientationsTimesAllOps() throws {
        let base = PixelTestKit.distinctImage()
        var displayedByOrientation: [ExifOrientation: [[UInt32]]] = [:]
        for o in ExifOrientation.allCases {
            let url = tmp.url.appendingPathComponent("c\(o.rawValue).tiff")
            try PixelTestKit.write(base, to: url, type: .tiff, orientation: o.rawValue)
            displayedByOrientation[o] = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
        }
        var cases = 0
        for o in ExifOrientation.allCases {
            for op in PixelTestKit.allOps {
                let expected = PixelTestKit.apply(op, displayedByOrientation[o]!)
                let composed = o.applying(op)
                XCTAssertEqual(displayedByOrientation[composed]!, expected,
                               "orientation \(o.rawValue) + \(op) → \(composed.rawValue) is wrong")
                cases += 1
            }
        }
        XCTAssertEqual(cases, 48)
    }

    func test_composition_roundTrips() {
        for o in ExifOrientation.allCases {
            XCTAssertEqual(o.rotated(quarters: 1).rotated(quarters: -1), o)
            XCTAssertEqual(o.rotated(quarters: 4), o)
            XCTAssertEqual(o.flippedHorizontally().flippedHorizontally(), o)
            XCTAssertEqual(o.flippedVertically().flippedVertically(), o)
            XCTAssertEqual(ExifOrientation(mirrored: o.components.mirrored,
                                           quarters: o.components.quarters), o)
        }
        XCTAssertEqual(ExifOrientation.up.rotated(quarters: 1), .right)
        XCTAssertEqual(ExifOrientation.up.rotated(quarters: -1), .left)
        XCTAssertEqual(ExifOrientation.right.rotated(quarters: 1), .down)
        XCTAssertEqual(ExifOrientation.up.flippedHorizontally(), .upMirrored)
        XCTAssertEqual(ExifOrientation.up.flippedVertically(), .downMirrored)
    }

    // MARK: Export honours the source orientation.

    /// 400×200 stored pixels tagged orientation 6 → the viewer shows a
    /// 200×400 portrait. The exported file must look the same (and carry
    /// orientation 1), and a display-space crop must select the same
    /// region in the saved file.
    func test_export_orientation6_matchesDisplayedPixels_andCropRegion() async throws {
        for orientation: UInt32 in [3, 6, 8] {
            let src = tmp.url.appendingPathComponent("portrait\(orientation).jpg")
            try PixelTestKit.write(PixelTestKit.quadrantImage(width: 400, height: 200),
                                   to: src, type: .jpeg, orientation: orientation)
            let shown = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(src)))
            let shownW = shown[0].count, shownH = shown.count
            if orientation != 3 {
                XCTAssertEqual(shownW, 200)
                XCTAssertEqual(shownH, 400)
            }

            // 1) Plain export (identity-ish recipe).
            let full = tmp.url.appendingPathComponent("full\(orientation).png")
            let r1 = EditRecipe()
            await r1.append(.colorAdjust(ColorAdjustParams()))
            try await ImageExporter(backupStore: nil).export(recipe: r1, from: src, to: full, format: .png,
                                             quality: 1, preserveEXIF: true, stripGPS: false)
            XCTAssertEqual(PixelTestKit.orientation(full), 1)
            let outFull = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(full)))
            XCTAssertEqual(outFull[0].count, shownW, "width must match what the viewer shows")
            XCTAssertEqual(outFull.count, shownH, "height must match what the viewer shows")
            assertQuadrants(outFull, match: shown, label: "full o\(orientation)")

            // 2) Crop the top half in display space.
            let cropped = tmp.url.appendingPathComponent("crop\(orientation).png")
            let r2 = EditRecipe()
            await r2.append(.crop(CropRect(originX: 0, originY: 0, width: 1, height: 0.5)))
            try await ImageExporter(backupStore: nil).export(recipe: r2, from: src, to: cropped, format: .png,
                                             quality: 1, preserveEXIF: true, stripGPS: false)
            let outCrop = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(cropped)))
            XCTAssertEqual(outCrop[0].count, shownW)
            XCTAssertEqual(outCrop.count, shownH / 2)
            let topHalf = Array(shown[0..<(shownH / 2)])
            assertQuadrants(outCrop, match: topHalf, label: "crop o\(orientation)")
        }
    }

    private func assertQuadrants(_ a: [[UInt32]], match b: [[UInt32]], label: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let w = b[0].count, h = b.count
        guard a.count == h, a.first?.count == w else {
            XCTFail("\(label): size \(a.first?.count ?? 0)×\(a.count) != \(w)×\(h)",
                    file: file, line: line)
            return
        }
        // Sample the centre of each quarter, 10% inset to dodge JPEG edges.
        for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            let cx = Int(Double(w) * fx), cy = Int(Double(h) * fy)
            let dx = max(1, w / 10), dy = max(1, h / 10)
            let ca = PixelTestKit.meanColor(a, x0: cx - dx, y0: cy - dy, x1: cx + dx, y1: cy + dy)
            let cb = PixelTestKit.meanColor(b, x0: cx - dx, y0: cy - dy, x1: cx + dx, y1: cy + dy)
            XCTAssertLessThan(abs(ca.0 - cb.0) + abs(ca.1 - cb.1) + abs(ca.2 - cb.2), 30,
                              "\(label): colour at (\(fx),\(fy)) differs: \(ca) vs \(cb)",
                              file: file, line: line)
        }
    }
}

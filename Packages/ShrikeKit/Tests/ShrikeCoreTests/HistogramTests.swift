//
//  HistogramTests.swift
//  ShrikeCoreTests
//
//  Synthetic CGImages in several pixel formats and colour spaces.
//

import XCTest
import CoreGraphics
@testable import ShrikeCore

final class HistogramTests: XCTestCase {

    // MARK: - Image factories

    /// 8-bit RGBA in `space` (default sRGB). `pixel(x, y)` returns RGBA.
    private func makeRGBA8(
        width: Int, height: Int,
        space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
        alpha: CGImageAlphaInfo = .noneSkipLast,
        pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = a
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | alpha.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    /// Large fixtures drawn by CoreGraphics (a per-pixel Swift loop over
    /// 24 MP takes seconds in debug builds).
    private func makeDrawn(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        draw(context)
        return context.makeImage()!
    }

    private func makeRGBA16(width: Int, height: Int, value: UInt16) -> CGImage {
        let values = [UInt16](repeating: value, count: width * height * 4)
        let data = values.withUnsafeBytes { Data($0) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: width * 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func makeRGBAFloat(width: Int, height: Int, value: Float, space: CGColorSpace) -> CGImage {
        var values = [Float](repeating: value, count: width * height * 4)
        for i in stride(from: 3, to: values.count, by: 4) { values[i] = 1 }
        let data = values.withUnsafeBytes { Data($0) }
        return CGImage(
            width: width, height: height, bitsPerComponent: 32, bitsPerPixel: 128,
            bytesPerRow: width * 16, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGBitmapInfo.floatComponents.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func makeGray8(width: Int, height: Int, value: UInt8) -> CGImage {
        let data = Data(repeating: value, count: width * height)
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )!
    }

    private func peak(_ bins: [UInt32]) -> Int {
        bins.indices.max { bins[$0] < bins[$1] }!
    }

    // MARK: - Correctness

    func testSolidRed() {
        let image = makeRGBA8(width: 64, height: 64) { _, _ in (255, 0, 0, 255) }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.pixelCount, 4096)
        XCTAssertEqual(h.red[255], 4096)
        XCTAssertEqual(h.green[0], 4096)
        XCTAssertEqual(h.blue[0], 4096)
        // Rec.709: 0.2126 * 255 = 54.2
        XCTAssertTrue((54...55).contains(peak(h.luminance)), "luma peak \(peak(h.luminance))")
        XCTAssertEqual(h.luminance.reduce(0, +), 4096)
        XCTAssertEqual(h.shadowsClippedPercent, 0)
        XCTAssertEqual(h.highlightsClippedPercent, 0)
        XCTAssertEqual(h.clippedPercent(.red).highlights, 100)
        XCTAssertEqual(h.clippedPercent(.green).shadows, 100)
        // Any-channel clip marks: R is 255 and G/B are 0 on every pixel.
        XCTAssertEqual(h.anyChannelHighlightsClippedPercent, 100)
        XCTAssertEqual(h.anyChannelShadowsClippedPercent, 100)
    }

    func testAnyChannelClippingIsAUnionAcrossChannels() {
        // 4 columns: R clipped high, G clipped high, mid grey, B at zero.
        let image = makeRGBA8(width: 4, height: 10) { x, _ in
            switch x {
            case 0: return (255, 100, 100, 255)
            case 1: return (100, 255, 100, 255)
            case 2: return (100, 100, 100, 255)
            default: return (100, 100, 0, 255)
            }
        }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.anyChannelHighlightsClippedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(h.anyChannelShadowsClippedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(h.highlightsClippedPercent, 0)   // luminance never reaches 255
    }

    func testBlackWhiteSplitClipping() {
        let image = makeRGBA8(width: 100, height: 100) { x, _ in
            x < 50 ? (0, 0, 0, 255) : (255, 255, 255, 255)
        }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.shadowsClippedPercent, 50, accuracy: 0.001)
        XCTAssertEqual(h.highlightsClippedPercent, 50, accuracy: 0.001)
    }

    func testGrayRampFillsEveryBinOnce() {
        let image = makeRGBA8(width: 256, height: 1) { x, _ in
            let v = UInt8(x)
            return (v, v, v, 255)
        }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.red, Array(repeating: 1, count: 256))
        XCTAssertEqual(h.green, Array(repeating: 1, count: 256))
        XCTAssertEqual(h.blue, Array(repeating: 1, count: 256))
        XCTAssertEqual(h.luminance, Array(repeating: 1, count: 256))
        XCTAssertEqual(h.meanLuminancePercent, 50, accuracy: 0.001)
        XCTAssertEqual(HistogramData.empty.meanLuminancePercent, 0)
    }

    func testLargeImageIsDownsampledFirst() {
        // 1-px vertical stripes: any averaging would create in-between greys.
        let image = makeDrawn(width: 4000, height: 3000) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 10 / 255, green: 10 / 255, blue: 10 / 255, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
            ctx.setFillColor(CGColor(srgbRed: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1))
            for x in stride(from: 1, to: 4000, by: 2) {
                ctx.fill(CGRect(x: x, y: 0, width: 1, height: 3000))
            }
        }
        let h = Histogram.computeSync(from: image, maxSampleEdge: 512)
        XCTAssertEqual(h.sampleWidth, 512)
        XCTAssertEqual(h.sampleHeight, 384)
        XCTAssertEqual(h.pixelCount, 512 * 384)
        XCTAssertEqual(Int(h.luminance.reduce(0, +)), 512 * 384)
        // Point sampling keeps the two populations; no averaged greys.
        XCTAssertEqual(Int(h.luminance[10] + h.luminance[240]), 512 * 384)
    }

    func testSixteenBitSource() {
        let h = Histogram.computeSync(from: makeRGBA16(width: 32, height: 32, value: 32768))
        XCTAssertTrue((127...128).contains(peak(h.red)), "peak \(peak(h.red))")
        XCTAssertEqual(h.red[peak(h.red)], 1024)
    }

    func testExtendedRangeFloatClipsToWhite() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let h = Histogram.computeSync(from: makeRGBAFloat(width: 16, height: 16, value: 2.0, space: space))
        XCTAssertEqual(h.pixelCount, 256)
        XCTAssertEqual(h.highlightsClippedPercent, 100, accuracy: 0.001)
    }

    func testDisplayP3GreyMapsToSameGrey() {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let image = makeRGBA8(width: 20, height: 20, space: p3) { _, _ in (128, 128, 128, 255) }
        let h = Histogram.computeSync(from: image)
        XCTAssertTrue((127...129).contains(peak(h.luminance)), "peak \(peak(h.luminance))")
    }

    func testGrayscaleSource() {
        let h = Histogram.computeSync(from: makeGray8(width: 30, height: 30, value: 200))
        XCTAssertTrue((196...204).contains(peak(h.red)), "peak \(peak(h.red))")
        XCTAssertEqual(peak(h.red), peak(h.green))
        XCTAssertEqual(peak(h.green), peak(h.blue))
        XCTAssertEqual(h.pixelCount, 900)
    }

    func testFullyTransparentPixelsAreExcluded() {
        let image = makeRGBA8(width: 10, height: 10, alpha: .premultipliedLast) { x, _ in
            x < 5 ? (0, 0, 0, 0) : (255, 255, 255, 255)
        }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.pixelCount, 50)
        XCTAssertEqual(h.luminance[0], 0)
        XCTAssertEqual(h.highlightsClippedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(h.shadowsClippedPercent, 0)
        XCTAssertEqual(h.anyChannelShadowsClippedPercent, 0, "transparent pixels are not shadows")
        XCTAssertEqual(h.anyChannelHighlightsClippedPercent, 100)
    }

    func testCalculatorLatestRequestWins() async {
        let calculator = HistogramCalculator()
        let image = makeRGBA8(width: 64, height: 64) { _, _ in (10, 20, 30, 255) }
        let first = await calculator.compute(from: image)
        XCTAssertEqual(first, Histogram.computeSync(from: image, maxSampleEdge: 1024))

        // Two overlapping requests: only the newer one gets a result, in
        // whatever order their work runs. The order is fixed by `begin()`,
        // not by which task reaches the calculator first (two `async let`
        // calls have no order, so under load both used to get a result).
        let older = calculator.begin()
        let newer = calculator.begin()
        async let olderResult = calculator.compute(from: image, for: older)
        async let newerResult = calculator.compute(from: image, for: newer)
        let (o, n) = await (olderResult, newerResult)
        XCTAssertNil(o, "the older request never gets a result")
        XCTAssertEqual(n, first)

        // The newer request's work runs first and the older one's last
        // (a slow sample for the previous image): the older still loses.
        let a = calculator.begin()
        let b = calculator.begin()
        let bResult = await calculator.compute(from: image, for: b)
        let aResult = await calculator.compute(from: image, for: a)
        XCTAssertEqual(bResult, first)
        XCTAssertNil(aResult)

        // cancelAll drops the request in flight; a later one works again.
        let c = calculator.begin()
        calculator.cancelAll()
        let cResult = await calculator.compute(from: image, for: c)
        XCTAssertNil(cResult)
        let d = await calculator.compute(from: image)
        XCTAssertEqual(d, first)
    }

    func testDegenerateInputs() {
        let image = makeRGBA8(width: 4, height: 4) { _, _ in (1, 2, 3, 255) }
        XCTAssertEqual(Histogram.computeSync(from: image, maxSampleEdge: 0), .empty)
        let tiny = makeRGBA8(width: 1, height: 5000) { _, _ in (9, 9, 9, 255) }
        let h = Histogram.computeSync(from: tiny, maxSampleEdge: 100)
        XCTAssertEqual(h.sampleWidth, 1)
        XCTAssertEqual(h.sampleHeight, 100)
        XCTAssertEqual(HistogramData.empty.maxBinCount(), 0)
    }

    func testAsyncMatchesSync() async {
        let image = makeRGBA8(width: 50, height: 40) { x, y in (UInt8(x * 5), UInt8(y * 6), 77, 255) }
        let asyncResult = await Histogram.compute(from: image)
        XCTAssertEqual(asyncResult, Histogram.computeSync(from: image))
    }

    func testMaxBinCountExcludingEnds() {
        let image = makeRGBA8(width: 10, height: 10) { x, _ in
            x < 8 ? (0, 0, 0, 255) : (100, 100, 100, 255)
        }
        let h = Histogram.computeSync(from: image)
        XCTAssertEqual(h.maxBinCount(), 80)
        XCTAssertEqual(h.maxBinCount(excludingEnds: true), 20)
    }

    // MARK: - Performance

    /// Budget: < 5 ms for a 512-px sample. Also reports the cost of
    /// sampling down from a 24 MP source.
    func testPerformance() {
        var seed: UInt32 = 12345
        func next() -> UInt8 {
            seed = seed &* 1664525 &+ 1013904223
            return UInt8(truncatingIfNeeded: seed >> 24)
        }
        let small = makeRGBA8(width: 512, height: 512) { _, _ in (next(), next(), next(), 255) }
        let large = makeDrawn(width: 6000, height: 4000) { ctx in
            let colors = [CGColor(srgbRed: 0, green: 0.2, blue: 1, alpha: 1),
                          CGColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                      colors: colors, locations: nil)!
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 6000, y: 4000), options: [])
        }
        let p3 = makeRGBA8(width: 512, height: 512, space: CGColorSpace(name: CGColorSpace.displayP3)!) { _, _ in
            (next(), next(), next(), 255)
        }

        func bestMs(_ image: CGImage) -> Double {
            _ = Histogram.computeSync(from: image)   // warm up (provider decode, caches)
            let clock = ContinuousClock()
            var best = Duration.seconds(10)
            for _ in 0..<10 {
                best = min(best, clock.measure { _ = Histogram.computeSync(from: image) })
            }
            return Double(best.components.seconds) * 1000 + Double(best.components.attoseconds) / 1e15
        }

        let smallMs = bestMs(small)
        let mp1 = makeDrawn(width: 1024, height: 768) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.3, green: 0.6, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 768))
        }
        let calcMs = bestMs(mp1)
        let largeMs = bestMs(large)
        let p3Ms = bestMs(p3)
        print(String(format: "[Histogram] 512x512 sRGB: %.3f ms; 512x512 P3: %.3f ms; 6000x4000 → 512 sample: %.3f ms; 1024x768: %.3f ms",
                     smallMs, p3Ms, largeMs, calcMs))
        // The 5 ms target applies to release builds; debug gets headroom
        // for unoptimised Swift around the vImage calls.
        #if DEBUG
        let budget = 25.0
        #else
        let budget = 5.0
        #endif
        XCTAssertLessThan(smallMs, budget)
        XCTAssertLessThan(p3Ms, budget)
    }
}

//
//  ThumbnailFastPathTests.swift
//  ShrikeCoreTests
//
//  `FileImageSource.fastThumbnail` (subsampled decode + one scale-and-
//  orient draw) must match the old `CreateThumbnailAtIndex` +
//  `WithTransform` path: same size (short edge ±1 px), same orientation
//  for all 8 EXIF values, pixels within a small tolerance.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class ThumbnailFastPathTests: XCTestCase {

    private typealias F = OrientedImageFixtures

    /// Quadrants plus a soft diagonal gradient, so resampling differences
    /// show up in the mean difference.
    private func pattern(width: Int, height: Int) -> CGImage {
        let base = F.quadrants(width: width, height: height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
        let colors = [CGColor(gray: 0, alpha: 0.4), CGColor(gray: 1, alpha: 0.0)] as CFArray
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, colors: colors,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: width, y: height), options: [])
        return ctx.makeImage()!
    }

    /// The fast path, forced on for its candidate formats (production
    /// has it off; see `FileImageSource.fastThumbnailTypes`).
    private func thumbnail(_ url: URL, _ size: Int) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return try XCTUnwrap(FileImageSource.fastThumbnail(src, props: props, maxPixelSize: size,
                                                           types: FileImageSource.fastThumbnailCandidateTypes))
    }

    /// Same orientation and long edge; the short edge may differ by 1 px
    /// (ImageIO rounds it after its own internal subsample step, so its
    /// result is not a fixed rounding rule; the fast path rounds to nearest).
    private func assertSameSize(_ a: CGImage, _ b: CGImage, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.width >= a.height, b.width >= b.height, "orientation: \(message)", file: file, line: line)
        XCTAssertEqual(max(a.width, a.height), max(b.width, b.height), "long edge: \(message)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(min(a.width, a.height) - min(b.width, b.height)), 1,
                                 "short edge \(a.width)x\(a.height) vs \(b.width)x\(b.height): \(message)",
                                 file: file, line: line)
    }

    private func resized(_ image: CGImage, _ width: Int, _ height: Int) -> CGImage {
        if image.width == width, image.height == height { return image }
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func fastPathTaken(_ url: URL, _ size: Int,
                               types: Set<String> = FileImageSource.fastThumbnailCandidateTypes) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return false }
        return FileImageSource.fastThumbnail(src, props: props, maxPixelSize: size, types: types) != nil
    }

    private func checkAllOrientations(type: UTType, ext: String) throws {
        let tmp = TempDir("fast-thumb-\(ext)")
        defer { tmp.cleanup() }
        let stored = pattern(width: 1200, height: 800)
        for orientation in UInt32(1)...8 {
            let url = tmp.url.appendingPathComponent("o\(orientation).\(ext)")
            try F.write(stored, to: url, type: type, orientation: orientation)
            XCTAssertTrue(fastPathTaken(url, 256), "\(ext) orientation \(orientation) uses the fast path")

            let fast = try thumbnail(url, 256)
            let imageIO = try XCTUnwrap(F.imageIOOriented(url, maxPixelSize: 256))
            assertSameSize(fast, imageIO, "\(ext) orientation \(orientation)")
            // Compare pixels at the same size (the short edge may differ by 1 px).
            let ref = resized(imageIO, fast.width, fast.height)
            for (fx, fy) in [(0.2, 0.2), (0.8, 0.2), (0.2, 0.8), (0.8, 0.8)] {
                let a = F.sample(fast, fx, fy), b = F.sample(ref, fx, fy)
                XCTAssertLessThan(a.distance(to: b), 16, "\(ext) orientation \(orientation) at \(fx),\(fy): \(a) vs \(b)")
            }
            let diff = F.meanAbsDiff(fast, ref)
            XCTAssertLessThan(diff, 3.0, "\(ext) orientation \(orientation): mean diff \(diff)")
        }
    }

    func testJPEG_allEightOrientations_matchOldPath() throws {
        try checkAllOrientations(type: .jpeg, ext: "jpg")
    }

    func testHEIC_allEightOrientations_matchOldPath() throws {
        try checkAllOrientations(type: .heic, ext: "heic")
    }

    func testOddSizes_matchOldPathDimensions() throws {
        let tmp = TempDir("fast-thumb-sizes")
        defer { tmp.cleanup() }
        let cases: [(Int, Int, UInt32)] = [(1001, 667, 1), (667, 1001, 1), (4000, 2667, 6), (1333, 999, 8),
                                           (3001, 17, 1), (200, 100, 1), (513, 257, 3)]
        for (w, h, o) in cases {
            let url = tmp.url.appendingPathComponent("s\(w)x\(h)o\(o).jpg")
            try F.write(pattern(width: w, height: h), to: url, orientation: o)
            for size in [64, 97, 256, 360] {
                let fast = try thumbnail(url, size)
                let ref = try XCTUnwrap(F.imageIOOriented(url, maxPixelSize: min(size, max(w, h))))
                assertSameSize(fast, ref, "\(w)x\(h) o\(o) @ \(size)")
            }
        }
    }

    /// Timing print only (no assertion): one 12 MP file per format, old
    /// ImageIO thumbnail call vs the fast path forced on. Decides which
    /// formats go into `fastThumbnailTypes`.
    func testTiming_oldVsFast_perFormat() throws {
        guard ProcessInfo.processInfo.environment["SHRIKE_BENCH"] != nil else {
            throw XCTSkip("print-only benchmark; set SHRIKE_BENCH=1 to run it")
        }
        let tmp = TempDir("fast-thumb-timing")
        defer { tmp.cleanup() }
        let image = pattern(width: 4000, height: 3000)
        let formats: [(UTType, String)] = [(.jpeg, "jpg"), (.heic, "heic"), (.png, "png"), (.tiff, "tiff"), (.gif, "gif")]
        let all = Set(formats.map(\.0.identifier))
        for (type, ext) in formats {
            let url = tmp.url.appendingPathComponent("t.\(ext)")
            try F.write(image, to: url, type: type, orientation: 6)
            func time(_ body: () -> CGImage?) -> Double {
                var best = Double.infinity
                for _ in 0..<5 {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    // Nil = the codec ignored the subsample factor (GIF);
                    // the time is then only the bail-out.
                    _ = body()
                    best = min(best, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                }
                return best
            }
            let old = time { F.imageIOOriented(url, maxPixelSize: 256) }
            let fast = time {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
                return FileImageSource.fastThumbnail(src, props: props, maxPixelSize: 256, types: all)
            }
            print(String(format: "[thumb-path] %@ 4000x3000 @256: old %.1f ms, fast %.1f ms", ext, old, fast))
        }
    }

    func testLargeRequestsAndOtherFormats_keepTheImageIOPath() throws {
        let tmp = TempDir("fast-thumb-other")
        defer { tmp.cleanup() }
        let jpeg = tmp.url.appendingPathComponent("a.jpg")
        try F.write(pattern(width: 3000, height: 2000), to: jpeg, orientation: 6)
        XCTAssertFalse(fastPathTaken(jpeg, 2048), "display-size requests keep the ImageIO path")
        let png = tmp.url.appendingPathComponent("a.png")
        try F.write(pattern(width: 600, height: 400), to: png, type: .png)
        XCTAssertFalse(fastPathTaken(png, 256))

        // Production: the fast path lost the benchmark for every format,
        // so `decodeImage` gives exactly ImageIO's thumbnail.
        XCTAssertFalse(fastPathTaken(jpeg, 256, types: FileImageSource.fastThumbnailTypes))
        let prod = try FileImageSource(url: jpeg).decodeImage(maxPixelSize: 256)
        let ref = try XCTUnwrap(F.imageIOOriented(jpeg, maxPixelSize: 256))
        XCTAssertEqual("\(prod.width)x\(prod.height)", "\(ref.width)x\(ref.height)")
        XCTAssertLessThan(F.meanAbsDiff(prod, ref), 0.5)
    }
}

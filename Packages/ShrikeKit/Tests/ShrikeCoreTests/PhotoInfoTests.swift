//
//  PhotoInfoTests.swift
//  ShrikeCoreTests
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class PhotoInfoTests: XCTestCase {

    /// Writes a JPEG with EXIF / TIFF / GPS into `dir`.
    static func writeJPEG(to url: URL, width: Int, height: Int, noise: Bool = false,
                          gps: [CFString: Any]? = nil, orientation: Int = 1) throws {
        let bytesPerRow = width * 4
        var buf = [UInt8](repeating: 128, count: bytesPerRow * height)
        if noise { buf.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) } }
        let cs = CGColorSpace(name: CGColorSpace.displayP3)!
        let image: CGImage = try buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
                  let img = ctx.makeImage() else { throw PhotoInfoError.cannotOpen }
            return img
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString,
                                                         1, nil) else { throw PhotoInfoError.cannotOpen }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "OLYMPUS CORPORATION",
                kCGImagePropertyTIFFModel: "E-M1MarkIII",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:09:25 14:02:31",
                kCGImagePropertyExifOffsetTimeOriginal: "+02:00",
                kCGImagePropertyExifLensModel: "M.12-40mm F2.8",
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFocalLength: 25.0,
                kCGImagePropertyExifFocalLenIn35mmFilm: 50,
                kCGImagePropertyExifExposureBiasValue: -0.7,
                kCGImagePropertyExifFlash: 16,
                kCGImagePropertyExifWhiteBalance: 0,
            ] as [CFString: Any],
        ]
        if let gps { props[kCGImagePropertyGPSDictionary] = gps }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw PhotoInfoError.cannotOpen }
    }

    func testReadsAllFieldsAndSignsGPS() throws {
        let tmp = TempDir("photoinfo")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("DSC_0042.jpg")
        try Self.writeJPEG(to: url, width: 60, height: 40, gps: [
            kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.21, kCGImagePropertyGPSLongitudeRef: "E",
        ], orientation: 6)
        let info = try PhotoInfo.readSync(url)
        XCTAssertEqual(info.typeName, "JPEG")
        XCTAssertEqual(info.pixelWidth, 40, "orientation 6 swaps to display size")
        XCTAssertEqual(info.pixelHeight, 60)
        XCTAssertEqual(info.orientation, 6)
        XCTAssertEqual(info.colorProfileName, "Display P3")
        XCTAssertEqual(info.camera, "OLYMPUS CORPORATION E-M1MarkIII")
        XCTAssertEqual(info.lens, "M.12-40mm F2.8")
        XCTAssertEqual(info.aperture, 2.8)
        XCTAssertEqual(info.shutter, 0.004)
        XCTAssertEqual(info.iso, 200)
        XCTAssertEqual(info.focal, 25)
        XCTAssertEqual(info.focal35, 50)
        XCTAssertEqual(info.exposureBias ?? 0, -0.7, accuracy: 0.001)
        XCTAssertEqual(info.flashFired, false)
        XCTAssertEqual(info.whiteBalanceAuto, true)
        XCTAssertEqual(info.dpi, 300)
        XCTAssertEqual(info.frameCount, 1)
        XCTAssertEqual(info.dateTakenOffsetSeconds, 7200)
        // 14:02:31 at +02:00 = 12:02:31 UTC.
        XCTAssertEqual(info.dateTaken, ISO8601DateFormatter().date(from: "2026-09-25T12:02:31Z"))
        let gps = try XCTUnwrap(info.gps)
        XCTAssertEqual(gps.latitude, -33.86, accuracy: 1e-6)
        XCTAssertEqual(gps.longitude, 151.21, accuracy: 1e-6)
        XCTAssertEqual(PhotoInfo.Format.coordinate(gps), "33.8600° S, 151.2100° E")
    }

    func testGPSSign_allQuadrants() {
        func coord(_ lat: Double, _ latRef: String?, _ lon: Double, _ lonRef: String?) -> PhotoInfo.Coordinate? {
            var g: [CFString: Any] = [kCGImagePropertyGPSLatitude: lat, kCGImagePropertyGPSLongitude: lon]
            if let latRef { g[kCGImagePropertyGPSLatitudeRef] = latRef }
            if let lonRef { g[kCGImagePropertyGPSLongitudeRef] = lonRef }
            return PhotoInfo.parse(properties: [kCGImagePropertyGPSDictionary: g], typeIdentifier: nil).gps
        }
        XCTAssertEqual(coord(45.4371, "N", 12.3327, "E"), .init(latitude: 45.4371, longitude: 12.3327))
        XCTAssertEqual(coord(45.4371, "S", 12.3327, "W"), .init(latitude: -45.4371, longitude: -12.3327))
        XCTAssertEqual(coord(40.7, "N", 74.0, "W"), .init(latitude: 40.7, longitude: -74.0))
        XCTAssertEqual(coord(-40.7, nil, -74.0, nil), .init(latitude: -40.7, longitude: -74.0),
                       "no Ref: keep the stored sign")
        XCTAssertEqual(coord(-40.7, "N", 74.0, "E"), .init(latitude: 40.7, longitude: 74.0),
                       "Ref wins over a stray sign")
        XCTAssertEqual(PhotoInfo.Format.coordinate(.init(latitude: 40.7, longitude: -74)),
                       "40.7000° N, 74.0000° W")
    }

    func testMissingFieldsAreNil() throws {
        let url = try TestFixture.url("small.png")
        let info = try PhotoInfo.readSync(url)
        XCTAssertEqual(info.typeName, "PNG")
        XCTAssertNil(info.lens)
        XCTAssertNil(info.gps)
        XCTAssertNil(info.dateTaken)
        XCTAssertNotNil(info.pixelSize)
    }

    func testCorruptFileThrows() throws {
        let tmp = TempDir("photoinfo-bad")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("x.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try PhotoInfo.readSync(url))
    }

    func testCameraAndFormats() {
        var i = PhotoInfo()
        i.make = "Canon"; i.model = "Canon EOS R5"
        XCTAssertEqual(i.camera, "Canon EOS R5")
        i.make = "NIKON CORPORATION"; i.model = "NIKON Z 6"
        XCTAssertEqual(i.camera, "NIKON Z 6")
        i.make = "FUJIFILM"; i.model = "X-T5"
        XCTAssertEqual(i.camera, "FUJIFILM X-T5")
        i.make = nil
        XCTAssertEqual(i.camera, "X-T5")
        typealias F = PhotoInfo.Format
        XCTAssertEqual(F.aperture(2.8), "ƒ/2.8")
        XCTAssertEqual(F.aperture(8), "ƒ/8")
        XCTAssertEqual(F.shutter(0.004), "1/250 s")
        XCTAssertEqual(F.shutter(2.5), "2.5 s")
        XCTAssertEqual(F.focal(25, equivalent: 50), "25 mm (50 mm equiv.)")
        XCTAssertEqual(F.focal(50, equivalent: 50), "50 mm")
        XCTAssertEqual(F.exposureBias(-0.67), "\u{2212}0.7 EV")
        XCTAssertEqual(F.exposureBias(0.02), "0 EV")
        XCTAssertEqual(F.dimensions(CGSize(width: 6000, height: 4000)), "6000 × 4000 (24.0 MP)")
        XCTAssertEqual(PhotoInfo.offsetSeconds("-05:30"), -19800)
        XCTAssertNil(PhotoInfo.offsetSeconds("garbage"))
    }

    /// Must be cheap enough for every navigation
    /// (target < 2 ms for a 24 MP JPEG).
    func testRead24MPJPEG_timing() throws {
        let tmp = TempDir("photoinfo-24mp")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("big.jpg")
        try Self.writeJPEG(to: url, width: 6000, height: 4000, noise: true, gps: [
            kCGImagePropertyGPSLatitude: 45.4371, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 12.3327, kCGImagePropertyGPSLongitudeRef: "E",
        ])
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        var times: [Double] = []
        var info = PhotoInfo()
        for _ in 0..<50 {
            let t0 = CFAbsoluteTimeGetCurrent()
            info = try PhotoInfo.readSync(url)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        let first = times[0]
        times.sort()
        XCTAssertEqual(info.pixelWidth, 6000)
        XCTAssertEqual(info.gps?.latitude ?? 0, 45.4371, accuracy: 1e-6)
        print(String(format: "[timing] PhotoInfo.readSync 24 MP JPEG (%.1f MB): first=%.3f ms "
                     + "median=%.3f ms p90=%.3f ms min=%.3f ms", Double(size) / 1e6,
                     first, times[25], times[45], times[0]))
        XCTAssertLessThan(times[25], 10, "median; target < 2 ms, loose guard for loaded CI")
    }
}

//
//  LosslessRotatorTests.swift
//  ShrikeEditTests
//
//  Lossless rotate rewrites only the orientation tag. Decoded (with
//  transform) pixels after == rotated pixels before; JPEG compressed data
//  is byte-identical; the original is backed up first.
//

import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit
import ShrikeIO

final class LosslessRotatorTests: XCTestCase {

    var tmp: EditTempDir!
    var store: BackupStore!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("LosslessRotatorTests")
        store = BackupStore(root: tmp.url.appendingPathComponent("backups"), retentionDays: { -1 })
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func file(_ name: String, type: UTType, orientation: UInt32 = 1,
                      image: CGImage = PixelTestKit.quadrantImage(width: 40, height: 20)) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try PixelTestKit.write(image, to: url, type: type, orientation: orientation, quality: 0.9)
        return url
    }

    /// Every JPEG segment except APPn / COM, plus the entropy-coded scan
    /// — i.e. everything that describes the compressed pixels.
    private func jpegImageData(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var out = Data()
        var i = 2
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xDA { out.append(contentsOf: b[i...]); return out }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            let isAppOrCom = (0xE0...0xEF).contains(marker) || marker == 0xFE
            if !isAppOrCom { out.append(contentsOf: b[i..<(i + 2 + len)]) }
            i += 2 + len
        }
        return nil
    }

    // MARK: JPEG — pixels, byte identity, backup, orientation fields.

    func test_jpeg_rotateCW_pixelsRotated_dataByteIdentical_backedUp() async throws {
        let url = try file("a.jpg", type: .jpeg)
        let bytesBefore = try Data(contentsOf: url)
        let shownBefore = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))

        let rotator = LosslessRotator(backupStore: store)
        let result = try await rotator.rotate(url: url, quarters: 1)

        XCTAssertEqual(result.oldOrientation, .up)
        XCTAssertEqual(result.newOrientation, .right)
        XCTAssertEqual(PixelTestKit.orientation(url), 6)
        let shownAfter = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
        XCTAssertEqual(shownAfter, PixelTestKit.rotateCW(shownBefore),
                       "displayed pixels must be the original rotated 90° CW")
        XCTAssertEqual(jpegImageData(try Data(contentsOf: url)), jpegImageData(bytesBefore),
                       "compressed image data must be byte-identical (no re-encode)")
        XCTAssertNotNil(jpegImageData(bytesBefore))
        XCTAssertEqual(try Data(contentsOf: result.backup.backupURL), bytesBefore)
        XCTAssertEqual(result.backup.reason, .rotate)

        // TIFF / XMP orientation agree.
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let tiff = props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertEqual((tiff?[kCGImagePropertyTIFFOrientation] as? NSNumber)?.intValue, 6)
        if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil),
           let xmp = CGImageMetadataCopyStringValueWithPath(md, nil, "tiff:Orientation" as CFString) {
            XCTAssertEqual(xmp as String, "6")
        }

        // Undo restores the exact original bytes.
        try await rotator.undo(result)
        XCTAssertEqual(try Data(contentsOf: url), bytesBefore)
    }

    /// All 8 starting orientations × 6 ops on a real file (48 cases).
    func test_jpeg_allOrientationsTimesAllOps() async throws {
        let rotator = LosslessRotator(backupStore: store)
        var n = 0
        for o in ExifOrientation.allCases {
            for op in PixelTestKit.allOps {
                let url = try file("m\(o.rawValue)-\(n).jpg", type: .jpeg, orientation: o.rawValue,
                                   image: PixelTestKit.distinctImage())
                let before = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
                let dataBefore = jpegImageData(try Data(contentsOf: url))
                let r = try await rotator.apply(op, to: url)
                XCTAssertEqual(r.oldOrientation, o)
                XCTAssertEqual(r.newOrientation, o.applying(op))
                let after = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
                XCTAssertEqual(after, PixelTestKit.apply(op, before), "o\(o.rawValue) + \(op)")
                XCTAssertEqual(jpegImageData(try Data(contentsOf: url)), dataBefore)
                n += 1
            }
        }
        XCTAssertEqual(n, 48)
    }

    func test_rotateTwiceAndBack_isIdentityTag() async throws {
        let url = try file("b.jpg", type: .jpeg, orientation: 6)
        let rotator = LosslessRotator(backupStore: store)
        try await rotator.rotate(url: url, quarters: -1)
        XCTAssertEqual(PixelTestKit.orientation(url), 1)
        try await rotator.rotate(url: url, quarters: 2)
        XCTAssertEqual(PixelTestKit.orientation(url), 3)
        try await rotator.flip(url: url, horizontal: true)
        XCTAssertEqual(PixelTestKit.orientation(url), 4)
    }

    // MARK: Other formats.

    func test_heic_tiff_png_rotateLosslessly() async throws {
        let rotator = LosslessRotator(backupStore: store)
        for (name, type) in [("c.heic", UTType.heic), ("c.tiff", .tiff), ("c.png", .png)] {
            let url = try file(name, type: type)
            let before = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
            try await rotator.rotate(url: url, quarters: 1)
            XCTAssertEqual(PixelTestKit.orientation(url), 6, name)
            let after = PixelTestKit.grid(try XCTUnwrap(PixelTestKit.displayed(url)))
            let expected = PixelTestKit.rotateCW(before)
            if type == .heic {
                // HEIC decodes through a clean-aperture crop that can land
                // one pixel differently after `irot`; compare regions.
                XCTAssertEqual(after.count, expected.count)
                XCTAssertEqual(after.first?.count, expected.first?.count)
                let h = expected.count, w = expected[0].count
                for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let x = Int(Double(w) * fx), y = Int(Double(h) * fy)
                    let a = PixelTestKit.meanColor(after, x0: x - 2, y0: y - 2, x1: x + 2, y1: y + 2)
                    let b = PixelTestKit.meanColor(expected, x0: x - 2, y0: y - 2, x1: x + 2, y1: y + 2)
                    XCTAssertLessThan(abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2), 30, "\(name) at \(fx),\(fy)")
                }
            } else {
                XCTAssertEqual(after, expected, "\(name): pixels must be rotated, not re-encoded")
            }
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(src) as String?, type.identifier, "\(name) keeps its format")
        }
    }

    // MARK: Refusals.

    private func assertUnsupported(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try Data(contentsOf: url)
        do {
            try await LosslessRotator(backupStore: store).rotate(url: url, quarters: 1)
            XCTFail("expected .unsupportedFormat", file: file, line: line)
        } catch let e as LosslessRotateError {
            XCTAssertEqual(e, .unsupportedFormat, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: url), before, file: file, line: line)
    }

    func test_unsupported_gif_multiPageTIFF_raw() async throws {
        try await assertUnsupported(try file("d.gif", type: .gif))

        let pages = tmp.url.appendingPathComponent("pages.tiff")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(pages as CFURL, UTType.tiff.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(dest, PixelTestKit.distinctImage(), nil)
        CGImageDestinationAddImage(dest, PixelTestKit.distinctImage(), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        try await assertUnsupported(pages)

        // RAW by extension, even if the bytes happen to be a JPEG.
        let raw = tmp.url.appendingPathComponent("IMG.PEF")
        try FileManager.default.copyItem(at: try file("e.jpg", type: .jpeg), to: raw)
        try await assertUnsupported(raw)
    }

    func test_missingFile() async {
        do {
            try await LosslessRotator(backupStore: store)
                .rotate(url: tmp.url.appendingPathComponent("nope.jpg"), quarters: 1)
            XCTFail("expected throw")
        } catch let e as LosslessRotateError {
            XCTAssertEqual(e, .sourceMissing)
        } catch { XCTFail("\(error)") }
    }

    func test_backupFailure_leavesFileUntouched() async throws {
        let url = try file("f.jpg", type: .jpeg)
        let before = try Data(contentsOf: url)
        let blocker = tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let badStore = BackupStore(root: blocker.appendingPathComponent("b"), retentionDays: { -1 })
        do {
            try await LosslessRotator(backupStore: badStore).rotate(url: url, quarters: 1)
            XCTFail("expected throw")
        } catch let e as LosslessRotateError {
            guard case .backupFailed = e else { return XCTFail("wrong error \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.contains("shrikerotate") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}

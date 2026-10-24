//
//  ExporterFileSafetyTests.swift
//  ShrikeEditTests
//
//  Audit 2026-10-24: FS-2 (revert after Save As onto an existing file),
//  FS-4 / FS-5 (metadata kept on save, location text removed) and FS-10
//  (hidden temp name). Temp folders only.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class ExporterFileSafetyTests: XCTestCase {

    private var tmp: EditTempDir!
    private var backups: BackupStore!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("ExporterFileSafety")
        backups = BackupStore(root: tmp.url.appendingPathComponent("backups"), retentionDays: { 30 })
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    func writeJPEG(_ name: String, w: Int, h: Int = 80, properties: [CFString: Any]? = nil) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, properties as CFDictionary?)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func cropAll() -> EditRecipe {
        EditRecipe(operations: [.crop(CropRect(originX: 0, originY: 0, width: 0.9, height: 1))])
    }

    // MARK: FS-2

    func testRevertAfterSaveAsOntoAnExistingFileDoesNotBringBackTheReplacedPhoto() async throws {
        let a = try writeJPEG("a.jpg", w: 200)
        let b = try writeJPEG("b.jpg", w: 300)
        let oldB = try Data(contentsOf: b)
        let exporter = ImageExporter(backupStore: backups)
        // Save As: edited A replaces B.
        try await exporter.export(recipe: cropAll(), from: a, to: b, format: .jpeg)
        let newB = try Data(contentsOf: b)
        XCTAssertNotEqual(newB, oldB)
        // The replaced photo is still recoverable (by its record) ...
        let all = await backups.allRecords()
        XCTAssertEqual(all.filter { $0.reason == .save }.count, 1)
        // ... but B's own history starts empty.
        let bRecords = await backups.records(for: b)
        XCTAssertTrue(bRecords.isEmpty, "the new b.jpg must not inherit the replaced photo's backup")
        // Edit the new B in place, then Revert to Original.
        try await exporter.export(recipe: cropAll(), from: b, to: b, format: .jpeg)
        XCTAssertNotEqual(try Data(contentsOf: b), newB)
        _ = try await backups.revertToOriginal(b)
        XCTAssertEqual(try Data(contentsOf: b), newB, "revert gives back the edited photo's own bytes, not the old b.jpg")
    }

    func testReplacedPhotoCanStillBeRestoredFromItsRecord() async throws {
        let a = try writeJPEG("a.jpg", w: 200)
        let b = try writeJPEG("b.jpg", w: 300)
        let oldB = try Data(contentsOf: b)
        let record = try await XCTUnwrapAsync(try await ImageExporter(backupStore: backups)
            .export(recipe: cropAll(), from: a, to: b, format: .jpeg, backupReason: .replace))
        _ = try await backups.restore(record)
        XCTAssertEqual(try Data(contentsOf: b), oldB)
    }

    // MARK: FS-10 temp file

    func testTemporaryFileIsHiddenWhileSaving() async throws {
        let a = try writeJPEG("a.jpg", w: 200)
        let folder: URL = tmp.url
        let seen = LockedBox<[String]>([])
        let exporter = ImageExporter(backupStore: backups, checkpoint: { point in
            if point == .encoded {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                seen.set(names.filter { $0.contains(".shrikeedit.") })
            }
        })
        try await exporter.export(recipe: cropAll(), from: a, to: tmp.url.appendingPathComponent("b.jpg"), format: .jpeg)
        XCTAssertEqual(seen.get().count, 1)
        XCTAssertTrue(seen.get().allSatisfy { $0.hasPrefix(".") }, "\(seen.get())")
    }

    func testStaleTemporariesAreSweptButFreshOnesStay() throws {
        let folder = tmp.url.appendingPathComponent("sweep", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stale = folder.appendingPathComponent(".old.shrikeedit.AAAA.jpg.tmp")
        let legacy = folder.appendingPathComponent("old.shrikeedit.BBBB.jpg.tmp")
        let fresh = folder.appendingPathComponent(".new.shrikeedit.CCCC.jpg.tmp")
        let photo = folder.appendingPathComponent("photo.jpg")
        for url in [stale, legacy, fresh, photo] { try Data([1]).write(to: url) }
        let longAgo = Date().addingTimeInterval(-2 * 3600)
        for url in [stale, legacy, photo] {
            try FileManager.default.setAttributes([.modificationDate: longAgo], ofItemAtPath: url.path)
        }
        ImageExporter.sweepStaleTemporaries(in: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path), "may belong to a save in progress")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "never touches a photo")
    }

    // MARK: FS-4 / FS-5 metadata

    /// A JPEG with a colour label and place names in XMP, IPTC place text and
    /// keywords, GPS, a maker note, a camera make, and a rotated orientation.
    private func richSource() throws -> URL {
        let md = CGImageMetadataCreateMutable()
        func set(_ ns: CFString, _ prefix: CFString, _ name: String, _ value: String) {
            CGImageMetadataRegisterNamespaceForPrefix(md, ns, prefix, nil)
            XCTAssertTrue(CGImageMetadataSetValueWithPath(md, nil, "\(prefix):\(name)" as CFString, value as CFString), name)
        }
        set(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "Label", "Red")
        set(kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop, "City", "Paris")
        set(kCGImageMetadataNamespacePhotoshop, kCGImageMetadataPrefixPhotoshop, "Country", "France")
        let url = tmp.url.appendingPathComponent("rich.jpg")
        let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Paris", kCGImagePropertyIPTCSubLocation: "Rue Example 12",
                                             kCGImagePropertyIPTCProvinceState: "IdF", kCGImagePropertyIPTCCountryPrimaryLocationName: "France",
                                             kCGImagePropertyIPTCKeywords: ["alpha", "beta"]],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.8, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 2.3, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyMakerAppleDictionary: ["17": "LIVE-PHOTO-LINK"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Shrike Test"],
        ]
        CGImageDestinationAddImageAndMetadata(dest, ctx.makeImage()!, md, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private struct Facts {
        var properties: [CFString: Any]
        var tags: [String: String]   // "prefix:name" -> value text
    }

    private func facts(_ url: URL) throws -> Facts {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        var tags: [String: String] = [:]
        if let md = CGImageSourceCopyMetadataAtIndex(src, 0, nil), let all = CGImageMetadataCopyTags(md) as? [Any] {
            for case let tag as CGImageMetadataTag in all {
                let prefix = (CGImageMetadataTagCopyPrefix(tag) as String?) ?? ""
                let name = (CGImageMetadataTagCopyName(tag) as String?) ?? ""
                tags["\(prefix):\(name)"] = "\(CGImageMetadataTagCopyValue(tag) ?? "" as CFString)"
            }
        }
        return Facts(properties: props, tags: tags)
    }

    func testSaveKeepsXMPColourLabelMakerNotesAndKeywords() async throws {
        let src = try richSource()
        let out = tmp.url.appendingPathComponent("out.jpg")
        try await ImageExporter(backupStore: backups).export(recipe: cropAll(), from: src, to: out, format: .jpeg)
        let f = try facts(out)
        XCTAssertEqual(f.tags["xmp:Label"], "Red", "colour label survives")
        let link = (f.properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])?["17"] as? String ?? ""
        XCTAssertTrue(link.hasPrefix("LIVE-PHOTO-LINK"), "maker note (Live Photo link) survives: \(link)")
        XCTAssertEqual((f.properties[kCGImagePropertyIPTCDictionary] as? [String: Any])?["Keywords"] as? [String], ["alpha", "beta"])
        XCTAssertEqual((f.properties[kCGImagePropertyTIFFDictionary] as? [String: Any])?["Make"] as? String, "Shrike Test")
        XCTAssertNotNil(f.properties[kCGImagePropertyGPSDictionary], "GPS kept when not asked to remove")
        // The orientation tag is gone / 1 (the pixels are turned), and the size is the new one.
        let orientation = (f.properties[kCGImagePropertyOrientation] as? Int) ?? 1
        XCTAssertEqual(orientation, 1)
        let exif = f.properties[kCGImagePropertyExifDictionary] as? [String: Any]
        if let w = exif?["PixelXDimension"] as? Int {
            XCTAssertEqual(w, f.properties[kCGImagePropertyPixelWidth] as? Int, "XMP/Exif size is the new picture's")
        }
    }

    func testRemoveLocationRemovesGPSAndPlaceTextButKeepsTheRest() async throws {
        let src = try richSource()
        let out = tmp.url.appendingPathComponent("out.jpg")
        try await ImageExporter(backupStore: backups).export(recipe: cropAll(), from: src, to: out, format: .jpeg, stripGPS: true)
        let f = try facts(out)
        XCTAssertNil(f.properties[kCGImagePropertyGPSDictionary], "coordinates gone")
        XCTAssertNil(f.tags.keys.first { $0.hasPrefix("exif:GPS") }, "XMP coordinates gone: \(f.tags.keys.sorted())")
        let iptc = f.properties[kCGImagePropertyIPTCDictionary] as? [String: Any] ?? [:]
        for key in ["City", "Sub-location", "Province/State", "Country/PrimaryLocationName", "Country/PrimaryLocationCode"] {
            XCTAssertNil(iptc[key], "IPTC \(key) must go: \(iptc)")
        }
        for key in ["photoshop:City", "photoshop:State", "photoshop:Country", "Iptc4xmpCore:Location", "Iptc4xmpCore:CountryCode"] {
            XCTAssertNil(f.tags[key], "\(key) must go")
        }
        // Everything that is not a place stays.
        XCTAssertEqual(f.tags["xmp:Label"], "Red")
        XCTAssertEqual(iptc["Keywords"] as? [String], ["alpha", "beta"])
        XCTAssertEqual((f.properties[kCGImagePropertyTIFFDictionary] as? [String: Any])?["Make"] as? String, "Shrike Test")
    }

    func testDroppingMetadataDropsEverything() async throws {
        let src = try richSource()
        let out = tmp.url.appendingPathComponent("out.jpg")
        try await ImageExporter(backupStore: backups).export(recipe: cropAll(), from: src, to: out, format: .jpeg, preserveEXIF: false)
        let f = try facts(out)
        XCTAssertNil(f.tags["xmp:Label"])
        XCTAssertNil(f.properties[kCGImagePropertyGPSDictionary])
        XCTAssertNil(f.properties[kCGImagePropertyMakerAppleDictionary])
    }

    private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
}

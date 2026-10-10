//
//  ExporterTests.swift
//  ShrikeEditTests
//
//  Covers atomic rename under mid-write failure, EXIF preservation
//  (except orientation) on the recipe path, and non-JPEG files falling
//  through to the recipe path.
//

import XCTest
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers
@testable import ShrikeEdit
import ShrikeIO

final class ExporterTests: XCTestCase {

    var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("ExporterTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    // MARK: Atomic rename on bad destination leaves original intact.

    func test_export_failureLeavesOriginalIntact() async throws {
        // Copy `small.jpg` into tmp as "original.jpg". We'll then ask
        // the exporter to write to a destination inside a non-existent
        // directory — atomic rename fails, and original.jpg is
        // untouched because we never even opened it for writing.
        let originalFixture = try EditFixture.url("small.jpg")
        let originalDest = tmp.url.appendingPathComponent("original.jpg")
        try FileManager.default.copyItem(at: originalFixture, to: originalDest)

        let originalBytesBefore = try Data(contentsOf: originalDest)

        // Bogus destination: under a directory that doesn't exist.
        let bogusDir = tmp.url.appendingPathComponent("does/not/exist")
        let bogusDest = bogusDir.appendingPathComponent("out.jpg")

        let recipe = EditRecipe()
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.1)))

        let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
        do {
            try await exporter.export(
                recipe: recipe,
                from: originalDest,
                to: bogusDest,
                format: .jpeg,
                quality: 0.92
            )
            XCTFail("export should have thrown")
        } catch {
            // Expected. Assert original is byte-identical.
            let originalBytesAfter = try Data(contentsOf: originalDest)
            XCTAssertEqual(originalBytesBefore, originalBytesAfter,
                           "export failure must not touch the source file")
            // Assert the destination was never created.
            XCTAssertFalse(FileManager.default.fileExists(atPath: bogusDest.path),
                           "failed export must not leave a partial destination file")
        }
    }

    // MARK: Successful export writes bytes to dest and clears tmp.

    func test_export_success_writesDestinationAndCleansTmp() async throws {
        let originalFixture = try EditFixture.url("small.jpg")
        let source = tmp.url.appendingPathComponent("in.jpg")
        try FileManager.default.copyItem(at: originalFixture, to: source)

        let dest = tmp.url.appendingPathComponent("out.jpg")

        let recipe = EditRecipe()
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.1)))

        let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
        try await exporter.export(
            recipe: recipe,
            from: source,
            to: dest,
            format: .jpeg,
            quality: 0.92
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        // No `.shrikeedit.*.tmp` leftovers in the destination directory.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        for s in siblings {
            XCTAssertFalse(s.contains(".shrikeedit."),
                           "temp file must be cleaned up: \(s)")
        }
    }

    // MARK: EXIF preservation with orientation rewritten to 1.

    func test_export_preservesEXIF_rewritesOrientation() async throws {
        // `landscape_with_exif.jpg` has Make/Model/etc. Rotate by 90°
        // via the recipe; confirm destination keeps Make/Model but
        // orientation == 1.
        let originalFixture = try EditFixture.url("landscape_with_exif.jpg")
        let source = tmp.url.appendingPathComponent("in.jpg")
        try FileManager.default.copyItem(at: originalFixture, to: source)
        let dest = tmp.url.appendingPathComponent("out.jpg")

        let recipe = EditRecipe()
        await recipe.append(.rotate90(quarters: 1))

        let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
        try await exporter.export(
            recipe: recipe,
            from: source,
            to: dest,
            format: .jpeg,
            quality: 0.92,
            preserveEXIF: true,
            stripGPS: false
        )

        // Re-read destination properties.
        let imageSource = CGImageSourceCreateWithURL(dest as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any] ?? [:]

        // Orientation is top-level on JPEG; always 1 after bake.
        if let orientation = props[kCGImagePropertyOrientation] as? Int {
            XCTAssertEqual(orientation, 1, "baked rotation must rewrite orientation to 1")
        }

        // TIFF Make/Model round-trip.
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNotNil(tiff, "TIFF dictionary must be present after preserveEXIF")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFMake] as? String, "Shrike Test")
        XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, "Fixture")

        // EXIF lens should round-trip.
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNotNil(exif, "EXIF dictionary must be present after preserveEXIF")
    }

    // MARK: Non-JPEG ⌘R (recipe path) writes rotated PNG, format preserved.

    func test_recipePath_rotatesPNGPreservingFormat() async throws {
        // Build a non-square PNG so rotation is observable.
        let src = EditFixture.solidRGB(width: 16, height: 8, red: 0, green: 1, blue: 0)
        let source = tmp.url.appendingPathComponent("in.png")

        // Encode the source as PNG manually.
        let destOut = CGImageDestinationCreateWithURL(source as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destOut, src, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destOut))

        // One-op recipe: rotate 90° CW.
        let recipe = EditRecipe()
        await recipe.append(.rotate90(quarters: 1))

        let dest = tmp.url.appendingPathComponent("out.png")
        let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
        try await exporter.export(
            recipe: recipe,
            from: source,
            to: dest,
            format: .png,
            quality: 1.0,
            preserveEXIF: false,
            stripGPS: false
        )

        // Dest is a PNG.
        let imageSource = CGImageSourceCreateWithURL(dest as CFURL, nil)!
        let type = CGImageSourceGetType(imageSource)! as String
        XCTAssertEqual(type, UTType.png.identifier, "export with .png must write a PNG")

        // Dest pixels are rotated: 16×8 becomes 8×16.
        let outImg = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)!
        XCTAssertEqual(outImg.width, 8)
        XCTAssertEqual(outImg.height, 16)
    }

    // MARK: RAW redirect suffix is surfaced for UI use.

    func test_rawRedirectSuffix_publicConstant() {
        XCTAssertEqual(ImageExporter.rawRedirectSuffix, "-edited",
                       "suffix is '-edited'")
    }
}

// MARK: - Backup before overwrite

final class ExporterBackupTests: XCTestCase {

    var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("ExporterBackupTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func recipe() async -> EditRecipe {
        let r = EditRecipe()
        await r.append(.colorAdjust(ColorAdjustParams(brightness: 0.2)))
        return r
    }

    func test_inPlaceSave_backsUpOriginalFirst() async throws {
        let src = tmp.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: try EditFixture.url("small.jpg"), to: src)
        let before = try Data(contentsOf: src)
        let store = BackupStore(root: tmp.url.appendingPathComponent("backups"))

        let record = try await ImageExporter(backupStore: store).export(
            recipe: await recipe(), from: src, to: src, format: .jpeg)

        let rec = try XCTUnwrap(record, "an overwrite must return its backup record")
        XCTAssertEqual(rec.reason, .save)
        XCTAssertEqual(try Data(contentsOf: rec.backupURL), before, "backup holds the original bytes")
        XCTAssertNotEqual(try Data(contentsOf: src), before, "the file was re-encoded")
        let latest = await store.latest(for: src)
        XCTAssertEqual(latest?.id, rec.id)

        // Revert restores the original bytes.
        try await store.restore(rec)
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    func test_newFile_takesNoBackup() async throws {
        let src = tmp.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: try EditFixture.url("small.jpg"), to: src)
        let store = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let record = try await ImageExporter(backupStore: store).export(
            recipe: await recipe(), from: src,
            to: tmp.url.appendingPathComponent("new.jpg"), format: .jpeg)
        XCTAssertNil(record)
        let all = await store.allRecords()
        XCTAssertTrue(all.isEmpty)
    }

    func test_backupFailure_blocksOverwrite() async throws {
        let src = tmp.url.appendingPathComponent("photo.jpg")
        try FileManager.default.copyItem(at: try EditFixture.url("small.jpg"), to: src)
        let before = try Data(contentsOf: src)
        // A root *under a regular file* can never be created.
        let blocker = tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = BackupStore(root: blocker.appendingPathComponent("backups"))
        do {
            try await ImageExporter(backupStore: store).export(
                recipe: await recipe(), from: src, to: src, format: .jpeg)
            XCTFail("export must fail when the backup can't be written")
        } catch let e as ExportError {
            guard case .backupFailed = e else { return XCTFail("wrong error \(e)") }
        }
        XCTAssertEqual(try Data(contentsOf: src), before, "no backup → no overwrite")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
            .filter { $0.contains(".shrikeedit.") }
        XCTAssertTrue(leftovers.isEmpty, "temp file cleaned up: \(leftovers)")
    }
}

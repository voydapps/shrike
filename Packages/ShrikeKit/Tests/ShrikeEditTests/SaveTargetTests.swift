//
//  SaveTargetTests.swift
//  ShrikeEditTests
//
//  Never write the wrong format over a user's file.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit

final class SaveTargetTests: XCTestCase {

    var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("SaveTargetTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func path(_ name: String) -> URL { tmp.url.appendingPathComponent(name) }

    private func writeFrames(_ url: URL, type: UTType, frames: Int) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, frames, nil))
        for i in 0..<frames {
            let img = EditFixture.solidRGB(width: 8, height: 8,
                                           red: Double(i) / Double(max(frames, 1)),
                                           green: 0.5, blue: 0.2)
            CGImageDestinationAddImage(dest, img, nil)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // MARK: Extension-only answers (file doesn't exist yet).

    func test_inPlace_extensionTable() {
        let expect: [String: ExportFormat?] = [
            "jpg": .jpeg, "JPG": .jpeg, "jpeg": .jpeg, "jpe": .jpeg, "JFIF": .jpeg,
            "png": .png, "tif": .tiff, "TIFF": .tiff, "heic": .heic, "heif": .heic,
            "gif": nil, "bmp": nil, "psd": nil, "pdf": nil, "xyz": nil, "": nil,
            "heics": nil,
        ]
        for (ext, want) in expect {
            let url = URL(fileURLWithPath: "/nonexistent-shrike/x" + (ext.isEmpty ? "" : ".\(ext)"))
            XCTAssertEqual(ExportFormat.inPlaceFormat(for: url), want, ".\(ext)")
        }
    }

    func test_inPlace_everyRAWIsNil() {
        for ext in ["cr2", "cr3", "nef", "nrw", "arw", "sr2", "srf", "dng", "orf", "rw2",
                    "raf", "pef", "srw", "x3f", "mrw", "3fr", "erf", "rwl", "iiq", "dcr", "PEF"] {
            let url = URL(fileURLWithPath: "/nonexistent-shrike/x.\(ext)")
            XCTAssertNil(ExportFormat.inPlaceFormat(for: url), ".\(ext) must never be overwritten")
        }
    }

    func test_inPlace_webpAvif_followRuntimeEncoderSupport() {
        let encoders = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let webp = ExportFormat.inPlaceFormat(for: URL(fileURLWithPath: "/nonexistent-shrike/x.webp"))
        XCTAssertEqual(webp != nil, encoders.contains(UTType.webP.identifier))
        let avif = ExportFormat.inPlaceFormat(for: URL(fileURLWithPath: "/nonexistent-shrike/x.avif"))
        XCTAssertEqual(avif != nil, encoders.contains("public.avif"))
    }

    // MARK: Content checks on real files.

    func test_inPlace_singleFrameFilesAllowed() throws {
        let jpg = path("a.jpg"); try writeFrames(jpg, type: .jpeg, frames: 1)
        let png = path("a.png"); try writeFrames(png, type: .png, frames: 1)
        let tif = path("a.tif"); try writeFrames(tif, type: .tiff, frames: 1)
        XCTAssertEqual(ExportFormat.inPlaceFormat(for: jpg), .jpeg)
        XCTAssertEqual(ExportFormat.inPlaceFormat(for: png), .png)
        XCTAssertEqual(ExportFormat.inPlaceFormat(for: tif), .tiff)
    }

    func test_inPlace_multiFrameIsNil() throws {
        let tif = path("pages.tiff"); try writeFrames(tif, type: .tiff, frames: 3)
        XCTAssertNil(ExportFormat.inPlaceFormat(for: tif), "multi-page TIFF must force Save As")
        let gif = path("anim.gif"); try writeFrames(gif, type: .gif, frames: 2)
        XCTAssertNil(ExportFormat.inPlaceFormat(for: gif))
    }

    func test_inPlace_contentMismatchIsNil() throws {
        let fake = path("really-a-png.jpg"); try writeFrames(fake, type: .png, frames: 1)
        XCTAssertNil(ExportFormat.inPlaceFormat(for: fake), "PNG bytes named .jpg must not be rewritten as JPEG")
    }

    func test_editedSiblingURL() {
        let u = ExportFormat.editedSiblingURL(for: URL(fileURLWithPath: "/p/IMG_1.PEF"))
        XCTAssertEqual(u.path, "/p/IMG_1-edited.jpg")
    }

    // MARK: Exporter refuses (defence in depth).

    private func recipe() async -> EditRecipe {
        let r = EditRecipe()
        await r.append(.colorAdjust(ColorAdjustParams(brightness: 0.1)))
        return r
    }

    private func assertRefuses(_ source: URL, to dest: URL, format: ExportFormat,
                               _ expected: ExportError,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        let before = try Data(contentsOf: source)
        do {
            try await ImageExporter(backupStore: nil).export(
                recipe: await recipe(), from: source, to: dest, format: format)
            XCTFail("export should have thrown \(expected)", file: file, line: line)
        } catch let e as ExportError {
            XCTAssertEqual(e, expected, file: file, line: line)
        }
        XCTAssertEqual(try Data(contentsOf: source), before, "source must be untouched",
                       file: file, line: line)
    }

    func test_exporter_refusesInPlaceGIF() async throws {
        let gif = path("party.gif"); try writeFrames(gif, type: .gif, frames: 2)
        try await assertRefuses(gif, to: gif, format: .jpeg, .extensionMismatch)
        try await assertRefuses(gif, to: gif, format: .png, .extensionMismatch)
    }

    func test_exporter_refusesInPlaceMultiPageTIFF() async throws {
        let tif = path("scan.tiff"); try writeFrames(tif, type: .tiff, frames: 2)
        try await assertRefuses(tif, to: tif, format: .tiff, .inPlaceWriteNotAllowed)
    }

    func test_exporter_refusesInPlaceMislabelled() async throws {
        let fake = path("fake.jpg"); try writeFrames(fake, type: .png, frames: 1)
        try await assertRefuses(fake, to: fake, format: .jpeg, .inPlaceWriteNotAllowed)
    }

    func test_exporter_refusesRAWDestination() async throws {
        let jpg = path("a.jpg"); try writeFrames(jpg, type: .jpeg, frames: 1)
        try await assertRefuses(jpg, to: path("a.nef"), format: .jpeg, .unwritableFormat)
    }

    func test_exporter_allowsInPlaceJPEG() async throws {
        let jpg = path("ok.jpg"); try writeFrames(jpg, type: .jpeg, frames: 1)
        try await ImageExporter(backupStore: nil).export(
            recipe: await recipe(), from: jpg, to: jpg, format: .jpeg)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(jpg as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
    }
}

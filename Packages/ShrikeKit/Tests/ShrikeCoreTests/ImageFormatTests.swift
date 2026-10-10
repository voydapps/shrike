//
//  ImageFormatTests.swift
//  ShrikeCoreTests
//
//  Classification-by-extension tests for `ImageFormat`. Kept
//  deliberately tight: the enum is cheap, the point is the
//  extension → format mapping and case-insensitivity.
//

import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class ImageFormatTests: XCTestCase {

    // MARK: - Common image formats

    func testClassifiesJPEGVariants() {
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.jpg")), .jpeg)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.jpeg")), .jpeg)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.JPG")), .jpeg)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.Jpeg")), .jpeg)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.jpe")), .jpeg)
    }

    func testClassifiesHEIC() {
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.heic")), .heic)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.HEIC")), .heic)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.heif")), .heic)
    }

    func testClassifiesCommonFormats() {
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.png")), .png)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.PNG")), .png)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.gif")), .gif)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.tif")), .tiff)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.tiff")), .tiff)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.webp")), .webp)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.avif")), .avif)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.bmp")), .bmp)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.psd")), .psd)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.pdf")), .pdf)
    }

    // MARK: - RAW coverage

    func testClassifiesAllRAWExtensions() {
        // All supported vendors; each must map to .raw.
        let rawExtensions = [
            "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2",
            "raf", "pef", "srw", "mrw", "nrw", "sr2",
            // Not in the table: reached through UTType conformance.
            "3fr", "iiq", "erf", "rwl", "dcr", "crw", "srf",
        ]
        for ext in rawExtensions {
            let url = URL(fileURLWithPath: "/a/b.\(ext)")
            XCTAssertEqual(ImageFormat(url: url), .raw,
                           "extension .\(ext) should classify as .raw")
            // Case-insensitivity applies to RAW too — cameras vary.
            let upper = URL(fileURLWithPath: "/a/b.\(ext.uppercased())")
            XCTAssertEqual(ImageFormat(url: upper), .raw,
                           "extension .\(ext.uppercased()) should classify as .raw")
        }
    }

    // MARK: - Unknown / edge cases

    func testUnknownExtensionMapsToOther() {
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.xyz")), .other)
        XCTAssertEqual(ImageFormat(url: URL(fileURLWithPath: "/a/b.wat")), .other)
    }

    func testURLWithoutExtensionReturnsNil() {
        // Path with no extension at all → nil (no basis to classify).
        // Callers typically treat this identically to .other.
        XCTAssertNil(ImageFormat(url: URL(fileURLWithPath: "/a/no_extension_here")))
    }

    func testInitFromExtensionString() {
        XCTAssertEqual(ImageFormat(extension: "jpg"), .jpeg)
        XCTAssertEqual(ImageFormat(extension: "JPG"), .jpeg)
        XCTAssertEqual(ImageFormat(extension: "mystery"), .other)
        XCTAssertNil(ImageFormat(extension: ""))
    }

    // MARK: - hasEmbeddedPreview

    /// Truth table for the embedded-preview pre-gate used by
    /// `FileImageSource.loadEmbeddedPreview`. JPEG / HEIC / RAW / TIFF
    /// are on the "yes" side; everything else is "no" (TIFF is
    /// intentionally permissive — see the docstring on
    /// `hasEmbeddedPreview` for why).
    func testHasEmbeddedPreview_yesFormats() {
        XCTAssertTrue(ImageFormat.jpeg.hasEmbeddedPreview)
        XCTAssertTrue(ImageFormat.heic.hasEmbeddedPreview)
        XCTAssertTrue(ImageFormat.raw.hasEmbeddedPreview)
        XCTAssertTrue(ImageFormat.tiff.hasEmbeddedPreview,
                      "TIFF kept on yes-list to cover RAW-in-TIFF (DNG etc.)")
    }

    func testHasEmbeddedPreview_noFormats() {
        XCTAssertFalse(ImageFormat.png.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.gif.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.bmp.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.webp.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.avif.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.psd.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.pdf.hasEmbeddedPreview)
        XCTAssertFalse(ImageFormat.other.hasEmbeddedPreview)
    }

    /// Exhaustive coverage so adding a new `ImageFormat` case forces a
    /// conscious yes/no decision (the switch in `hasEmbeddedPreview`
    /// won't compile without it). This test is mostly a tripwire for
    /// future enum additions.
    func testHasEmbeddedPreview_coversAllCases() {
        for format in ImageFormat.allCases {
            // Just call the property — exhaustive switch will fail to
            // compile if a case is missing, which is the real guarantee.
            _ = format.hasEmbeddedPreview
        }
        XCTAssertEqual(ImageFormat.allCases.count, 12,
                       "if you added a new ImageFormat case, decide its hasEmbeddedPreview value and update both tests above")
    }

    // MARK: - Supported formats (the one list)

    func testSupportedCommonFormats() {
        for ext in ["jpg", "JPG", "jpeg", "jpe", "jfif", "heic", "HEIF", "png", "gif",
                    "tif", "tiff", "webp", "avif", "bmp", "psd",
                    "cr2", "cr3", "nef", "nrw", "arw", "sr2", "dng", "orf", "rw2",
                    "raf", "pef", "srw", "mrw", "3fr", "iiq"] {
            XCTAssertTrue(ImageFormat.isSupported(URL(fileURLWithPath: "/a/b.\(ext)")), ".\(ext)")
        }
    }

    func testUndecodableAndNonImageFormatsAreNotSupported() {
        // X3F / KDC: ImageIO has no decoder, so Shrike must not list them as
        // images (they are companion-only RAWs).
        for ext in ["x3f", "X3F", "kdc", "pdf", "txt", "mov", "xmp", "aae", "", "xyz"] {
            XCTAssertFalse(ImageFormat.isSupported(URL(fileURLWithPath: "/a/b.\(ext)")), ".\(ext)")
        }
        XCTAssertFalse(ImageFormat.isSupported(URL(fileURLWithPath: "/a/no_extension")))
        XCTAssertFalse(ImageFormat.supportedExtensions.contains("x3f"))
        XCTAssertFalse(ImageFormat.supportedExtensions.contains("kdc"))
        XCTAssertEqual(ImageFormat.companionOnlyRAWExtensions, ["x3f", "kdc"])
        XCTAssertFalse(ImageFormat.supportedRAWExtensions.contains("x3f"))
    }

    func testSupportedTypesFollowImageIO() {
        let decodable = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        XCTAssertTrue(ImageFormat.isSupported(UTType.jpeg))
        XCTAssertTrue(ImageFormat.isSupported(UTType.png))
        XCTAssertFalse(ImageFormat.isSupported(UTType.pdf), "ImageIO does not decode PDF")
        XCTAssertFalse(ImageFormat.isSupported(UTType.plainText))
        XCTAssertFalse(ImageFormat.isSupported(UTType.quickTimeMovie))
        // JPEG XL is in exactly when this OS's ImageIO lists it.
        if let jxl = UTType("public.jpeg-xl") {
            XCTAssertEqual(ImageFormat.isSupported(jxl), decodable.contains(jxl.identifier))
            XCTAssertEqual(ImageFormat.supportedExtensions.contains("jxl"),
                           decodable.contains(jxl.identifier))
        }
        for type in ImageFormat.decodableImageTypes {
            XCTAssertTrue(decodable.contains(type.identifier), type.identifier)
            XCTAssertTrue(type.conforms(to: .image), type.identifier)
        }
    }

    func testRAWExtensionSetExcludesTIFF() {
        let raws = ImageFormat.supportedRAWExtensions
        XCTAssertTrue(raws.isSuperset(of: ["cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "raf"]))
        XCTAssertFalse(raws.contains("tif"), "`.tif` resolves to TIFF, not Canon's TIFF-RAW type")
        XCTAssertFalse(raws.contains("jpg"))
        XCTAssertTrue(raws.isSubset(of: ImageFormat.supportedExtensions))
    }

    func testFolderScanSetAddsCompanions() {
        XCTAssertTrue(ImageFormat.folderScanExtensions.isSuperset(of: ["xmp", "aae", "mov", "jpg", "orf"]))
        XCTAssertTrue(ImageFormat.isFolderScanCandidate(URL(fileURLWithPath: "/a/IMG_1.MOV")))
        XCTAssertTrue(ImageFormat.isFolderScanCandidate(URL(fileURLWithPath: "/a/IMG_1.xmp")))
        XCTAssertFalse(ImageFormat.isFolderScanCandidate(URL(fileURLWithPath: "/a/notes.txt")))
        // Companion-only RAWs are picked up so ImageGrouping can attach them.
        XCTAssertTrue(ImageFormat.isFolderScanCandidate(URL(fileURLWithPath: "/a/IMG_1.X3F")))
        XCTAssertTrue(ImageFormat.isFolderScanCandidate(URL(fileURLWithPath: "/a/IMG_1.kdc")))
    }

    func testX3FIsNoLongerClassifiedAsRAW() {
        XCTAssertEqual(ImageFormat(extension: "x3f"), .other)
        XCTAssertFalse(ImageFormat.isCameraRAW(URL(fileURLWithPath: "/a/b.x3f")))
        XCTAssertTrue(ImageFormat.isCameraRAW(URL(fileURLWithPath: "/a/b.3fr")))
    }
}

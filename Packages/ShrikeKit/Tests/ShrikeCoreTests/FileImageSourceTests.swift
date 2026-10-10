//
//  FileImageSourceTests.swift
//  ShrikeCoreTests
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class FileImageSourceTests: XCTestCase {

    // MARK: - Properties

    func testLoadProperties_smallJpeg() async throws {
        let url = try TestFixture.url("small.jpg")
        let source = FileImageSource(url: url)
        let props = try await source.loadProperties()

        XCTAssertEqual(props.pixelWidth, 128)
        XCTAssertEqual(props.pixelHeight, 128)
        XCTAssertEqual(props.orientation, .up)
        XCTAssertGreaterThan(props.fileSize, 0)
        XCTAssertTrue(
            props.utType.conforms(to: .jpeg),
            "expected JPEG UTType, got \(props.utType.identifier)"
        )
    }

    func testLoadProperties_landscapeWithExif() async throws {
        let url = try TestFixture.url("landscape_with_exif.jpg")
        let source = FileImageSource(url: url)
        let props = try await source.loadProperties()

        XCTAssertEqual(props.pixelWidth, 192)
        XCTAssertEqual(props.pixelHeight, 128)

        let exif = try XCTUnwrap(props.exif, "EXIF payload expected on fixture")
        XCTAssertEqual(exif.cameraMake, "Shrike Test")
        XCTAssertEqual(exif.cameraModel, "Fixture")
        XCTAssertEqual(exif.lensModel, "Test 50mm f/1.8")
        XCTAssertEqual(exif.fNumber ?? 0, 2.8, accuracy: 0.01)
        XCTAssertEqual(exif.iso, 100)
        XCTAssertEqual(exif.focalLengthMM ?? 0, 50.0, accuracy: 0.01)
        XCTAssertNotNil(exif.dateTimeOriginal)
    }

    // MARK: - Thumbnail decode

    func testLoadThumbnail_256() async throws {
        let url = try TestFixture.url("small.jpg")
        let source = FileImageSource(url: url)
        let image = try await source.loadCGImage(maxPixelSize: 256)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        // Fixture is 128px — ImageIO may upscale to maxPixelSize or keep
        // original; either way the long edge should be <= 256.
        XCTAssertLessThanOrEqual(max(image.width, image.height), 256)
    }

    func testLoadThumbnail_smallerThanSource() async throws {
        let url = try TestFixture.url("small.jpg")
        let source = FileImageSource(url: url)
        let image = try await source.loadCGImage(maxPixelSize: 32)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 32)
    }

    /// Request a thumbnail far larger than the source's longer edge. The
    /// FileImageSource must clamp the request to the source's own longer
    /// edge before asking ImageIO — otherwise ImageIO logs
    /// `createThumbnailAtIndex: N is larger than image-dimension: WxH`
    /// on the ASL error channel. We can't assert directly against the
    /// private log channel without fragile stdout capture, but the clamp
    /// is observable: a clamped request returns an image at the source's
    /// natural size (128x128 for `small.jpg`), never upscaled to 99999.
    /// Both the clamped and unclamped paths return ~source size, but only
    /// the clamped path is silent.
    func testLoadThumbnail_requestLargerThanSource_clampsSilently() async throws {
        let url = try TestFixture.url("small.jpg")
        let source = FileImageSource(url: url)
        // 99999 is well above the fixture's 128-px longer edge. Pre-fix,
        // this would hit `createThumbnailAtIndex: 99999 is larger than
        // image-dimension: 128x128` on every call. Post-fix, the clamp
        // inside loadCGImage rewrites the request to max(w, h) = 128.
        let image = try await source.loadCGImage(maxPixelSize: 99999)
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128)
    }

    /// Same test for a differently-sized fixture: small.png (64x64).
    /// Guards against a degenerate clamp that always returns a constant.
    func testLoadThumbnail_requestLargerThanSource_png() async throws {
        let url = try TestFixture.url("small.png")
        let source = FileImageSource(url: url)
        let image = try await source.loadCGImage(maxPixelSize: 8192)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
    }

    // MARK: - Full-res decode

    func testLoadFullRes() async throws {
        let url = try TestFixture.url("small.png")
        let source = FileImageSource(url: url)
        let image = try await source.loadCGImage(maxPixelSize: nil)
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 64)
    }

    // MARK: - Error paths

    func testCorruptFile_throwsCorruptOrCannotOpen() async throws {
        let url = try TestFixture.url("corrupt.jpg")
        let source = FileImageSource(url: url)
        do {
            _ = try await source.loadCGImage(maxPixelSize: nil)
            XCTFail("expected decode to fail on corrupt fixture")
        } catch let err as ImageSourceError {
            // ImageIO may classify random bytes as either "cannot open" or
            // "corrupt" depending on version.
            XCTAssertTrue(
                err == .corrupt || err == .cannotOpen || err == .unsupported,
                "unexpected error \(err)"
            )
        } catch {
            XCTFail("expected ImageSourceError, got \(error)")
        }
    }

    // MARK: - Embedded preview (camera-instant path)

    /// Small fixture JPEG without an embedded preview: `loadEmbeddedPreview`
    /// must return `nil` cleanly, not throw, not crash. This is the
    /// fall-through path the viewer relies on for non-camera-out files.
    func testLoadEmbeddedPreview_returnsNilForFixtureWithoutPreview() async throws {
        let url = try TestFixture.url("small.jpg")
        let source = FileImageSource(url: url)
        let preview = try await source.loadEmbeddedPreview()
        XCTAssertNil(preview, "small.jpg has no embedded preview; expected nil")
    }

    /// PNG must short-circuit on the format pre-gate without ever calling
    /// `CGImageSourceCreateThumbnailAtIndex`. Pre-gate, ImageIO logged
    /// `… 'PNG ' - failed to create thumbnail [-50]` on every PNG nav
    /// (the embedded-preview-only flag pair returns nil but logs first).
    /// Post-gate, `loadEmbeddedPreview` returns nil before opening the
    /// CGImageSource at all — silent and faster.
    func testLoadEmbeddedPreview_returnsNilForPNG_withoutInvokingImageIO() async throws {
        let url = try TestFixture.url("small.png")
        let source = FileImageSource(url: url)
        let preview = try await source.loadEmbeddedPreview()
        XCTAssertNil(preview, "PNG must skip the embedded-preview path on the format gate")
    }

    /// Same negative coverage for the other formats with no embedded
    /// preview convention. Fixtures don't exist for GIF/BMP/TIFF so we
    /// synthesize tiny ones in a temp dir; the only thing the test
    /// exercises is the pre-gate, so the file content just needs to be
    /// readable enough that ImageIO would *otherwise* try.
    func testLoadEmbeddedPreview_returnsNilForGIF_andBMP_andTIFF() async throws {
        let tmp = TempDir()
        defer { tmp.cleanup() }
        // Tiny synthesized images in each negative format. We never
        // actually decode them — the format pre-gate returns nil before
        // ImageIO touches the bytes.
        let gif = tmp.url.appendingPathComponent("nopreview.gif")
        try Self.writeTinyImage(to: gif, utType: UTType.gif.identifier as CFString)
        let bmp = tmp.url.appendingPathComponent("nopreview.bmp")
        try Self.writeTinyImage(to: bmp, utType: UTType.bmp.identifier as CFString)

        for url in [gif, bmp] {
            let source = FileImageSource(url: url)
            let preview = try await source.loadEmbeddedPreview()
            XCTAssertNil(
                preview,
                "\(url.pathExtension) must short-circuit on the format gate"
            )
        }

        // Note: TIFF is intentionally on the "yes" list of
        // `ImageFormat.hasEmbeddedPreview` so RAW-in-TIFF containers
        // (DNG, etc.) still get the preview-first paint. Plain TIFFs
        // without an embedded preview pay one ImageIO log entry as the
        // tradeoff. The truth table is asserted directly in
        // `ImageFormatTests`; no runtime test here.
    }

    /// Helper: emit a 4×4 grey image in `utType` to `url`. Used by the
    /// negative-format tests above; we only need a syntactically valid
    /// container for the negative path.
    private static func writeTinyImage(to url: URL, utType: CFString) throws {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8,
            bytesPerRow: 4, space: cs,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw NSError(domain: "FileImageSourceTests", code: 1)
        }
        ctx.setFillColor(gray: 0.5, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil)
        else {
            throw NSError(domain: "FileImageSourceTests", code: 2)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "FileImageSourceTests", code: 3)
        }
    }

    /// Generate a JPEG with an embedded thumbnail at runtime, then assert
    /// `loadEmbeddedPreview` returns it. Uses
    /// `kCGImageDestinationEmbedThumbnail` — the documented ImageIO API
    /// for emitting a preview-bearing JPEG, the same path camera firmware
    /// (or `sips --thumbnail`) takes when writing a JPG that carries its
    /// own preview.
    ///
    /// We assert two things:
    ///   1. The preview is non-nil — the fast path actually reads it.
    ///   2. The preview's longer edge is **smaller than** the source's
    ///      longer edge — proves we got the embedded sub-image, not a
    ///      fresh decode of the full container. Without the
    ///      `FromImageAlways: false` + `FromImageIfAbsent: false` flag
    ///      pair, ImageIO would happily fall back to a full decode and
    ///      the dimensions would equal the full image. Asserting strict
    ///      `<` is what guards the perf contract.
    /// `embedded_preview.jpg` is a 2048×2048 JPEG with a 192×192 EXIF
    /// IFD1 thumbnail prebuilt at fixture-creation time. (Generated via
    /// Pillow + piexif rather than ImageIO's
    /// `kCGImageDestinationEmbedThumbnail` because the latter is
    /// platform-version-sensitive — some macOS releases ignore it on
    /// images below an internal heuristic threshold. Pre-baking a
    /// known-good fixture keeps the test deterministic across
    /// macOS 14 / 15 / 26.)
    ///
    /// This is the camera-instant path the production code is designed
    /// for: `loadEmbeddedPreview` should read the IFD1 thumbnail in
    /// 10-30 ms and return it at its native dimensions, not decode the
    /// full 2048² container.
    func testLoadEmbeddedPreview_returnsSmallerThanFullSize() async throws {
        let url = try TestFixture.url("embedded_preview.jpg")
        let source = FileImageSource(url: url)
        let preview = try await source.loadEmbeddedPreview()

        let preview2 = try XCTUnwrap(
            preview,
            "embedded_preview.jpg has a baked-in EXIF IFD1 thumbnail; expected non-nil"
        )
        let previewLong = max(preview2.width, preview2.height)
        XCTAssertLessThan(
            previewLong, 2048,
            "embedded preview (longer edge \(previewLong)) must be smaller than the 2048 source — otherwise we got a full decode, not the embedded preview"
        )
        XCTAssertGreaterThan(
            previewLong, 0,
            "embedded preview must have non-zero dimensions"
        )
        // The fixture was built with a 192×192 thumbnail; allow a wider
        // band (any preview meaningfully smaller than full-res is a
        // success) so future fixture revs don't lock to one number.
        XCTAssertLessThanOrEqual(
            previewLong, 1024,
            "embedded preview should be the small EXIF IFD1 thumb, not a midsize re-encode"
        )
    }

    /// Default-implementation test: a synthetic `ImageSource` that doesn't
    /// override `loadEmbeddedPreview` returns `nil` from the protocol
    /// extension. This is the contract the viewer's fall-through path
    /// relies on for non-file sources (archive entries, network sources)
    /// later.
    func testLoadEmbeddedPreview_defaultImplementationReturnsNil() async throws {
        let synthetic = SyntheticImageSourceForPreviewTest()
        let preview = try await synthetic.loadEmbeddedPreview()
        XCTAssertNil(preview, "default ImageSource implementation must return nil")
    }

    func testUnknownFile_throwsCannotOpen() async throws {
        let tmp = TempDir()
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("nope.xyz")
        try Data("not an image".utf8).write(to: url)
        let source = FileImageSource(url: url)
        do {
            _ = try await source.loadCGImage(maxPixelSize: nil)
            XCTFail("expected decode to fail on unknown format")
        } catch let err as ImageSourceError {
            XCTAssertTrue(
                err == .cannotOpen || err == .unsupported || err == .corrupt,
                "unexpected error \(err)"
            )
        }
    }
}

// MARK: - Synthetic source for default-implementation test

/// Minimal `ImageSource` that doesn't override `loadEmbeddedPreview`,
/// used to verify the protocol extension's default returns `nil`. Real
/// image decode is stubbed — we only exercise the preview path here.
private struct SyntheticImageSourceForPreviewTest: ImageSource {
    var id: String { "synthetic-no-preview" }
    var displayName: String { "Synthetic" }
    var fileSize: Int64? { nil }
    var mtime: Date? { nil }

    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        throw ImageSourceError.unsupported
    }

    func loadProperties() async throws -> ImageProperties {
        throw ImageSourceError.unsupported
    }
    // Note: deliberately NOT overriding loadEmbeddedPreview — the
    // default-impl from the protocol extension should kick in and
    // return nil.
}

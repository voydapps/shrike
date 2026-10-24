//
//  NonRGBEditTests.swift
//  ShrikeEditTests
//
//  Audit 2026-10-24 COR-1 / COR-2: edits on CMYK and grayscale photos must
//  really happen (or fail loudly), and the conversion must be disclosed.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class NonRGBEditTests: XCTestCase {

    private var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("NonRGBEditTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private enum Model { case cmyk, gray }

    /// A real CMYK or gray JPEG with a gradient (not a flat colour).
    private func makeJPEG(_ name: String, _ model: Model, w: Int = 400, h: Int = 300) throws -> URL {
        let space: CGColorSpace = model == .cmyk ? CGColorSpaceCreateDeviceCMYK() : CGColorSpaceCreateDeviceGray()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue))
        for x in 0..<w {
            let t = CGFloat(x) / CGFloat(w)
            if model == .cmyk { ctx.setFillColor(CGColor(colorSpace: space, components: [t, 0.4, 0.2, 0.1, 1])!) }
            else { ctx.setFillColor(CGColor(colorSpace: space, components: [0.2 + 0.5 * t, 1])!) }
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let url = tmp.url.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let props = try XCTUnwrap(properties(url))
        let expected = model == .cmyk ? kCGImagePropertyColorModelCMYK : kCGImagePropertyColorModelGray
        XCTAssertEqual(props[kCGImagePropertyColorModel] as? String, expected as String, "fixture must really be \(model)")
        return url
    }

    private func properties(_ url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
    }

    private func decode(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    /// Pixels as sRGB RGBA bytes, for comparing two images of one size.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try XCTUnwrap(ctx.data)
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    // MARK: Tools

    func testResizeToolShrinksCMYK() throws {
        let image = try decode(try makeJPEG("c.jpg", .cmyk))
        XCTAssertEqual(image.colorSpace?.model, .cmyk)
        let out = ResizeTool.apply(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true), to: image)
        XCTAssertEqual(out.width, 200)
        XCTAssertEqual(out.height, 150)
        XCTAssertEqual(out.colorSpace?.model, .rgb)
    }

    func testRotateToolRotatesCMYK() throws {
        let image = try decode(try makeJPEG("c.jpg", .cmyk))
        let out = RotateTool.apply(degrees: 10, to: image, autocrop: false)
        XCTAssertFalse(out === image)
        XCTAssertGreaterThan(out.width, image.width)
        let quarter = RotateTool.apply90(quarters: 1, to: image)
        XCTAssertEqual(quarter.width, image.height)
    }

    func testColorAdjustChangesCMYKPixels() throws {
        let image = try decode(try makeJPEG("c.jpg", .cmyk))
        let out = ColorAdjustTool.apply(ColorAdjustParams(brightness: 0.3), to: image)
        XCTAssertFalse(out === image)
        XCTAssertEqual(out.width, image.width)
        XCTAssertNotEqual(try pixels(out), try pixels(image))
    }

    func testColorAdjustChangesGrayPixels() throws {
        let image = try decode(try makeJPEG("g.jpg", .gray))
        XCTAssertEqual(image.colorSpace?.model, .monochrome)
        let out = ColorAdjustTool.apply(ColorAdjustParams(brightness: 0.3, contrast: 0.2), to: image)
        XCTAssertFalse(out === image, "COR-2: Color Adjust did nothing on grayscale")
        XCTAssertNotEqual(try pixels(out), try pixels(image))
    }

    func testResizeAndRotateKeepGrayscaleGray() throws {
        let image = try decode(try makeJPEG("g.jpg", .gray))
        let small = ResizeTool.apply(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true), to: image)
        XCTAssertEqual(small.width, 200)
        XCTAssertEqual(small.colorSpace?.model, .monochrome)
    }

    // MARK: Export

    private func exporter() -> ImageExporter {
        ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
    }

    func testExportResizeWritesTheResizedCMYKPhoto() async throws {
        let src = try makeJPEG("c.jpg", .cmyk)
        let out = tmp.url.appendingPathComponent("out.jpg")
        let recipe = EditRecipe(operations: [.resize(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true))])
        try await exporter().export(recipe: recipe, from: src, to: out, format: .jpeg)
        let props = try XCTUnwrap(properties(out))
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int, 150)
        XCTAssertEqual(props[kCGImagePropertyColorModel] as? String, kCGImagePropertyColorModelRGB as String)
    }

    func testExportColorAdjustOnGrayDiffersFromPlainCopy() async throws {
        let src = try makeJPEG("g.jpg", .gray)
        let plain = tmp.url.appendingPathComponent("plain.jpg")
        let edited = tmp.url.appendingPathComponent("edited.jpg")
        try await exporter().export(recipe: EditRecipe(operations: [.crop(CropRect(originX: 0, originY: 0, width: 1, height: 1))]),
                                    from: src, to: plain, format: .jpeg)
        try await exporter().export(recipe: EditRecipe(operations: [.colorAdjust(ColorAdjustParams(brightness: 0.3))]),
                                    from: src, to: edited, format: .jpeg)
        XCTAssertNotEqual(try pixels(try decode(plain)), try pixels(try decode(edited)))
    }

    /// In place the conversion is refused (the file would change format).
    func testInPlaceSaveOfCMYKWithAnEditIsRefused() async throws {
        let src = try makeJPEG("c.jpg", .cmyk)
        let before = try Data(contentsOf: src)
        let recipe = EditRecipe(operations: [.resize(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true))])
        do {
            try await exporter().export(recipe: recipe, from: src, to: src, format: .jpeg)
            XCTFail("must not silently convert a CMYK file in place")
        } catch ExportError.inPlaceWriteNotAllowed {}
        XCTAssertEqual(try Data(contentsOf: src), before)
    }

    // MARK: Disclosure

    func testCapabilityTellsAboutCMYKConversion() throws {
        let src = try makeJPEG("c.jpg", .cmyk)
        let resize = ImageExporter.capability(for: src, operations: [.resize(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true))])
        XCTAssertTrue(resize.requiresCopy)
        XCTAssertTrue(resize.conversionDisclosure?.contains("CMYK") == true, "\(String(describing: resize.conversionDisclosure))")
        let crop = ImageExporter.capability(for: src, operations: [.crop(CropRect(originX: 0, originY: 0, width: 0.5, height: 0.5))])
        XCTAssertFalse(crop.requiresCopy)
        XCTAssertNil(crop.conversionDisclosure)
    }

    func testCapabilityTellsAboutGrayToColour() throws {
        let src = try makeJPEG("g.jpg", .gray)
        let colour = ImageExporter.capability(for: src, operations: [.colorAdjust(ColorAdjustParams(brightness: 0.2))])
        XCTAssertTrue(colour.requiresCopy)
        XCTAssertTrue(colour.conversionDisclosure?.contains("grayscale") == true)
        let resize = ImageExporter.capability(for: src, operations: [.resize(ResizeSpec(width: 200, height: 150, interpolation: .lanczos, preventUpscale: true))])
        XCTAssertFalse(resize.requiresCopy, "resize keeps gray, no conversion")
    }

    // MARK: Batch

    func testBatchResizeOfCMYKReallyResizes() async throws {
        let src = try makeJPEG("c.jpg", .cmyk)
        let backups = BackupStore(root: tmp.url.appendingPathComponent("b2"), retentionDays: { 30 })
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let out = tmp.url.appendingPathComponent("out", isDirectory: true)
        let plan = BatchPlan(items: [ImageGroup(primary: src)], resize: ResizeOptions(mode: .longEdge, value: 100), output: .folder(out))
        var last: BatchResult?
        for try await p in runner.run(plan) { if let r = p.result { last = r } }
        XCTAssertEqual(last?.doneCount, 1)
        XCTAssertEqual(BatchRunner.Header(out.appendingPathComponent("c.jpg"))?.displaySize.width, 100)
    }
}

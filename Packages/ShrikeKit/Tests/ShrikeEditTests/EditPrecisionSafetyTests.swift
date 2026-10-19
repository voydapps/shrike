import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShrikeIO
@testable import ShrikeEdit

final class EditPrecisionSafetyTests: XCTestCase {
    private func gradient(_ url: URL) throws {
        let values = (0..<(1024 * 4)).map { UInt16(($0 % 1024) * 64).littleEndian }
        let data = values.withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: 1024, height: 4, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: 2048,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .byteOrder16Little, provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func testHighPrecisionNonIdentityToolsRequireCopyAndCannotOverwrite() async throws {
        let tmp = EditTempDir("PrecisionSafety"); defer { tmp.cleanup() }
        let source = tmp.url.appendingPathComponent("gradient.tiff"); try gradient(source)
        let before = try Data(contentsOf: source)
        let operations: [EditOperation] = [.rotate90(quarters: 1), .rotate(degrees: 4),
            .resize(.init(width: 512, height: 2, interpolation: .lanczos, preventUpscale: false)),
            .colorAdjust(.init(brightness: 0.1)), .levels(.init(master: .init(gamma: 1.2))),
            .rotateAutoCrop(degrees: 4)]
        for (i, op) in operations.enumerated() {
            let capability = ImageExporter.capability(for: source, operations: [op])
            XCTAssertTrue(capability.requiresCopy); XCTAssertFalse(capability.isHDR)
            XCTAssertEqual(capability.sourceBitsPerComponent, 16); XCTAssertNotNil(capability.conversionDisclosure)
            let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
            do { _ = try await exporter.export(recipe: EditRecipe(operations: [op]), from: source, to: source, format: .tiff); XCTFail("unsafe overwrite") }
            catch ExportError.inPlaceWriteNotAllowed {}
            let copy = tmp.url.appendingPathComponent("copy-\(i).tiff")
            _ = try await exporter.export(recipe: EditRecipe(operations: [op]), from: source, to: copy, format: .tiff)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(try Data(contentsOf: source), before)
        }
        let unknown = ImageExporter.capability(for: tmp.url.appendingPathComponent("missing.tiff"), operations: [])
        XCTAssertTrue(unknown.requiresCopy); XCTAssertNotNil(unknown.conversionDisclosure)
        let multi: [EditOperation] = [.crop(.init(originX: 0, originY: 0, width: 0.5, height: 1)), operations[3], operations[4]]
        XCTAssertTrue(ImageExporter.capability(for: source, operations: multi).requiresCopy)
        let copy = tmp.url.appendingPathComponent("multi.tiff")
        _ = try await ImageExporter(backupStore: nil).export(recipe: EditRecipe(operations: multi),
                                                             from: source, to: copy, format: .tiff)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
    func testIdentityAndCropKeepSupportedSixteenBitPrecision() async throws {
        let tmp = EditTempDir("PrecisionCrop"); defer { tmp.cleanup() }
        let source = tmp.url.appendingPathComponent("gradient.tiff"); try gradient(source)
        let crop = EditOperation.crop(.init(originX: 0, originY: 0, width: 0.5, height: 1))
        XCTAssertFalse(ImageExporter.capability(for: source, operations: [.colorAdjust(.identity), .rotateAutoCrop(degrees: 360), crop]).requiresCopy)
        _ = try await ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))
            .export(recipe: EditRecipe(operations: [crop]), from: source, to: source, format: .tiff)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16); XCTAssertEqual(image.width, 512)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let step = image.bitsPerPixel / 8
        let values = data.withUnsafeBytes { bytes in (0..<image.width).map { bytes.loadUnaligned(fromByteOffset: $0 * step, as: UInt16.self) } }
        XCTAssertGreaterThan(Set(values).count, 256, "crop must retain more than eight bits of tonal detail")
    }
    func testHDRProfileRequiresCopyEvenWithoutEightBitAdjustment() async throws {
        let tmp = EditTempDir("PrecisionHDR"); defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("hdr.tiff")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.itur_2100_PQ))
        let values: [UInt16] = Array(Array(repeating: [UInt16(1000), 2000, 3000, 65535], count: 16 * 8).joined())
        let data = values.withUnsafeBytes { Data($0) }
        let image = try XCTUnwrap(CGImage(width: 16, height: 8, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: 16 * 8,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: try XCTUnwrap(CGDataProvider(data: data as CFData)), decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let capability = ImageExporter.capability(for: url, operations: [])
        XCTAssertTrue(capability.isHDR); XCTAssertTrue(capability.requiresCopy)
        do { _ = try await ImageExporter(backupStore: nil).export(recipe: EditRecipe(), from: url, to: url, format: .tiff); XCTFail("HDR original must be protected") }
        catch ExportError.inPlaceWriteNotAllowed {}
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}

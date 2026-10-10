//
//  SaveTargetDecisionTests.swift
//  ShrikeEditTests
//
//  What ⌘S does, and the message the Save panel shows.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit

final class SaveTargetDecisionTests: XCTestCase {

    var tmp: EditTempDir!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("SaveTargetDecisionTests")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func path(_ name: String) -> URL { tmp.url.appendingPathComponent(name) }

    private func image(alpha: Bool) -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                              : CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: alpha ? 0.5 : 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    @discardableResult
    private func write(_ name: String, type: UTType, frames: Int = 1, alpha: Bool = false) throws -> URL {
        let url = path(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString,
                                                                 frames, nil))
        for _ in 0..<frames { CGImageDestinationAddImage(dest, image(alpha: alpha), nil) }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testWritableSingleFrameSavesInPlace() throws {
        let jpg = try write("DSC_0042.jpg", type: .jpeg)
        let decision = SaveTarget.evaluate(jpg)
        XCTAssertEqual(decision, .inPlace(.jpeg))
        XCTAssertNil(decision.reason)
        XCTAssertEqual(decision.format, .jpeg)
        XCTAssertEqual(SaveTarget.saveAsURL(for: jpg, decision: decision).lastPathComponent,
                       "DSC_0042-edited.jpg")
        XCTAssertEqual(SaveTarget.evaluate(try write("a.png", type: .png, alpha: true)), .inPlace(.png))
    }

    func testRAWNeedsSaveAsWithM1() {
        let raw = URL(fileURLWithPath: "/nonexistent-shrike/P1.ORF")
        let decision = SaveTarget.evaluate(raw)
        XCTAssertEqual(decision, .saveAsRequired(.raw, suggested: .jpeg))
        XCTAssertEqual(decision.reason?.message(for: raw),
                       "RAW files are never changed. Save an edited copy instead.")
        XCTAssertEqual(SaveTarget.saveAsURL(for: raw, decision: decision).lastPathComponent, "P1-edited.jpg")
    }

    func testMultiPageTIFFCountsPages() throws {
        let tif = try write("scan.tif", type: .tiff, frames: 4)
        let decision = SaveTarget.evaluate(tif)
        XCTAssertEqual(decision, .saveAsRequired(.multiFrame(count: 4), suggested: .jpeg))
        XCTAssertEqual(decision.reason?.message(for: tif),
                       "“scan.tif” has 4 pages. Saving in place would keep only the first one. "
                       + "Save an edited copy instead.")
    }

    func testAnimatedGIFCountsFrames() throws {
        let gif = try write("anim.gif", type: .gif, frames: 3, alpha: true)
        let decision = SaveTarget.evaluate(gif)
        XCTAssertEqual(decision.reason, .multiFrame(count: 3))
        XCTAssertEqual(decision.reason?.message(for: gif),
                       "“anim.gif” has 3 frames. Saving in place would keep only the first one. "
                       + "Save an edited copy instead.")
    }

    func testStillGIFIsNotWritableAndSuggestsPNGForAlpha() throws {
        let gif = try write("party.gif", type: .gif, alpha: true)
        let decision = SaveTarget.evaluate(gif)
        guard case .saveAsRequired(.notWritable(let typeName), let suggested) = decision else {
            return XCTFail("got \(decision)")
        }
        XCTAssertTrue(typeName.localizedCaseInsensitiveContains("GIF"), typeName)
        XCTAssertEqual(suggested, .png, "GIF has alpha")
        XCTAssertEqual(SaveTarget.saveAsURL(for: gif, decision: decision).lastPathComponent, "party-edited.png")
        XCTAssertEqual(decision.reason?.message(for: gif),
                       "“party.gif” can't be saved in place without losing data. Save an edited copy instead.")
    }

    func testOpaqueNonWritableSuggestsJPEG() throws {
        let bmp = try write("old.bmp", type: .bmp, alpha: false)
        let decision = SaveTarget.evaluate(bmp)
        guard case .saveAsRequired(.notWritable, let suggested) = decision else {
            return XCTFail("got \(decision)")
        }
        XCTAssertEqual(suggested, .jpeg)
    }

    func testBytesNotMatchingExtension() throws {
        let fake = try write("really-a-png.jpg", type: .png, alpha: true)
        let decision = SaveTarget.evaluate(fake)
        XCTAssertEqual(decision, .saveAsRequired(.extensionMismatch, suggested: .png))
        XCTAssertEqual(decision.reason?.message(for: fake),
                       "“really-a-png.jpg” can't be saved in place without losing data. Save an edited copy instead.")
    }

    func testUnknownExtensionUsesExtensionAsTypeName() {
        let url = URL(fileURLWithPath: "/nonexistent-shrike/x.xyz")
        XCTAssertEqual(SaveTarget.evaluate(url), .saveAsRequired(.notWritable(typeName: "XYZ"), suggested: .jpeg))
    }

    func testWebPFollowsEncoderSupport() {
        let url = URL(fileURLWithPath: "/nonexistent-shrike/x.webp")
        let decision = SaveTarget.evaluate(url)
        if ExportFormat.webp.isEncodable {
            XCTAssertEqual(decision, .inPlace(.webp))
        } else {
            XCTAssertNotNil(decision.reason.flatMap { if case .notWritable = $0 { $0 } else { nil } })
        }
    }

    /// The in-place answer is always exactly `inPlaceFormat(for:)`.
    func testAgreesWithInPlaceFormat() throws {
        var urls = ["a.jpg", "a.png", "a.tif", "a.heic", "a.gif", "a.bmp", "a.psd", "a.pdf", "a.cr3",
                    "a.dng", "a.x3f", "a", "a.webp", "a.avif"]
            .map { URL(fileURLWithPath: "/nonexistent-shrike/\($0)") }
        urls.append(try write("one.jpg", type: .jpeg))
        urls.append(try write("two.tiff", type: .tiff, frames: 2))
        urls.append(try write("mis.png", type: .jpeg))
        for url in urls {
            XCTAssertEqual(SaveTarget.evaluate(url).inPlaceFormat, ExportFormat.inPlaceFormat(for: url),
                           url.lastPathComponent)
        }
    }
}

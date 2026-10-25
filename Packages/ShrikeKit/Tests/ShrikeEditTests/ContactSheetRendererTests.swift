//
//  ContactSheetRendererTests.swift
//  ShrikeEditTests
//
//  Small generated images keep these fast.
//

import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeEdit

final class ContactSheetRendererTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = TestScratch.directory
            .appendingPathComponent("contact-sheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// `count` tiny JPEGs (alternating landscape / portrait).
    private func makeImages(_ count: Int) throws -> [ImageGroup] {
        let images = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var masters: [URL] = []
        for (i, size) in [(64, 48), (48, 64)].enumerated() {
            let ctx = CGContext(data: nil, width: size.0, height: size.1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: CGFloat(i), alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            let url = folder.appendingPathComponent("master\(i).jpg")
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            masters.append(url)
        }
        return try (0..<count).map { i in
            let url = images.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            try FileManager.default.copyItem(at: masters[i % 2], to: url)
            return ImageGroup(primary: url)
        }
    }

    private func cache() throws -> ThumbnailCache {
        try ThumbnailCache(diskURL: folder.appendingPathComponent("thumbs", isDirectory: true))
    }

    private func render(_ groups: [ImageGroup], _ options: ContactSheetOptions, to url: URL) async throws -> [Double] {
        var progress: [Double] = []
        for try await p in ContactSheetRenderer.render(groups, options: options, thumbnails: try cache(), to: url) {
            progress.append(p)
        }
        return progress
    }

    private func pageCount(_ url: URL) throws -> Int {
        let doc = try XCTUnwrap(CGPDFDocument(url as CFURL))
        return doc.numberOfPages
    }

    // MARK: Layout arithmetic

    func testLayout_A4() {
        let five = ContactSheetLayout(options: ContactSheetOptions(title: "t", columns: 5, paper: .a4))
        XCTAssertEqual(five.cell, 98.256, accuracy: 0.01)
        XCTAssertEqual(five.rowPitch, five.cell + 14, accuracy: 0.001)
        XCTAssertEqual(five.rowsPerPage, 6)
        XCTAssertEqual(five.perPage, 30)
        XCTAssertGreaterThanOrEqual(Double(five.thumbnailPixelSize), five.cell * 2)

        let eight = ContactSheetLayout(options: ContactSheetOptions(title: "t", columns: 8, paper: .a4))
        XCTAssertEqual(eight.cell, 58.41, accuracy: 0.01)
        XCTAssertEqual(eight.rowsPerPage, 10)

        let noCaption = ContactSheetLayout(options: ContactSheetOptions(title: "t", columns: 5, paper: .a4,
                                                                        caption: .none))
        XCTAssertEqual(noCaption.rowPitch, noCaption.cell + 8, accuracy: 0.001)

        // Cells stay inside the margins and below the title band.
        let last = five.cellRect(at: five.perPage - 1)
        XCTAssertEqual(last.maxX, 595.28 - 36, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(last.minY - 14, 36 - 0.01)
        XCTAssertEqual(five.cellRect(at: 0).maxY, 841.89 - 36 - five.titleBand, accuracy: 0.01)
    }

    /// US Letter at 5 columns drops from
    /// 6 to 5 rows with the + 14 pt pitch.
    func testLayout_USLetter() {
        let five = ContactSheetLayout(options: ContactSheetOptions(title: "t", columns: 5, paper: .usLetter))
        XCTAssertEqual(five.cell, 101.6, accuracy: 0.01)
        XCTAssertEqual(five.rowPitch, five.cell + 14, accuracy: 0.001)
        XCTAssertEqual(five.rowsPerPage, 5)
        XCTAssertEqual(five.perPage, 25)
        let last = five.cellRect(at: five.perPage - 1)
        XCTAssertGreaterThanOrEqual(last.minY - 14, 36 - 0.01)
    }

    /// The caption's top sits 1 pt below its cell, and its bottom stays at
    /// least 3 pt above the next row's cell (before, a
    /// portrait photo started about 1 pt under the caption above).
    func testCaptionClearsTheNextRow() {
        let font = ContactSheetFonts.caption
        let lineHeight = ContactSheetLayout.lineHeight(font)
        for paper in ContactSheetPaper.allCases {
            for columns in ContactSheetOptions.columnRange {
                let layout = ContactSheetLayout(options: ContactSheetOptions(title: "t", columns: columns,
                                                                             paper: paper))
                guard layout.rowsPerPage > 1 else { continue }
                let cell = layout.cellRect(at: 0)
                let baseline = ContactSheetLayout.captionBaseline(below: cell, font: font)
                let captionTop = baseline + CTFontGetAscent(font)
                XCTAssertEqual(cell.minY - captionTop, 1, accuracy: 0.001, "\(paper) \(columns)")
                let captionBottom = captionTop - lineHeight
                let nextTop = layout.cellRect(at: columns).maxY
                XCTAssertGreaterThanOrEqual(captionBottom - nextTop, 3, "\(paper) \(columns)")
            }
        }
    }

    func testColumnsAreClamped() {
        XCTAssertEqual(ContactSheetOptions(title: "", columns: 1).columns, 3)
        XCTAssertEqual(ContactSheetOptions(title: "", columns: 20).columns, 8)
        var o = ContactSheetOptions(title: "", columns: 6)
        o.columns = 0
        XCTAssertEqual(o.columns, 3)
    }

    func testDefaultPaperFromLocale() {
        XCTAssertEqual(ContactSheetOptions.defaultPaper(for: Locale(identifier: "en_US")), .usLetter)
        XCTAssertEqual(ContactSheetOptions.defaultPaper(for: Locale(identifier: "it_IT")), .a4)
        XCTAssertEqual(ContactSheetOptions.defaultPaper(for: Locale(identifier: "en_GB")), .a4)
        XCTAssertEqual(ContactSheetOptions.defaultPaper(for: Locale(identifier: "fr_CA")), .usLetter)
    }

    /// The sheet starts from the stored print settings and
    /// remembers what the user chose.
    func testOptionsFromAndBackToStoredSettings() {
        let stored = PrintSettings(contactSheetColumns: 7, contactSheetPaper: .usLetter,
                                   contactSheetCaption: .fileNameAndDate)
        let o = ContactSheetOptions(title: "Italy 2026", settings: stored)
        XCTAssertEqual(o.title, "Italy 2026")
        XCTAssertEqual(o.columns, 7)
        XCTAssertEqual(o.paper, .usLetter)
        XCTAssertEqual(o.caption, .fileNameAndDate)

        var changed = o
        changed.columns = 3
        changed.paper = .a4
        changed.caption = .none
        var settings = stored
        settings.remember(changed)
        XCTAssertEqual(settings.contactSheetColumns, 3)
        XCTAssertEqual(settings.contactSheetPaper, .a4)
        XCTAssertEqual(settings.contactSheetCaption, .none)
        XCTAssertEqual(settings.scaling, stored.scaling, "print settings untouched")
        for paper in ContactSheetPaper.allCases {
            XCTAssertEqual(ContactSheetPaper(PrintSettings.Paper(rawValue: paper.rawValue)!), paper)
        }
        for caption in ContactSheetCaption.allCases {
            XCTAssertEqual(ContactSheetCaption(PrintSettings.Caption(rawValue: caption.rawValue)!), caption)
        }
    }

    // MARK: Rendering

    func test180Images_5Columns_A4_captions_sixPages() async throws {
        let groups = try makeImages(180)
        let url = folder.appendingPathComponent("Italy 2026 contact sheet.pdf")
        let options = ContactSheetOptions(title: "Italy 2026", columns: 5, paper: .a4, caption: .fileName)
        let progress = try await render(groups, options, to: url)

        XCTAssertEqual(try pageCount(url), 6)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress, progress.sorted(), "progress only goes up")
        XCTAssertTrue(progress.allSatisfy { (0...1).contains($0) })

        let doc = try XCTUnwrap(PDFDocument(url: url))
        let box = try XCTUnwrap(doc.page(at: 0)?.bounds(for: .mediaBox))
        XCTAssertEqual(box.width, 595.28, accuracy: 0.1)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.1)
        // PDFKit breaks lines at "_"; compare without whitespace.
        func squashed(_ i: Int) -> String { (doc.page(at: i)?.string ?? "").filter { !$0.isWhitespace } }
        let text = squashed(0)
        XCTAssertTrue(text.contains("Italy2026"), text)
        XCTAssertTrue(text.contains("Page1of6"), text)
        XCTAssertTrue(text.contains("IMG_0000.jpg"), text)
        XCTAssertTrue(squashed(5).contains("IMG_0179.jpg"))

        // No temp file left next to the PDF.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func test180Images_8Columns_threePages() async throws {
        let groups = try makeImages(180)
        let url = folder.appendingPathComponent("eight.pdf")
        _ = try await render(groups, ContactSheetOptions(title: "Eight", columns: 8, paper: .a4), to: url)
        XCTAssertEqual(try pageCount(url), 3)
    }

    func testFileNameAndDateCaption() async throws {
        let groups = try makeImages(3)
        let url = folder.appendingPathComponent("dated.pdf")
        _ = try await render(groups, ContactSheetOptions(title: "", columns: 3, paper: .usLetter,
                                                         caption: .fileNameAndDate), to: url)
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(doc.pageCount, 1)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // PDFKit breaks lines at "_"; compare without whitespace.
        func squashed(_ i: Int) -> String { (doc.page(at: i)?.string ?? "").filter { !$0.isWhitespace } }
        let text = squashed(0)
        // No EXIF date in these files: the modification date (today) is used.
        XCTAssertTrue(text.contains(formatter.string(from: Date()).filter { !$0.isWhitespace }), text)
    }

    func testCancel_leavesNoFile() async throws {
        let groups = try makeImages(180)
        let url = folder.appendingPathComponent("cancelled.pdf")
        let thumbs = try cache()
        let options = ContactSheetOptions(title: "Cancel", columns: 3, paper: .a4)
        let consumer = Task {
            var seen = 0
            for try await _ in ContactSheetRenderer.render(groups, options: options, thumbnails: thumbs, to: url) {
                seen += 1
                if seen == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        _ = await consumer.result
        // The producer notices at its next step; give it a moment.
        for _ in 0..<50 where !leftoverTemps().isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(leftoverTemps(), [])
    }

    private func leftoverTemps() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".tmp") }
    }
}

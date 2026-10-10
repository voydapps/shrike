//
//  PrintTests.swift
//  ShrikeUITests
//
//  Printing. The print view is built offscreen
//  and its pages drawn into a PDF context; no print panel and no real
//  print job.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class PrintTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-print-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = makeTestDefaults()
        PrintController.presentsPanels = false
    }

    override func tearDown() async throws {
        PrintController.presentsPanels = true
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int, height: Int, dpi: Double? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let dpi { props[kCGImagePropertyDPIWidth] = dpi; props[kCGImagePropertyDPIHeight] = dpi }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func a4() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        return info
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func pageCount(_ view: PrintPagesView) -> Int {
        var range = NSRange(location: 0, length: 0)
        XCTAssertTrue(view.knowsPageRange(&range))
        XCTAssertEqual(range.location, 1)
        return range.length
    }

    // MARK: Geometry

    func testFitFillAndActualSize() {
        let area = CGRect(x: 0, y: 0, width: 500, height: 800)
        let size = CGSize(width: 3000, height: 2000)
        let fit = PrintLayout.imageRect(pixelSize: size, dpi: nil, scaling: .fit, in: area)
        XCTAssertEqual(fit.width, 500, accuracy: 0.01)
        XCTAssertEqual(fit.midY, 400, accuracy: 0.01, "centred")
        XCTAssertTrue(area.contains(fit.insetBy(dx: 0.01, dy: 0.01)))
        let fill = PrintLayout.imageRect(pixelSize: size, dpi: nil, scaling: .fill, in: area)
        XCTAssertEqual(fill.height, 800, accuracy: 0.01)
        XCTAssertTrue(fill.contains(area), "covers the page (the view clips it)")
        let actual = PrintLayout.imageRect(pixelSize: size, dpi: 150, scaling: .actual, in: area)
        XCTAssertEqual(actual.width, 3000.0 / 150 * 72, accuracy: 0.01)
        let fallback = PrintLayout.imageRect(pixelSize: size, dpi: nil, scaling: .actual, in: area)
        XCTAssertEqual(fallback.width, 3000.0 / 300 * 72, accuracy: 0.01, "300 ppi when the file has none")
        XCTAssertEqual(PrintLayout.orientation(for: CGSize(width: 4000, height: 3000)), .landscape)
        XCTAssertEqual(PrintLayout.orientation(for: CGSize(width: 3000, height: 3000)), .portrait)
        let named = PrintLayout.imageArea(content: area, showFileName: true)
        XCTAssertEqual(named.height, 800 - PrintLayout.nameLineHeight)
    }

    // MARK: Portrait, Fit, A4 → a portrait page with the whole image

    func testVector1PortraitImageFitA4GivesAPortraitPageWithTheWholeImage() async throws {
        let url = try writeJPEG("portrait.jpg", width: 900, height: 1200)
        let store = PrintSettingsStore(defaults: defaults)
        store.update { $0.scaling = .fit }
        let info = a4()
        info.orientation = .landscape
        let pages = [PrintPage.read(url)]
        let job = PrintController(pages: pages, printInfo: info, settingsStore: store)
        XCTAssertEqual(info.orientation, .portrait, "the page follows the photo")
        XCTAssertEqual(pageCount(job.view), 1)
        job.decodeAll()
        await job.waitForDecodes()
        XCTAssertNotNil(job.store.image(at: 0))
        let page = job.view.rectForPage(1)
        XCTAssertGreaterThan(page.height, page.width, "portrait page")
        let rect = try XCTUnwrap(job.view.imageRect(forPage: 0))
        XCTAssertTrue(page.insetBy(dx: -0.01, dy: -0.01).contains(rect), "the whole image is on the page")
        XCTAssertEqual(rect.width / rect.height, 900.0 / 1200.0, accuracy: 0.001)
        XCTAssertTrue(abs(rect.width - page.width) < 0.5 || abs(rect.height - page.height) < 0.5,
                      "Fit: as large as the margins allow")
        // The page draws (offscreen, into a PDF).
        let pdf = job.view.dataWithPDF(inside: page)
        XCTAssertGreaterThan(pdf.count, 1000)
    }

    func testLandscapePhotoGetsALandscapePageAndSettingsAreRemembered() throws {
        let url = try writeJPEG("wide.jpg", width: 1600, height: 900, dpi: 72)
        let store = PrintSettingsStore(defaults: defaults)
        store.update { $0.scaling = .actual; $0.showFileName = true }
        let info = a4()
        let job = PrintController(pages: [PrintPage.read(url)], printInfo: info, settingsStore: store)
        XCTAssertEqual(info.orientation, .landscape)
        XCTAssertEqual(job.view.scaling, .actual)
        XCTAssertTrue(job.view.showFileName)
        XCTAssertEqual(job.pages[0].dpi, 72)
        job.accessory.model.scaling = .fill
        job.accessory.model.showFileName = false
        XCTAssertEqual(store.load().scaling, .fill)
        XCTAssertFalse(store.load().showFileName)
        XCTAssertEqual(defaults.string(forKey: "shrike.print.scaling"), "fill")
        XCTAssertEqual(job.accessory.scalingValue, "fill", "the preview's KVO key follows")
        XCTAssertEqual(job.view.scaling, .fill)
        XCTAssertTrue(job.accessory.keyPathsForValuesAffectingPreview().contains("revision"))
    }

    // MARK: A Browser selection of 3 → 3 pages

    func testVector3BrowserSelectionOfThreePrintsThreePages() async throws {
        for (i, name) in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"].enumerated() {
            try writeJPEG(name, width: 800 + i * 10, height: 600)
        }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let listed = await waitUntil { browser.contentController.visibleItems.count == 4 }
        XCTAssertTrue(listed)
        browser.contentController.select(urls: ["a.jpg", "c.jpg", "d.jpg"].map { dir.appendingPathComponent($0) })
        XCTAssertTrue(browser.canPerform(.print))
        let before = PrintController.lastForTesting
        browser.perform(.print)
        let made = await waitUntil { PrintController.lastForTesting !== before && PrintController.lastForTesting != nil }
        XCTAssertTrue(made)
        let job = try XCTUnwrap(PrintController.lastForTesting)
        XCTAssertEqual(job.pages.map(\.name), ["a.jpg", "c.jpg", "d.jpg"])
        XCTAssertEqual(pageCount(job.view), 3)
        await job.waitForDecodes()
        for page in 1...3 {
            XCTAssertNotNil(job.view.imageRect(forPage: page - 1))
            XCTAssertGreaterThan(job.view.dataWithPDF(inside: job.view.rectForPage(page)).count, 1000)
        }
    }

    func testMenuEnablesPrintAndPageSetup() throws {
        let url = try writeJPEG("a.jpg", width: 100, height: 80)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        XCTAssertFalse(viewer.canPerform(.print), "nothing shown yet")
        viewer.markDisplayedForTesting(0)
        XCTAssertTrue(viewer.canPerform(.print))
        XCTAssertTrue(viewer.canPerform(.pageSetup))
        XCTAssertEqual(ViewerKeyMap.action(for: .print, context: .viewer), .print)
    }
}

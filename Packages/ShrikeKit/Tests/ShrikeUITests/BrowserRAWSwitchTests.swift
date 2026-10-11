//
//  BrowserRAWSwitchTests.swift
//  ShrikeUITests
//
//  ⌥R and the RAW chip in the Browser: the selected pair shows its RAW
//  (Filmstrip's big preview, the info panel in every view), per photo, view
//  only. (The test "RAW" is a bigger JPEG under an .ORF name: ImageIO reads
//  by content.)
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserRAWSwitchTests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        BrowserWindowController.restoresViewModeUnderTests = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-brawsw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        BrowserWindowController.restoresViewModeUnderTests = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ width: Int, _ height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return cond()
    }

    /// P1.JPG + P1.ORF (bigger), P2.JPG alone. `rawData` swaps the RAW bytes.
    private func open(_ mode: BrowserViewMode, rawData: Data? = nil) async throws -> BrowserWindowController {
        try jpeg(160, 120).write(to: dir.appendingPathComponent("P1.JPG"))
        try (rawData ?? jpeg(320, 240)).write(to: dir.appendingPathComponent("P1.ORF"))
        try jpeg(160, 120).write(to: dir.appendingPathComponent("P2.JPG"))
        Prefs.browserViewMode = mode.rawValue
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(listed)
        _ = await waitUntil { browser.contentController.selectedItems.first?.url.lastPathComponent == "P1.JPG" }
        browser.window?.setContentSize(NSSize(width: 1280, height: 800))
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    private func shownName(_ browser: BrowserWindowController) -> String? {
        browser.inspectorStateForTesting.commonName
    }

    func testOptionRIsInTheBrowserKeyMapAndTheMenuLineExistsOnlyForAPair() async throws {
        let browser = try await open(.grid)
        defer { browser.close() }
        XCTAssertEqual(ShortcutTable.bindings(for: .toggleRAWFile, context: .browser, preset: .macNative)
            .first?.displayString, "⌥R")
        XCTAssertEqual(BrowserKeyMap.action(for: .toggleRAWFile), .toggleRAWFile)
        XCTAssertTrue(browser.canPerform(.toggleRAWFile), "P1 is a pair")
        XCTAssertEqual(browser.rawSwitchMenuTitle, "Show RAW File")
        // A single photo and a two-photo selection: not enabled.
        XCTAssertTrue(browser.contentController.select(url: dir.appendingPathComponent("P2.JPG")))
        XCTAssertFalse(browser.canPerform(.toggleRAWFile))
        browser.contentController.selectAll()
        XCTAssertFalse(browser.canPerform(.toggleRAWFile))
    }

    func testFilmstripPreviewAndInfoPanelShowTheRAWThenTheJPEG() async throws {
        let browser = try await open(.filmstrip)
        defer { browser.close() }
        let content = browser.contentController
        let preview = content.filmstripPreviewForTesting
        _ = await waitUntil { preview.image != nil }
        XCTAssertEqual(preview.image?.size.width, 160, "the JPEG first")
        let namedJPG = await waitUntil { self.shownName(browser) == "P1.JPG" }
        XCTAssertTrue(namedJPG)

        browser.perform(.toggleRAWFile)
        let raw = await waitUntil { content.isShowingRAW && preview.image?.size.width == 320 }
        XCTAssertTrue(raw, "the large preview is the RAW")
        let namedORF = await waitUntil { self.shownName(browser) == "P1.ORF" }
        XCTAssertTrue(namedORF, "the info panel names the RAW")
        XCTAssertEqual(browser.inspectorStateForTesting.previewURL?.lastPathComponent, "P1.ORF")
        XCTAssertEqual(browser.rawSwitchMenuTitle, "Show JPEG File")
        XCTAssertEqual(content.selectedItems.map(\.url.lastPathComponent), ["P1.JPG"], "the selection is still the pair")

        browser.perform(.toggleRAWFile)
        let back = await waitUntil { !content.isShowingRAW && preview.image?.size.width == 160 }
        XCTAssertTrue(back)
        let namedBack = await waitUntil { self.shownName(browser) == "P1.JPG" }
        XCTAssertTrue(namedBack)
    }

    func testGridInfoPanelShowsTheRAWAndAnotherPhotoEndsIt() async throws {
        let browser = try await open(.grid)
        defer { browser.close() }
        let content = browser.contentController
        browser.perform(.toggleRAWFile)
        let ok972 = await waitUntil { content.isShowingRAW }
        XCTAssertTrue(ok972)
        let namedORF = await waitUntil { self.shownName(browser) == "P1.ORF" }
        XCTAssertTrue(namedORF)
        XCTAssertEqual(browser.inspectorStateForTesting.commonFileSize,
                       try FileManager.default.attributesOfItem(
                        atPath: dir.appendingPathComponent("P1.ORF").path)[.size] as? Int64)

        // Rating applies to the pair and the RAW view shows it.
        browser.perform(.rate3)
        let rated = await waitUntil { browser.inspectorStateForTesting.commonRating == 3 }
        XCTAssertTrue(rated, "the rating shows on the RAW view too")
        XCTAssertEqual(content.selectedItems.first?.rating, 3, "and sits on the pair")

        XCTAssertTrue(content.select(url: dir.appendingPathComponent("P2.JPG")))
        XCTAssertFalse(content.isShowingRAW, "another photo ends the RAW view")
        let second = await waitUntil { self.shownName(browser) == "P2.JPG" }
        XCTAssertTrue(second)
        XCTAssertTrue(content.select(url: dir.appendingPathComponent("P1.JPG")))
        XCTAssertFalse(content.isShowingRAW, "and coming back shows the JPEG")
        let first = await waitUntil { self.shownName(browser) == "P1.JPG" }
        XCTAssertTrue(first)
    }

    func testListInfoPanelShowsTheRAW() async throws {
        let browser = try await open(.list)
        defer { browser.close() }
        browser.perform(.toggleRAWFile)
        let ok285 = await waitUntil { browser.contentController.isShowingRAW }
        XCTAssertTrue(ok285)
        let namedORF = await waitUntil { self.shownName(browser) == "P1.ORF" }
        XCTAssertTrue(namedORF)
    }

    func testAnUnreadableRAWStaysOnTheJPEGWithAToast() async throws {
        let browser = try await open(.filmstrip, rawData: Data("not an image".utf8))
        defer { browser.close() }
        browser.perform(.toggleRAWFile)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertFalse(browser.contentController.isShowingRAW)
        let namedJPG = await waitUntil { self.shownName(browser) == "P1.JPG" }
        XCTAssertTrue(namedJPG)
    }

    func testTheRAWChipIsAClickableButtonThatDoesTheSame() async throws {
        let browser = try await open(.grid)
        defer { browser.close() }
        let content = browser.contentController
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(content.collectionViewForTesting.item(at: IndexPath(item: 0, section: 0)) as? ThumbnailItem)
        let chip = cell.rawChipButtonForTesting
        XCTAssertFalse(chip.isHidden, "a pair's cell has the chip")
        XCTAssertTrue(chip.toolTip?.contains("Show RAW File") == true)
        // The other photo selected; the chip click selects its photo and switches.
        XCTAssertTrue(content.select(url: dir.appendingPathComponent("P2.JPG")))
        chip.performClick(nil)
        XCTAssertEqual(content.selectedItems.map(\.url.lastPathComponent), ["P1.JPG"])
        let ok972 = await waitUntil { content.isShowingRAW }
        XCTAssertTrue(ok972)
        let namedORF = await waitUntil { self.shownName(browser) == "P1.ORF" }
        XCTAssertTrue(namedORF)
        let single = try XCTUnwrap(content.collectionViewForTesting.item(at: IndexPath(item: 1, section: 0)) as? ThumbnailItem)
        XCTAssertTrue(single.rawChipButtonForTesting.isHidden, "no chip without a RAW")
    }
}

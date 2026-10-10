//
//  BrowserSelectionSteadinessTests.swift
//  ShrikeUITests
//
//  And 2: a click in the Browser sets the inspector and
//  the status bar once (no Capture section that goes away and comes back,
//  no blank preview, no short status that grows). Temp folders, windows
//  never shown.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class BrowserSelectionSteadinessTests: XCTestCase {

    private var dir: URL!
    private var savedSortKey = ""
    private var savedSortAscending = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-steady-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedSortKey = Prefs.browserSortKey
        savedSortAscending = Prefs.browserSortAscending
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
    }

    override func tearDown() async throws {
        await CullingUndo.waitForPendingWrites()
        Prefs.browserSortKey = savedSortKey
        Prefs.browserSortAscending = savedSortAscending
        try? FileManager.default.removeItem(at: dir)
    }

    /// A JPEG with camera EXIF (so it has Capture rows).
    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Shrike",
                kCGImagePropertyTIFFModel: "Test Camera",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [200],
                kCGImagePropertyExifFNumber: 2.8,
                kCGImagePropertyExifDateTimeOriginal: "2026:09:25 14:02:31",
            ],
        ]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }

    /// A Browser on `dir` whose listing and saved values have landed.
    private func makeBrowser(count: Int) async throws -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        let ok = await waitUntil { hydrated && browser.contentController.allItems.count == count }
        XCTAssertTrue(ok, "the folder lists and hydrates")
        // A loaded test run must not hit the slow-read path by accident.
        browser.headerWait = .seconds(5)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    /// What a click on a cell does: AppKit changes the selection, then
    /// tells the delegate about the deselected and the selected items.
    private func click(_ url: URL, in browser: BrowserWindowController) throws {
        let content = browser.contentController
        let cv = content.collectionViewForTesting
        let index = try XCTUnwrap(content.visibleItems.firstIndex { $0.url == url })
        let old = cv.selectionIndexPaths
        let ip = IndexPath(item: index, section: 0)
        cv.selectionIndexPaths = [ip]
        if !old.isEmpty { content.collectionView(cv, didDeselectItemsAt: old) }
        content.collectionView(cv, didSelectItemsAt: [ip])
    }

    private func layOutInspector(_ browser: BrowserWindowController) {
        browser.inspectorForTesting.view.layoutSubtreeIfNeeded()
        browser.inspectorForTesting.hostViewForTesting?.layoutSubtreeIfNeeded()
    }

    // MARK:

    func testAClickPublishesTheInspectorOnceWithItsCaptureRows() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg", width: 48, height: 64)
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        let pane = browser.inspectorForTesting
        var published: [InspectorState] = []
        pane.onPublishForTesting = { published.append($0) }

        for (step, url) in [a, b, a].enumerated() {
            published.removeAll()
            try click(url, in: browser)
            await browser.waitForInspectorInfo()
            XCTAssertEqual(published.count, 1, "step \(step): one publish per click")
            let state = try XCTUnwrap(published.last)
            XCTAssertEqual(state.previewURL, url)
            XCTAssertTrue(state.capture.contains { $0.label == "Camera" && $0.value.contains("Test Camera") },
                          "step \(step): the Capture rows are in the one published state: \(state.capture)")
            XCTAssertNotNil(state.commonWidth, "step \(step): the size from the header")
        }
        XCTAssertEqual(browser.headerReadCount, 2, "A read once, B read once; A again comes from the cache")
    }

    func testTheSecondClickOnAPhotoFillsInTheSameTurn() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg")
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        try click(a, in: browser)
        await browser.waitForInspectorInfo()
        try click(b, in: browser)
        await browser.waitForInspectorInfo()
        let reads = browser.headerReadCount
        try click(a, in: browser)
        // No await: the cached header fills the state in the click's turn.
        let state = browser.inspectorStateForTesting
        XCTAssertEqual(state.previewURL, a)
        XCTAssertFalse(state.capture.isEmpty)
        XCTAssertTrue(browser.statusTextForTesting.contains("64 × 48"), browser.statusTextForTesting)
        XCTAssertEqual(browser.headerReadCount, reads, "no second read of the file")
    }

    func testASlowReadKeepsTheCaptureSectionShape() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg")
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        try click(a, in: browser)
        await browser.waitForInspectorInfo()
        let labels = browser.inspectorStateForTesting.capture.map(\.label)
        XCTAssertFalse(labels.isEmpty)

        // The wait ends before any read can: the placeholder path.
        browser.headerWait = .zero
        var published: [InspectorState] = []
        browser.inspectorForTesting.onPublishForTesting = { published.append($0) }
        try click(b, in: browser)
        await browser.waitForInspectorInfo()
        XCTAssertFalse(published.isEmpty)
        for state in published {
            XCTAssertEqual(state.capture.map(\.label), labels, "the section never goes away")
        }
        XCTAssertEqual(published.last?.previewURL, b)
        XCTAssertTrue(published.last?.capture.contains { $0.value.contains("Test Camera") } ?? false)
    }

    func testThePreviewNeverBlanksBetweenTwoPhotos() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg", width: 48, height: 64)
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        try click(a, in: browser)
        await browser.waitForInspectorInfo()
        layOutInspector(browser)
        let host = try XCTUnwrap(browser.inspectorForTesting.hostViewForTesting)
        let preview = try XCTUnwrap(InspectorPreviewImageView.find(in: host), "the preview view is made")
        await preview.waitForLoad()
        let imageA = try XCTUnwrap(preview.image, "A's picture")
        XCTAssertEqual(preview.shownURL, a)

        try click(b, in: browser)
        XCTAssertTrue(preview.image === imageA, "A stays until B is ready")
        await browser.waitForInspectorInfo()
        layOutInspector(browser)
        XCTAssertEqual(preview.shownURL, b)
        XCTAssertNotNil(preview.image, "never nil between A and B")
        await preview.waitForLoad()
        XCTAssertNotNil(preview.image)
        XCTAssertFalse(preview.image === imageA, "B's picture")

        try click(a, in: browser)
        layOutInspector(browser)
        XCTAssertNotNil(preview.image)
        await preview.waitForLoad()
        XCTAssertEqual(preview.blankings, 0, "the picture never went blank")
    }

    // MARK:

    func testTheStatusTextChangesOncePerClick() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg", width: 48, height: 64)
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        XCTAssertNil(browser.contentController.allItems.first?.pixelWidth, "a JPEG listing has no size")
        let bar = browser.bottomBar
        for (step, url) in [a, b, a].enumerated() {
            let before = bar.statusChanges
            try click(url, in: browser)
            await browser.waitForInspectorInfo()
            XCTAssertEqual(bar.statusChanges - before, 1, "step \(step): one text per click")
        }
        XCTAssertEqual(browser.statusTextForTesting.components(separatedBy: " · ").first, "a.jpg")
        XCTAssertTrue(browser.statusTextForTesting.contains("64 × 48"), browser.statusTextForTesting)
    }

    func testThePathControlIsNotSetAgainOnASelectionChange() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg")
        let browser = try await makeBrowser(count: 2)
        defer { browser.close() }
        let items = browser.bottomBar.pathControl.pathItems
        XCTAssertFalse(items.isEmpty)
        try click(a, in: browser)
        try click(b, in: browser)
        await browser.waitForInspectorInfo()
        XCTAssertTrue(zip(items, browser.bottomBar.pathControl.pathItems).allSatisfy { $0 === $1 },
                      "the same path items: nothing re-laid out")
    }
}

//
//  InspectorPanelImageTests.swift
//  ShrikeUITests
//
//  The inspector's own picture while moving through photos: a sharp picture
//  already in memory shows at once; otherwise the previous sharp picture is
//  held (at most the stand-in delay), then the small stand-in, then the
//  sharp one. Never nil, never a blurry picture when a sharp one was
//  available. Also: the fixed header heights (file name two lines, "Also").
//

import XCTest
import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

/// A distinct CGImage per call (identity tells them apart).
private func panelTestCG(_ size: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

private func panelTestURL(_ n: Int) -> URL { URL(fileURLWithPath: "/tmp/panel-\(n).jpg") }

@MainActor
final class InspectorPanelImageTests: XCTestCase {

    // MARK: Fixtures

    /// Width of the picture on screen (720 = sharp, 120 = stand-in).
    private func shownWidth(_ view: InspectorPreviewImageView) -> Int? {
        view.image.map { Int($0.size.width) } // NSImage(cgImage:size:.zero) takes the pixel size
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cond()
    }

    // MARK: Panel image

    func testASharpPictureInMemoryShowsAtOnce() {
        let view = InspectorPreviewImageView()
        let lookups = InspectorPreviewImageView.Lookups(
            quick: { _ in panelTestCG(120) },
            cachedSharp: { $0 == panelTestURL(1) ? panelTestCG(720) : panelTestCG(721) })
        view.show(panelTestURL(1), lookups: lookups)
        XCTAssertTrue(view.isShowingSharp, "the first photo, sharp in the same call")
        view.show(panelTestURL(2), lookups: lookups)
        XCTAssertTrue(view.isShowingSharp, "the next photo, sharp in the same call")
        XCTAssertEqual(shownWidth(view), 721)
        XCTAssertEqual(view.quickShows, 0)
        XCTAssertEqual(view.blankings, 0)
    }

    func testAnUncachedStepKeepsThePreviousSharpPictureUntilTheSharpOneLands() async {
        let view = InspectorPreviewImageView()
        view.standInDelay = .seconds(30) // never within this test
        // B's sharp read is held by the test (not timed), so "still A" is
        // checked while the read is really in flight on any machine.
        let gate = PanelReadGate()
        let lookups = InspectorPreviewImageView.Lookups(
            quick: { _ in panelTestCG(120) },
            cachedSharp: { $0 == panelTestURL(1) ? panelTestCG(720) : nil },
            loadSharp: { _ in
                await gate.wait()
                return panelTestCG(721)
            })
        view.show(panelTestURL(1), lookups: lookups)
        view.show(panelTestURL(2), lookups: lookups)
        XCTAssertEqual(shownWidth(view), 720, "A stays while B's sharp picture is read")
        XCTAssertFalse(view.isShowingSharp, "B is not shown yet")
        var started = false
        let deadline = Date().addingTimeInterval(5)
        while !started, Date() < deadline {
            started = await gate.entered
            if !started { try? await Task.sleep(for: .milliseconds(5)) }
        }
        XCTAssertTrue(started, "B's sharp read started")
        XCTAssertEqual(shownWidth(view), 720, "still A")
        await gate.open()
        await view.waitForLoad()
        XCTAssertEqual(shownWidth(view), 721, "then B, sharp")
        XCTAssertTrue(view.isShowingSharp)
        XCTAssertEqual(view.quickShows, 0, "no blurry picture in between")
        XCTAssertEqual(view.blankings, 0)
    }

    func testASlowStepShowsTheStandInAfterTheDelayThenTheSharpPicture() async {
        let view = InspectorPreviewImageView()
        view.standInDelay = .milliseconds(40)
        let lookups = InspectorPreviewImageView.Lookups(
            quick: { _ in panelTestCG(120) },
            cachedSharp: { $0 == panelTestURL(1) ? panelTestCG(720) : nil },
            loadSharp: { _ in
                try? await Task.sleep(for: .milliseconds(600))
                return panelTestCG(721)
            })
        view.show(panelTestURL(1), lookups: lookups)
        view.show(panelTestURL(2), lookups: lookups)
        XCTAssertEqual(shownWidth(view), 720, "held first")
        let landed = await waitUntil { view.quickShows == 1 }
        XCTAssertTrue(landed, "the stand-in shows after the delay")
        XCTAssertEqual(shownWidth(view), 120)
        XCTAssertFalse(view.isShowingSharp)
        await view.waitForLoad()
        XCTAssertEqual(shownWidth(view), 721, "then the sharp picture")
        XCTAssertTrue(view.isShowingSharp)
        XCTAssertEqual(view.blankings, 0)
    }

    func testTheFirstPhotoHasNothingToHoldSoTheStandInShowsAtOnce() async {
        let view = InspectorPreviewImageView()
        view.standInDelay = .seconds(30)
        let lookups = InspectorPreviewImageView.Lookups(
            quick: { _ in panelTestCG(120) },
            loadSharp: { _ in
                try? await Task.sleep(for: .milliseconds(300))
                return panelTestCG(721)
            })
        view.show(panelTestURL(1), lookups: lookups)
        let landed = await waitUntil(2) { view.quickShows == 1 }
        XCTAssertTrue(landed, "no 30 s wait with nothing sharp to hold")
        await view.waitForLoad()
        XCTAssertTrue(view.isShowingSharp)
    }

    func testRapidStepsWithCachedAndUncachedNeighboursNeverBlankOrDowngrade() async {
        let view = InspectorPreviewImageView()
        // The step interval and the read time are both well under the delay.
        view.standInDelay = .milliseconds(500)
        let cachedSet = Set([0, 2, 3, 6, 8].map(panelTestURL))
        let lookups = InspectorPreviewImageView.Lookups(
            quick: { _ in panelTestCG(120) },
            cachedSharp: { cachedSet.contains($0) ? panelTestCG(720) : nil },
            loadSharp: { _ in
                try? await Task.sleep(for: .milliseconds(25))
                return panelTestCG(720)
            })
        view.show(panelTestURL(0), lookups: lookups)
        for n in 1...9 {
            view.show(panelTestURL(n), lookups: lookups)
            XCTAssertNotNil(view.image, "step \(n): never nil")
            XCTAssertEqual(shownWidth(view), 720, "step \(n): never the low-res stand-in")
            if cachedSet.contains(panelTestURL(n)) {
                XCTAssertTrue(view.isShowingSharp, "step \(n): cached means sharp at once")
            }
            try? await Task.sleep(for: .milliseconds(n % 2 == 0 ? 2 : 40))
        }
        await view.waitForLoad()
        XCTAssertTrue(view.isShowingSharp)
        XCTAssertEqual(view.shownURL, panelTestURL(9))
        XCTAssertEqual(view.quickShows, 0)
        XCTAssertEqual(view.blankings, 0)
    }

    func testAnUnreadablePhotoNeverKeepsTheLastPhotosPicture() async {
        let view = InspectorPreviewImageView()
        view.standInDelay = .milliseconds(10)
        let lookups = InspectorPreviewImageView.Lookups(
            cachedSharp: { $0 == panelTestURL(1) ? panelTestCG(720) : nil },
            loadSharp: { _ in nil })
        view.show(panelTestURL(1), lookups: lookups)
        view.show(panelTestURL(2), lookups: lookups)
        await view.waitForLoad()
        XCTAssertNil(view.image)
    }

    // MARK: Read ahead through the Browser

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

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

    func testTheNeighbourIsReadAheadSoAStepShowsItSharpAtOnce() async throws {
        let a = try writeJPEG("a.jpg")
        let b = try writeJPEG("b.jpg", width: 48, height: 64)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        var hydrated = false
        browser.onHydratedForTesting = { hydrated = true }
        let listed = await waitUntil { hydrated && browser.contentController.allItems.count == 2 }
        XCTAssertTrue(listed)
        browser.headerWait = .seconds(5)
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        let cache = browser.services.thumbnailCache
        let px = InspectorPreviewImageView.maxPixelSize

        try click(a, in: browser)
        await browser.waitForInspectorInfo()
        browser.inspectorForTesting.view.layoutSubtreeIfNeeded()
        let host = try XCTUnwrap(browser.inspectorForTesting.hostViewForTesting)
        host.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(InspectorPreviewImageView.find(in: host))
        await preview.waitForLoad()
        let ahead = await waitUntil { cache.cachedThumbnail(for: FileImageSource(url: b), maxPixelSize: px) != nil }
        XCTAssertTrue(ahead, "B's panel picture was read ahead")

        // A's own first show may put its stand-in up when the quick read
        // beats the sharp one (nothing sharp was on screen to hold); only
        // the step to B is under test.
        let quickShowsBefore = preview.quickShows, blankingsBefore = preview.blankings
        try click(b, in: browser)
        await browser.waitForInspectorInfo()
        browser.inspectorForTesting.view.layoutSubtreeIfNeeded()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(preview.shownURL, b)
        XCTAssertTrue(preview.isShowingSharp, "B is sharp before any read")
        XCTAssertEqual(preview.quickShows, quickShowsBefore, "B never shows a stand-in")
        XCTAssertEqual(preview.blankings, blankingsBefore, "the picture never goes blank on the step")
    }

    // MARK: Header heights

    /// Height of the preview section's rows for one state, laid out at the
    /// pane's width. The rows below the header start where it ends, so equal
    /// heights mean they never move.
    private func headerHeight(name: String, also: String?) -> CGFloat {
        var state = InspectorState(count: 1, commonName: name)
        state.alsoLine = also
        let host = NSHostingView(rootView: PreviewSection(state: state, panelLookups: nil).frame(width: 300))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheHeaderKeepsItsHeightForShortAndLongNamesWithAndWithoutAlso() {
        let long = String(repeating: "A very long file name ", count: 8) + ".jpg"
        let cases: [(String, String?)] = [
            ("a.jpg", nil),
            ("a.jpg", "Also: a.ORF (24.1 MB)"),
            (long, nil),
            (long, "Also: " + String(repeating: "x", count: 120) + ".ORF (24.1 MB)"),
            ("Two words.jpg", "Also: b.ORF (1 MB)"),
        ]
        let heights = cases.map { headerHeight(name: $0.0, also: $0.1) }
        XCTAssertGreaterThan(heights[0], 180, "the box and the text rows")
        for (i, h) in heights.enumerated() {
            XCTAssertEqual(h, heights[0], accuracy: 0.5, "case \(i): same height as the short name without Also")
        }
    }
}

/// Holds a sharp-picture read until the test opens it.
private actor PanelReadGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = false
    func wait() async {
        entered = true
        if !isOpen { await withCheckedContinuation { waiting.append($0) } }
    }
    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

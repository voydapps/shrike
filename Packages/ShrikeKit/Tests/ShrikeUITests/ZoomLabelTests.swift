//
//  ZoomLabelTests.swift
//  ShrikeUITests
//
//  The zoom HUD shows the
//  photo's pixel percent (100 % = one image pixel per screen pixel),
//  the same number as the title's Zoom line and VoiceOver, for a
//  subsampled display texture and after the full-resolution swap. It
//  shows only when the user changes the zoom.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ZoomLabelTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-zoomlabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = false
        MetalImageView.reduceMotionOverrideForTesting = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        MetalImageView.reduceMotionOverrideForTesting = nil
    }

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }

    /// 800 × 600 viewer on 3000 × 2000 photos with a 1024 px display
    /// texture: texture zoom and pixel percent differ.
    private func makeViewer() async throws -> (ViewerWindow, MetalImageView) {
        let urls = try (0..<2).map { try writeJPEG("z\($0).jpg", width: 3000, height: 2000) }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 1, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let queue = window.navigationForTesting.decodeQueue
        await queue.purge()
        await queue.setMaxLongEdge(1024)
        window.setGroups(urls.map { ImageGroup(primary: $0) }, startIndex: 0)
        let view = window.imageViewForTesting
        let ready = await waitUntil {
            (view.sourceID ?? "").hasSuffix("z0.jpg") && view.image != nil && !view.isCurrentImagePlaceholder
                && view.sourcePixelSize != nil && (view.textureSizeForTesting?.width ?? 3000) < 3000
        }
        XCTAssertTrue(ready, "subsampled photo with a known pixel size never reached the canvas")
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func percent(_ scale: Double) -> String { "\(Int((scale * 100).rounded())) %" }

    func testFitDoubleClickAndCommandOneShowPixelPercent() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        window.cancelFullResolution()
        let hud = window.contentRoot
        XCTAssertNotEqual(percent(view.zoom), percent(view.pixelScale),
                          "precondition: the texture is subsampled, so the two numbers differ")

        // Fit (⌘0): the fit pixel percent, not the texture zoom.
        window.dispatch(.fitToWindow)
        XCTAssertTrue(view.isAtFit)
        XCTAssertEqual(hud.zoomBadgeTextForTesting, percent(view.fitPixelScale))
        XCTAssertNotEqual(hud.zoomBadgeTextForTesting, percent(view.zoom))
        XCTAssertEqual(window.toolbarZoomLine, "Fit (\(percent(view.fitPixelScale)))")

        // Double-click at Fit: exactly 100 %.
        hud.hideZoomBadgeForTesting()
        view.toggleZoomForTesting(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        XCTAssertEqual(hud.zoomBadgeTextForTesting, "100 %")
        XCTAssertTrue(hud.zoomBadgeShownForTesting, "a double-click is a user zoom")
        XCTAssertEqual(window.toolbarZoomLine, "100 %")

        // ⌘1 from Fit: the same 100 %.
        window.cancelFullResolution()
        window.dispatch(.fitToWindow)
        window.dispatch(.zoomActualSize)
        XCTAssertEqual(hud.zoomBadgeTextForTesting, "100 %")
        XCTAssertEqual(window.toolbarZoomLine, "100 %")
    }

    func testFullResolutionSwapKeepsTheNumber() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        let hud = window.contentRoot
        window.dispatch(.zoom200)
        XCTAssertEqual(hud.zoomBadgeTextForTesting, "200 %")
        let swapped = await waitUntil { view.isShowingFullResolution }
        XCTAssertTrue(swapped, "no full-resolution swap at 200 %")
        XCTAssertEqual(view.textureSizeForTesting, CGSize(width: 3000, height: 2000))
        XCTAssertEqual(hud.zoomBadgeTextForTesting, "200 %", "the swap must not change the HUD")
        XCTAssertEqual(window.toolbarZoomLine, "200 %")
        // A user zoom after the swap reads the same definition.
        window.dispatch(.zoomActualSize)
        XCTAssertEqual(hud.zoomBadgeTextForTesting, "100 %")
    }

    /// Re-fits the app makes on its own keep the HUD hidden.
    func testRefitsAndPhotoChangesDoNotShowTheHUD() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        let hud = window.contentRoot
        hud.hideZoomBadgeForTesting()
        window.setContentSize(NSSize(width: 1000, height: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(hud.zoomBadgeShownForTesting, "a window resize re-fit showed the HUD")
        window.dispatch(.nextImage)
        let moved = await waitUntil { (view.sourceID ?? "").hasSuffix("z1.jpg") && !view.isCurrentImagePlaceholder }
        XCTAssertTrue(moved)
        XCTAssertFalse(hud.zoomBadgeShownForTesting, "a photo change showed the HUD")
        window.dispatch(.zoomIn)
        XCTAssertTrue(hud.zoomBadgeShownForTesting, "Zoom In is a user zoom")
        XCTAssertEqual(hud.zoomBadgeTextForTesting, percent(view.pixelScale))
    }
}

/// The zoom HUD always ends hidden, also when full screen starts around
/// its fade (the QA run found it stuck on screen in full screen).
@MainActor
final class ZoomBadgeHidesTests: XCTestCase {

    override func tearDown() async throws {
        HUDGlass.forceFallbackForTesting = false
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Polls (every 10 ms) until `condition` holds or `timeout` passes. A late
    /// wake-up on a loaded runner only makes the wait longer, never the test wrong.
    private func waitUntil(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            await sleep(0.01)
        }
        return true
    }

    private func makeContent(fullscreen: Bool) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.windowMode = fullscreen ? .fullscreen : .windowed
        content.layoutSubtreeIfNeeded()
        return content
    }

    /// `pulseAt`: when (seconds after the pulse) full screen starts.
    private func run(glass: Bool, switchAt: Double?, startFullscreen: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) async {
        HUDGlass.forceFallbackForTesting = !glass
        let content = makeContent(fullscreen: startFullscreen)
        content.userChangedZoom()
        XCTAssertTrue(content.zoomBadgeShownForTesting, file: file, line: line)
        if let switchAt {
            await sleep(switchAt)
            content.windowMode = .fullscreen
            content.layoutSubtreeIfNeeded()
        }
        // Hidden at about 1.8 s after the pulse; the 4 s bound only absorbs a loaded runner.
        let hidden = await waitUntil(timeout: 4) { !content.zoomBadgeShownForTesting }
        XCTAssertTrue(hidden,
                      "glass \(glass), switch at \(String(describing: switchAt)): the zoom HUD is stuck on screen",
                      file: file, line: line)
    }

    func testHidesInFullScreenWithGlass() async { await run(glass: true, switchAt: nil, startFullscreen: true) }
    func testHidesInFullScreenWithoutGlass() async { await run(glass: false, switchAt: nil, startFullscreen: true) }
    func testHidesWhenFullScreenStartsBeforeTheFade() async { await run(glass: true, switchAt: 1.1) }
    func testHidesWhenFullScreenStartsDuringTheFade() async { await run(glass: true, switchAt: 1.3) }
    func testHidesWhenFullScreenStartsDuringTheFadeWithoutGlass() async { await run(glass: false, switchAt: 1.3) }
    func testHidesWhenFullScreenStartsRightAway() async { await run(glass: true, switchAt: 0.05) }

    /// The fade is dropped (the HUD snaps back to visible mid-fade): the
    /// hand-made hide still removes it.
    func testALostFadeIsFinishedByHand() async {
        for fullscreen in [false, true] {
            let content = makeContent(fullscreen: fullscreen)
            content.userChangedZoom()
            // Wait for the fade to start (the HUD's alpha goes to 0 at 1.2 s), then
            // bring it back: the hand-made hide, 0.6 s after the fade start, must
            // still remove it. Waiting for the event instead of a fixed 1.3 s
            // keeps the forced show ahead of the hand-hide on a slow runner.
            let fadeStarted = await waitUntil(timeout: 5) { !content.zoomBadgeShownForTesting }
            XCTAssertTrue(fadeStarted, "fullscreen \(fullscreen): the fade never started")
            content.forceZoomBadgeVisibleForTesting()
            XCTAssertTrue(content.zoomBadgeShownForTesting)
            let hidden = await waitUntil(timeout: 4) { !content.zoomBadgeShownForTesting }
            XCTAssertTrue(hidden, "fullscreen \(fullscreen): a lost fade left the HUD up")
        }
    }

    /// A newer pulse is not hidden by an older pulse's safety hide.
    func testANewPulseOutlivesTheOldOnesSafetyHide() async {
        let content = makeContent(fullscreen: true)
        content.userChangedZoom()
        await sleep(1.5)
        content.userChangedZoom()
        await sleep(0.5)   // the old pulse's safety hide (at 1.8 s) has run
        XCTAssertTrue(content.zoomBadgeShownForTesting)
        let hidden = await waitUntil(timeout: 6) { !content.zoomBadgeShownForTesting }
        XCTAssertTrue(hidden)
    }
}

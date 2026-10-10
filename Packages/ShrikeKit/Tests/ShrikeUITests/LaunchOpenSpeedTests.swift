//
//  LaunchOpenSpeedTests.swift
//  ShrikeUITests
//
//  (launch and window-open speed): an offscreen harness for
//  the main-thread work between "open this photo" and the first frame.
//  Prints the numbers (Debug unless run with `-c release`) and checks the
//  rules that keep them low:
//    * no layout pass inside `ViewerWindow.init` (1.2);
//    * a ready texture is on the canvas before the window is shown (1.1);
//    * chrome nobody sees is not built before the first frame (1.3).
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
final class LaunchOpenSpeedTests: XCTestCase {

    private var dir: URL!
    private var services: ShrikeServices!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    override func tearDown() async throws {
        services = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func ms(_ start: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }
    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
    private func fmt(_ x: Double) -> String { String(format: "%.1f", x) }

    /// 1.2 + 1.3: init time, layout passes inside init, and the first
    /// layout (what AppKit does once before the first display).
    func testViewerInitPieces() throws {
        let urls = try (0..<5).map { try writeJPEG("p\($0).jpg") }
        let groups = urls.map { ImageGroup(primary: $0) }
        ViewerWindow(groups: groups, startIndex: 0, services: services).close()   // warm-up
        spin()

        var inits: [Double] = [], layouts: [Double] = [], passes: [Int] = []
        if ProcessInfo.processInfo.environment["SHRIKE_TRACE_LAYOUT"] != nil {
            ViewerContentView.onAnyLayoutForTesting = {
                print("[layout in init]\n" + Thread.callStackSymbols.prefix(40).joined(separator: "\n"))
            }
            ViewerWindow(groups: groups, startIndex: 0, services: services).close()
            ViewerContentView.onAnyLayoutForTesting = nil
        }
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
            inits.append(ms(start))
            passes.append(viewer.contentRootForTesting.layoutPassesForTesting)
            let layoutStart = CFAbsoluteTimeGetCurrent()
            viewer.contentView?.layoutSubtreeIfNeeded()
            layouts.append(ms(layoutStart))
            viewer.close()
            spin()
        }
        print("[viewer init] ViewerWindow.init median \(fmt(median(inits))) ms (\(inits.map(fmt))), "
              + "layout passes in init \(passes), first layout median \(fmt(median(layouts))) ms")
        XCTAssertEqual(passes.max(), 0, "no layout pass inside ViewerWindow.init")
    }

    /// 1.3: a window never shows the full-screen capsule, so it is not
    /// built before the first frame; full screen builds it in its z-order
    /// slot (above the filmstrip, below the edit rail).
    func testCapsuleIsBuiltOnlyForFullScreen() throws {
        let url = try writeJPEG("a.jpg")
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        let root = viewer.contentRootForTesting
        root.layoutSubtreeIfNeeded()
        spin()
        XCTAssertFalse(root.isCapsuleBuiltForTesting, "no capsule in a window")
        root.windowMode = .fullscreen
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(root.isCapsuleBuiltForTesting)
        let capsule = root.toolbarForTesting
        // The HUDs share one parent (the glass container on macOS 26).
        let order = capsule.superview?.subviews ?? []
        let capsuleIndex = try XCTUnwrap(order.firstIndex(of: capsule))
        let stripIndex = try XCTUnwrap(order.firstIndex { $0 is FilmstripView })
        let railIndex = try XCTUnwrap(order.firstIndex { $0 is EditRail })
        XCTAssertLessThan(stripIndex, capsuleIndex)
        XCTAssertLessThan(capsuleIndex, railIndex)
        XCTAssertTrue(capsule.isHidden, "built hidden; hover shows it")
    }

    /// Async tests run inside a main-actor job: a nested run loop does not
    /// run other main-actor tasks, so these waits sleep instead.
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }
    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// 1.5: textures follow the canvas; a grown canvas swaps in a larger
    /// texture of the same photo, keeping Fit or the on-screen zoom.
    func testTextureSizeFollowsTheCanvas() async throws {
        let urls = try ["large-a.jpg", "large-b.jpg"].map { try writeJPEG($0, width: 4000, height: 3000) }
        let viewer = ViewerWindow(groups: [ImageGroup(primary: urls[0])], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 500, height: 400))
        viewer.contentView?.layoutSubtreeIfNeeded()
        let view = viewer.imageViewForTesting
        let scale = viewer.backingScaleFactor
        let small = Int((500 * scale).rounded(.up))
        XCTAssertEqual(viewer.textureLongEdgeForTesting, min(small, Prefs.maxDisplayLongEdge),
                       "the first layout sets the canvas long edge in pixels")
        await waitUntil { viewer.displayedItem != nil && view.displayTextureLongEdge != nil && !view.isCurrentImagePlaceholder }
        // The first photo may have started decoding before the first
        // layout (screen-size target); the next one is decoded for the canvas.
        viewer.showFromBrowser(groups: [ImageGroup(primary: urls[1])], startIndex: 0)
        viewer.orderOut(nil)
        await waitUntil {
            viewer.displayedItem?.group.primary == urls[1] && !view.isCurrentImagePlaceholder
                && view.sourceID == FileImageSource(url: urls[1]).id
        }
        await pause(0.3)
        let queueEdge = await viewer.navigationForTesting.decodeQueue.maxDisplayLongEdge
        XCTAssertEqual(queueEdge, viewer.textureLongEdgeForTesting)
        let before = try XCTUnwrap(view.displayTextureLongEdge)
        XCTAssertLessThan(before, 4000, "a small window gets a small texture")

        // Zoom to 50 % of the file, then the window grows (end of a live resize).
        view.setPixelScale(0.5, anchor: nil)
        let scaleBefore = view.pixelScale
        viewer.setContentSize(NSSize(width: 1900, height: 1500))
        viewer.contentView?.layoutSubtreeIfNeeded()
        viewer.contentRootForTesting.updateTextureLongEdge()
        let big = min(Int((1900 * scale).rounded(.up)), Prefs.maxDisplayLongEdge)
        XCTAssertEqual(viewer.textureLongEdgeForTesting, big)
        if big > before {
            await waitUntil { viewer.textureRefetchCount > 0 }
            XCTAssertEqual(viewer.textureRefetchCount, 1)
            XCTAssertGreaterThan(try XCTUnwrap(view.displayTextureLongEdge), before)
            XCTAssertEqual(view.pixelScale, scaleBefore, accuracy: scaleBefore * 0.01,
                           "the zoom keeps its on-screen size")
        }
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[1])

        // Shrinking (leaving full screen) swaps the
        // big texture for a canvas-sized one, so it is released.
        let bigEdge = try XCTUnwrap(view.displayTextureLongEdge)
        let count = viewer.textureRefetchCount
        viewer.setContentSize(NSSize(width: 600, height: 400))
        viewer.contentRootForTesting.updateTextureLongEdge()
        await waitUntil { viewer.textureRefetchCount > count }
        XCTAssertEqual(viewer.textureRefetchCount, count + 1, "one swap to the smaller texture")
        XCTAssertLessThan(try XCTUnwrap(view.displayTextureLongEdge), bigEdge)
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[1])
        // A small step (inside the 25 % slack) fetches nothing.
        let settled = viewer.textureRefetchCount
        viewer.setContentSize(NSSize(width: 580, height: 390))
        viewer.contentRootForTesting.updateTextureLongEdge()
        await pause(0.3)
        XCTAssertEqual(viewer.textureRefetchCount, settled)
    }

    /// 1.3: where the init time goes (prints only).
    func testInitBreakdown() throws {
        _ = ViewerContentView(services: services)
        _ = FilmstripView(); _ = ViewerToolbar(); _ = EditRail(); _ = InspectorPanel()
        _ = HistogramOverlayView(); _ = LoupeView(); _ = NavigationPositionOverlayView()
        _ = ViewerWindowToolbar(host: nil)
        func time(_ name: String, _ body: () -> Void) -> String {
            var xs: [Double] = []
            for _ in 0..<5 { let s = CFAbsoluteTimeGetCurrent(); body(); xs.append(ms(s)) }
            return "\(name) \(fmt(median(xs)))"
        }
        let parts = [
            time("contentView") { _ = ViewerContentView(services: services) },
            time("filmstrip") { _ = FilmstripView() },
            time("capsule") { _ = ViewerToolbar() },
            time("editRail") { _ = EditRail() },
            time("inspector") { _ = InspectorPanel() },
            time("histogram") { _ = HistogramOverlayView() },
            time("loupe") { _ = LoupeView() },
            time("pill") { _ = NavigationPositionOverlayView() },
            time("windowToolbar") { _ = ViewerWindowToolbar(host: nil) },
            time("metalView") { _ = MetalImageView(frame: .zero) },
            time("split") {
                let c = ViewerContentView(services: services)
                _ = ViewerSplitController(canvas: c, model: c.inspectorPanel.viewModel).view
            },
            time("bareWindow+split+toolbar") {
                let c = ViewerContentView(services: services)
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                 backing: .buffered, defer: false)
                w.isReleasedWhenClosed = false
                let split = ViewerSplitController(canvas: c, model: c.inspectorPanel.viewModel)
                split.view.setFrameSize(NSSize(width: 1200, height: 800))
                w.contentViewController = split
                let bar = ViewerWindowToolbar(host: nil)
                w.toolbar = bar.toolbar
                w.close()
            },
        ]
        print("[window cost] " + parts.joined(separator: " · ") + " ms")
    }

    /// When the early decode is ready, the photo is on the canvas
    /// before the window is ordered front (no empty first frame).
    func testReadyTextureIsOnTheCanvasBeforeOrderFront() async throws {
        let url = try writeJPEG("big.jpg", width: 2400, height: 1600)
        DecodeHandoff.shared.start(url: url, targetLongEdge: Prefs.maxDisplayLongEdge,
                                   preparer: DisplayTextureFactory.preparer)
        try await Task.sleep(for: .milliseconds(400))   // the early decode finishes
        let start = CFAbsoluteTimeGetCurrent()
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        let initMs = ms(start)
        var painted = false
        for _ in 0..<20 where !painted {
            painted = await viewer.paintReadyFirstPhoto()
            if !painted { try await Task.sleep(for: .milliseconds(5)) }
        }
        let readyMs = ms(start)
        print("[ready photo] init \(fmt(initMs)) ms, ready photo on the canvas at \(fmt(readyMs)) ms")
        XCTAssertTrue(painted)
        XCTAssertTrue(viewer.imageViewForTesting.hasTextureForTesting, "the texture is set before order front")
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)
        XCTAssertGreaterThan(viewer.imageViewForTesting.drawableSizeForTesting.width, 1,
                             "the canvas is laid out, so the first frame has its real size")
        // The normal first navigation still runs and changes nothing.
        spin(0.3)
        XCTAssertTrue(viewer.imageViewForTesting.hasTextureForTesting)
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)
    }
}

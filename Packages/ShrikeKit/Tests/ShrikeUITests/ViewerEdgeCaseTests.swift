//
//  ViewerEdgeCaseTests.swift
//  ShrikeUITests
//
//  Viewer edge cases: the histogram on a new viewer's first photo, a file
//  already open, rotation in the loupe, and the preferred-top layout.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerEdgeCaseTests: XCTestCase {

    private var dir: URL!
    private var savedHistogram = false
    private var savedInspector = false
    private var coordinators: [WindowCoordinator] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-viewer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedHistogram = Prefs.viewerHistogramVisible
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = false
    }

    override func tearDown() async throws {
        for c in coordinators { for v in c.viewers { v.close() } }
        coordinators = []
        Prefs.viewerHistogramVisible = savedHistogram
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 1600, height: Int = 1200) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        return services
    }

    /// A coordinator whose viewers stay invisible and take no clicks.
    private func coordinator() -> WindowCoordinator {
        let coordinator = WindowCoordinator()
        coordinator.standaloneFrameForTesting = NSRect(x: 80, y: 80, width: 1200, height: 800)
        coordinator.onWindowOpened = { [weak coordinator] in
            coordinator?.viewers.last?.alphaValue = 0
            coordinator?.viewers.last?.ignoresMouseEvents = true
        }
        coordinators.append(coordinator)
        return coordinator
    }

    private func reached(within seconds: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func firstPhotoShown(_ viewer: ViewerWindow) async -> Bool {
        let view = viewer.imageViewForTesting
        return await reached { viewer.displayedItem != nil && view.image != nil && !view.isCurrentImagePlaceholder }
    }

    // MARK: The histogram on a new viewer's first photo

    /// A second viewer opened like Finder / `open -a` (on
    /// another photo of the folder: the same photo now brings the first
    /// viewer forward) shows the floating histogram, with data,
    /// for its first photo, in the window and in full screen (after the
    /// idle fade and the pointer's return), with no navigation.
    func testSecondViewerShowsTheHistogramForItsFirstPhoto() async throws {
        Prefs.viewerHistogramVisible = true
        let a = writeJPEG("a.jpg")
        let b = writeJPEG("b.jpg")
        let coordinator = coordinator()
        let services = try services()
        coordinator.open([a], services: services, noteRecent: false)
        let one = await reached { coordinator.viewers.count == 1 && coordinator.pendingOpens == 0 }
        XCTAssertTrue(one)
        coordinator.open([b], services: services, noteRecent: false)
        let two = await reached { coordinator.viewers.count == 2 && coordinator.pendingOpens == 0 }
        XCTAssertTrue(two)
        let second = try XCTUnwrap(coordinator.viewers.last)
        let shown = await firstPhotoShown(second)
        XCTAssertTrue(shown)
        let content = second.contentRootForTesting
        content.animatesPanelFades = false
        let landed = await reached { content.histogram.state.data != nil && !content.histogram.state.isStale }
        XCTAssertTrue(landed, "the first photo has a histogram")
        XCTAssertEqual(second.displayedItem?.group.primary.lastPathComponent, "b.jpg", "no navigation happened")
        XCTAssertEqual(content.histogram.lastShownURL?.lastPathComponent, "b.jpg")
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "shown in the window")

        content.windowMode = .fullscreen
        second.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 982), display: false)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "shown in full screen")
        content.forceIdleFireForTesting()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "stays: no idle fade")
        XCTAssertNotNil(content.histogramOverlayIfBuiltForTesting?.stateForTesting.data)
        content.windowMode = .windowed
    }

    /// The ready first photo feeds the histogram itself when the first
    /// navigation did not (it was superseded); once only.
    func testShownPhotoFeedsAHistogramThatWasNeverFed() async throws {
        Prefs.viewerHistogramVisible = true
        let a = writeJPEG("a.jpg")
        let coordinator = coordinator()
        let viewer = coordinator.openViewer(groups: [ImageGroup(primary: a)], startIndex: 0, services: try services())
        let shown = await firstPhotoShown(viewer)
        XCTAssertTrue(shown)
        let histogram = viewer.contentRootForTesting.histogram
        _ = await reached { histogram.completedCount > 0 }
        await histogram.waitForIdle()
        // As if the first navigation had been superseded before its end.
        histogram.reset()
        XCTAssertNil(histogram.lastShownURL)
        let before = histogram.completedCount
        viewer.feedHistogramWithShownPhoto()
        XCTAssertEqual(histogram.lastShownURL, a)
        let computed = await reached { histogram.completedCount == before + 1 }
        XCTAssertTrue(computed, "the shown photo was computed")
        // Already fed: nothing more.
        viewer.feedHistogramWithShownPhoto()
        try await Task.sleep(nanoseconds: 150_000_000)
        await histogram.waitForIdle()
        XCTAssertEqual(histogram.completedCount, before + 1)
    }

    // MARK: A file already open brings its viewer forward

    /// `open -a Shrike a.jpg` while a viewer shows a.jpg brings
    /// that viewer forward; no second window. Another photo of the same
    /// folder still opens its own viewer, and a hidden viewer is not reused.
    func testOpeningAFileAlreadyShownBringsItsViewerForward() async throws {
        let a = writeJPEG("a.jpg")
        let b = writeJPEG("b.jpg")
        let coordinator = coordinator()
        let services = try services()
        coordinator.open([a], services: services, noteRecent: false)
        let one = await reached { coordinator.viewers.count == 1 && coordinator.pendingOpens == 0 }
        XCTAssertTrue(one)
        let first = try XCTUnwrap(coordinator.viewers.first)
        let shown = await firstPhotoShown(first)
        XCTAssertTrue(shown)

        // The same file, also spelled through /private (the temp folder's
        // real path) and with a "./" in it.
        let privateSpelling = URL(fileURLWithPath: "/private" + a.path)
        let dotted = a.deletingLastPathComponent().appendingPathComponent("./a.jpg")
        for (n, url) in [a, privateSpelling, dotted].enumerated() {
            coordinator.open([url], services: services, noteRecent: false)
            XCTAssertEqual(coordinator.pendingOpens, 0, "no scan started (\(n))")
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertEqual(coordinator.viewers.count, 1, "no second window (\(n))")
            XCTAssertEqual(coordinator.broughtForwardCountForTesting, n + 1)
            XCTAssertTrue(first.isVisible)
        }

        // Another photo: its own viewer, as before.
        coordinator.open([b], services: services, noteRecent: false)
        let two = await reached { coordinator.viewers.count == 2 && coordinator.pendingOpens == 0 }
        XCTAssertTrue(two, "another photo opens its own viewer")
        XCTAssertEqual(coordinator.broughtForwardCountForTesting, 3)

        // A viewer put away (orderOut) is not brought back for a.jpg.
        first.orderOut(nil)
        coordinator.open([a], services: services, noteRecent: false)
        let three = await reached { coordinator.viewers.count == 3 && coordinator.pendingOpens == 0 }
        XCTAssertTrue(three, "a hidden viewer is not reused")
        XCTAssertEqual(coordinator.broughtForwardCountForTesting, 3)
    }

    func testPathKeyIgnoresThePrivatePrefix() {
        XCTAssertEqual(WindowCoordinator.pathKey(URL(fileURLWithPath: "/private/var/folders/x/a.jpg")),
                       WindowCoordinator.pathKey(URL(fileURLWithPath: "/var/folders/x/a.jpg")))
        XCTAssertEqual(WindowCoordinator.pathKey(URL(fileURLWithPath: "/private/tmp/a.jpg")), "/tmp/a.jpg")
        XCTAssertEqual(WindowCoordinator.pathKey(URL(fileURLWithPath: "/Users/x/private/var/a.jpg")),
                       "/Users/x/private/var/a.jpg")
        XCTAssertNotEqual(WindowCoordinator.pathKey(URL(fileURLWithPath: "/Users/x/a.jpg")),
                          WindowCoordinator.pathKey(URL(fileURLWithPath: "/Users/x/b.jpg")))
    }

    // MARK: The loupe follows the view's turn and mirrors

    /// One pixel of `image` (top-left origin), in sRGB 0...1.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }

    private enum Swatch: String { case red, green, blue, white, black }

    private func swatch(_ c: (r: Double, g: Double, b: Double)) -> Swatch? {
        func hi(_ v: Double) -> Bool { v > 0.7 }
        func lo(_ v: Double) -> Bool { v < 0.3 }
        if hi(c.r), hi(c.g), hi(c.b) { return .white }
        if lo(c.r), lo(c.g), lo(c.b) { return .black }
        if hi(c.r), lo(c.g), lo(c.b) { return .red }
        if lo(c.r), hi(c.g), lo(c.b) { return .green }
        // Pure blue, or the viewer fixture's (0.2, 0.5, 0.8).
        if lo(c.r), hi(c.b), c.g < c.b - 0.2 { return .blue }
        return nil
    }

    /// 200 × 200: red top-left, green top-right, blue bottom-left, white
    /// bottom-right.
    private func quadrants() -> CGImage {
        let ctx = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let fills: [(CGRect, CGColor)] = [
            (CGRect(x: 0, y: 100, width: 100, height: 100), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: 100, y: 100, width: 100, height: 100), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: 0, width: 100, height: 100), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: 100, y: 0, width: 100, height: 100), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ]
        for (rect, color) in fills { ctx.setFillColor(color); ctx.fill(rect) }
        return ctx.makeImage()!
    }

    /// The patch's four corners, clockwise from top-left.
    private func corners(_ patch: CGImage) -> [Swatch?] {
        let e = patch.width - 10
        return [(10, 10), (e, 10), (e, e), (10, e)].map { swatch(pixel(patch, $0.0, $0.1)) }
    }

    /// The patch is turned and mirrored as `MetalImageView` shows the
    /// image: mirror first, then the clockwise turn.
    func testLoupePatchIsTurnedAndMirroredLikeTheView() throws {
        let image = quadrants()
        func patch(_ degrees: Double, _ h: Bool = false, _ v: Bool = false) -> [Swatch?] {
            let p = LoupeView.makePatch(source: image, center: CGPoint(x: 100, y: 100), side: 110,
                                        rotationDegrees: degrees, flippedH: h, flippedV: v)!
            XCTAssertEqual(p.width, 110)
            return corners(p)
        }
        XCTAssertEqual(patch(0), [.red, .green, .white, .blue], "unturned")
        XCTAssertEqual(patch(90), [.blue, .red, .green, .white], "Rotate Right")
        XCTAssertEqual(patch(270), [.green, .white, .blue, .red], "Rotate Left")
        XCTAssertEqual(patch(180), [.white, .blue, .red, .green])
        XCTAssertEqual(patch(0, true), [.green, .red, .blue, .white], "mirrored")
        XCTAssertEqual(patch(0, false, true), [.blue, .white, .green, .red], "flipped")
        // Outside the image: black.
        let edge = LoupeView.makePatch(source: image, center: CGPoint(x: 0, y: 0), side: 110,
                                       rotationDegrees: 0, flippedH: false, flippedV: false)!
        XCTAssertEqual(corners(edge), [.black, .black, .red, .black])
    }

    /// A screen point maps back to the source pixel under it, through the
    /// drawn rect, the turn and the mirror.
    func testLoupeSourcePointWalksBackTheViewTransform() {
        let size = CGSize(width: 200, height: 100)
        func source(_ p: CGPoint, _ rect: CGRect, _ degrees: Double, _ h: Bool = false) -> CGPoint {
            LoupeView.sourcePoint(forViewPoint: p, drawnRect: rect, imageSize: size,
                                  rotationDegrees: degrees, flippedH: h, flippedV: false)!
        }
        func near(_ a: CGPoint, _ b: CGPoint, _ label: String) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.5, label)
            XCTAssertEqual(a.y, b.y, accuracy: 0.5, label)
        }
        // Drawn at 2x, 50 pt from the left: view (y up) top-left = pixel (0, 0).
        let wide = CGRect(x: 50, y: 20, width: 400, height: 200)
        near(source(CGPoint(x: 50, y: 220), wide, 0), CGPoint(x: 0, y: 0), "top-left")
        near(source(CGPoint(x: 450, y: 20), wide, 0), CGPoint(x: 200, y: 100), "bottom-right")
        near(source(CGPoint(x: 50, y: 220), wide, 0, true), CGPoint(x: 200, y: 0), "mirrored")
        // Turned right: the drawn rect stands up; its top-left is the
        // image's bottom-left, its top-right the image's top-left.
        let tall = CGRect(x: 0, y: 0, width: 100, height: 200)
        near(source(CGPoint(x: 0, y: 200), tall, 90), CGPoint(x: 0, y: 100), "turned right, top-left")
        near(source(CGPoint(x: 100, y: 200), tall, 90), CGPoint(x: 0, y: 0), "turned right, top-right")
        near(source(CGPoint(x: 0, y: 200), tall, 270), CGPoint(x: 200, y: 0), "turned left, top-left")
        XCTAssertNil(LoupeView.sourcePoint(forViewPoint: .zero, drawnRect: .zero, imageSize: size,
                                           rotationDegrees: 0, flippedH: false, flippedV: false))
    }

    /// In a viewer: after Rotate Right the loupe at the image's (turned)
    /// top-left shows the photo's red bottom-left corner, and a mirror
    /// moves it to the bottom-right, as on screen.
    func testLoupeInTheViewerFollowsRotateAndMirror() async throws {
        let a = writeJPEG("a.jpg")   // blue, red bottom-left quarter
        let coordinator = coordinator()
        let viewer = coordinator.openViewer(groups: [ImageGroup(primary: a)], startIndex: 0, services: try services())
        let shown = await firstPhotoShown(viewer)
        XCTAssertTrue(shown)
        let content = viewer.contentRootForTesting
        let imageView = viewer.imageViewForTesting
        content.layoutSubtreeIfNeeded()
        content.setLoupeActive(true)
        defer { content.setLoupeActive(false) }

        func look(_ fx: CGFloat, _ fy: CGFloat) -> Swatch? {
            let r = content.convert(imageView.drawnImageRect, from: imageView)
            content.moveLoupe(to: NSPoint(x: r.minX + fx * r.width, y: r.minY + fy * r.height))
            guard let patch = content.loupeViewForTesting.patchForTesting else { return nil }
            return swatch(pixel(patch, patch.width / 2, patch.height / 2))
        }
        // Upright: red bottom-left, blue top-left.
        XCTAssertEqual(look(0.05, 0.05), .red)
        XCTAssertEqual(look(0.05, 0.95), .blue)

        imageView.rotateBy(degrees: 90)      // Rotate Right (view turn)
        XCTAssertEqual(imageView.rotationDegrees, 90)
        XCTAssertEqual(look(0.05, 0.95), .red, "the red corner is now top-left")
        XCTAssertEqual(look(0.05, 0.05), .blue)
        imageView.rotateBy(degrees: -180)    // Rotate Left twice from there
        XCTAssertEqual(look(0.95, 0.05), .red, "turned left: bottom-right")

        imageView.rotateBy(degrees: 90)      // upright again
        imageView.flipHorizontal()
        XCTAssertEqual(look(0.95, 0.05), .red, "mirrored: bottom-right")
        XCTAssertEqual(look(0.05, 0.05), .blue)
    }
}


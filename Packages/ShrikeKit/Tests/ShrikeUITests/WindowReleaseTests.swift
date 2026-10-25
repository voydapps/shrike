//
//  WindowReleaseTests.swift
//  ShrikeUITests
//
//  Regression: closed viewer windows were
//  never freed. After opening 4 viewers and closing 3, the Release app
//  still held 4 of every viewer object (window, content view, Metal view,
//  CAMetalLayer, decode queue), so each dead window kept its screen
//  buffers ("back to 1 window" 178 MB, full screen 380 MB).
//
//  Each test opens a window the way the app does (the viewer through
//  `WindowCoordinator.openViewer` and `orderFrontWithReadyPhoto`, shown
//  on screen but fully transparent), closes it, turns the run loop and
//  asserts that weak references to the window and its views are nil.
//

import XCTest
import AppKit
import QuartzCore
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class WindowReleaseTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedHistogram = Prefs.viewerHistogramVisible
        savedOverlayAutoHides = Prefs.viewerPositionOverlayAutoHides
    }

    private var savedHistogram = false
    private var savedOverlayAutoHides = false

    override func tearDown() async throws {
        Prefs.viewerHistogramVisible = savedHistogram
        Prefs.viewerPositionOverlayAutoHides = savedOverlayAutoHides
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        return services
    }

    @discardableResult
    private func writeJPEG(_ name: String, width: Int = 1600, height: Int = 1200, gray: CGFloat = 0.4) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A short H.264 movie (9 frames, 64×48): the Live Photo's movie.
    nonisolated private static func writeMovie(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 48,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 48,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<9 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 48, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(20 * i), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    /// Weak references to a viewer and the views that hold its screen
    /// buffers.
    private struct ViewerRefs {
        let window: Weak<ViewerWindow>
        let content: Weak<ViewerContentView>
        let metal: Weak<MetalImageView>
        let layer: Weak<CALayer>
        let queue: Weak<DecodeQueue>

        var objects: [(String, AnyObject)] {
            let all: [(String, AnyObject?)] = [("ViewerWindow", window.value), ("ViewerContentView", content.value),
                                               ("MetalImageView", metal.value), ("DecodeQueue", queue.value)]
            return all.compactMap { name, object in object.map { (name, $0) } }
        }

        var alive: [String] {
            var names: [String] = []
            if window.value != nil { names.append("ViewerWindow") }
            if content.value != nil { names.append("ViewerContentView") }
            if metal.value != nil { names.append("MetalImageView") }
            if layer.value != nil { names.append("CAMetalLayer") }
            if queue.value != nil { names.append("DecodeQueue") }
            return names
        }
    }

    private func refs(_ viewer: ViewerWindow) async -> ViewerRefs {
        let content = viewer.contentRootForTesting
        return ViewerRefs(window: Weak(viewer), content: Weak(content),
                          metal: Weak(content.imageView), layer: Weak(content.imageView.layer),
                          queue: Weak(viewer.navigationForTesting.decodeQueue))
    }

    /// Turns the run loop until nothing in `alive` is left, or `timeout`.
    /// Each turn's own pool is drained; what the test body autoreleased
    /// is drained by the run-loop callout it ran in. The lifetime tests
    /// run through `runWithoutXCTestEventPump`, so no XCTest waiter pool
    /// (which lives for the whole test method) can hold a closed window.
    private func settle(_ timeout: TimeInterval = 12, alive: () -> [String]) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        while !alive().isEmpty, Date() < deadline {
            autoreleasepool { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return alive()
    }

    /// Opens a viewer through the coordinator on `groups`, on screen but
    /// fully transparent, and waits for its photo. The explicit frame
    /// skips the frame autosave (that writes the test runner's defaults).
    private func openViewer(_ coordinator: WindowCoordinator, groups: [ImageGroup],
                            services: ShrikeServices) async throws -> ViewerWindow {
        let viewer = coordinator.openViewer(groups: groups, startIndex: 0, services: services,
                                            frame: NSRect(x: 80, y: 80, width: 900, height: 640))
        viewer.alphaValue = 0
        viewer.ignoresMouseEvents = true
        await viewer.orderFrontWithReadyPhoto()
        let view = viewer.imageViewForTesting
        let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
        XCTAssertTrue(shown, "the photo is on the canvas")
        viewer.contentRootForTesting.layoutSubtreeIfNeeded()
        viewer.displayIfNeeded()
        return viewer
    }

    /// Reads the window's accessibility tree the way an assistive app
    /// does (System Events counting windows and finding the close
    /// button): every element's role, subrole, value, title and children.
    private func walkAccessibility(_ element: Any, depth: Int = 0) {
        guard depth < 14 else { return }
        let e = element as AnyObject
        _ = e.accessibilityRole?()
        _ = e.accessibilitySubrole?()
        _ = (e as? NSView)?.accessibilityValue() ?? (e as? NSAccessibilityElement)?.accessibilityValue()
        _ = e.accessibilityTitle?()
        _ = e.accessibilityLabel?()
        _ = e.accessibilityFrame?()
        _ = e.accessibilityParent?()
        if e.responds(to: NSSelectorFromString("accessibilityIsIgnored")) {
            _ = e.perform(NSSelectorFromString("accessibilityIsIgnored"))   // legacy; the typed call is deprecated
        }
        for child in (e.accessibilityChildren?() ?? nil) ?? [] {
            walkAccessibility(child, depth: depth + 1)
        }
    }

    private func plainGroups(_ count: Int = 3) -> [ImageGroup] {
        (0..<count).map { ImageGroup(primary: writeJPEG("p\($0).jpg", gray: 0.2 + CGFloat($0) * 0.2)) }
    }

    private func assertFreed(_ refs: ViewerRefs, _ coordinator: WindowCoordinator,
                             file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertTrue(coordinator.viewers.isEmpty, "the coordinator dropped the viewer", file: file, line: line)
        let left = await settle { refs.alive }
        if !left.isEmpty { LifetimeDiagnostics.dump(name, alive: refs.objects) }
        XCTAssertEqual(left, [], "a closed viewer must be freed; still alive: \(left)", file: file, line: line)
    }

    // MARK: Viewer

    /// Exercises the actual final close path with a live CAMetalLayer. This
    /// proves a one-pixel command submission while attached, not compositor
    /// display or an idle-RAM improvement.
    func testFinalViewerCloseSubmitsTheReleasedCanvasBeforeOrderingOut() async throws {
        let coordinator = WindowCoordinator()
        let viewer = try await openViewer(coordinator, groups: plainGroups(), services: services())
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        let drew = await waitUntil { view.frameSubmissionsForTesting > 0 }
        XCTAssertTrue(drew, "A real photo drawable must have been submitted before final close")
        XCTAssertTrue(viewer.isVisible)
        XCTAssertTrue(view.window === viewer)
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 0)

        viewer.performClose(nil)

        XCTAssertTrue(viewer.didTearDown)
        XCTAssertFalse(viewer.isVisible)
        XCTAssertTrue(coordinator.viewers.isEmpty)
        XCTAssertEqual(view.releasedCanvasOutcomeForTesting, .submitted,
                       "Final close must retire the drawable before the window becomes invisible")
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1)
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1)
        XCTAssertEqual(view.releasedCanvasTextureSizeForTesting, CGSize(width: 1, height: 1))
        XCTAssertEqual(view.releasedCanvasClearColorForTesting, SIMD4<Double>(0, 0, 0, 1))
        XCTAssertNil(view.image)
        XCTAssertFalse(view.hasTextureForTesting)
        viewer.close()
        XCTAssertEqual(view.releasedCanvasAcquisitionAttemptsForTesting, 1, "Final teardown remains idempotent")
        XCTAssertEqual(view.releasedCanvasSubmissionsForTesting, 1)
    }

    func testFinalCloseDetachesTheGraphicsLayerEvenWhenItsViewIsRetained() throws {
        try runWithoutXCTestEventPump { try await self.finalCloseDetachesTheGraphicsLayerEvenWhenItsViewIsRetained() }
    }
    private func finalCloseDetachesTheGraphicsLayerEvenWhenItsViewIsRetained() async throws {
        let coordinator = WindowCoordinator()
        let viewer = try await openViewer(coordinator, groups: plainGroups(), services: services())
        let retainedView = viewer.imageViewForTesting
        let oldLayer = Weak(retainedView.layer)
        XCTAssertNotNil(oldLayer.value)
        viewer.performClose(nil)
        XCTAssertTrue(viewer.didTearDown)
        XCTAssertTrue(coordinator.viewers.isEmpty)
        XCTAssertNil(retainedView.layer, "A retained closed view must not keep its drawable pool")
        let layerFreed = await waitUntil { oldLayer.value == nil }
        XCTAssertTrue(layerFreed, "The closed view must release both NSView and configured-layer ownership")
        let submissions = retainedView.frameSubmissionsForTesting
        retainedView.image = SaveFlowTests.image()
        retainedView.setFrameSize(NSSize(width: 1200, height: 800))
        retainedView.layoutSubtreeIfNeeded()
        retainedView.viewDidChangeBackingProperties()
        retainedView.needsDisplay = true
        XCTAssertNil(retainedView.image)
        XCTAssertFalse(retainedView.hasTextureForTesting)
        XCTAssertFalse(retainedView.makeBackingLayer() is CAMetalLayer)
        XCTAssertEqual(retainedView.frameSubmissionsForTesting, submissions)
        viewer.close()
    }

    func testViewerIsFreedAfterPerformClose() throws {
        try runWithoutXCTestEventPump { try await self.viewerIsFreedAfterPerformClose() }
    }
    private func viewerIsFreedAfterPerformClose() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            r = await refs(viewer)
            viewer.performClose(nil)
            XCTAssertTrue(viewer.didTearDown, "performClose closed the window")
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    func testViewerIsFreedAfterClose() throws {
        try runWithoutXCTestEventPump { try await self.viewerIsFreedAfterClose() }
    }
    private func viewerIsFreedAfterClose() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            r = await refs(viewer)
            // Navigate once, as a user does, before closing.
            await viewer.navigate(to: 1)
            viewer.close()
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// The panels the user keeps shown (histogram on, the position
    /// overlay kept), several photos visited, then ⌘W.
    func testViewerWithHistogramAndOverlayIsFreed() throws {
        try runWithoutXCTestEventPump { try await self.viewerWithHistogramAndOverlayIsFreed() }
    }
    private func viewerWithHistogramAndOverlayIsFreed() async throws {
        Prefs.viewerHistogramVisible = true
        Prefs.viewerPositionOverlayAutoHides = false
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups(4)
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            XCTAssertTrue(viewer.contentRootForTesting.isHistogramShown, "the histogram is shown")
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: viewer)
            NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: viewer)
            await viewer.navigate(to: 1)
            await viewer.navigate(to: 2)
            try? await Task.sleep(nanoseconds: 300_000_000)
            r = await refs(viewer)
            viewer.performClose(nil)
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// Full-screen chrome built (the HUD glass container and
    /// every HUD in it), then the window closes.
    func testViewerWithFullScreenChromeIsFreed() throws {
        try runWithoutXCTestEventPump { try await self.viewerWithFullScreenChromeIsFreed() }
    }
    private func viewerWithFullScreenChromeIsFreed() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            let content = viewer.contentRootForTesting
            content.animatesPanelFades = false
            content.windowMode = .fullscreen
            content.togglePanel(.filmstrip)
            content.togglePanel(.inspector)
            _ = content.histogramOverlayFrameForTesting()
            content.layoutSubtreeIfNeeded()
            viewer.displayIfNeeded()
            if #available(macOS 26, *) {
                XCTAssertNotNil(content.glassContainerForTesting, "the glass container is built")
            }
            content.windowMode = .windowed
            content.layoutSubtreeIfNeeded()
            r = await refs(viewer)
            viewer.performClose(nil)
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// Edit mode entered and left, then the window closes.
    func testViewerIsFreedAfterEditMode() throws {
        try runWithoutXCTestEventPump { try await self.viewerIsFreedAfterEditMode() }
    }
    private func viewerIsFreedAfterEditMode() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            let canEdit = await waitUntil { viewer.canPerform(.editImage) }
            XCTAssertTrue(canEdit, "The accepted photo enables editing before entering the session")
            viewer.enterEditMode(landOn: .crop)
            await viewer.waitForEditLoad()
            XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
            viewer.exitEditMode(nil)
            let left = await waitUntil(5) { !viewer.contentRootForTesting.isEditModeActive }
            XCTAssertTrue(left, "edit mode was left")
            r = await refs(viewer)
            viewer.performClose(nil)
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// A Live Photo on screen (the LIVE badge shown, played once).
    func testLivePhotoViewerIsFreed() throws {
        try runWithoutXCTestEventPump { try await self.livePhotoViewerIsFreed() }
    }
    private func livePhotoViewerIsFreed() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let still = writeJPEG("live.jpg", width: 1200, height: 1600)
        let mov = dir.appendingPathComponent("live.mov")
        try Self.writeMovie(to: mov)
        let groups = [ImageGroup(primary: still, companions: [.init(url: mov, kind: .livePhotoMovie)]),
                      ImageGroup(primary: writeJPEG("plain.jpg"))]
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            let content = viewer.contentRootForTesting
            let badge = content.livePhotoBadgeForTesting
            XCTAssertFalse(badge.isHidden, "the LIVE badge is shown")
            badge.requestPlay(withSound: false, fromHover: false)
            let playing = await waitUntil(5) { content.livePhotoPlayback?.player != nil }
            XCTAssertTrue(playing, "a player was made")
            r = await refs(viewer)
            viewer.performClose(nil)
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// The app's own open path (Finder / `open -a`): the early decode
    /// handed over to the new viewer, the folder scan, the window up
    /// with its photo, a second viewer cascaded from it; one is closed.
    func testViewerOpenedLikeFinderIsFreed() throws {
        try runWithoutXCTestEventPump { try await self.viewerOpenedLikeFinderIsFreed() }
    }
    private func viewerOpenedLikeFinderIsFreed() async throws {
        Prefs.viewerHistogramVisible = true
        let coordinator = WindowCoordinator()
        coordinator.standaloneFrameForTesting = NSRect(x: 80, y: 80, width: 900, height: 640)
        coordinator.onWindowOpened = { [weak coordinator] in
            coordinator?.viewers.last?.alphaValue = 0
            coordinator?.viewers.last?.ignoresMouseEvents = true
        }
        let services = try services()
        let groups = plainGroups(4)
        var r: ViewerRefs?
        do {
            coordinator.open([groups[0].primary], services: services, noteRecent: false)
            let first = await waitUntil { coordinator.viewers.count == 1 && coordinator.pendingOpens == 0 }
            XCTAssertTrue(first)
            coordinator.open([groups[2].primary], services: services, noteRecent: false)
            let second = await waitUntil { coordinator.viewers.count == 2 && coordinator.pendingOpens == 0 }
            XCTAssertTrue(second)
            let viewer = try XCTUnwrap(coordinator.viewers.first)
            let view = viewer.imageViewForTesting
            let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
            XCTAssertTrue(shown)
            try? await Task.sleep(nanoseconds: 300_000_000)
            r = await refs(viewer)
            viewer.performClose(nil)
        }
        let rr = try XCTUnwrap(r)
        XCTAssertEqual(coordinator.viewers.count, 1)
        let left = await settle { rr.alive }
        if !left.isEmpty { LifetimeDiagnostics.dump(name, alive: rr.objects) }
        XCTAssertEqual(left, [], "a closed viewer must be freed; still alive: \(left)")
        coordinator.viewers.last?.close()
    }

    /// Closed through accessibility, the way a screen reader or automation
    /// closes windows: the tree is read, then the close button is pressed.
    func testViewerIsFreedAfterAccessibilityClose() throws {
        try runWithoutXCTestEventPump { try await self.viewerIsFreedAfterAccessibilityClose() }
    }
    private func viewerIsFreedAfterAccessibilityClose() async throws {
        Prefs.viewerHistogramVisible = true
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            walkAccessibility(NSApp as Any)
            walkAccessibility(viewer)
            r = await refs(viewer)
            let close = try XCTUnwrap(viewer.standardWindowButton(.closeButton))
            _ = close.accessibilityPerformPress()
            if !viewer.didTearDown { viewer.performClose(nil) }
            XCTAssertTrue(viewer.didTearDown, "the close button closed the window")
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// Window-server events reach the viewer through `NSApp.sendEvent`,
    /// which autoreleases the window. On the release-gate runner XCTest
    /// sent such events from its own wait, in a pool that lived for the
    /// whole test, and closed viewers looked leaked. Through the app's
    /// own event path (one pool per event) the window must still be freed.
    func testViewerIsFreedAfterWindowServerEvents() throws {
        try runWithoutXCTestEventPump { try await self.viewerIsFreedAfterWindowServerEvents() }
    }
    private func viewerIsFreedAfterWindowServerEvents() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let groups = plainGroups()
        var r: ViewerRefs?
        do {
            let viewer = try await openViewer(coordinator, groups: groups, services: services)
            r = await refs(viewer)
            for subtype in [NSEvent.EventSubtype.windowExposed, .windowMoved] {
                let event = try XCTUnwrap(NSEvent.otherEvent(with: .appKitDefined, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: viewer.windowNumber, context: nil, subtype: subtype.rawValue, data1: 0, data2: 0))
                autoreleasepool { NSApp.sendEvent(event) }
            }
            viewer.performClose(nil)
        }
        await assertFreed(try XCTUnwrap(r), coordinator)
    }

    /// The real leak. The titlebar auto-hider owns a tracking area on
    /// the canvas, but its callbacks were exposed as `mouseEnteredWith:` /
    /// `mouseExitedWith:`. The first time the pointer crossed the canvas
    /// edge (a click on the close button, a window closing under the
    /// pointer), AppKit sent `mouseEntered:` / `mouseExited:`, hit
    /// "unrecognized selector", caught the exception in `sendEvent` and
    /// leaked the event and the window. Every tracking area in a viewer
    /// must have an owner that answers the messages its options send.
    func testEveryViewerTrackingAreaOwnerAnswersItsMessages() async throws {
        let coordinator = WindowCoordinator()
        let services = try services()
        let viewer = try await openViewer(coordinator, groups: plainGroups(), services: services)
        var areas: [NSTrackingArea] = []
        func collect(_ view: NSView) {
            areas += view.trackingAreas
            view.subviews.forEach(collect)
        }
        collect(try XCTUnwrap(viewer.contentView?.superview ?? viewer.contentView))
        let hider = try XCTUnwrap(viewer.autoHider)
        XCTAssertTrue(areas.contains { $0.owner === hider }, "the auto-hider's canvas area is installed")
        for area in areas {
            guard let owner = area.owner as? NSObject else { continue }
            var needed: [String] = []
            if area.options.contains(.mouseEnteredAndExited) { needed += ["mouseEntered:", "mouseExited:"] }
            if area.options.contains(.mouseMoved) { needed.append("mouseMoved:") }
            if area.options.contains(.cursorUpdate) { needed.append("cursorUpdate:") }
            for name in needed {
                XCTAssertTrue(owner.responds(to: NSSelectorFromString(name)),
                              "\(type(of: owner)) owns a tracking area but does not answer \(name)")
            }
        }
        viewer.close()
    }

    // MARK: Browser and Compare

    func testBrowserIsFreedAfterClose() throws {
        try runWithoutXCTestEventPump { try await self.browserIsFreedAfterClose() }
    }
    private func browserIsFreedAfterClose() async throws {
        _ = plainGroups()
        let services = try services()
        let window = Weak<NSWindow>(nil)
        let controller = Weak<BrowserWindowController>(nil)
        do {
            let browser = BrowserWindowController(services: services, initialFolder: dir)
            controller.value = browser
            window.value = browser.window
            let listed = await waitUntil { browser.contentController.visibleItems.count == 3 }
            XCTAssertTrue(listed, "the folder is listed")
            browser.window?.performClose(nil)
        }
        let left = await settle {
            (controller.value == nil ? [] : ["BrowserWindowController"])
                + (window.value == nil ? [] : ["window"])
        }
        XCTAssertEqual(left, [], "a closed Browser must be freed; still alive: \(left)")
    }

    func testCompareWindowIsFreedAfterClose() throws {
        try runWithoutXCTestEventPump { try await self.compareWindowIsFreedAfterClose() }
    }
    private func compareWindowIsFreedAfterClose() async throws {
        let groups = plainGroups()
        var services = try services()
        services.backupStore = nil
        let window = Weak<CompareWindow>(nil)
        let pane = Weak<MetalImageView>(nil)
        do {
            let compare = CompareWindow.open(CompareRequest(list: groups, shown: [0, 1], truncated: false),
                                             services: services, origin: nil,
                                             frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
            window.value = compare
            // A shown window closes with the system fade animation, and
            // AppKit keeps the window alive until that animation has run.
            // Under load it can outlast the wait below, so (as for the
            // viewers in this file) the window is fully transparent and
            // has no close animation.
            compare.alphaValue = 0
            compare.ignoresMouseEvents = true
            compare.animationBehavior = .none
            pane.value = compare.panes.first?.view.imageView
            let loaded = await waitUntil { compare.panes.allSatisfy { $0.view.imageView.image != nil } }
            XCTAssertTrue(loaded)
            compare.performClose(nil)
            XCTAssertTrue(compare.isClosedForTesting)
        }
        XCTAssertNil(CompareWindow.current)
        let left = await settle {
            (window.value == nil ? [] : ["CompareWindow"])
                + (pane.value == nil ? [] : ["pane MetalImageView"])
        }
        XCTAssertEqual(left, [], "a closed Compare window must be freed; still alive: \(left)")
    }
}

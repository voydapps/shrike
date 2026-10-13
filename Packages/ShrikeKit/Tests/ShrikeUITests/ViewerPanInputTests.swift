//
//  ViewerPanInputTests.swift
//  ShrikeUITests
//
//  Pan while zoomed in, and the window-move strip (drop back). Events go
//  through `window.sendEvent`
//  of an offscreen viewer, never straight to the canvas, so a view that
//  swallows them is caught (a trackpad test: a
//  two-finger slide did not move a zoomed photo).
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
final class ViewerPanInputTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false
    private var savedAutoHide = false
    private var savedFilmstrip = false
    private var savedWheel = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-pan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedAutoHide = Prefs.viewerToolbarAutoHide
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        Prefs.viewerInspectorVisibleWindowed = false
        // These tests must not read the machine's trackpad / wheel settings.
        savedWheel = Prefs.scrollWheelNavigates
        Prefs.scrollWheelNavigates = true
        MetalImageView.swipeEnabledOverrideForTesting = true
        MetalImageView.reduceMotionOverrideForTesting = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        Prefs.viewerToolbarAutoHide = savedAutoHide
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
        MetalImageView.reduceMotionOverrideForTesting = nil
        MetalImageView.swipeEnabledOverrideForTesting = nil
        Prefs.scrollWheelNavigates = savedWheel
    }

    // MARK: Helpers

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String, width: Int = 4000, height: Int = 3000) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }

    /// An 800 × 600 offscreen viewer with a 4000 × 3000 photo on screen.
    private func makeViewer(count: Int = 1) async throws -> ViewerWindow {
        let urls = try (0..<count).map { try writeJPEG("p\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 0, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = window.imageViewForTesting
        // The file's pixel size is read off the main thread after the window
        // opens. "100 %" (double-click zoom) is computed from it, so a test
        // that zooms before it lands gets 1 texel per point on the small
        // display texture, which has no pan slack (the flaky
        // testSlideRightAfterDoubleClickZoomPans).
        let shown = await waitUntil {
            view.image != nil && !view.isCurrentImagePlaceholder && view.sourcePixelSize != nil
        }
        XCTAssertTrue(shown, "photo (and its pixel size) never reached the canvas")
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func canvasCentreInWindow(_ window: ViewerWindow) -> NSPoint {
        let view = window.imageViewForTesting
        return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// Synthetic scroll event, bound to `window`.
    private func scrollEvent(_ window: ViewerWindow, dx: Int32, dy: Int32,
                             phase: Int64 = 0, momentum: Int64 = 0,
                             at pointInWindow: NSPoint? = nil) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                               wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return nil }
        // A CGEvent starts with the machine's live modifier state (a held
        // or stuck Command turns every scroll into a zoom), so clear it.
        cg.flags = []
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        let p = pointInWindow ?? canvasCentreInWindow(window)
        let screen = window.convertPoint(toScreen: p)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                value: Int64(window.windowNumber))
        return NSEvent(cgEvent: cg)
    }

    /// Delivers a scroll event the way `NSWindow` does. When
    /// `NSEvent(cgEvent:)` cannot bind an offscreen window (it can't on
    /// this OS: the window server does not know the window), the event
    /// goes to the view the window's frame view hit-tests at the event's
    /// point, exactly as `NSWindow.sendEvent` would route it — never
    /// straight to the canvas.
    private func send(_ window: ViewerWindow, _ event: NSEvent?, file: StaticString = #filePath, line: UInt = #line) {
        guard let event else { return XCTFail("no event", file: file, line: line) }
        XCTAssertTrue(event.hasPreciseScrollingDeltas, file: file, line: line)
        if event.window === window {
            window.sendEvent(event)
            return
        }
        guard let frameView = window.contentView?.superview else {
            return XCTFail("no frame view", file: file, line: line)
        }
        let p = scrollPointInWindow(window, event)
        let inFrameSuper = frameView.superview.map { $0.convert(p, from: nil) }
            ?? frameView.convert(p, from: nil)
        guard let hit = frameView.hitTest(inFrameSuper) else {
            return XCTFail("nothing under the pointer", file: file, line: line)
        }
        lastScrollTarget = hit
        hit.scrollWheel(with: event)
    }

    private var lastScrollTarget: NSView?

    /// The event's point in window coordinates (from its global location).
    private func scrollPointInWindow(_ window: ViewerWindow, _ event: NSEvent) -> NSPoint {
        guard let cg = event.cgEvent else { return .zero }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let screen = NSPoint(x: cg.location.x, y: primaryHeight - cg.location.y)
        return window.convertPoint(fromScreen: screen)
    }

    private func mouse(_ window: ViewerWindow, _ type: NSEvent.EventType, at p: NSPoint,
                       clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: flags,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clicks, pressure: 1)!
    }

    /// Delivers a mouse event like `NSWindow` does for a key window. An
    /// offscreen window can't become key, and `sendEvent` would treat the
    /// click as the activating first click, so the event goes to the view
    /// under the pointer (drags and ups to the view that got the down).
    private func deliverMouse(_ window: ViewerWindow, _ event: NSEvent) {
        if window.isKeyWindow { window.sendEvent(event); return }
        switch event.type {
        case .leftMouseDown:
            guard let frameView = window.contentView?.superview else { return }
            let p = frameView.superview.map { $0.convert(event.locationInWindow, from: nil) }
                ?? frameView.convert(event.locationInWindow, from: nil)
            mouseTarget = frameView.hitTest(p)
            mouseTarget?.mouseDown(with: event)
        case .leftMouseDragged: mouseTarget?.mouseDragged(with: event)
        case .leftMouseUp:
            mouseTarget?.mouseUp(with: event)
            mouseTarget = nil
        default: window.sendEvent(event)
        }
    }

    private var mouseTarget: NSView?

    /// Slack of the clamp on x (view points).
    private func slackX(_ view: MetalImageView) -> CGFloat {
        (view.displayedImageSizeForTesting.width - view.bounds.width) / 2
    }

    // MARK: Pan direction

    func testTrackpadPanFollowsSystemDeltas() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)
        XCTAssertFalse(view.isAtFit)
        XCTAssertEqual(view.pan, .zero)

        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 1))
        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 2))
        XCTAssertEqual(view.pan.x, -80, accuracy: 0.5, "fingers left: the image moves left")
        send(window, scrollEvent(window, dx: 0, dy: 30, phase: 2))
        XCTAssertEqual(view.pan.y, -30, accuracy: 0.5)
        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 4))
        XCTAssertEqual(view.pan.x, -80, accuracy: 0.5)
        XCTAssertEqual(view.pan.y, -30, accuracy: 0.5)
    }

    func testTrackpadAtFitStartsSwipeNotPan() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        XCTAssertTrue(view.isAtFit)
        var began = 0
        view.swipeTrackerForTesting = { _ in began += 1 }
        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 1))
        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 2))
        XCTAssertEqual(view.pan, .zero, "never pans at Fit")
        // The swipe setting is forced on in setUp, not read from the machine.
        XCTAssertEqual(began, 1)
    }

    // MARK: Pan edge

    func testTrackpadRubberBandAndSpringBack() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)
        let slack = slackX(view)
        XCTAssertGreaterThan(slack, 0)
        // Fingers right (dx > 0) move the image right, toward its left edge
        // (pan.x = +slack is the clamp).
        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 1))
        var sent: CGFloat = 0
        while sent < slack {
            let step = min(50, slack - sent)
            send(window, scrollEvent(window, dx: Int32(step.rounded(.up)), dy: 0, phase: 2))
            sent += step.rounded(.up)
        }
        let atClamp = view.pan.x
        XCTAssertEqual(atClamp, slack, accuracy: 1)
        let over = sent - slack
        for _ in 0..<4 { send(window, scrollEvent(window, dx: 25, dy: 0, phase: 2)) }
        let x = over + 100
        let d = view.bounds.width
        let expected = slack + d * (1 - 1 / (x * 0.55 / d + 1))
        XCTAssertEqual(view.pan.x, expected, accuracy: 0.5, "rubber band past the clamp")

        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 4))
        XCTAssertGreaterThan(view.pan.x, slack + 1, "springs back over time, not at once")
        let back = await waitUntil(1) { abs(view.pan.x - slack) < 0.01 }
        XCTAssertTrue(back, "back at the clamp after 200 ms")
    }

    func testRubberBandReturnIsInstantUnderReduceMotion() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        MetalImageView.reduceMotionOverrideForTesting = true
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)
        let slack = slackX(view)
        view.pan = CGPoint(x: slack, y: 0)
        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 1))
        send(window, scrollEvent(window, dx: 100, dy: 0, phase: 2))
        XCTAssertGreaterThan(view.pan.x, slack)
        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 4))
        XCTAssertEqual(view.pan.x, slack, accuracy: 0.01, "same pass under Reduce Motion")
    }

    func testMomentumStopsHardAtTheClamp() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)
        let slack = slackX(view)
        view.pan = CGPoint(x: slack - 50, y: 0)
        send(window, scrollEvent(window, dx: 0, dy: 0, phase: 4))
        send(window, scrollEvent(window, dx: 100, dy: 0, momentum: 1))
        send(window, scrollEvent(window, dx: 100, dy: 0, momentum: 2))
        send(window, scrollEvent(window, dx: 100, dy: 0, momentum: 2))
        XCTAssertEqual(view.pan.x, slack, accuracy: 0.01, "hard stop, no bounce")
        send(window, scrollEvent(window, dx: -100, dy: 0, momentum: 2))
        XCTAssertEqual(view.pan.x, slack, accuracy: 0.01, "rest of that momentum is dropped")
        send(window, scrollEvent(window, dx: 0, dy: 0, momentum: 3))
    }

    // MARK: Mouse-drag pan

    func testMouseDragPansOneToOneAndStopsHard() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)
        var sessions = 0
        view.beginFileDragForTesting = { sessions += 1 }
        let c = canvasCentreInWindow(window)
        deliverMouse(window, mouse(window, .leftMouseDown, at: c))
        deliverMouse(window, mouse(window, .leftMouseDragged, at: NSPoint(x: c.x + 30, y: c.y)))
        deliverMouse(window, mouse(window, .leftMouseUp, at: NSPoint(x: c.x + 30, y: c.y)))
        XCTAssertEqual(view.pan.x, 30, accuracy: 0.5, "the image follows the pointer")
        XCTAssertEqual(sessions, 0)

        let slack = slackX(view)
        deliverMouse(window, mouse(window, .leftMouseDown, at: c))
        deliverMouse(window, mouse(window, .leftMouseDragged, at: NSPoint(x: c.x + slack + 200, y: c.y)))
        XCTAssertEqual(view.pan.x, slack, accuracy: 0.01, "hard stop at the clamp")
        deliverMouse(window, mouse(window, .leftMouseUp, at: NSPoint(x: c.x + slack + 200, y: c.y)))
    }

    // Root cause of the user's bug: input during the 200 ms double-click
    // zoom animation used to abandon it half-done (zoomed, but still in
    // fit mode), so the slide was treated as "at Fit" and never panned.
    func testSlideRightAfterDoubleClickZoomPans() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        XCTAssertTrue(view.isAtFit)
        let c = canvasCentreInWindow(window)
        deliverMouse(window, mouse(window, .leftMouseDown, at: c, clicks: 1))
        deliverMouse(window, mouse(window, .leftMouseUp, at: c, clicks: 1))
        deliverMouse(window, mouse(window, .leftMouseDown, at: c, clicks: 2))
        deliverMouse(window, mouse(window, .leftMouseUp, at: c, clicks: 2))
        // The slide starts at once, while the zoom animation still runs.
        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 1))
        XCTAssertFalse(view.isAtFit, "a slide during the zoom animation lands on the zoomed state")
        send(window, scrollEvent(window, dx: -40, dy: 0, phase: 2))
        XCTAssertEqual(view.pan.x, -80, accuracy: 0.5, "the slide pans")
        window.contentView?.layoutSubtreeIfNeeded()
        view.layout()
        XCTAssertFalse(view.isAtFit, "a layout pass does not snap back to Fit")
        XCTAssertEqual(view.pan.x, -80, accuracy: 0.5)
    }

    // MARK: Window-move strip, drop back

    private func stripPoint(_ window: ViewerWindow, x: CGFloat? = nil) -> NSPoint {
        NSPoint(x: x ?? window.contentLayoutRect.midX, y: window.contentLayoutRect.maxY + 10)
    }

    func testStripRevealShowsHiddenTitlebar() async throws {
        Prefs.viewerToolbarAutoHide = true
        let window = try await makeViewer()
        defer { window.close() }
        let hider = try XCTUnwrap(window.autoHider)
        guard let container = hider.container else {
            throw XCTSkip("titlebar container not found on this OS (auto-hide is off)")
        }
        let maxYShown = window.contentLayoutRect.maxY
        hider.hideForTesting()
        XCTAssertTrue(container.isHidden)
        // The strip does not change size when the titlebar hides.
        XCTAssertEqual(window.contentLayoutRect.maxY, maxYShown)

        let below = mouse(window, .leftMouseDown, at: NSPoint(x: window.contentLayoutRect.midX,
                                                              y: window.contentLayoutRect.maxY - 10))
        XCTAssertFalse(window.revealTitlebarIfStripMouseDown(below))
        XCTAssertTrue(container.isHidden, "a canvas click changes nothing")

        XCTAssertTrue(window.revealTitlebarIfStripMouseDown(mouse(window, .leftMouseDown, at: stripPoint(window))))
        XCTAssertFalse(container.isHidden)
        XCTAssertEqual(container.alphaValue, 1)
    }

    func testStripSafetyNetMovesWindowNeverDrags() async throws {
        Prefs.viewerToolbarAutoHide = true
        let window = try await makeViewer()
        defer { window.close() }
        window.stripRevealEnabled = false
        window.autoHider?.hideForTesting()
        let view = window.imageViewForTesting
        var actions: [MetalImageView.WindowStripAction] = []
        view.windowStripActionHandler = { action, _ in actions.append(action) }
        var sessions = 0
        view.beginFileDragForTesting = { sessions += 1 }
        let zoomBefore = view.pixelScale

        // A strip point where the canvas is what the window hit-tests.
        guard let frameView = window.contentView?.superview else { return XCTFail() }
        let candidates = stride(from: 0.3, through: 0.7, by: 0.1).map {
            stripPoint(window, x: window.contentLayoutRect.width * $0)
        }
        let p = candidates.first { pt in
            let q = frameView.superview.map { $0.convert(pt, from: nil) } ?? pt
            return frameView.hitTest(q) === view
        }
        let point = try XCTUnwrap(p, "the canvas reaches under the hidden titlebar")

        deliverMouse(window, mouse(window, .leftMouseDown, at: point))
        deliverMouse(window, mouse(window, .leftMouseDragged, at: NSPoint(x: point.x + 40, y: point.y)))
        deliverMouse(window, mouse(window, .leftMouseUp, at: NSPoint(x: point.x + 40, y: point.y)))
        XCTAssertEqual(actions, [.move])
        XCTAssertEqual(sessions, 0, "no file drag from the strip")
        XCTAssertEqual(view.pan, .zero, "no pan from the strip")

        actions = []
        view.doubleClickActionOverrideForTesting = .some("Minimize")
        deliverMouse(window, mouse(window, .leftMouseDown, at: point, clicks: 2))
        XCTAssertEqual(actions, [.minimize])
        view.doubleClickActionOverrideForTesting = .some(nil)
        deliverMouse(window, mouse(window, .leftMouseDown, at: point, clicks: 2))
        XCTAssertEqual(actions, [.minimize, .zoom], "missing pref → zoom(nil)")
        view.doubleClickActionOverrideForTesting = .some("None")
        deliverMouse(window, mouse(window, .leftMouseDown, at: point, clicks: 2))
        XCTAssertEqual(actions, [.minimize, .zoom, .none])
        XCTAssertEqual(view.pixelScale, zoomBefore, accuracy: 0.0001, "never the canvas zoom toggle")
    }

    func testCanvasDropBackOffersNothingInsideShrike() async throws {
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        let session = NSDraggingSession()
        XCTAssertEqual(view.draggingSession(session, sourceOperationMaskFor: .withinApplication), [])
        XCTAssertEqual(view.draggingSession(session, sourceOperationMaskFor: .outsideApplication), [.copy])
    }

    // MARK: Nothing covers the canvas

    func testNothingCoversTheCanvasCentre() async throws {
        Prefs.filmstripVisibleInWindowed = true
        Prefs.viewerToolbarAutoHide = true
        let window = try await makeViewer()
        defer { window.close() }
        let view = window.imageViewForTesting
        view.setPixelScale(2.0, anchor: nil)   // the zoom badge shows

        func hit() -> NSView? {
            guard let content = window.contentView else { return nil }
            let p = content.convert(canvasCentreInWindow(window), from: nil)
            let inSuper = content.superview.map { content.convert(p, to: $0) } ?? p
            return content.hitTest(inSuper)
        }
        XCTAssertTrue(hit() === view, "toolbar shown: \(String(describing: hit()))")
        window.autoHider?.hideForTesting()
        XCTAssertTrue(hit() === view, "toolbar hidden: \(String(describing: hit()))")
        window.dispatch(.toggleInspector)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(hit() === view, "inspector shown: \(String(describing: hit()))")
    }
}

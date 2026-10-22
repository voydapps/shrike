//
//  LivePhotoPlaybackTests.swift
//  ShrikeUITests
//
//  The LIVE badge plays the photo's movie over the still
//  (hover 300 ms, click, VoiceOver), once, muted, then fades back. It
//  stops on a key, on navigation and when the pointer leaves the photo;
//  it plays only at fit. An
//  offscreen viewer and a tiny movie written into a temp folder.
//

import AppKit
import AVFoundation
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
final class LivePhotoPlaybackTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    // MARK: Fixtures

    /// 1200×1600 portrait: fit is well below 100 % (so 200 % is truly
    /// zoomed in), and the 800×600 canvas has room beside the photo.
    private func writeJPEG(_ name: String, width: Int = 1200, height: Int = 1600) -> URL {
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

    /// A short H.264 movie (`frames` at 30 fps, 64×48). Keep the fixture
    /// long enough for playback-state assertions on slower hosted runners.
    nonisolated private static func writeMovie(to url: URL, frames: Int = 60) throws {
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
        for i in 0..<frames {
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

    private var viewers: [ViewerWindow] = []

    /// A viewer on a Live Photo (`live.jpg` + `live.mov`) and a plain photo.
    private func viewer(movie: Bool = true, brokenMovie: Bool = false,
                        still size: (width: Int, height: Int) = (1200, 1600),
                        contentSize: NSSize = NSSize(width: 800, height: 600)) async throws -> ViewerWindow {
        let still = writeJPEG("live.jpg", width: size.width, height: size.height)
        let plain = writeJPEG("plain.jpg")
        let mov = dir.appendingPathComponent("live.mov")
        if brokenMovie {
            try Data("not a movie".utf8).write(to: mov)
        } else if movie {
            try Self.writeMovie(to: mov)
            let asset = AVURLAsset(url: mov)
            guard try await asset.load(.isPlayable),
                  !(try await asset.loadTracks(withMediaType: .video)).isEmpty else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: mov])
            }
        }
        let first = ImageGroup(primary: still, companions: movie || brokenMovie
                               ? [.init(url: mov, kind: .livePhotoMovie)] : [])
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [first, ImageGroup(primary: plain)], startIndex: 0, services: services)
        viewers.append(viewer)
        viewer.setContentSize(contentSize)
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.displayedItem?.listIndex == 0
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        content.layoutSubtreeIfNeeded()
        return viewer
    }

    override func tearDown() async throws {
        for v in viewers { v.close() }
        viewers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func reached(within seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    private func state(_ content: ViewerContentView) -> LivePhotoPlayback.State {
        content.livePhotoPlayback?.state ?? .idle
    }

    private func waitUntilPlaying(_ content: ViewerContentView, label: String = "playing") async throws {
        try await waitUntil(label, timeout: 8) {
            self.state(content) == .playing || content.livePhotoPlayback?.loadFailure != nil
        }
        XCTAssertNil(content.livePhotoPlayback?.loadFailure,
                     "Live Photo asset loading failed: \(content.livePhotoPlayback?.loadFailure ?? "unknown error")")
        XCTAssertEqual(state(content), .playing, label)
    }

    // MARK: The badge

    func testBadgeIsAButtonAndNoPlayerIsMadeBeforeTheFirstPlay() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        XCTAssertFalse(badge.isHidden, "the group has a movie")
        XCTAssertFalse(badge.isDimmed)
        XCTAssertEqual(badge.toolTip, "Live Photo — hover to play")
        XCTAssertEqual(badge.accessibilityRole(), .button)
        XCTAssertEqual(badge.accessibilityCustomActions()?.map(\.name), ["Play Live Photo"])
        XCTAssertNil(content.livePhotoPlayback, "no player before the first play")

        // The plain photo has no movie: no badge.
        viewer.markDisplayedForTesting(1)
        XCTAssertTrue(badge.isHidden)
    }

    /// The badge sits below the titlebar, with the
    /// viewer toolbar hidden (the user's setting) and shown.
    func testBadgeSitsBelowTheTitlebarWithTheToolbarHiddenAndShown() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        let wasShown = viewer.toolbar?.isVisible ?? false
        defer { viewer.toolbar?.isVisible = wasShown }
        for shown in [false, true] {
            viewer.toolbar?.isVisible = shown
            content.layoutSubtreeIfNeeded()
            let chromeHeight = viewer.frame.height - viewer.contentLayoutRect.height
            XCTAssertGreaterThan(chromeHeight, 20, "a titlebar is there (toolbar shown: \(shown))")
            let inWindow = badge.convert(badge.bounds, to: nil)
            XCTAssertLessThanOrEqual(inWindow.maxY, viewer.contentLayoutRect.maxY - ViewerContentView.liveBadgeChromeGap + 0.5,
                                     "badge below the titlebar/toolbar (toolbar shown: \(shown))")
            // At the photo's left edge (the portrait photo
            // leaves a band on each side), not the window's.
            let photo = content.convert(content.imageView.drawnImageRect, from: content.imageView)
            XCTAssertEqual(badge.frame.minX, photo.minX + ViewerContentView.liveBadgeInset, accuracy: 1)
            XCTAssertGreaterThan(badge.frame.minX, 100, "on the photo, not on the side band")
            // The hover area is the badge itself: its centre hits it.
            let host = try XCTUnwrap(content.superview)
            let centre = host.convert(NSPoint(x: badge.bounds.midX, y: badge.bounds.midY), from: badge)
            XCTAssertTrue(content.hitTest(centre)?.isDescendant(of: badge) ?? false,
                          "the badge is hit where it is drawn (toolbar shown: \(shown))")
        }
    }

    // MARK: Hover 300 ms: plays muted, then back to the still

    func testVector1_HoverPlaysMutedOnceThenReturnsToTheStill() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        badge.beginHover()
        XCTAssertTrue(badge.isHoverPending)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertNil(content.livePhotoPlayback, "nothing before 300 ms")

        try await waitUntilPlaying(content)
        let playback = try XCTUnwrap(content.livePhotoPlayback)
        XCTAssertEqual(playback.isMuted, true, "muted by default")
        let movieView = try XCTUnwrap(playback.movieView)
        let subviews = content.subviews
        XCTAssertEqual(subviews.firstIndex(of: movieView), subviews.firstIndex(of: content.imageView).map { $0 + 1 },
                       "just above the Metal view")
        let drawn = content.imageView.convert(content.imageView.drawnImageRect, to: content)
        XCTAssertEqual(movieView.frame, drawn, "framed to the photo")
        XCTAssertFalse(movieView.isHidden)

        try await waitUntil("fade to the still", timeout: 6) { self.state(content) == .idle }
        XCTAssertTrue(movieView.isHidden, "the still shows again")
        XCTAssertEqual(movieView.alphaValue, 0)
        XCTAssertFalse(badge.isHidden)
    }

    func testOptionClickPlaysWithSoundAndTheVoiceOverActionPlays() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        XCTAssertTrue(badge.requestPlay(withSound: true, fromHover: false))
        try await waitUntil("playing") { self.state(content) == .playing }
        XCTAssertEqual(content.livePhotoPlayback?.isMuted, false, "⌥-click plays with sound")
        content.stopLivePhoto()
        XCTAssertEqual(state(content), .idle)

        let action = try XCTUnwrap(badge.accessibilityCustomActions()?.first)
        XCTAssertTrue(action.handler?() ?? false)
        try await waitUntil("playing again") { self.state(content) == .playing }
        XCTAssertEqual(content.livePhotoPlayback?.isMuted, true)
    }

    // MARK: → during playback

    func testVector2_ArrowKeyDuringPlaybackShowsTheNextPhotoAndNothingPlays() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
        let player = try XCTUnwrap(content.livePhotoPlayback?.player)

        let right = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: viewer.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        viewer.sendEvent(right)
        XCTAssertEqual(state(content), .idle, "any key stops at once")
        XCTAssertEqual(player.rate, 0)
        if !(await reached(within: 2) { viewer.displayedItem?.listIndex == 1 }) {
            // An offscreen window may not route the key to the viewer;
            // drive the same key path directly.
            _ = viewer.handleKeySnapshot(KeyEventSnapshot(key: "\u{F703}", keyCode: 124))
        }
        try await waitUntil("next photo") { viewer.displayedItem?.listIndex == 1 }
        XCTAssertNil(content.livePhotoPlayback, "navigation frees the player")
        XCTAssertEqual(player.rate, 0, "nothing keeps playing")
        XCTAssertNil(player.currentItem)
        XCTAssertTrue(content.livePhotoBadgeForTesting.isHidden, "the next photo has no movie")
        XCTAssertFalse(content.subviews.contains { $0 is LivePhotoMovieView })
    }

    // MARK: Zoomed to 200 %

    func testVector3_ZoomedInHoverDoesNothing() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        content.imageView.setPixelScale(2.0, anchor: nil)
        XCTAssertFalse(content.imageView.isAtFit)
        XCTAssertTrue(badge.isDimmed)
        XCTAssertEqual(badge.toolTip, "Zoom to fit to play")
        XCTAssertLessThan(badge.alphaValue, 1)

        badge.beginHover()
        XCTAssertFalse(badge.isHoverPending, "no hover timer when dimmed")
        content.playLivePhoto(withSound: false, fromHover: true)
        XCTAssertFalse(badge.requestPlay(withSound: false, fromHover: false), "a click does nothing either")
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(content.livePhotoPlayback)

        content.imageView.zoomToFit()
        XCTAssertFalse(badge.isDimmed)
        XCTAssertEqual(badge.toolTip, "Live Photo — hover to play")
    }

    func testZoomingInDuringPlaybackStops() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
        content.imageView.setPixelScale(2.0, anchor: nil)
        XCTAssertEqual(state(content), .idle)
    }

    // MARK: Stops, Reduce Motion, failures, close

    func testPointerLeavingThePhotoStops() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
        let photo = content.imageView.convert(content.imageView.drawnImageRect, to: content)
        content.livePhotoPointerMovedForTesting(to: CGPoint(x: photo.midX, y: photo.midY))
        XCTAssertEqual(state(content), .playing, "inside the photo: keeps playing")
        content.livePhotoPointerMovedForTesting(to: content.livePhotoBadgeForTesting.frame.center)
        XCTAssertEqual(state(content), .playing, "on the badge: keeps playing")
        content.livePhotoPointerMovedForTesting(to: CGPoint(x: content.bounds.maxX - 2, y: content.bounds.midY))
        XCTAssertTrue(photo.maxX < content.bounds.maxX - 2, "the fixture leaves room beside the photo")
        XCTAssertEqual(state(content), .idle, "outside the photo: stops")
        XCTAssertNotNil(content.livePhotoPlayback, "the player stays for a replay")
    }

    func testReduceMotionBlocksHoverButNotClick() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.reduceMotionOverrideForTesting = true
        content.playLivePhoto(withSound: false, fromHover: true)
        XCTAssertNil(content.livePhotoPlayback, "hover does not play")
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
    }

    func testAMovieThatCannotLoadHidesTheBadge() async throws {
        let viewer = try await viewer(movie: false, brokenMovie: true)
        let content = viewer.contentRootForTesting
        let badge = content.livePhotoBadgeForTesting
        XCTAssertFalse(badge.isHidden)
        badge.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("badge hides") { badge.isHidden }
        XCTAssertEqual(state(content), .idle)
        XCTAssertNotNil(content.livePhotoPlayback?.loadFailure,
                        "the failed AVFoundation load should remain observable for diagnostics")
        XCTAssertFalse(content.subviews.contains { $0 is LivePhotoMovieView })
    }

    func testClosingTheWindowFreesThePlayer() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
        let player = try XCTUnwrap(content.livePhotoPlayback?.player)
        viewer.close()
        XCTAssertNil(content.livePhotoPlayback)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(player.currentItem)
    }

    func testEditModeStopsAndBlocksPlayback() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        content.livePhotoBadgeForTesting.requestPlay(withSound: false, fromHover: false)
        try await waitUntil("playing") { self.state(content) == .playing }
        let target = viewer.groups[0].primary
        try await waitUntil("accepted live photo for editing") {
            viewer.displayedItem?.listIndex == 0 && viewer.displayedItem?.shownURL == target
                && content.imageView.sourceID == FileImageSource(url: target).id
                && viewer.canPerform(.editImage)
        }
        XCTAssertEqual(state(content), .playing, "playback is running immediately before edit entry")
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        XCTAssertTrue(content.editModeController.isActive)
        XCTAssertEqual(state(content), .idle)
        content.playLivePhoto(withSound: false, fromHover: false)
        XCTAssertEqual(state(content), .idle, "no playback while editing")
        content.editModeController.finalizeExit()
    }

    // MARK: The badge on the photo's top-left corner

    /// The badge is inset from the visible photo's top-left corner, never
    /// above the safe-area limit and inside the view.
    private func assertBadgeOnPhotoCorner(_ content: ViewerContentView, _ label: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        content.layoutSubtreeIfNeeded()
        let badge = content.livePhotoBadgeForTesting
        XCTAssertFalse(badge.isHidden, label, file: file, line: line)
        let canvas = content.imageView.frame
        let photo = content.convert(content.imageView.drawnImageRect, from: content.imageView).intersection(canvas)
        XCTAssertFalse(photo.isNull, label, file: file, line: line)
        let inset = ViewerContentView.liveBadgeInset
        let safeLimit = content.bounds.maxY - content.safeAreaInsets.top - ViewerContentView.liveBadgeChromeGap
        let f = badge.frame
        XCTAssertEqual(f.minX, photo.minX + inset, accuracy: 1, "\(label): left edge", file: file, line: line)
        XCTAssertEqual(f.maxY, min(photo.maxY - inset, safeLimit, content.bounds.maxY - inset), accuracy: 1,
                       "\(label): top edge", file: file, line: line)
        XCTAssertLessThanOrEqual(f.maxY, safeLimit + 0.5, "\(label): below the chrome", file: file, line: line)
    }

    /// On the photo, following resizes, zoom,
    /// pan, a view turn and full screen.
    func testBadgeSitsOnThePhotosTopLeftCorner() async throws {
        let viewer = try await viewer()
        let content = viewer.contentRootForTesting
        let view = content.imageView
        content.animatesPanelFades = false
        assertBadgeOnPhotoCorner(content, "portrait at fit, side bands")
        XCTAssertGreaterThan(content.livePhotoBadgeForTesting.frame.minX, 100)

        viewer.setContentSize(NSSize(width: 500, height: 900))
        assertBadgeOnPhotoCorner(content, "tall window, bands above and below")
        let photo = content.convert(view.drawnImageRect, from: view)
        XCTAssertGreaterThan(content.bounds.maxY - photo.maxY, 60, "the photo starts well below the top")

        viewer.setContentSize(NSSize(width: 800, height: 600))
        view.setPixelScale(1.0, anchor: nil)
        _ = await reached(within: 2) { !view.isZoomAnimating }
        assertBadgeOnPhotoCorner(content, "zoomed to 100 %")
        view.pan = CGPoint(x: view.drawnImageRect.width / 2, y: 0)
        assertBadgeOnPhotoCorner(content, "panned: the left edge in view")
        XCTAssertGreaterThan(content.livePhotoBadgeForTesting.frame.minX, 200)
        view.zoomToFit()
        _ = await reached(within: 2) { !view.isZoomAnimating }
        assertBadgeOnPhotoCorner(content, "back to fit")

        view.rotateBy(degrees: 90)
        content.layoutLiveBadge()
        assertBadgeOnPhotoCorner(content, "turned: landscape now")
        view.rotateBy(degrees: -90)
        content.layoutLiveBadge()

        content.windowMode = .fullscreen
        viewer.setFrame(NSRect(x: 0, y: 0, width: 1512, height: 982), display: false)
        assertBadgeOnPhotoCorner(content, "full screen")
        content.windowMode = .windowed
        viewer.setContentSize(NSSize(width: 800, height: 600))
        assertBadgeOnPhotoCorner(content, "window again")
    }
}

private extension NSRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

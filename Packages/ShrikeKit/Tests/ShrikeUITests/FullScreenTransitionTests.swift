//
//  FullScreenTransitionTests.swift
//  ShrikeUITests
//
//  Regression: "the previous photo flashes when leaving full screen"
//  AppKit's stock transition animated a
//  snapshot taken at full-screen entry. The viewer now runs a custom
//  animation that resizes the real window, so the Metal view keeps
//  drawing the photo that is actually current. These tests pin:
//    1. the window opts in to the custom enter AND exit animation;
//    2. a mode flip plus resizes never hand the view another file's
//       pixels — every image given to MetalImageView during the flip
//       belongs to the file on screen — and the view keeps redrawing.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore

@MainActor
final class FullScreenTransitionTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = TestScratch.directory
            .appendingPathComponent("shrike-fs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writePNG(_ name: String, width: Int, height: Int, gray: CGFloat) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Wait (on the main actor) until the view shows the full image of
    /// `id`, or fail after `timeout`.
    private func waitForFullImage(
        of id: String, in view: MetalImageView, timeout: TimeInterval = 5
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if view.sourceID == id, view.image != nil, !view.isCurrentImagePlaceholder { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("view never showed the full image of \(id); showing \(view.sourceID ?? "nil")")
    }

    func testWindowOptsInToCustomEnterAndExitAnimation() {
        let window = ViewerWindow(imageSources: [], startIndex: 0, services: .makeDefault())
        defer { window.close() }
        let transition = window.fullScreenTransition
        XCTAssertTrue(window.delegate === transition,
                      "the transition object must be the window delegate, or AppKit never asks it")
        XCTAssertEqual(transition.customWindowsToEnterFullScreen(for: window)?.count, 1)
        XCTAssertTrue(transition.customWindowsToEnterFullScreen(for: window)?.first === window)
        XCTAssertTrue(transition.customWindowsToExitFullScreen(for: window)?.first === window,
                      "without a custom exit, AppKit animates the stale entry snapshot")
    }

    func testFailedEnterRollsBackTheModeFlip() {
        let window = ViewerWindow(imageSources: [], startIndex: 0, services: .makeDefault())
        defer { window.close() }
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        XCTAssertEqual(window.contentRootForTesting.windowMode, .fullscreen)
        window.fullScreenTransition.onEnterFailed?()
        XCTAssertEqual(window.contentRootForTesting.windowMode, .windowed)
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        window.fullScreenTransition.onExitFailed?()
        XCTAssertEqual(window.contentRootForTesting.windowMode, .fullscreen)
    }

    func testModeFlipAndResize_NeverShowAnotherFile() async throws {
        let a = FileImageSource(url: try writePNG("a.png", width: 300, height: 200, gray: 0.2))
        let b = FileImageSource(url: try writePNG("b.png", width: 200, height: 300, gray: 0.8))
        let window = ViewerWindow(imageSources: [a, b], startIndex: 0, services: .makeDefault())
        defer { window.close() }
        let view = window.imageViewForTesting

        await waitForFullImage(of: a.id, in: view)
        // Browse to B (as a user would while in full screen), so the
        // photo from "entry time" (A) differs from the current one (B).
        await window.navigate(to: 1)
        await waitForFullImage(of: b.id, in: view)

        view.recordsImageAssignmentsForTesting = true
        view.imageAssignmentLogForTesting = []
        let drawsBefore = view.redrawCountForTesting
        let transition = window.fullScreenTransition

        // Enter: mode flip + the custom frame animation (duration 0 in tests).
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        transition.animate(window, to: NSRect(x: 0, y: 0, width: 1600, height: 1000), duration: 0)
        // Exit: mode flip + animate back.
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: window)
        transition.animate(window, to: transition.exitTargetFrame(for: window), duration: 0)
        // A plain resize afterwards.
        window.setFrame(NSRect(x: 80, y: 80, width: 900, height: 700), display: true)

        // Let any stray async work (prefetch, filmstrip, stand-ins) land.
        try await Task.sleep(nanoseconds: 400_000_000)

        let ids = view.imageAssignmentLogForTesting.map { $0.sourceID }
        XCTAssertTrue(ids.allSatisfy { $0 == b.id },
                      "a mode flip / resize handed the view another file: \(ids)")
        XCTAssertEqual(view.sourceID, b.id)
        XCTAssertGreaterThan(view.redrawCountForTesting, drawsBefore,
                             "the view must redraw the live photo while the window resizes")
    }
}

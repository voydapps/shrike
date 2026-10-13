//
//  ViewerTitleScrim028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-2: a dark top scrim behind the title block while the photo runs
//  under the titlebar (zoomed in, or filling the window); none at Fit when the
//  photo sits below it, and none in edit mode.
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
final class ViewerTitleScrim028Tests: XCTestCase {

    private var dir: URL!
    private var savedAutoHide = false
    private var savedInspector = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-scrim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedAutoHide = Prefs.viewerToolbarAutoHide
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerToolbarAutoHide = false
        Prefs.viewerInspectorVisibleWindowed = false
        MetalImageView.reduceMotionOverrideForTesting = true
        ReduceMotion.overrideForTesting = true
    }

    override func tearDown() async throws {
        Prefs.viewerToolbarAutoHide = savedAutoHide
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        MetalImageView.reduceMotionOverrideForTesting = nil
        ReduceMotion.overrideForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeViewer() async throws -> ViewerWindow {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 4000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 2000))
        let url = dir.appendingPathComponent("wide.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        let services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: services)
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = window.imageViewForTesting
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !(view.image != nil && !view.isCurrentImagePlaceholder && view.sourcePixelSize != nil) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    func testScrimShowsWhenTheZoomedPhotoRunsUnderTheTitlebarAndNotAtFit() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let view = viewer.imageViewForTesting
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.imageOverlapsTitlebar, "at Fit the photo sits below the titlebar")
        XCTAssertFalse(content.titleScrimIsShownForTesting)

        view.setPixelScale(1.0, anchor: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.imageOverlapsTitlebar, "at 100 % the photo is taller than the window")
        XCTAssertTrue(content.titleScrimIsShownForTesting)
        let scrim = try XCTUnwrap(content.titleScrimForTesting)
        XCTAssertEqual(scrim.topAlpha, 0.5, accuracy: 0.001, "black 0.5 at the top")
        XCTAssertEqual(scrim.alphaValue, 1, accuracy: 0.01)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(scrim.frame.height, content.safeAreaInsets.top + 24, accuracy: 0.5, "titlebar + 24 pt")
        XCTAssertEqual(scrim.frame.maxY, content.bounds.maxY, accuracy: 0.5, "from the window top")
        XCTAssertNil(scrim.hitTest(NSPoint(x: 10, y: 10)), "never takes a click")

        view.zoomToFit()
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.titleScrimIsShownForTesting, "back at Fit it goes")
        XCTAssertEqual(scrim.alphaValue, 0, accuracy: 0.01)
    }

    func testNoScrimInEditMode() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let view = viewer.imageViewForTesting
        view.setPixelScale(1.0, anchor: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.titleScrimIsShownForTesting)
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.imageOverlapsTitlebar)
        XCTAssertFalse(content.titleScrimIsShownForTesting, "the edit toolbar is opaque glass")
        content.editModeController.finalizeExit()
    }
}

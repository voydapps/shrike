//
//  ViewerTitleScrim028Tests.swift
//  ShrikeUITests
//
//  Native title contrast: one opaque, appearance-matched backing belongs to
//  the native chrome, independently of image zoom or edit canvas placement.
//  The original case identities retain their image-overlap regression checks.
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
    private let filmstripKey = "shrike.viewer.filmstrip.visibleInWindowed"
    private var savedFilmstripPreference: Any?

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-scrim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedAutoHide = Prefs.viewerToolbarAutoHide
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedFilmstripPreference = ShrikeDefaults.store.object(forKey: filmstripKey)
        // The original Fit/nonoverlap case requires the full-height canvas.
        // A visible strip is covered separately against its actual Fit area.
        Prefs.filmstripVisibleInWindowed = false
        Prefs.viewerToolbarAutoHide = true
        Prefs.viewerInspectorVisibleWindowed = false
        MetalImageView.reduceMotionOverrideForTesting = true
        ReduceMotion.overrideForTesting = true
    }

    override func tearDown() async throws {
        Prefs.viewerToolbarAutoHide = savedAutoHide
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        if let savedFilmstripPreference {
            ShrikeDefaults.store.set(savedFilmstripPreference, forKey: filmstripKey)
        } else {
            ShrikeDefaults.store.removeObject(forKey: filmstripKey)
        }
        XCTAssertEqual(ShrikeDefaults.store.object(forKey: filmstripKey) as? NSObject,
                       savedFilmstripPreference as? NSObject, "Restore the exact preference object or absence")
        MetalImageView.reduceMotionOverrideForTesting = nil
        ReduceMotion.overrideForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeViewer(toolbarShown: Bool = true) async throws -> ViewerWindow {
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
        // Per-instance control avoids inheriting another test's toolbar state
        // and never changes the native toolbar's global autosaved defaults.
        let toolbar = try XCTUnwrap(window.toolbar)
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = toolbarShown
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertEqual(toolbar.isVisible, toolbarShown)
        XCTAssertFalse(toolbar.autosavesConfiguration)
        let view = window.imageViewForTesting
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline, !(view.image != nil && !view.isCurrentImagePlaceholder && view.sourcePixelSize != nil) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        return window
    }

    /// The historical case name is retained; the translucent image scrim recipe
    /// was superseded by an opaque native band in the contrast specification.
    func testScrimShowsWhenTheZoomedPhotoRunsUnderTheTitlebarAndNotAtFit() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let view = viewer.imageViewForTesting
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.imageOverlapsTitlebar, "at Fit the photo sits below the titlebar")
        assertNativeBand(viewer)

        view.setPixelScale(1.0, anchor: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.imageOverlapsTitlebar, "at 100 % the photo is taller than the window")
        assertNativeBand(viewer)

        view.zoomToFit()
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.imageOverlapsTitlebar, "back at Fit the photo clears the titlebar")
        assertNativeBand(viewer)
    }

    /// No separate image-overlap scrim in Edit; the native chrome stays backed.
    func testNoScrimInEditMode() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let view = viewer.imageViewForTesting
        view.setPixelScale(1.0, anchor: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        view.finishZoomAnimationForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.imageOverlapsTitlebar)
        assertNativeBand(viewer)
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: nil)
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.imageOverlapsTitlebar)
        assertNativeBand(viewer)
        content.editModeController.finalizeExit()
        assertNativeBand(viewer)
    }

    func testNativeBandIsOpaqueInBothAppearancesAndTracksNativeLayoutAndVisibility() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let hider = try XCTUnwrap(viewer.autoHider)
        let container = try XCTUnwrap(hider.container)
        let toolbar = try XCTUnwrap(viewer.toolbar)
        let content = viewer.contentRootForTesting
        let view = viewer.imageViewForTesting
        var nativeBandHeights: [Bool: CGFloat] = [:]
        for stripShown in [false, true] {
            if Prefs.filmstripVisibleInWindowed != stripShown { content.togglePanel(.filmstrip) }
            for toolbarShown in [false, true] {
                toolbar.isVisible = toolbarShown
                for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                    viewer.appearance = try XCTUnwrap(NSAppearance(named: name))
                    for size in [NSSize(width: 900, height: 600), NSSize(width: 720, height: 480)] {
                        viewer.setContentSize(size)
                        viewer.contentView?.superview?.layoutSubtreeIfNeeded()
                        view.zoomToFit()
                        view.finishZoomAnimationForTesting()
                        content.layoutSubtreeIfNeeded()
                        XCTAssertEqual(toolbar.isVisible, toolbarShown)
                        XCTAssertFalse(toolbar.autosavesConfiguration)
                        XCTAssertEqual(content.filmstripForTesting.isHidden, !stripShown)
                        XCTAssertTrue(view.isAtFit)
                        XCTAssertTrue(view.fitArea.insetBy(dx: -0.5, dy: -0.5).contains(view.drawnImageRect),
                                      "Fit remains within its canvas even when auto-hide lets it overlap native chrome")
                        XCTAssertEqual(view.frame.maxY, content.bounds.maxY, accuracy: 0.5)
                        XCTAssertEqual(view.frame.minY, stripShown ? content.filmstripForTesting.frame.maxY : 0, accuracy: 0.5)
                        nativeBandHeights[toolbarShown] = container.bounds.height
                        let imageFrame = viewer.imageViewForTesting.frame
                        let imageRect = viewer.imageViewForTesting.drawnImageRect
                        assertNativeBand(viewer)
                        let backing = try XCTUnwrap(viewer.titlebarScrim)
                        XCTAssertEqual(backing.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                                       container.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))
                        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3,
                            pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
                        var expected: NSColor!
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        backing.effectiveAppearance.performAsCurrentDrawingAppearance {
                            expected = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB)
                            context.cgContext.scaleBy(x: 3 / backing.bounds.width, y: 3 / backing.bounds.height)
                            backing.draw(backing.bounds)
                        }
                        NSGraphicsContext.restoreGraphicsState()
                        // Spec 21b §2: a translucent band (the photo shows softly through), never a
                        // solid block. Sample the middle row (the 0.5 pt separator is at the bottom).
                        for (x, y) in [(0, 1), (1, 1), (2, 1)] {
                            let actual = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                            XCTAssertEqual(actual.alphaComponent, TitlebarScrimView.fillAlpha, accuracy: 2 / 255, "translucent")
                            XCTAssertLessThan(actual.alphaComponent, 1)
                            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 2 / 255)
                            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 2 / 255)
                            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 2 / 255)
                        }
                        XCTAssertEqual(viewer.imageViewForTesting.frame, imageFrame)
                        XCTAssertEqual(viewer.imageViewForTesting.drawnImageRect, imageRect)
                    }
                }
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(nativeBandHeights[true]), try XCTUnwrap(nativeBandHeights[false]),
                             "Exercise the complete shown toolbar band as well as the title-only band")
        print("Native band geometry: toolbar shown \(try XCTUnwrap(nativeBandHeights[true])) pt, hidden \(try XCTUnwrap(nativeBandHeights[false])) pt; strip on/off Fit containment verified")
        hider.hideForTesting()
        XCTAssertTrue(container.isHidden)
        XCTAssertTrue(try XCTUnwrap(viewer.titlebarScrim).isDescendant(of: container),
                      "The band must disappear with native chrome, without a second fade")
        hider.show(animated: false)
        XCTAssertFalse(container.isHidden)
        XCTAssertEqual(container.alphaValue, 1)
        assertNativeBand(viewer)
    }

    func testNativeBandIsRemovedForFullscreenAndRestoredWithTheNativeToolbar() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        assertNativeBand(viewer)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        XCTAssertNil(viewer.titlebarScrim, "Fullscreen uses its separate bottom HUD")
        NotificationCenter.default.post(name: NSWindow.willExitFullScreenNotification, object: viewer)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        viewer.contentView?.superview?.layoutSubtreeIfNeeded()
        assertNativeBand(viewer)
    }

    func testAutoHideOffUsesTheNativeOpaqueTitlebarWithoutAnImageGradient() async throws {
        Prefs.viewerToolbarAutoHide = false
        for toolbarShown in [false, true] {
            let viewer = try await makeViewer(toolbarShown: toolbarShown)
            defer { viewer.close() }
            XCTAssertFalse(viewer.titlebarAppearsTransparent)
            XCTAssertNil(viewer.titlebarScrim, "AppKit supplies the opaque backing when auto-hide is off")
            let view = viewer.imageViewForTesting
            view.setPixelScale(1, anchor: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
            view.finishZoomAnimationForTesting()
            viewer.contentView?.layoutSubtreeIfNeeded()
            XCTAssertNil(viewer.titlebarScrim)
        }
    }

    private func assertNativeBand(_ viewer: ViewerWindow, file: StaticString = #filePath, line: UInt = #line) {
        guard let backing = viewer.titlebarScrim, let container = viewer.autoHider?.container else {
            XCTFail("The native chrome requires its own opaque backing", file: file, line: line)
            return
        }
        XCTAssertFalse(backing.isOpaque, "Spec 21b §2: the band is translucent, the photo shows through", file: file, line: line)
        XCTAssertTrue(backing.superview === container, "Backing must share native chrome layout and animation", file: file, line: line)
        XCTAssertEqual(backing.frame, container.bounds, "Cover the entire measured native band", file: file, line: line)
        XCTAssertEqual(backing.alphaValue, 1, accuracy: 0.001, file: file, line: line)
        XCTAssertNil(backing.hitTest(NSPoint(x: backing.bounds.midX, y: backing.bounds.midY)),
                     "Never take a native chrome click", file: file, line: line)
    }
}

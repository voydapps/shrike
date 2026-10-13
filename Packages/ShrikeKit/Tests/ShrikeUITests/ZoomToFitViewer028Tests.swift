//
//  ZoomToFitViewer028Tests.swift
//  ShrikeUITests
//
//  Spec 27 B1 vectors 2 and 3: after a ⌘ + precise scroll zoom-out, the
//  View menu's Zoom to Fit and Fit to Window items (run through
//  `performShrikeCommand` on a real viewer window) bring the photo back to
//  Fit. Vector 1 and 4 live in ShrikeRenderingTests/ZoomToFitInvariantTests.
//  No scroll-routing test here: those wait for an unlocked screen.
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
final class ZoomToFitViewer028Tests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-fit028-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = false
        MetalImageView.reduceMotionOverrideForTesting = false
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        MetalImageView.reduceMotionOverrideForTesting = nil
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

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    private func makeViewer() async throws -> ViewerWindow {
        let url = try writeJPEG("p0.jpg")
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("meta.sqlite"), fallback: nil)
        let services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: services)
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = window.imageViewForTesting
        let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder && view.sourcePixelSize != nil }
        XCTAssertTrue(shown, "photo never reached the canvas")
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    /// Six ⌘ + precise scrolls of -60 through the canvas' own `scrollWheel`.
    private func commandScrollZoomOut(_ view: MetalImageView) throws {
        for _ in 0..<6 {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: -60, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.flags = .maskCommand
            view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        }
    }

    private func runMenuItem(_ command: ShrikeCommand, on viewer: ViewerWindow) throws {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        // `.zoomBestFit` (the key-only twin) has no menu row; give it a plain item.
        let item = bar.items(for: command).first ?? {
            let made = NSMenuItem(title: "\(command)", action: ShrikeMainMenu.commandAction, keyEquivalent: "")
            made.representedObject = command.rawValue
            return made
        }()
        XCTAssertTrue(viewer.validateMenuItem(item))
        viewer.performShrikeCommand(item)
    }

    private func assertAtFit(_ view: MetalImageView, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(view.isAtFit, message, file: file, line: line)
        XCTAssertEqual(view.pixelScale, view.fitPixelScale, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertFalse(view.isZoomAnimating, message, file: file, line: line)
    }

    func testZoomToFitMenuItemAfterCommandScrollZoomOut() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        try commandScrollZoomOut(view)
        XCTAssertFalse(view.isAtFit, "precondition: zoomed out (scale \(view.pixelScale), fit \(view.fitPixelScale))")
        try runMenuItem(.zoomToFit, on: viewer)
        assertAtFit(view, "View > Zoom to Fit")
    }

    func testBestFitCommandAfterCommandScrollZoomOut() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        try commandScrollZoomOut(view)
        XCTAssertFalse(view.isAtFit, "precondition: zoomed out")
        try runMenuItem(.zoomBestFit, on: viewer)
        assertAtFit(view, "zoomBestFit command")
    }

    func testZoomToFitAfterZoomOutAndFromActualSize() async throws {
        let viewer = try await makeViewer()
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        try commandScrollZoomOut(view)
        try runMenuItem(.zoomToFit, on: viewer)
        assertAtFit(view, "after zoom-out")
        try runMenuItem(.actualSize, on: viewer)
        view.finishZoomAnimationForTesting()
        XCTAssertFalse(view.isAtFit)
        try runMenuItem(.zoomToFit, on: viewer)
        assertAtFit(view, "after 100 %")
    }
}

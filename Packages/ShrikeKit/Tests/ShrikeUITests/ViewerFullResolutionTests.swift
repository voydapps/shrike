//
//  ViewerFullResolutionTests.swift
//  ShrikeUITests
//
//  100 % is one
//  image pixel per screen pixel for a subsampled display texture, and
//  past the texture's resolution the full-resolution decode is swapped
//  in without moving the image. Navigation cancels and frees it.
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
final class ViewerFullResolutionTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-fullres-\(UUID().uuidString)", isDirectory: true)
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

    /// An 800 × 600 viewer on 3000 × 2000 photos decoded for a 1024 px
    /// long edge, so the display texture is subsampled.
    private func makeViewer() async throws -> (ViewerWindow, MetalImageView) {
        let urls = try (0..<2).map { try writeJPEG("f\($0).jpg", width: 3000, height: 2000) }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 1, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let queue = await window.navigationForTesting.decodeQueue
        await queue.purge()
        await queue.setMaxLongEdge(1024)
        window.setGroups(urls.map { ImageGroup(primary: $0) }, startIndex: 0)
        let view = window.imageViewForTesting
        let ready = await waitUntil {
            (view.sourceID ?? "").hasSuffix("f0.jpg") && view.image != nil && !view.isCurrentImagePlaceholder && view.sourcePixelSize != nil
                && (view.textureSizeForTesting?.width ?? 3000) < 3000
        }
        XCTAssertTrue(ready, "subsampled photo with a known pixel size never reached the canvas")
        window.contentView?.layoutSubtreeIfNeeded()
        return (window, view)
    }

    private func backing(_ view: MetalImageView) -> Double {
        Double(view.window?.backingScaleFactor ?? 2)
    }

    func testDoubleClickFromFitIsExactHundredPercent() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        window.cancelFullResolution()
        XCTAssertTrue(view.isAtFit)
        view.toggleZoomForTesting(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
        // One image pixel per screen pixel: the drawn width in screen
        // pixels equals the file's 3000 px, whatever the texture size.
        let drawnPixels = Double(view.displayedImageSizeForTesting.width) * backing(view)
        XCTAssertEqual(drawnPixels, 3000, accuracy: 1.5)
        XCTAssertEqual(view.pixelScale, 1.0, accuracy: 0.001, "the HUD % uses the same definition")
        // ⌘1 lands on the same scale.
        view.zoomToFit()
        view.zoomToActual()
        XCTAssertEqual(Double(view.displayedImageSizeForTesting.width) * backing(view), 3000, accuracy: 1.5)
    }

    func testFullResolutionSwapKeepsTheDisplayedRect() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        view.setPixelScale(2.0, anchor: CGPoint(x: view.bounds.midX + 40, y: view.bounds.midY + 30))
        let swapped = await waitUntil { view.isShowingFullResolution }
        XCTAssertTrue(swapped, "no full-resolution swap past the display texture")
        XCTAssertEqual(view.textureSizeForTesting, CGSize(width: 3000, height: 2000))
        XCTAssertEqual(view.pixelScale, 2.0, accuracy: 0.001)
        let rect = view.displayedImageRectForTesting
        XCTAssertEqual(Double(rect.width) * backing(view), 6000, accuracy: 2, "200 % of 3000 px")
        // Same rect as before the swap: recompute what the display
        // texture drew and compare.
        view.dropFullResolution()
        let before = view.displayedImageRectForTesting
        XCTAssertEqual(before.origin.x, rect.origin.x, accuracy: 0.5)
        XCTAssertEqual(before.origin.y, rect.origin.y, accuracy: 0.5)
        XCTAssertEqual(before.width, rect.width, accuracy: 0.5)
        // The subsampled texture's short edge is rounded to whole texels
        // (1024 × 683 for 3000 × 2000): under one point of difference.
        XCTAssertEqual(before.height, rect.height, accuracy: 1.5)
    }

    func testReturnToFitDropsTheFullResolutionTexture() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        view.setPixelScale(1.0, anchor: nil)
        let swapped = await waitUntil { view.isShowingFullResolution }
        XCTAssertTrue(swapped)
        view.zoomToFit()
        XCTAssertFalse(view.isShowingFullResolution, "Fit gives the memory back")
        XCTAssertLessThan(view.textureSizeForTesting?.width ?? 0, 3000)
    }

    func testNavigationCancelsAndFreesTheFullResolution() async throws {
        let (window, view) = try await makeViewer()
        defer { window.close() }
        let firstID = view.sourceID
        view.setPixelScale(1.5, anchor: nil)
        let pending = try XCTUnwrap(window.fullResTask, "a decode starts past the texture")
        await window.navigate(to: 1)
        XCTAssertTrue(pending.isCancelled, "navigation cancels the decode")
        let moved = await waitUntil { window.displayedItem?.listIndex == 1 }
        XCTAssertTrue(moved)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotEqual(view.sourceID, firstID)
        XCTAssertNotEqual(view.fullResolutionSourceIDForTesting, firstID,
                          "no late swap of the old photo onto the canvas")
        // Back to Fit, then navigate: nothing full-size is kept.
        view.zoomToFit()
        await window.navigate(to: 0)
        _ = await waitUntil { window.displayedItem?.listIndex == 0 && view.sourceID == firstID }
        XCTAssertFalse(view.isShowingFullResolution)
        XCTAssertNil(window.fullResTask)
        XCTAssertLessThan(view.textureSizeForTesting?.width ?? 0, 3000)
    }
}

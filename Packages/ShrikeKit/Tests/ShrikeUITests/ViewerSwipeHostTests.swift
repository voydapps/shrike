//
//  ViewerSwipeHostTests.swift
//  ShrikeUITests
//
//  On a real offscreen ViewerWindow:
//  the host side of the paging swipe (hand-over with no flash and no new
//  decode, chrome only at completion, the end-of-list toast, keys with no
//  slide). The swipe is scripted through `handleSwipe` says.
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
final class ViewerSwipeHostTests: XCTestCase {

    private var dir: URL!
    private var savedInspector = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-swipe-\(UUID().uuidString)", isDirectory: true)
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

    private func services() throws -> ShrikeServices {
        let support = dir.appendingPathComponent(".support", isDirectory: true)
        let thumbs = try ThumbnailCache(diskURL: support.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: support.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ folder: URL, _ name: String, width: Int = 1200, height: Int = 900) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = folder.appendingPathComponent(name)
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

    private func makeViewer(_ urls: [URL], start: Int = 0) async throws -> ViewerWindow {
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: start, services: try services())
        window.setContentSize(NSSize(width: 800, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let view = window.imageViewForTesting
        let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
        XCTAssertTrue(shown, "photo never reached the canvas")
        return window
    }

    // Hand-over. The completed page keeps the very texture the
    // slide drew, in the same rect; the decode queue gets no new request
    // for that photo; the title and subtitle change only at completion.
    func testCompletedSwipeHandsOverWithNoFlashAndChromeAtCompletion() async throws {
        let folder = dir.appendingPathComponent("a", isDirectory: true)
        let urls = try (0..<3).map { try writeJPEG(folder, "p\($0).jpg") }
        let window = try await makeViewer(urls)
        defer { window.close() }
        let view = window.imageViewForTesting
        let nav = window.navigationForTesting
        let cached = await waitUntil { await nav.cachedEntry(at: 1)?.prepared != nil }
        XCTAssertTrue(cached, "the next photo was never prefetched")
        // The first photo's own title update must have landed before the
        // title is observed (it raced the neighbour's prefetch).
        _ = await waitUntil { window.displayedItem?.listIndex == 0 }
        try await Task.sleep(for: .milliseconds(100))
        let queue = nav.decodeQueue
        let spawnedBefore = await queue.spawnedIndicesForTesting().filter { $0 == 1 }.count

        var titleChanges = 0
        var subtitleChanges = 0
        let t = window.observe(\.title, options: [.new]) { _, _ in
            MainActor.assumeIsolated { titleChanges += 1 }
        }
        let st = window.observe(\.subtitle, options: [.new]) { _, _ in
            MainActor.assumeIsolated { subtitleChanges += 1 }
        }
        defer { t.invalidate(); st.invalidate() }
        let titleBefore = window.title

        view.beginSwipe(isDirectionInverted: true, hasNext: true, hasPrevious: false)
        view.handleSwipe(amount: -0.2, phase: .changed, isComplete: false)
        let arrived = await waitUntil { view.swipeNeighbourForTesting != nil }
        XCTAssertTrue(arrived, "the host never supplied the prefetched neighbour")
        let neighbour = try XCTUnwrap(view.swipeNeighbourForTesting)
        view.handleSwipe(amount: -0.6, phase: .ended, isComplete: false)
        view.handleSwipe(amount: -0.9, phase: [], isComplete: false)
        view.handleSwipe(amount: -1.0, phase: [], isComplete: false)
        let lastSlideRect = try XCTUnwrap(view.swipeDrawnRectsForTesting.neighbour)
        XCTAssertEqual(titleChanges, 0, "no chrome change during the slide")
        XCTAssertEqual(subtitleChanges, 0)
        XCTAssertEqual(window.title, titleBefore)

        view.handleSwipe(amount: -1.0, phase: [], isComplete: true)
        XCTAssertTrue(view.currentDisplayForTesting === neighbour, "same texture object")
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current, lastSlideRect, "same rect, no jump")

        let landed = await waitUntil { window.displayedItem?.listIndex == 1 }
        XCTAssertTrue(landed)
        XCTAssertTrue(view.currentDisplayForTesting === neighbour,
                      "the navigation landed the same texture (no re-upload, no stand-in)")
        XCTAssertEqual(view.swipeDrawnRectsForTesting.current, lastSlideRect)
        XCTAssertFalse(view.isCurrentImagePlaceholder)
        XCTAssertEqual(titleChanges, 1, "the title changed exactly once, at completion")
        XCTAssertGreaterThanOrEqual(subtitleChanges, 1)
        let spawnedAfter = await queue.spawnedIndicesForTesting().filter { $0 == 1 }.count
        XCTAssertEqual(spawnedAfter, spawnedBefore, "no decode request for the handed-over photo")
        let prioritized = await queue.prioritizedForTesting
        XCTAssertEqual(prioritized, [], "a prefetched neighbour never asks for a decode")
    }

    // Spring-back on the host: nothing changes (host side).
    func testSpringBackChangesNothingOnTheHost() async throws {
        let folder = dir.appendingPathComponent("a", isDirectory: true)
        let urls = try (0..<2).map { try writeJPEG(folder, "p\($0).jpg") }
        let window = try await makeViewer(urls)
        defer { window.close() }
        let view = window.imageViewForTesting
        let before = view.currentDisplayForTesting
        let title = window.title
        view.beginSwipe(isDirectionInverted: true, hasNext: true, hasPrevious: false)
        view.handleSwipe(amount: -0.2, phase: .changed, isComplete: false)
        view.handleSwipe(amount: -0.3, phase: .cancelled, isComplete: false)
        view.handleSwipe(amount: -0.1, phase: [], isComplete: false)
        view.handleSwipe(amount: 0, phase: [], isComplete: true)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(window.displayedItem?.listIndex, 0)
        XCTAssertEqual(window.title, title)
        XCTAssertTrue(view.currentDisplayForTesting === before)
    }

    // End of the list. A stretch under 12 pt: no toast. 12 pt
    // or more: the "Last image" toast; a second swipe never changes the
    // folder; → within 3 s opens the next folder.
    func testEndOfListSwipeShowsTheToastAndNeverOpensAFolder() async throws {
        let a = dir.appendingPathComponent("a", isDirectory: true)
        let b = dir.appendingPathComponent("b", isDirectory: true)
        let urls = try (0..<2).map { try writeJPEG(a, "p\($0).jpg") }
        let other = try writeJPEG(b, "q0.jpg")
        let window = try await makeViewer(urls, start: 1)
        defer { window.close() }
        let view = window.imageViewForTesting
        let toasts = window.contentRootForTesting.toastHost

        func stretch(_ amount: Double) {
            view.beginSwipe(isDirectionInverted: true, hasNext: false, hasPrevious: true)
            view.handleSwipe(amount: amount, phase: .changed, isComplete: false)
            view.handleSwipe(amount: 0, phase: .cancelled, isComplete: false)
            view.handleSwipe(amount: 0, phase: [], isComplete: true)
        }
        stretch(-0.01)   // 8.2 pt with S = 824
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(toasts.isShowing, "under 12 pt: no toast")

        stretch(-0.02)   // 16.5 pt
        let shown = await waitUntil { toasts.isShowing && window.endOfFolderCue?.folder != nil }
        XCTAssertTrue(shown, "the Last image toast never showed")
        XCTAssertEqual(window.displayedItem?.listIndex, 1, "the photo did not change")

        stretch(-0.02)   // a second swipe: still no folder change
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(window.groups.map(\.primary), urls, "a swipe never opens another folder")

        let ready = await waitUntil { toasts.isShowing && window.endOfFolderCue?.folder != nil }
        XCTAssertTrue(ready)
        window.dispatch(.nextImage)
        let opened = await waitUntil {
            window.groups.map(\.primary.standardizedFileURL) == [other.standardizedFileURL]
        }
        XCTAssertTrue(opened, "→ within 3 s opens the next folder")
    }

    // Keys and buttons change the photo with no slide.
    func testKeysChangeThePhotoWithNoSlide() async throws {
        let folder = dir.appendingPathComponent("a", isDirectory: true)
        let urls = try (0..<4).map { try writeJPEG(folder, "p\($0).jpg") }
        let window = try await makeViewer(urls)
        defer { window.close() }
        let view = window.imageViewForTesting
        for step in 1...3 {
            window.dispatch(.nextImage)
            XCTAssertFalse(view.isSwipeActiveForTesting, "no slide for a key")
            XCTAssertEqual(view.swipeDrawnRectsForTesting.current.midX, view.bounds.midX, accuracy: 0.5)
            let landed = await waitUntil { window.displayedItem?.listIndex == step }
            XCTAssertTrue(landed)
            XCTAssertEqual(view.swipeDrawnRectsForTesting.current.midX, view.bounds.midX, accuracy: 0.5)
        }
        XCTAssertEqual(view.lastSwipeHandOverForTesting, nil)
    }
}

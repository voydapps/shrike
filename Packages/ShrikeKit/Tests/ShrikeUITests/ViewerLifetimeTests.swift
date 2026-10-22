//
//  ViewerLifetimeTests.swift
//  ShrikeUITests
//
//  Regression: closing viewer windows
//  did not give their memory back (4 windows 1487 MB → close 3 → 951 MB).
//  A closed viewer must release its window, its decode queue, every
//  prepared neighbour texture and the CGImages it decoded.
//

import XCTest
import AppKit
import ImageIO
import Darwin
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore

@MainActor
final class ViewerLifetimeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-lifetime-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Helpers

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: tempDir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(
            primary: tempDir.appendingPathComponent("meta.sqlite"), fallback: nil
        )
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String, gray: CGFloat, width: Int = 3000, height: Int = 2000) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }

    /// Process physical footprint in MB (what Activity Monitor shows).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    private func resourceDiagnostics(_ viewer: ViewerWindow) async -> String {
        let navigation = viewer.navigationForTesting
        #if DEBUG
        let queueState = await navigation.decodeQueue.stateForTesting()
        #else
        let queueState = "queue diagnostics require Debug"
        #endif
        let windowState = "window visible=\(viewer.isVisible) closed=\(viewer.didTearDown) intent=\(viewer.intent.currentIndex) displayed=\(String(describing: viewer.displayedItem?.listIndex)) navIdle=\(viewer.navCoalescer.isIdle) hiddenTrim=\(viewer.hiddenTrimTask != nil) image=\(viewer.imageViewForTesting.image != nil) placeholder=\(viewer.imageViewForTesting.isCurrentImagePlaceholder)"
        let s = ImageResourceBudget.shared.snapshot()
        return "\(windowState) \(queueState) resources target=\(s.normalTarget) effective=\(s.effectiveTarget) pressure=\(s.pressure) retained=\(s.uniqueRetainedBytes) conservative=\(s.conservativeRetainedBytes) reserved=\(s.reservedEstimatedBytes) active=\(s.activeDiscretionaryOperationCount) oversize=\(s.activeOversizeOperationCount) waiters=\(s.pendingWaiterCount) categories=\(s.bytesByCategory)"
    }

    private final class WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    // MARK: Tests

    func testClosedViewerReleasesWindowQueueAndTextures() async throws {
        let urls = try (0..<5).map { try writeJPEG("p\($0).jpg", gray: 0.1 + CGFloat($0) * 0.15) }
        let services = try services()

        let weakWindow = WeakBox<ViewerWindow>(nil)
        let weakView = WeakBox<MetalImageView>(nil)
        let weakQueue = WeakBox<DecodeQueue>(nil)
        let weakNav = WeakBox<NavigationController>(nil)
        let weakTexture = WeakBox<DisplayTexture>(nil)

        do {
            let window = ViewerWindow(
                imageSources: urls.map { FileImageSource(url: $0) },
                startIndex: 1,
                services: services
            )
            weakWindow.value = window
            weakView.value = window.imageViewForTesting
            let nav = window.navigationForTesting
            weakNav.value = nav
            weakQueue.value = nav.decodeQueue

            let view = window.imageViewForTesting
            let shown = await waitUntil { view.image != nil && !view.isCurrentImagePlaceholder }
            XCTAssertTrue(shown)
            let prefetched = await waitUntil { await nav.cachedEntry(at: 2)?.prepared != nil }
            XCTAssertTrue(prefetched)
            weakTexture.value = await nav.cachedEntry(at: 2)?.prepared as? DisplayTexture
            XCTAssertNotNil(weakTexture.value)

            window.close()
        }

        let released = await waitUntil(5) {
            weakWindow.value == nil && weakView.value == nil && weakNav.value == nil
                && weakQueue.value == nil && weakTexture.value == nil
        }
        XCTAssertTrue(released, """
            closed viewer still alive: window=\(weakWindow.value != nil) \
            view=\(weakView.value != nil) nav=\(weakNav.value != nil) \
            queue=\(weakQueue.value != nil) neighbourTexture=\(weakTexture.value != nil)
            """)
    }

    /// Neighbours hold their GPU texture only: the CPU image is a lazy
    /// twin, and the texture is capped at the requested long edge.
    func testPreparedNeighbourHoldsTextureOnly() async throws {
        let urls = try (0..<3).map { try writeJPEG("n\($0).jpg", gray: 0.3, width: 6000, height: 4000) }
        let window = ViewerWindow(
            imageSources: urls.map { FileImageSource(url: $0) },
            startIndex: 0,
            services: try services()
        )
        defer { window.close() }
        let nav = window.navigationForTesting
        let ready = await waitUntil { await nav.cachedEntry(at: 1)?.prepared != nil }
        let diagnostics = ready ? "" : await resourceDiagnostics(window)
        XCTAssertTrue(ready, diagnostics)
        let maybeEntry = await nav.cachedEntry(at: 1)
        let entry = try XCTUnwrap(maybeEntry)
        XCTAssertTrue(entry.imageIsLazy, "a prepared neighbour must not keep decoded CPU pixels")
        let texture = try XCTUnwrap(entry.prepared as? DisplayTexture)
        let requested = try XCTUnwrap(entry.requestedLongEdge)
        // The request is the window's size now, not the
        // screen's, so the fast path may subsample (6000 -> 3000 for a
        // 2400 px request). It keeps the smallest power-of-2 step that
        // still covers the request.
        var factor = 1
        while factor < 8, 6000 / (factor * 2) >= requested { factor *= 2 }
        XCTAssertEqual(entry.image.width, 6000 / factor,
                       "the fast path keeps the smallest power-of-2 subsample that covers the request")
        XCTAssertEqual(max(texture.storage.width, texture.storage.height), min(requested, 6000),
                       "the texture is capped at the requested long edge")
        XCTAssertTrue(texture.matches(entry.image))
        XCTAssertEqual(entry.byteCount, texture.byteCount)
    }

    /// Four windows open, three closed: memory falls back to about one
    /// window's working set. Wait for actual queue/cache teardown and
    /// report tracked resource snapshots alongside the process footprint.
    func testClosingWindowsReturnsMemory() async throws {
        let services = try services()
        var windows: [ViewerWindow] = []
        let before = Self.footprintMB()
        let resourcesBefore = ImageResourceBudget.shared.snapshot()
        for w in 0..<4 {
            let urls = try (0..<5).map {
                try writeJPEG("w\(w)-\($0).jpg", gray: 0.1 + CGFloat($0) * 0.1, width: 6000, height: 4000)
            }
            let window = ViewerWindow(
                imageSources: urls.map { FileImageSource(url: $0) },
                startIndex: 2,
                services: services
            )
            let queue = window.navigationForTesting.decodeQueue
            await queue.setMaxLongEdge(3456)
            windows.append(window)
            let nav = window.navigationForTesting
            let ready = await waitUntil(15) {
                let a = await nav.cachedEntry(at: 1)?.prepared != nil
                let b = await nav.cachedEntry(at: 3)?.prepared != nil
                return a && b
            }
            let diagnostics = ready ? "" : await resourceDiagnostics(window)
            XCTAssertTrue(ready, "window \(w): \(diagnostics)")
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let four = Self.footprintMB()
        let resourcesWithFour = ImageResourceBudget.shared.snapshot()
        for window in windows.dropFirst() {
            let queue = window.navigationForTesting.decodeQueue
            window.close()
            await window.waitForResourceTeardownForTesting()
            let cachedIDs = await queue.cachedIDs()
            let inFlightIDs = await queue.inFlightIDs()
            XCTAssertTrue(cachedIDs.isEmpty, "closed viewer cache is empty")
            XCTAssertTrue(inFlightIDs.isEmpty, "closed viewer has no in-flight decodes")
        }
        windows.removeLast(3)
        let perWindowTracked = (resourcesWithFour.uniqueRetainedBytes - resourcesBefore.uniqueRetainedBytes) / 4
        let released = await waitUntil(30) {
            let resourceBytes = ImageResourceBudget.shared.snapshot().uniqueRetainedBytes
            let processBytes = Self.footprintMB() - before
            return resourceBytes <= resourcesBefore.uniqueRetainedBytes + Int(Double(perWindowTracked) * 1.6)
                && processBytes < (four - before) / 4 * 1.6
        }
        let one = Self.footprintMB()
        let resourcesAfter = ImageResourceBudget.shared.snapshot()
        print("MEMORY footprint: start \(Int(before)) MB, 4 windows \(Int(four)) MB, after closing 3 \(Int(one)) MB; tracked bytes before=\(resourcesBefore.uniqueRetainedBytes) four=\(resourcesWithFour.uniqueRetainedBytes) after=\(resourcesAfter.uniqueRetainedBytes)")
        let perWindow = (four - before) / 4
        XCTAssertTrue(released,
                      "close-time resources did not settle: before=\(resourcesBefore.uniqueRetainedBytes), four=\(resourcesWithFour.uniqueRetainedBytes), after=\(resourcesAfter.uniqueRetainedBytes)")
        XCTAssertLessThan(one - before, perWindow * 1.6,
                          "after closing 3 of 4 windows, about one window's memory must remain")
        if let remaining = windows.first {
            remaining.close()
            await remaining.waitForResourceTeardownForTesting()
        }
        let allClosed = await waitUntil(10) {
            ImageResourceBudget.shared.snapshot().uniqueRetainedBytes
                <= resourcesBefore.uniqueRetainedBytes + 8 * 1_048_576
        }
        XCTAssertTrue(allClosed, "tracked image resources remain after every viewer closed: \(ImageResourceBudget.shared.snapshot().uniqueRetainedBytes)")
    }

    /// Closing a viewer drops its decode cache even while something else
    /// still holds the queue (a straggling task): `close()` purges it.
    func testCloseClearsDecodeCacheImmediately() async throws {
        let urls = try (0..<3).map { try writeJPEG("q\($0).jpg", gray: 0.2 + CGFloat($0) * 0.2) }
        let window = ViewerWindow(
            imageSources: urls.map { FileImageSource(url: $0) },
            startIndex: 0,
            services: try services()
        )
        let nav = window.navigationForTesting
        let queue = nav.decodeQueue
        let prefetched = await waitUntil { await nav.cachedEntry(at: 1)?.prepared != nil }
        XCTAssertTrue(prefetched)

        window.close()
        let purged = await waitUntil(2) {
            let cached = await queue.cachedIDs()
            let inFlight = await queue.inFlightIDs()
            return cached.isEmpty && inFlight.isEmpty
        }
        XCTAssertTrue(purged, "close() must drop cached and in-flight decodes")
        XCTAssertNil(window.imageViewForTesting.image, "the closed window's view must drop its CGImage")
    }
}

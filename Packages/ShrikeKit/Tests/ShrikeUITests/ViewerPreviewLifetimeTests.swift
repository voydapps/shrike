import AppKit
import XCTest
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeUI

/// Optional preview work must not own a viewer while awaiting an uncooperative source/cache.
@MainActor
final class ViewerPreviewLifetimeTests: XCTestCase {
    private enum Path { case embedded, thumbnail }
    private final class Weak<T: AnyObject> {
        weak var value: T?
        init(_ value: T?) { self.value = value }
    }

    private var savedEdge = 0

    /// The source below answers a 1024 px request with the small preview (that is what the
    /// thumbnail bridge asks for) and holds every other request at `fullGate`. The viewer asks
    /// for its own texture size, which on a 1024 pt wide, 1x screen (the CI runner) is also
    /// 1024 px: the required decode then returned at once, never reached the gate, and the
    /// optional paths were then skipped. A decode size cap below the bridge size
    /// keeps the two requests apart on every screen.
    override func setUp() async throws {
        savedEdge = Prefs.maxDisplayLongEdge
        Prefs.maxDisplayLongEdge = 512
    }

    override func tearDown() async throws {
        Prefs.maxDisplayLongEdge = savedEdge
    }

    private func until(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    func testCloseReleasesViewerWhileEmbeddedPreviewIsStillHeld() throws {
        try runWithoutXCTestEventPump { try await self.exercise(.embedded, closeWhileHeld: true) }
    }

    func testCloseReleasesViewerWhileThumbnailCacheIsStillHeld() throws {
        try runWithoutXCTestEventPump { try await self.exercise(.thumbnail, closeWhileHeld: true) }
    }

    func testEmbeddedPreviewStillPaintsBeforeFullImageInActiveViewer() async throws {
        try await exercise(.embedded, closeWhileHeld: false)
    }

    func testThumbnailBridgeStillPaintsBeforeFullImageInActiveViewer() async throws {
        try await exercise(.thumbnail, closeWhileHeld: false)
    }

    private func exercise(_ path: Path, closeWhileHeld: Bool) async throws {
        let root = TestScratch.directory.appendingPathComponent("shrike-preview-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fullGate = HeldPreviewWork(), embeddedGate = HeldPreviewWork(), thumbnailGate = HeldPreviewWork()
        let source = HeldPreviewSource(id: UUID().uuidString, fullGate: fullGate,
            embeddedGate: path == .embedded ? embeddedGate : nil,
            full: try image(width: 2048, height: 1536), preview: try image(width: 1024, height: 768))
        let cache = try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs"))
        let bridgeURL = try await cache.diskFileURL(for: source, maxPixelSize: 1024)
        await cache.setHooksForTesting(.init(beforeDiskRead: { url in
            if url == bridgeURL { await thumbnailGate.wait() }
        }))
        let store = try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false })
        var viewer: ViewerWindow? = ViewerWindow(imageSources: [source], startIndex: 0,
            services: ShrikeServices(thumbnailCache: cache, metadataStore: store))
        let weakViewer = Weak(viewer)
        let weakContent = Weak(viewer?.contentRootForTesting)
        let weakNavigation = Weak(viewer?.navigationForTesting)
        let weakQueue = Weak(viewer?.navigationForTesting.decodeQueue)
        let fullStarted = await until { await fullGate.entered > 0 }
        XCTAssertTrue(fullStarted, "The actual image decode is controlled by the test")
        let optionalStarted = await until {
            if path == .embedded { return await embeddedGate.entered > 0 }
            return await thumbnailGate.entered > 0
        }
        XCTAssertTrue(optionalStarted, "The optional path must be suspended before testing its lifetime")

        if closeWhileHeld {
            await fullGate.release()
            let fullShown = await until {
                viewer?.navCoalescer.isIdle == true && viewer?.imageViewForTesting.image != nil
                    && viewer?.imageViewForTesting.isCurrentImagePlaceholder == false
            }
            XCTAssertTrue(fullShown, "Required navigation must finish before ownership is tested")
            viewer?.close(); viewer = nil
            let released = await until {
                weakViewer.value == nil && weakContent.value == nil
                    && weakNavigation.value == nil && weakQueue.value == nil
            }
            if !released {
                let held: [(String, AnyObject?)] = [("ViewerWindow", weakViewer.value), ("ViewerContentView", weakContent.value)]
                LifetimeDiagnostics.dump(name, alive: held.compactMap { label, object in object.map { (label, $0) } })
            }
            XCTAssertTrue(released, "Held optional work retained window=\(weakViewer.value != nil), content=\(weakContent.value != nil), navigation=\(weakNavigation.value != nil), queue=\(weakQueue.value != nil)")
            let stillHeld = path == .embedded ? await embeddedGate.isHeld : await thumbnailGate.isHeld
            XCTAssertTrue(stillHeld, "The assertion must happen before the cancellation-resistant work is released")
        } else {
            if path == .embedded { await embeddedGate.release() }
            else { await thumbnailGate.release() }
            let previewShown = await until { viewer?.imageViewForTesting.isCurrentImagePlaceholder == true }
            XCTAssertTrue(previewShown, "The active viewer still paints its optional preview")
            await fullGate.release()
            let fullShown = await until {
                viewer?.navCoalescer.isIdle == true && viewer?.imageViewForTesting.image != nil
                    && viewer?.imageViewForTesting.isCurrentImagePlaceholder == false
            }
            XCTAssertTrue(fullShown, "The final image replaces the preview")
            viewer?.close(); viewer = nil
        }
        // Resume every controlled child even on assertion failures; no suspended test work leaks.
        await fullGate.release(); await embeddedGate.release(); await thumbnailGate.release()
        await cache.setHooksForTesting(.init())
        _ = await until { await cache.jobCountForTesting() == 0 }
        await cache.waitForPendingDiskWrites(); await cache.evictMemory()
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

/// Deliberately ignores cancellation until the test explicitly releases real work.
private actor HeldPreviewWork {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    var isHeld: Bool { !open && entered > 0 }
    func wait() async {
        entered += 1
        if !open { await withCheckedContinuation { waiting.append($0) } }
    }
    func release() {
        open = true
        let continuations = waiting; waiting = []
        for continuation in continuations { continuation.resume() }
    }
}

private struct HeldPreviewSource: ImageSource {
    let id: String
    let fullGate: HeldPreviewWork
    let embeddedGate: HeldPreviewWork?
    let full: CGImage
    let preview: CGImage
    var displayName: String { id }
    var fileSize: Int64? { nil }
    var mtime: Date? { nil }
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        if maxPixelSize == 1024 { return preview }
        await fullGate.wait()
        return full
    }
    func loadEmbeddedPreview() async throws -> CGImage? {
        guard let embeddedGate else { return nil }
        await embeddedGate.wait()
        return preview
    }
    func loadProperties() async throws -> ImageProperties {
        ImageProperties(pixelWidth: full.width, pixelHeight: full.height, orientation: .up,
            colorSpaceName: nil, bitDepth: 8, hasAlpha: false, exif: nil, utType: .png, fileSize: 0)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

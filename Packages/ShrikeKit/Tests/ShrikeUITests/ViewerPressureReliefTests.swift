import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerPressureReliefTests: XCTestCase {
    private var root: URL!
    private var savedEdge = 4096
    private var viewers: [ViewerWindow] = []
    private var gates: [PressureWorkGate] = []
    private var caches: [ThumbnailCache] = []
    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-pressure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedEdge = Prefs.maxDisplayLongEdge; Prefs.maxDisplayLongEdge = 1024
    }
    override func tearDown() async throws {
        for viewer in viewers { viewer.onImagePressureHandledForTesting = nil; viewer.close() }
        viewers = []
        for gate in gates { await gate.release() }
        gates = []
        for cache in caches {
            await cache.setHooksForTesting(.init())
            _ = await until { await cache.jobCountForTesting() == 0 }
            await cache.waitForPendingDiskWrites(); await cache.evictMemory()
        }
        caches = []; Prefs.maxDisplayLongEdge = savedEdge
        try? FileManager.default.removeItem(at: root)
    }
    private func until(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return await condition()
    }
    private func gate() -> PressureWorkGate {
        let gate = PressureWorkGate(); gates.append(gate); return gate
    }
    private func makeViewer(startup: PressureWorkGate? = nil, detail: PressureWorkGate? = nil) async throws -> ViewerWindow {
        let cache = try ThumbnailCache(diskURL: root.appendingPathComponent(UUID().uuidString))
        caches.append(cache)
        // Hold unrelated thumbnail admission so this test delivers precisely
        // the explicit, real resource-relief notification below.
        let thumbnailGate = gate()
        await cache.setHooksForTesting(.init(beforeResourceReservation: { await thumbnailGate.wait() }))
        let urls = try (0..<3).map { index in
            let url = root.appendingPathComponent("\(UUID())-\(index).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 3000, height: 2000, red: 0.2 + CGFloat(index) * 0.2), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
        }
        let sources = urls.map { PressurePhoto(url: $0, startup: startup, detail: detail) }
        let viewer = ViewerWindow(imageSources: sources, startIndex: 1,
            services: ShrikeServices(thumbnailCache: cache,
                metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("\(UUID()).sqlite"), writeFileAttributes: { false })),
            groups: urls.map { ImageGroup(primary: $0) })
        viewers.append(viewer)
        viewer.setContentSize(NSSize(width: 800, height: 600)); viewer.contentView?.layoutSubtreeIfNeeded()
        return viewer
    }
    private func ready(_ viewer: ViewerWindow) async {
        let queue = viewer.navigationForTesting.decodeQueue
        let ready = await until {
            guard viewer.navCoalescer.isIdle, viewer.displayedItem?.listIndex == 1,
                  viewer.imageViewForTesting.sourcePixelSize != nil else { return false }
            let previous = await queue.cachedEntry(at: 0), current = await queue.cachedEntry(at: 1), next = await queue.cachedEntry(at: 2)
            return previous?.prepared != nil && current?.prepared != nil && next?.prepared != nil
        }
        XCTAssertTrue(ready, "Current and both direct neighbors must be prepared before relief")
    }
    private func relieve(_ viewer: ViewerWindow) async {
        var handled = false
        // The closure captures only this local flag; it cannot retain the viewer.
        viewer.onImagePressureHandledForTesting = { handled = true }
        defer { viewer.onImagePressureHandledForTesting = nil }
        viewer.navigationForTesting.decodeQueue.resources.requestOptionalRelief()
        let completed = await until { handled }
        XCTAssertTrue(completed, "Assertions follow completion of the real viewer pressure observer")
    }
    private func assertRequiredNeighbors(_ viewer: ViewerWindow) async {
        let queue = viewer.navigationForTesting.decodeQueue
        let current = await queue.cachedEntry(at: 1)
        let previous = await queue.cachedEntry(at: 0), next = await queue.cachedEntry(at: 2)
        XCTAssertNotNil(current); XCTAssertNotNil(previous); XCTAssertNotNil(next)
    }

    func testReliefPreservesHeldRequiredStartupDecodeAndNavigationSources() async throws {
        let startup = gate(), viewer = try await makeViewer(startup: startup)
        let queue = viewer.navigationForTesting.decodeQueue
        let started = await until {
            let entered = await startup.entered, inFlight = await queue.inFlightIDs()
            return entered > 0 && inFlight.count == 3
        }
        XCTAssertTrue(started)
        await relieve(viewer)
        let wanted = await queue.wantedIDs(), inFlight = await queue.inFlightIDs()
        XCTAssertEqual(wanted.count, 3, "Relief keeps current and immediate neighbors configured")
        XCTAssertEqual(inFlight.count, 3, "Relief cannot cancel required startup image work")
        await startup.release()
        await ready(viewer)
        await assertRequiredNeighbors(viewer)
    }

    func testReliefPreservesPreparedCurrentAndDirectNeighbors() async throws {
        let viewer = try await makeViewer(); await ready(viewer)
        let sourceID = viewer.imageViewForTesting.sourceID
        await relieve(viewer)
        await assertRequiredNeighbors(viewer)
        XCTAssertEqual(viewer.imageViewForTesting.sourceID, sourceID)
    }

    func testReliefPreservesInUseActualResolutionAndDisplayedRect() async throws {
        let viewer = try await makeViewer(); await ready(viewer)
        let view = viewer.imageViewForTesting
        view.zoomToActual()
        let actual = await until { view.isShowingFullResolution }
        XCTAssertTrue(actual)
        let rect = view.displayedImageRectForTesting, texture = view.textureSizeForTesting, sourceID = view.sourceID
        await relieve(viewer)
        XCTAssertTrue(view.isShowingFullResolution)
        XCTAssertEqual(view.textureSizeForTesting, texture)
        XCTAssertEqual(view.displayedImageRectForTesting, rect)
        XCTAssertEqual(view.sourceID, sourceID)
        XCTAssertEqual(view.pixelScale, 1, accuracy: 0.001)
        await assertRequiredNeighbors(viewer)
    }

    func testReliefPreservesPendingDetailNeededAtActualSize() async throws {
        let detail = gate(), viewer = try await makeViewer(detail: detail)
        await ready(viewer)
        viewer.imageViewForTesting.zoomToActual()
        let started = await until { await detail.entered > 0 }
        XCTAssertTrue(started)
        let required = try XCTUnwrap(viewer.fullResTask)
        await relieve(viewer)
        XCTAssertNotNil(viewer.fullResTask); XCTAssertFalse(required.isCancelled)
        await detail.release()
        let actual = await until { viewer.imageViewForTesting.isShowingFullResolution }
        XCTAssertTrue(actual, "The needed full image still arrives after memory relief")
    }

    func testReliefCancelsUnneededDetailWorkAtStableFit() async throws {
        let viewer = try await makeViewer(); await ready(viewer)
        XCTAssertTrue(viewer.imageViewForTesting.isAtFit)
        let pending = gate()
        let unneeded = Task { await pending.wait() }
        viewer.fullResTask = unneeded
        await relieve(viewer)
        XCTAssertTrue(unneeded.isCancelled); XCTAssertNil(viewer.fullResTask)
        await pending.release(); await unneeded.value
        await assertRequiredNeighbors(viewer)
    }
}

private actor PressureWorkGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0
    func wait() async { entered += 1; if !open { await withCheckedContinuation { waiting.append($0) } } }
    func release() {
        open = true
        let pending = waiting; waiting = []
        for continuation in pending { continuation.resume() }
    }
}
private struct PressurePhoto: ImageSource {
    let url: URL
    let startup: PressureWorkGate?
    let detail: PressureWorkGate?
    var id: String { FileImageSource(url: url).id }
    var displayName: String { url.lastPathComponent }
    var fileSize: Int64? { FileImageSource(url: url).fileSize }
    var mtime: Date? { FileImageSource(url: url).mtime }
    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        if maxPixelSize == nil, let detail { await detail.wait() }
        else if let startup { await startup.wait() }
        return try await FileImageSource(url: url).loadCGImage(maxPixelSize: maxPixelSize)
    }
    func loadProperties() async throws -> ImageProperties { try await FileImageSource(url: url).loadProperties() }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

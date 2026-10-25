import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ComparePressureReliefTests: XCTestCase {
    private var root: URL!
    private var savedEdge = 4096
    private var savedMotion: Bool?
    private var savedPresents = true
    private var blockers: [(CompareLaneGate, Task<Void, Never>)] = []
    private var caches: [ThumbnailCache] = []
    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-compare-pressure-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedEdge = Prefs.maxDisplayLongEdge; Prefs.maxDisplayLongEdge = 1024
        savedMotion = ReduceMotion.overrideForTesting; ReduceMotion.overrideForTesting = true
        savedPresents = CompareWindow.presentsWindows; CompareWindow.presentsWindows = false
    }
    override func tearDown() async throws {
        CompareWindow.current?.close()
        for (gate, _) in blockers { gate.release() }
        for (_, task) in blockers { await task.value }
        blockers = []
        for cache in caches { await cache.waitForPendingDiskWrites(); await cache.evictMemory() }
        caches = []
        Prefs.maxDisplayLongEdge = savedEdge; ReduceMotion.overrideForTesting = savedMotion
        CompareWindow.presentsWindows = savedPresents
        try? FileManager.default.removeItem(at: root)
    }
    private func until(_ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return await condition()
    }
    private func open() async throws -> (CompareWindow, ComparePane) {
        let urls = try (0..<2).map { index in
            let url = root.appendingPathComponent("photo-\(index).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 3000, height: 2000, red: 0.2 + CGFloat(index) * 0.3), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination)); return url
        }
        let cache = try ThumbnailCache(diskURL: root.appendingPathComponent("thumbs")); caches.append(cache)
        let services = ShrikeServices(thumbnailCache: cache,
            metadataStore: try MetadataStore(databaseURL: root.appendingPathComponent("metadata.sqlite"), writeFileAttributes: { false }))
        let window = CompareWindow.open(.init(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: services, origin: nil, frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        window.contentView?.layoutSubtreeIfNeeded()
        for pane in window.panes { await pane.loadTask?.value }
        let ready = await until {
            window.panes.allSatisfy { $0.loadedURL != nil && $0.view.imageView.sourcePixelSize != nil && $0.view.imageView.image != nil }
        }
        XCTAssertTrue(ready)
        window.perform(try XCTUnwrap(CompareKeyMap.hit(for: .init(key: "s", modifiers: []), preset: .macNative)))
        XCTAssertFalse(window.isLocked)
        let pane = try XCTUnwrap(window.panes.first)
        XCTAssertLessThan(try XCTUnwrap(pane.view.imageView.textureSizeForTesting).width, 3000)
        return (window, pane)
    }
    private func relieve(_ pane: ComparePane) async {
        let before = pane.pressureHandledCount
        pane.queue.resources.requestOptionalRelief()
        let handled = await until { pane.pressureHandledCount > before }
        XCTAssertTrue(handled, "Assertions follow the real Compare pressure observer")
    }
    private func holdFullResolutionLane() async -> CompareLaneGate {
        let gate = CompareLaneGate()
        let task = Task.detached {
            _ = try? await DecodeLane.fullResolution.runInterruptible { _ in gate.block(); return true }
        }
        blockers.append((gate, task))
        let entered = await until { gate.entered }
        XCTAssertTrue(entered); return gate
    }
    func testReliefPreservesLoadedActualDetailAndGeometry() async throws {
        let (_, pane) = try await open(); let view = pane.view.imageView
        view.zoomToActual()
        let loaded = await until { view.isShowingFullResolution && !view.isZoomAnimating }
        XCTAssertTrue(loaded)
        let texture = view.textureSizeForTesting, rect = view.displayedImageRectForTesting, source = view.sourceID
        await relieve(pane)
        XCTAssertTrue(view.isShowingFullResolution)
        XCTAssertEqual(view.textureSizeForTesting, texture); XCTAssertEqual(view.displayedImageRectForTesting, rect)
        XCTAssertEqual(view.sourceID, source); XCTAssertEqual(view.pixelScale, 1, accuracy: 0.001)
    }
    func testReliefPreservesRealPendingActualDetail() async throws {
        let (_, pane) = try await open(); let view = pane.view.imageView
        let gate = await holdFullResolutionLane()
        view.zoomToActual()
        let task = try XCTUnwrap(pane.fullResTask)
        XCTAssertTrue(view.wantsFullResolution); XCTAssertFalse(view.isShowingFullResolution)
        await relieve(pane)
        XCTAssertNotNil(pane.fullResTask); XCTAssertFalse(task.isCancelled)
        gate.release()
        let loaded = await until { view.isShowingFullResolution }
        XCTAssertTrue(loaded, "Real queued full-resolution work must reach the Actual pane")
        await task.value
    }
    func testReliefReleasesLoadedDetailAtStableFit() async throws {
        let (_, pane) = try await open(); let view = pane.view.imageView
        view.zoomToActual()
        let loaded = await until { view.isShowingFullResolution }; XCTAssertTrue(loaded)
        view.zoomToFit()
        XCTAssertTrue(view.isAtFit); XCTAssertFalse(view.isZoomAnimating)
        await relieve(pane)
        XCTAssertFalse(view.isShowingFullResolution)
    }
    func testReliefCancelsRealUnneededPendingDetailAtStableFit() async throws {
        let (_, pane) = try await open(); let view = pane.view.imageView
        let gate = await holdFullResolutionLane()
        view.zoomToActual()
        let task = try XCTUnwrap(pane.fullResTask)
        view.zoomToFit()
        XCTAssertTrue(view.isAtFit); XCTAssertFalse(view.isZoomAnimating)
        await relieve(pane)
        XCTAssertTrue(task.isCancelled); XCTAssertNil(pane.fullResTask)
        gate.release(); await task.value
        XCTAssertFalse(view.isShowingFullResolution)
    }
}

private final class CompareLaneGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didEnter = false
    private let semaphore = DispatchSemaphore(value: 0)
    private var released = false
    var entered: Bool { lock.withLock { didEnter } }
    func block() { lock.withLock { didEnter = true }; semaphore.wait() }
    func release() {
        let signal = lock.withLock { if released { return false }; released = true; return true }
        if signal { semaphore.signal() }
    }
}

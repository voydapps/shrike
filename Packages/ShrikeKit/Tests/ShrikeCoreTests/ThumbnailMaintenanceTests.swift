import XCTest
import os
@testable import ShrikeCore

private actor ThumbnailTestGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = 0
    func wait() async {
        entered += 1
        if !open { await withCheckedContinuation { continuations.append($0) } }
    }
    func release() { open = true; let waiting = continuations; continuations = []; for c in waiting { c.resume() } }
}

final class ThumbnailMaintenanceTests: XCTestCase {
    private func until(_ condition: @escaping () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !(await condition()), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        let satisfied = await condition(); XCTAssertTrue(satisfied)
    }
    func testSaturatedNearbyThumbnailCompletesWhenPromotedVisible() async throws {
        let tmp = TempDir("thumbnail-visible-promotion"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 100))
        let object = NSObject()
        let retained = resources.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                        owner: .init(), category: .editOriginal)
        defer { retained.release() }
        let cache = try ThumbnailCache(diskURL: tmp.url, resources: resources)
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            return try await cache.thumbnail(for: source, maxPixelSize: 64, priority: .nearby)
        }
        defer { task.cancel() }
        try await until { resources.snapshot().pendingWaiterCount == 1 }
        XCTAssertEqual(resources.snapshot().activeDiscretionaryOperationCount, 0)
        await cache.setPriority(.visible, for: source, maxPixelSize: 64)
        try await until { finished.withLock { $0 } }
        guard finished.withLock({ $0 }) else { task.cancel(); _ = try? await task.value; return }
        let image = try await task.value
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertEqual(resources.snapshot().bytesByCategory[.editOriginal], 100,
                       "the current required image was never released to make progress")
        await cache.waitForPendingDiskWrites(); await cache.evictMemory()
        XCTAssertEqual(resources.snapshot().aggregateChargedBytes, 100)
        XCTAssertEqual(resources.snapshot().pendingWaiterCount, 0)
    }
    func testThumbnailPromotionBeforeBudgetEnqueueIsNotLost() async throws {
        let tmp = TempDir("thumbnail-pre-enqueue-visible"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 100)), object = NSObject()
        let retained = resources.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                        owner: .init(), category: .editOriginal)
        defer { retained.release() }
        let cache = try ThumbnailCache(diskURL: tmp.url, resources: resources), gate = ThumbnailTestGate()
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        await cache.setHooksForTesting(.init(beforeResourceReservation: { await gate.wait() }))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            return try await cache.thumbnail(for: source, maxPixelSize: 64, priority: .nearby)
        }
        defer { task.cancel() }
        try await until { await gate.entered == 1 }
        XCTAssertEqual(resources.snapshot().pendingWaiterCount, 0)
        await cache.setPriority(.visible, for: source, maxPixelSize: 64)
        await gate.release()
        try await until { finished.withLock { $0 } }
        guard finished.withLock({ $0 }) else { task.cancel(); _ = try? await task.value; return }
        _ = try await task.value
        await cache.waitForPendingDiskWrites(); await cache.evictMemory()
        XCTAssertEqual(resources.snapshot().aggregateChargedBytes, 100)
        XCTAssertEqual(resources.snapshot().pendingWaiterCount, 0)
    }
    func testPreEnqueueThumbnailPromotionAndDemotionUseLatestDemand() async throws {
        let tmp = TempDir("thumbnail-pre-enqueue-promotion"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 100))
        let object = NSObject()
        let retained = resources.retain([.init(identity: .init(object: object, kind: .cpuPixels), bytes: 100)],
                                        owner: .init(), category: .editOriginal)
        defer { retained.release() }
        let cache = try ThumbnailCache(diskURL: tmp.url, resources: resources), gate = ThumbnailTestGate()
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        await cache.setHooksForTesting(.init(beforeResourceReservation: { await gate.wait() }))
        let finished = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            defer { finished.withLock { $0 = true } }
            return try await cache.thumbnail(for: source, maxPixelSize: 64, priority: .nearby)
        }
        defer { task.cancel() }
        try await until { await gate.entered == 1 }
        await cache.setPriority(.visible, for: source, maxPixelSize: 64)
        await cache.setPriority(.nearby, for: source, maxPixelSize: 64)
        await gate.release()
        try await until { resources.snapshot().pendingWaiterCount == 1 }
        XCTAssertFalse(finished.withLock { $0 }, "demotion must remove the unused oversized exception")
        XCTAssertEqual(resources.snapshot().activeOversizeOperationCount, 0)
        // A visible caller raises the same existing job, rather than starting
        // a second decode or depending on an unrelated required-image release.
        let visible = Task { try await cache.thumbnail(for: source, maxPixelSize: 64, priority: .visible) }
        defer { visible.cancel() }
        try await until { finished.withLock { $0 } }
        guard finished.withLock({ $0 }) else { task.cancel(); visible.cancel(); _ = try? await task.value; return }
        _ = try await task.value; _ = try await visible.value
        await cache.waitForPendingDiskWrites(); await cache.evictMemory()
        XCTAssertEqual(resources.snapshot().aggregateChargedBytes, 100)
        XCTAssertEqual(resources.snapshot().pendingWaiterCount, 0)
    }
    func testCancelledPreEnqueueThumbnailDemandDoesNotLeaveWaiterOrCapacity() async throws {
        let tmp = TempDir("thumbnail-cancel-demand"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 100))
        let cache = try ThumbnailCache(diskURL: tmp.url, resources: resources), gate = ThumbnailTestGate()
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        await cache.setHooksForTesting(.init(beforeResourceReservation: { await gate.wait() }))
        let task = Task { try await cache.thumbnail(for: source, maxPixelSize: 64, priority: .nearby) }
        try await until { await gate.entered == 1 }
        await cache.setPriority(.visible, for: source, maxPixelSize: 64)
        task.cancel(); await gate.release()
        do { _ = try await task.value; XCTFail("cancelled demand must throw") } catch is CancellationError {}
        try await until { resources.snapshot().pendingWaiterCount == 0 && resources.snapshot().reservedEstimatedBytes == 0 }
        XCTAssertEqual(resources.snapshot().aggregateChargedBytes, 0)
    }
    func testWarmReadsUseSameBoundedSlots() async throws {
        let tmp = TempDir("thumbnail-warm-slots"); defer { tmp.cleanup() }
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        let warm = try ThumbnailCache(diskURL: tmp.url)
        for size in [64, 96, 128, 160] { _ = try await warm.thumbnail(for: source, maxPixelSize: size) }
        await warm.waitForPendingDiskWrites()
        let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: 2), gate = ThumbnailTestGate()
        await cache.setHooksForTesting(.init(beforeDiskRead: { _ in await gate.wait() }))
        let tasks = [64, 96, 128, 160].map { size in Task { try await cache.thumbnail(for: source, maxPixelSize: size) } }
        try await until { await gate.entered == 2 }
        let active = await cache.activeDecodeSlotsForTesting()
        XCTAssertEqual(active, 2)
        await gate.release()
        for task in tasks { _ = try await task.value }
        let stats = await cache.statistics(); XCTAssertEqual(stats.diskHits, 4)
    }
    func testEvictRejectsPausedOldReadInsteadOfPaintingOrRepopulating() async throws {
        let tmp = TempDir("thumbnail-paused-evict"); defer { tmp.cleanup() }
        let source = FileImageSource(url: try TestFixture.url("small.jpg")), cache = try ThumbnailCache(diskURL: tmp.url)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        await cache.waitForPendingDiskWrites(); await cache.evictMemory()
        let gate = ThumbnailTestGate()
        await cache.setHooksForTesting(.init(beforeDiskRead: { _ in await gate.wait() }))
        let old = Task { try await cache.thumbnail(for: source, maxPixelSize: 64) }
        try await until { await gate.entered == 1 }
        await cache.evict(url: source.url); await gate.release()
        do { _ = try await old.value; XCTFail("invalidated read must not deliver pixels") } catch is CancellationError {}
        XCTAssertNil(cache.cachedThumbnail(for: source, maxPixelSize: 64))
        await cache.setHooksForTesting(.init())
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
    }
    func testHeldStatisticsWalkDoesNotBlockVisibleThumbnail() async throws {
        let tmp = TempDir("thumbnail-statistics-background"); defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url), source = FileImageSource(url: try TestFixture.url("small.jpg"))
        let started = OSAllocatedUnfairLock(initialState: false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await cache.setHooksForTesting(.init(beforeExactScan: { started.withLock { $0 = true }; release.wait() }))
        let scan = Task { await cache.currentDiskBytes() }
        try await until { started.withLock { $0 } }
        let image = try await cache.thumbnail(for: source, maxPixelSize: 64)
        XCTAssertGreaterThan(image.width, 0)
        release.signal(); _ = await scan.value
        await cache.setHooksForTesting(.init())
    }
    func testNewGenerationSurvivesHeldTombstoneDeletion() async throws {
        let tmp = TempDir("thumbnail-tombstone"); defer { tmp.cleanup() }
        let root = tmp.url.appendingPathComponent("active"), cache = try ThumbnailCache(diskURL: root)
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64); await cache.waitForPendingDiskWrites()
        let started = OSAllocatedUnfairLock(initialState: false), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await cache.setHooksForTesting(.init(beforeTombstoneDelete: { started.withLock { $0 = true }; release.wait() }))
        let clear = Task { await cache.clearAll() }
        try await until { started.withLock { $0 } }
        _ = try await cache.thumbnail(for: source, maxPixelSize: 128); await cache.waitForPendingDiskWrites()
        XCTAssertNotNil(cache.cachedThumbnail(for: source, maxPixelSize: 128))
        release.signal(); let outcome = await clear.value; XCTAssertTrue(outcome.success)
        XCTAssertNotNil(cache.cachedThumbnail(for: source, maxPixelSize: 128))
        let newFile = try await cache.diskFileURL(for: source, maxPixelSize: 128)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFile.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        XCTAssertFalse(siblings.contains { $0.contains(".clearing.") })
    }
    func testCompletedDiskOperationDoesNotRetainImageLeaseThroughItsCapture() async throws {
        let tmp = TempDir("thumbnail-completed-write-capture"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 1 << 20))
        let disk = ThumbnailDiskStore(root: tmp.url, resources: resources)
        disk.setWritesSuspendedForTesting(true)
        defer { disk.setWritesSuspendedForTesting(false) }
        let image = OrientedImageFixtures.quadrants(width: 64, height: 64)
        XCTAssertTrue(disk.enqueueWrite(image, to: tmp.url.appendingPathComponent("capture.heic")))
        XCTAssertGreaterThan(resources.snapshot().uniqueRetainedBytes, 0)
        let operation = try XCTUnwrap(disk.operationsForTesting.first)
        disk.setWritesSuspendedForTesting(false)
        await disk.waitUntilIdle()
        withExtendedLifetime(operation) {
            XCTAssertTrue(operation.isFinished)
            XCTAssertEqual(resources.snapshot().aggregateChargedBytes, 0,
                           "a retained completed BlockOperation must not retain write pixels or their lease")
        }
    }
    func testClearingMemoryReleasesAllLRUNodesAndLeases() async throws {
        let tmp = TempDir("thumbnail-lru-lifetime"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 1 << 20))
        let cache = try ThumbnailCache(diskURL: tmp.url, resources: resources)
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        for size in [32, 48, 64] { _ = try await cache.thumbnail(for: source, maxPixelSize: size) }
        await cache.waitForPendingDiskWrites()
        XCTAssertGreaterThan(resources.snapshot().uniqueRetainedBytes, 0)
        await cache.evictMemory()
        XCTAssertEqual(resources.snapshot().uniqueRetainedBytes, 0, "weak previous links must not form an ARC cycle")
    }
}

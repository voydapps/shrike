//
//  ThumbnailCacheTests.swift
//  ShrikeCoreTests
//

import XCTest
@testable import ShrikeCore

final class ThumbnailCacheTests: XCTestCase {

    /// Tests of the cache's decode-slot queue must not depend on unrelated
    /// caches retaining pixels in the process-wide production budget. Keep
    /// the real admission path enabled, but give each test a private budget
    /// with enough room to reach the slot queue deterministically.
    private func isolatedThumbnailBudget() -> ImageResourceBudget {
        ImageResourceBudget(configuration: .init(
            normalBudget: 512 << 20,
            maximumDiscretionaryWorkCount: 8
        ))
    }

    func testGenerate_memoryAndDiskHits() async throws {
        let tmp = TempDir("thumb")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, diskCeilingBytes: 10 * 1024 * 1024)

        let source = FileImageSource(url: try TestFixture.url("small.jpg"))

        // First call — miss.
        let first = try await cache.thumbnail(for: source, maxPixelSize: 64)
        XCTAssertGreaterThan(first.width, 0)
        var stats = await cache.statistics()
        XCTAssertEqual(stats.memoryHits, 0)

        // Second call — memory hit.
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        stats = await cache.statistics()
        XCTAssertGreaterThanOrEqual(stats.memoryHits, 1)

        // Drop memory; third call should still hit disk (the write runs
        // after the thumbnail is returned, so wait for it).
        await cache.waitForPendingDiskWrites()
        await cache.evictMemory()
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        stats = await cache.statistics()
        XCTAssertGreaterThanOrEqual(stats.diskHits, 1)
        XCTAssertGreaterThan(stats.diskBytesUsed, 0)
    }

    func testEviction_deletesOverCeiling() async throws {
        let tmp = TempDir("thumb-evict")
        defer { tmp.cleanup() }
        // Tiny ceiling so one write triggers eviction.
        let cache = try ThumbnailCache(diskURL: tmp.url, diskCeilingBytes: 256)

        let source = FileImageSource(url: try TestFixture.url("small.jpg"))

        _ = try await cache.thumbnail(for: source, maxPixelSize: 96)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 128)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 160)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 192)
        await cache.waitForPendingDiskWrites()

        await cache.runEvictionNow()
        let stats = await cache.statistics()
        XCTAssertLessThanOrEqual(stats.diskBytesUsed, 512 + 256) // allow slack for one un-evictable entry
    }

    func testDifferentSizes_differentKeys() async throws {
        let tmp = TempDir("thumb-sizes")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url)

        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 128)

        let path64 = try await cache.diskFileURL(for: source, maxPixelSize: 64)
        let path128 = try await cache.diskFileURL(for: source, maxPixelSize: 128)
        XCTAssertNotEqual(path64.lastPathComponent, path128.lastPathComponent)
    }

    // MARK: - currentDiskBytes()

    func testCurrentDiskBytes_sumsLooseFilesUnderRoot() async throws {
        let tmp = TempDir("thumb-bytes")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, diskCeilingBytes: 10 * 1024 * 1024)

        // Empty root → 0 bytes.
        let initial = await cache.currentDiskBytes()
        XCTAssertEqual(initial, 0)

        // Write three files of known sizes directly into the cache root so
        // the test doesn't depend on HEIC compression output.
        let shard = tmp.url.appendingPathComponent("ab", isDirectory: true)
        try FileManager.default.createDirectory(at: shard, withIntermediateDirectories: true)
        let sizes: [Int] = [128, 256, 512]
        for (i, size) in sizes.enumerated() {
            let data = Data(repeating: 0x7F, count: size)
            try data.write(to: shard.appendingPathComponent("blob-\(i).bin"))
        }

        let total = await cache.currentDiskBytes()
        XCTAssertEqual(total, Int64(sizes.reduce(0, +)))
    }

    // MARK: - Decode-slot semaphore (concurrency cap)

    /// Verifies that the `maxConcurrentDecodes` semaphore actually caps
    /// concurrent ImageIO calls. Regression guard for the IOSurface /
    /// `task name port right` storm — see ThumbnailCache.swift comment
    /// on `maxConcurrentDecodes` and commit message for full diagnosis.
    ///
    /// Strategy: hand the cache N cache-miss requests with *distinct*
    /// keys (so coalescing doesn't apply), then poll the active-slot
    /// counter; it must never exceed the cap. We use distinct
    /// `maxPixelSize` values on the same source to force distinct cache
    /// keys without needing N separate fixtures.
    func testDecodeThrottle_neverExceedsCap() async throws {
        let tmp = TempDir("thumb-throttle")
        defer { tmp.cleanup() }
        let cap = 3
        let cache = try ThumbnailCache(
            diskURL: tmp.url,
            diskCeilingBytes: 10 * 1024 * 1024,
            maxConcurrentDecodes: cap
        )
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))

        let requestCount = 12
        // Fire all requests concurrently. Each gets its own pixel size
        // so the cache key differs and they don't coalesce.
        async let _: Void = withTaskGroup(of: Void.self) { group in
            for i in 0..<requestCount {
                let size = 32 + i * 4
                group.addTask {
                    _ = try? await cache.thumbnail(for: source, maxPixelSize: size)
                }
            }
            await group.waitForAll()
        }

        // Poll the active-slot counter while the burst is in flight.
        // Sample frequently for ~250 ms — long enough to cover the
        // decode burst even on the slowest CI box.
        var observedMax = 0
        for _ in 0..<250 {
            let active = await cache.activeDecodeSlotsForTesting()
            observedMax = max(observedMax, active)
            XCTAssertLessThanOrEqual(
                active, cap,
                "active decode slots (\(active)) must never exceed cap (\(cap))"
            )
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }

        // We expect at least one sample to have caught the cap saturated
        // — otherwise the test isn't actually exercising the throttle
        // and any pass is meaningless.
        XCTAssertGreaterThanOrEqual(
            observedMax, 1,
            "test never observed any active decode — burst completed before sampling started"
        )

        // After everything drains, slots should be empty.
        // Wait a generous moment for tail decodes to settle.
        for _ in 0..<200 where await cache.activeDecodeSlotsForTesting() > 0 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let finalActive = await cache.activeDecodeSlotsForTesting()
        let finalWaiters = await cache.decodeWaiterCountForTesting()
        XCTAssertEqual(finalActive, 0, "all decode slots must release after the burst")
        XCTAssertEqual(finalWaiters, 0, "no waiters should be left blocked")
    }

    func testClearAll_removesFilesAndResetsByteCount() async throws {
        let tmp = TempDir("thumb-clear")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, diskCeilingBytes: 10 * 1024 * 1024)

        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 96)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 192)
        await cache.waitForPendingDiskWrites()

        let before = await cache.currentDiskBytes()
        XCTAssertGreaterThan(before, 0, "cache must have bytes after two writes")

        await cache.clearAll()
        let after = await cache.currentDiskBytes()
        XCTAssertEqual(after, 0)
    }

    // MARK: - Priority, cancellation, LRU, atomic writes

    /// Fills the only slot with a gated source, then queues more.
    private func blockedCache(_ tmp: TempDir) throws -> (ThumbnailCache, GatedSource) {
        let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: 1,
                                       resources: isolatedThumbnailBudget())
        return (cache, GatedSource(id: "blocker"))
    }

    /// Polls up to 5 s; a condition that never comes true fails the test
    /// at once, instead of letting the next assertion fail with a
    /// misleading number (CI 0.2.22: "0 vs 1").
    private func waitUntil(_ cond: @Sendable () async -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2500 {
            if await cond() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not reached within 5 s", file: file, line: line)
    }

    // MARK: - A caller that arrives while a doomed decode runs

    /// A cell scrolls away while its decode runs (nobody waits any more, so
    /// the running job is marked "discard"), and comes back before it ends.
    /// The new request must get its own thumbnail, not the old job's
    /// CancellationError (grid cells stayed blank on first open).
    func testRequestAfterCallerCancelledMidDecode_getsAnImage() async throws {
        let tmp = TempDir("thumb-redo-cancel")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: 2,
                                       resources: isolatedThumbnailBudget())
        let x = GatedSource(id: "x")
        let first = Task { try await cache.thumbnail(for: x, maxPixelSize: 64) }
        await waitUntil { x.decodeCount == 1 }
        first.cancel()
        await waitUntil { await cache.doomedJobCountForTesting() == 1 }

        let again = Task { try await cache.thumbnail(for: x, maxPixelSize: 64) }
        try await Task.sleep(nanoseconds: 20_000_000)
        x.open()
        let image = try await again.value
        XCTAssertEqual(image.width, 64)
        _ = try? await first.value
        let cached = cache.cachedThumbnail(for: x, maxPixelSize: 64)
        XCTAssertNotNil(cached, "the second request's result is cached")
        let jobs = await cache.jobCountForTesting()
        XCTAssertEqual(jobs, 0)
    }

    /// Same, through the prefetch window: a started prefetch is withdrawn
    /// (row left the window) and the row appears again before it ends.
    func testRequestAfterCancelPrefetchMidDecode_getsAnImage() async throws {
        let tmp = TempDir("thumb-redo-prefetch")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: 2,
                                       resources: isolatedThumbnailBudget())
        let x = GatedSource(id: "x")
        await cache.prefetch([x], maxPixelSize: 64)
        await waitUntil { x.decodeCount == 1 }
        await cache.cancelPrefetch([x], maxPixelSize: 64)
        let doomed = await cache.doomedJobCountForTesting()
        XCTAssertEqual(doomed, 1)

        let shown = Task { try await cache.thumbnail(for: x, maxPixelSize: 64) }
        try await Task.sleep(nanoseconds: 20_000_000)
        x.open()
        let image = try await shown.value
        XCTAssertEqual(image.width, 64)
    }

    /// A prefetch that arrives after the same thumbnail was doomed must
    /// also start fresh work (it would otherwise be cancelled with it).
    func testPrefetchAfterDoomedJob_startsFreshWork() async throws {
        let tmp = TempDir("thumb-redo-prefetch2")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: 2,
                                       resources: isolatedThumbnailBudget())
        let x = GatedSource(id: "x")
        let first = Task { try await cache.thumbnail(for: x, maxPixelSize: 64) }
        await waitUntil { x.decodeCount == 1 }
        first.cancel()
        await waitUntil { await cache.doomedJobCountForTesting() == 1 }
        await cache.prefetch([x], maxPixelSize: 64)
        x.open()
        await waitUntil { cache.cachedThumbnail(for: x, maxPixelSize: 64) != nil }
    }

    func testCancelledCallerDropsQueuedDecode() async throws {
        let tmp = TempDir("thumb-cancel")
        defer { tmp.cleanup() }
        let (cache, blocker) = try blockedCache(tmp)
        let first = Task { try await cache.thumbnail(for: blocker, maxPixelSize: 64) }
        await waitUntil { await cache.activeDecodeSlotsForTesting() == 1 }

        let victim = GatedSource(id: "scrolled-away")
        let queued = Task { try await cache.thumbnail(for: victim, maxPixelSize: 64) }
        await waitUntil { await cache.decodeWaiterCountForTesting() == 1 }
        queued.cancel()
        await waitUntil { await cache.decodeWaiterCountForTesting() == 0 }
        do { _ = try await queued.value; XCTFail("expected CancellationError") } catch is CancellationError {}

        blocker.open()
        _ = try await first.value
        XCTAssertEqual(victim.decodeCount, 0, "a dropped job never decodes")
        let jobs = await cache.jobCountForTesting()
        XCTAssertEqual(jobs, 0)
    }

    func testExplicitCancelAndCancelQueuedPrefetch() async throws {
        let tmp = TempDir("thumb-cancel2")
        defer { tmp.cleanup() }
        let (cache, blocker) = try blockedCache(tmp)
        let first = Task { try await cache.thumbnail(for: blocker, maxPixelSize: 64) }
        await waitUntil { await cache.activeDecodeSlotsForTesting() == 1 }

        let a = GatedSource(id: "a"), b = GatedSource(id: "b"), c = GatedSource(id: "c")
        await cache.prefetch([a, b], maxPixelSize: 64)
        let waiting = Task { try await cache.thumbnail(for: c, maxPixelSize: 64) }
        await waitUntil { await cache.decodeWaiterCountForTesting() == 3 }

        await cache.cancelQueued(atOrBelow: .prefetch)
        var left = await cache.decodeWaiterCountForTesting()
        XCTAssertEqual(left, 1, "only the visible request stays")
        await cache.cancel(for: c, maxPixelSize: 64)
        left = await cache.decodeWaiterCountForTesting()
        XCTAssertEqual(left, 0)
        do { _ = try await waiting.value; XCTFail("expected CancellationError") } catch is CancellationError {}

        blocker.open()
        _ = try await first.value
        XCTAssertEqual(a.decodeCount + b.decodeCount + c.decodeCount, 0)
    }

    func testCancelPrefetch_dropsQueuedRowsButNotOnesSomeoneWaitsFor() async throws {
        let tmp = TempDir("thumb-cancel-prefetch")
        defer { tmp.cleanup() }
        let (cache, blocker) = try blockedCache(tmp)
        let first = Task { try await cache.thumbnail(for: blocker, maxPixelSize: 64) }
        await waitUntil { await cache.activeDecodeSlotsForTesting() == 1 }

        let a = GatedSource(id: "a"), b = GatedSource(id: "b"), c = GatedSource(id: "c")
        await cache.prefetch([a, b, c], maxPixelSize: 64)
        await waitUntil { await cache.decodeWaiterCountForTesting() == 3 }
        // A cell for c comes on screen and waits for it.
        let waiting = Task { try await cache.thumbnail(for: c, maxPixelSize: 64, priority: .visible) }
        await waitUntil { await cache.interestForTesting(for: c, maxPixelSize: 64) == 1 }

        // AppKit: the prefetch window moved away from a, b and c.
        await cache.cancelPrefetch([a, b, c], maxPixelSize: 64)
        let left = await cache.decodeWaiterCountForTesting()
        XCTAssertEqual(left, 1, "a and b are dropped; c stays because a cell waits for it")

        blocker.open(); c.open()
        _ = try await first.value
        _ = try await waiting.value
        XCTAssertEqual(a.decodeCount + b.decodeCount, 0, "a dropped prefetch never decodes")
        let jobs = await cache.jobCountForTesting()
        XCTAssertEqual(jobs, 0)
    }

    func testPrefetchedThenShownThenScrolledAway_isDropped() async throws {
        // The measured case: a row is prefetched (pinned), a cell shows it,
        // and the user scrolls on before it decodes. It must not decode.
        let tmp = TempDir("thumb-prefetched-away")
        defer { tmp.cleanup() }
        let (cache, blocker) = try blockedCache(tmp)
        let first = Task { try await cache.thumbnail(for: blocker, maxPixelSize: 64) }
        await waitUntil { await cache.activeDecodeSlotsForTesting() == 1 }

        let v = GatedSource(id: "v")
        await cache.prefetch([v], maxPixelSize: 64)
        await waitUntil { await cache.decodeWaiterCountForTesting() == 1 }
        let cell = Task { try await cache.thumbnail(for: v, maxPixelSize: 64, priority: .visible) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cell.cancel()   // the cell scrolled away
        await waitUntil { await cache.decodeWaiterCountForTesting() == 0 }
        let left = await cache.decodeWaiterCountForTesting()
        XCTAssertEqual(left, 0)

        blocker.open()
        _ = try await first.value
        XCTAssertEqual(v.decodeCount, 0)
    }

    func testCacheKey_sameWithKnownSizeAndDate_andChangesWithTheFile() throws {
        let tmp = TempDir("thumb-key")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("k.jpg")
        try FileManager.default.copyItem(at: try TestFixture.url("small.jpg"), to: url)
        let plain = FileImageSource(url: url)
        let size = try XCTUnwrap(plain.fileSize), mtime = try XCTUnwrap(plain.mtime)
        let known = FileImageSource(url: url, knownSize: size, knownMTime: mtime)
        XCTAssertEqual(known, plain, "known values are not part of the identity")
        XCTAssertEqual(ThumbnailCache.cacheKey(for: known, maxPixelSize: 96),
                       ThumbnailCache.cacheKey(for: plain, maxPixelSize: 96),
                       "the key format is unchanged, so old disk caches stay valid")
        // A second lookup comes from the memo and agrees.
        XCTAssertEqual(ThumbnailCache.cacheKey(for: known, maxPixelSize: 96),
                       ThumbnailCache.cacheKey(for: plain, maxPixelSize: 96))
        // Same file, new size or date: a new key.
        let moved = FileImageSource(url: url, knownSize: size + 1, knownMTime: mtime)
        let later = FileImageSource(url: url, knownSize: size, knownMTime: mtime.addingTimeInterval(5))
        XCTAssertNotEqual(ThumbnailCache.cacheKey(for: moved, maxPixelSize: 96),
                          ThumbnailCache.cacheKey(for: known, maxPixelSize: 96))
        XCTAssertNotEqual(ThumbnailCache.cacheKey(for: later, maxPixelSize: 96),
                          ThumbnailCache.cacheKey(for: known, maxPixelSize: 96))
        // The path hash is still the shared prefix of every size and version.
        XCTAssertTrue(ThumbnailCache.cacheKey(for: later, maxPixelSize: 96)
            .hasPrefix(ThumbnailCache.pathPrefix(for: plain)))
    }

    func testKnownValuesNeedNoFileSystemCall() {
        // A path that does not exist: with known values the key is still built.
        let url = URL(fileURLWithPath: "/nonexistent-shrike-dir/x.jpg")
        let src = FileImageSource(url: url, knownSize: 1234, knownMTime: Date(timeIntervalSince1970: 99))
        XCTAssertEqual(src.fileSize, 1234)
        XCTAssertEqual(src.mtime, Date(timeIntervalSince1970: 99))
        XCTAssertNil(FileImageSource(url: url).fileSize)
    }

    func testRequestPixels_scaleAndBucket() {
        XCTAssertEqual(ThumbnailSizing.requestPixels(points: 180, scale: 2), 384, "360 px rounds up to a multiple of 64")
        XCTAssertEqual(ThumbnailSizing.requestPixels(points: 180, scale: 1), 192)
        XCTAssertEqual(ThumbnailSizing.requestPixels(points: 118, scale: 2), 256)
        XCTAssertEqual(ThumbnailSizing.requestPixels(points: 120, scale: 2), 256)
        XCTAssertEqual(ThumbnailSizing.requestPixels(points: 800, scale: 2), 1024, "capped")
        // A slider drag over 8 points makes at most one new size.
        let sizes = Set((176...183).map { ThumbnailSizing.requestPixels(points: $0, scale: 2) })
        XCTAssertEqual(sizes.count, 1)
    }

    func testVisibleJumpsAheadOfPrefetch() async throws {
        let tmp = TempDir("thumb-prio")
        defer { tmp.cleanup() }
        let (cache, blocker) = try blockedCache(tmp)
        let first = Task { try await cache.thumbnail(for: blocker, maxPixelSize: 64) }
        await waitUntil { await cache.activeDecodeSlotsForTesting() == 1 }

        let order = OrderLog()
        let p = GatedSource(id: "prefetch", log: order), v = GatedSource(id: "visible", log: order)
        p.open(); v.open()
        await cache.prefetch([p], maxPixelSize: 64)
        await waitUntil { await cache.decodeWaiterCountForTesting() == 1 }
        let visible = Task { try await cache.thumbnail(for: v, maxPixelSize: 64, priority: .visible) }
        await waitUntil { await cache.decodeWaiterCountForTesting() == 2 }

        blocker.open()
        _ = try await first.value
        _ = try await visible.value
        await waitUntil { order.ids.count == 2 }
        XCTAssertEqual(order.ids, ["visible", "prefetch"])
    }

    func testCoalescedCallersShareOneDecode() async throws {
        let tmp = TempDir("thumb-coalesce")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url)
        let src = GatedSource(id: "shared")
        let t1 = Task { try await cache.thumbnail(for: src, maxPixelSize: 64) }
        let t2 = Task { try await cache.thumbnail(for: src, maxPixelSize: 64, priority: .prefetch) }
        await waitUntil { src.decodeCount == 1 }
        t2.cancel()   // one caller leaves; the other still gets the image
        src.open()
        let image = try await t1.value
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(src.decodeCount, 1)
        XCTAssertNotNil(cache.cachedThumbnail(for: src, maxPixelSize: 64), "sync memory lookup")
    }

    func testMemoryLRUIsBoundedByBytesAndKeepsRecent() {
        let lru = ThumbnailMemoryLRU(byteLimit: 3 * 64 * 64 * 4, countLimit: 100)
        func img() -> CGImage { GatedSource.image(side: 64) }
        lru.set(img(), for: "a"); lru.set(img(), for: "b"); lru.set(img(), for: "c")
        XCTAssertNotNil(lru.get("a"))          // a is now most recent
        lru.set(img(), for: "d")               // evicts b (least recent)
        XCTAssertNil(lru.get("b"))
        XCTAssertNotNil(lru.get("a"))
        XCTAssertNotNil(lru.get("c"))
        XCTAssertNotNil(lru.get("d"))
        XCTAssertLessThanOrEqual(lru.totalBytes, lru.byteLimit)
        lru.set(GatedSource.image(side: 256), for: "huge")   // bigger than the budget: kept alone
        XCTAssertEqual(lru.count, 1)
        XCTAssertNotNil(lru.get("huge"))
    }

    func testDiskWriteIsAtomicAndReadIsDecoded() async throws {
        let tmp = TempDir("thumb-atomic")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url)
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        await cache.waitForPendingDiskWrites()
        let file = try await cache.diskFileURL(for: source, maxPixelSize: 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [], "temp files are renamed into place")
        XCTAssertNotNil(ThumbnailDiskStore.read(at: file))
        XCTAssertNil(ThumbnailDiskStore.read(at: tmp.url.appendingPathComponent("missing.heic")))
    }

    func testDefaultConcurrencyFollowsCoreCount() throws {
        let n = ThumbnailCache.defaultMaxConcurrentDecodes
        XCTAssertGreaterThanOrEqual(n, 2)
        XCTAssertLessThanOrEqual(n, max(2, ProcessInfo.processInfo.activeProcessorCount))
    }
}

/// Order in which gated sources started decoding.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.lock(); defer { lock.unlock() }; return _ids }
    func append(_ id: String) { lock.lock(); _ids.append(id); lock.unlock() }
}

/// A source whose decode waits until `open()`; counts decodes.
private final class GatedSource: ImageSource, @unchecked Sendable {
    let id: String
    let log: OrderLog?
    private let lock = NSLock()
    private var isOpen = false
    private var decodes = 0

    init(id: String, log: OrderLog? = nil) { self.id = id; self.log = log }

    static func == (a: GatedSource, b: GatedSource) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
    var displayName: String { id }
    var fileSize: Int64? { 1 }
    var mtime: Date? { Date(timeIntervalSince1970: 1) }
    var decodeCount: Int { lock.lock(); defer { lock.unlock() }; return decodes }
    func open() { lock.lock(); isOpen = true; lock.unlock() }

    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        lock.withLock { decodes += 1 }
        log?.append(id)
        while !(lock.withLock { isOpen }) { try? await Task.sleep(nanoseconds: 1_000_000) }
        return Self.image(side: maxPixelSize ?? 64)
    }

    func loadProperties() async throws -> ImageProperties { throw ImageSourceError.unsupported }

    static func image(side: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx.makeImage()!
    }
}

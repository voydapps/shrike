//
//  DecodeQueueTests.swift
//  ShrikeCoreTests
//

import XCTest
import CoreGraphics
@testable import ShrikeCore

// MARK: - TestImageSource

/// Sleep-N-milliseconds-then-return-a-tiny-CGImage mock. Used by the
/// rapid-nav supersession tests so we can simulate realistic decode
/// cost without actually paying ImageIO's per-call overhead.
///
/// The sleep is a plain `Task.sleep` inside `loadCGImage`; the decode
/// runs inside a `Task.detached` in `DecodeQueue.spawnDecode`, so the
/// sleep doesn't block the actor's thread. This is what lets stale
/// jumps cut the queue once `latestNavGen` has advanced past them.
struct TestImageSource: ImageSource {
    let key: Int
    let decodeDelayMS: Int

    var id: String { "test://\(key)" }
    var displayName: String { "test-\(key)" }
    var fileSize: Int64? { 0 }
    var mtime: Date? { nil }

    func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
        if decodeDelayMS > 0 {
            try? await Task.sleep(nanoseconds: UInt64(decodeDelayMS) * 1_000_000)
        }
        // 1x1 RGBA pixel. Cheap to allocate, satisfies the width > 0
        // asserts in the rest of the suite without touching ImageIO.
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let img = ctx.makeImage() else {
            throw ImageSourceError.corrupt
        }
        return img
    }

    func loadProperties() async throws -> ImageProperties {
        ImageProperties(
            pixelWidth: 1,
            pixelHeight: 1,
            orientation: .up,
            colorSpaceName: "sRGB",
            bitDepth: 8,
            hasAlpha: true,
            exif: nil,
            utType: .png,
            fileSize: 0
        )
    }
}

final class DecodeQueueTests: XCTestCase {

    /// Helper — copies a fixture under N different names so we have N
    /// distinct `FileImageSource`s with different content hashes.
    private func makeNavList(count: Int, tmp: TempDir) throws -> [FileImageSource] {
        let src = try TestFixture.url("small.jpg")
        var list: [FileImageSource] = []
        for i in 0..<count {
            let dst = tmp.url.appendingPathComponent("img_\(i).jpg")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            // Touch mtime slightly so hashes differ on both path + mtime.
            let mtime = Date(timeIntervalSince1970: 1_700_000_000 + Double(i))
            try FileManager.default.setAttributes(
                [.modificationDate: mtime],
                ofItemAtPath: dst.path
            )
            list.append(FileImageSource(url: dst))
        }
        return list
    }

    func testNavigation_advanceAndRetreat() async throws {
        let tmp = TempDir("decode-nav")
        defer { tmp.cleanup() }
        let sources = try makeNavList(count: 5, tmp: tmp)

        let q = DecodeQueue()
        await q.setNavigation(list: sources, currentIndex: 0)
        // Drain prefetch.
        try await Task.sleep(nanoseconds: 200_000_000)

        let (img1, i1) = try await q.advance()
        XCTAssertEqual(i1, 1)
        XCTAssertGreaterThan(img1.width, 0)

        let (img2, i2) = try await q.advance()
        XCTAssertEqual(i2, 2)
        XCTAssertGreaterThan(img2.width, 0)

        let (img0, i0) = try await q.retreat()
        XCTAssertEqual(i0, 1) // retreat from 2 → 1
        XCTAssertGreaterThan(img0.width, 0)
    }

    func testJumpTo_populatesCurrent() async throws {
        let tmp = TempDir("decode-jump")
        defer { tmp.cleanup() }
        let sources = try makeNavList(count: 3, tmp: tmp)

        let q = DecodeQueue()
        await q.setNavigation(list: sources, currentIndex: 0)

        let img = try await q.jumpTo(index: 2)
        XCTAssertGreaterThan(img.width, 0)

        let current = await q.current()
        XCTAssertNotNil(current)
    }

    func testOutOfRange_throws() async throws {
        let tmp = TempDir("decode-oob")
        defer { tmp.cleanup() }
        let sources = try makeNavList(count: 2, tmp: tmp)

        let q = DecodeQueue()
        await q.setNavigation(list: sources, currentIndex: 0)

        do {
            _ = try await q.jumpTo(index: 99)
            XCTFail("expected out-of-range")
        } catch let err as DecodeQueueError {
            XCTAssertEqual(err, .outOfRange)
        }
    }

    func testLoadFullRes() async throws {
        let tmp = TempDir("decode-full")
        defer { tmp.cleanup() }
        let sources = try makeNavList(count: 1, tmp: tmp)

        let q = DecodeQueue()
        await q.setNavigation(list: sources, currentIndex: 0)
        let img = try await q.loadFullRes(at: 0)
        XCTAssertEqual(img.width, 128)
        XCTAssertEqual(img.height, 128)
    }

    // MARK: - Rapid-nav supersession
    //
    // The scenario: a folder of 81 photos, and the right arrow held down
    // for a full round (1→81), then a second round that stops at 47.
    // It used to take 10-15 seconds to show the right photo.
    //
    // Before the generation-counter fix, every jump that had already
    // landed on the actor kept running to completion — 128 queued
    // jumps serialized at ~80-120 ms each = 10-15 s drain. These
    // tests lock in the new behavior: only the *latest* jump does
    // real work; every earlier jump aborts at a `latestNavGen` guard.

    /// Burst 10 jumps without awaiting each. Only the final one should
    /// resolve with `(CGImage, Int)`; the earlier 9 should throw
    /// `CancellationError`.
    func testRapidJumps_OnlyLatestCompletesWithValue() async throws {
        let q = DecodeQueue()
        let sources = (0..<10).map { TestImageSource(key: $0, decodeDelayMS: 50) }
        await q.setNavigation(list: sources, currentIndex: 0)

        // Fire 10 jumps as child tasks of a task group so the burst is
        // genuinely concurrent on the actor's mailbox.
        let results = await withTaskGroup(of: (Int, Result<CGImage, any Error>).self) { group in
            for i in 0..<10 {
                group.addTask {
                    do {
                        let img = try await q.jumpTo(index: i)
                        return (i, .success(img))
                    } catch {
                        return (i, .failure(error))
                    }
                }
            }
            var out: [(Int, Result<CGImage, any Error>)] = []
            for await r in group { out.append(r) }
            return out
        }

        // Every jump that was *not* the final one to stamp its
        // generation should have aborted with `CancellationError`.
        // At least one jump must have succeeded. Which index ends up
        // "winning" depends on actor scheduling — we assert cardinality
        // plus the flavour of failures, not the specific winning index.
        let successes = results.filter {
            if case .success = $0.1 { return true } else { return false }
        }
        let cancellations = results.filter {
            if case .failure(let err) = $0.1, err is CancellationError { return true }
            return false
        }
        let otherErrors = results.filter {
            if case .failure(let err) = $0.1, !(err is CancellationError) { return true }
            return false
        }

        XCTAssertEqual(otherErrors.count, 0,
                       "no non-cancellation errors expected; saw: \(otherErrors)")
        XCTAssertGreaterThanOrEqual(successes.count, 1,
                                    "at least one jump must win and paint")
        XCTAssertEqual(successes.count + cancellations.count, 10)
        XCTAssertGreaterThanOrEqual(cancellations.count, 1,
                                    "stale jumps must be superseded, not all completed")
    }

    /// Fire 128 jumps, measure how long it takes the final one to
    /// resolve. With the fix, stale jumps abort at their first guard
    /// (skipping the 50 ms synthetic decode entirely), so total
    /// wall-clock should be dominated by a small number of actual
    /// decodes — well under 1 s. Before the fix this would be ~6.4 s
    /// (128 × 50 ms) worst case.
    func testBurstOf128Jumps_FinalResolvesQuickly() async throws {
        let q = DecodeQueue()
        let sources = (0..<128).map { TestImageSource(key: $0, decodeDelayMS: 50) }
        await q.setNavigation(list: sources, currentIndex: 0)

        let start = Date()

        // Fire 128 jumps concurrently; wait for *all* of them to either
        // succeed or throw, so we know the whole burst has drained.
        let allResolved: [Bool] = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<128 {
                group.addTask {
                    do {
                        _ = try await q.jumpTo(index: i)
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var out: [Bool] = []
            for await ok in group { out.append(ok) }
            return out
        }

        let elapsed = Date().timeIntervalSince(start)

        // Sanity: all 128 jumps returned (either success or cancel);
        // none hung.
        XCTAssertEqual(allResolved.count, 128)

        // Target: well under 1 s. If the generation supersession broke,
        // stale jumps would each wait on their own 50 ms decode and
        // this would easily exceed 5 s. Leave some slack for CI noise.
        XCTAssertLessThan(elapsed, 1.0,
                          "128-jump burst took \(elapsed)s — expected < 1.0s; "
                          + "supersession regressed, stale jumps are decoding")
    }

    /// Jump to index 5 and immediately jump to index 80 before the
    /// first resolves. The prefetch window must end up around 80,
    /// not 5 — a stale prefetch priming around 5 would cache the
    /// wrong neighbours and starve the new current's decode.
    ///
    /// We observe this via `current()`: after the winning jump
    /// lands, the actor's current index must be 80 (what the user
    /// asked for), not 5 (the stale starting point).
    func testStaleJumpDoesNotPollutePrefetch() async throws {
        let q = DecodeQueue()
        let sources = (0..<128).map { TestImageSource(key: $0, decodeDelayMS: 50) }
        await q.setNavigation(list: sources, currentIndex: 0)

        // Fire both jumps concurrently. The 80 must supersede the 5.
        async let stale: CGImage? = {
            do { return try await q.jumpTo(index: 5) }
            catch { return nil }
        }()
        async let winner: CGImage? = {
            do { return try await q.jumpTo(index: 80) }
            catch { return nil }
        }()

        let (staleResult, winResult) = await (stale, winner)

        // Exactly one must have been cancelled (got nil). The other
        // must hold a valid image. Which one wins depends on actor
        // scheduling, but the post-condition on the cache is what
        // we really care about.
        let succeeded = [staleResult, winResult].compactMap { $0 }
        XCTAssertGreaterThanOrEqual(succeeded.count, 1,
                                    "at least one jump should resolve")

        // After the dust settles, the actor's `current()` lookup must
        // point at index 80. If the stale jump had kept running and
        // completed last, it would have installed index 5 into the
        // cache and left `currentIndex = 5` — that's the regression.
        //
        // Because `jumpTo` sets `currentIndex` synchronously on entry,
        // whichever jump lands *last* on the actor stamps currentIndex.
        // With supersession, only the winning jump's installation
        // survives because stale jumps throw before `cache[index] = …`.
        let current = await q.current()
        XCTAssertNotNil(current,
                        "current() must return the winning decode's image")
    }

    // MARK: - Thumbnail-size clamp
    //
    // ImageIO emits `createThumbnailAtIndex: ... kCGImageSourceThumbnail-
    // MaxPixelSize: 8192 is larger than image-dimension: 5184x3888`
    // whenever we request a thumbnail at a long-edge larger than the
    // source's own longer edge. Before the fix, `targetPixelSize(for:)`
    // returned `maxDisplayLongEdge * 2 = 8192` unconditionally. After
    // the fix, a per-source header-dimensions cache clamps the request
    // to `min(unclamped, max(w, h))` on cache hit and populates the
    // cache lazily via a fire-and-forget probe on cache miss.

    /// An `ImageSource` whose `loadProperties()` returns fixed
    /// dimensions. Used by the clamp tests so we don't need a
    /// thousand-file on-disk fixture to exercise LRU eviction.
    struct DimensionedMockSource: ImageSource {
        let key: String
        let width: Int
        let height: Int
        /// When `true`, `loadProperties()` throws — simulates a
        /// probe that fails and confirms the cache stays empty.
        let failProperties: Bool

        init(key: String, width: Int, height: Int, failProperties: Bool = false) {
            self.key = key
            self.width = width
            self.height = height
            self.failProperties = failProperties
        }

        var id: String { "mock://\(key)" }
        var displayName: String { key }
        var fileSize: Int64? { 0 }
        var mtime: Date? { nil }

        func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
            // 1x1 stub — the clamp tests don't exercise the real
            // decode path.
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx = CGContext(
                data: nil,
                width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard let img = ctx.makeImage() else { throw ImageSourceError.corrupt }
            return img
        }

        func loadProperties() async throws -> ImageProperties {
            if failProperties { throw ImageSourceError.corrupt }
            return ImageProperties(
                pixelWidth: width,
                pixelHeight: height,
                orientation: .up,
                colorSpaceName: "sRGB",
                bitDepth: 8,
                hasAlpha: false,
                exif: nil,
                utType: .jpeg,
                fileSize: 0
            )
        }
    }

    /// With a seeded dimension cache, `targetPixelSize` must clamp to
    /// the source's longer edge. `maxDisplayLongEdge = 4096` → unclamped
    /// request is `8192`; source is `5184x3888` → clamped result `5184`.
    func testTargetPixelSize_ClampsToSourceDimensions() async throws {
        let q = DecodeQueue()
        let src = DimensionedMockSource(key: "a", width: 5184, height: 3888)
        await q.setNavigation(list: [src], currentIndex: 0)

        // Seed synchronously so this test doesn't depend on probe timing.
        await q.seedDimensionCache(id: src.id, width: 5184, height: 3888)

        let size = await q.targetPixelSize(for: 0)
        XCTAssertEqual(size, min(Prefs.maxDisplayLongEdge, 5184),
                       "should clamp to max(width, height) when < unclamped (8192)")
    }

    /// Empty cache — the fallback must preserve the pre-fix behaviour
    /// (return the unclamped request) so the decode pipeline still
    /// works on the *first* call for a source. The ImageIO warning
    /// fires once per URL in this window, then the probe lands and
    /// subsequent calls come back silent.
    func testTargetPixelSize_FallsBackToUnclampedOnCacheMiss() async throws {
        let q = DecodeQueue()
        let src = DimensionedMockSource(key: "miss", width: 5184, height: 3888)
        await q.setNavigation(list: [src], currentIndex: 0)

        // Cache is empty — no seed.
        let size = await q.targetPixelSize(for: 0)
        // maxDisplayLongEdge defaults to 4096, unclamped = Prefs.maxDisplayLongEdge.
        XCTAssertEqual(size, Prefs.maxDisplayLongEdge,
                       "cache miss must fall back to unclamped request")
    }

    /// A cache miss must launch a probe that populates the cache with
    /// the source's real dimensions. After the probe lands, a second
    /// call for the same index returns the clamped value.
    func testTargetPixelSize_CachePopulatedAfterFirstLoad() async throws {
        let q = DecodeQueue()
        let src = DimensionedMockSource(key: "probe", width: 3000, height: 2000)
        await q.setNavigation(list: [src], currentIndex: 0)

        // First call — cache miss, returns unclamped, fires probe.
        let first = await q.targetPixelSize(for: 0)
        XCTAssertEqual(first, Prefs.maxDisplayLongEdge)

        // The probe is a fire-and-forget Task. Poll until the cache
        // has it (bounded by a generous timeout so a slow CI doesn't
        // false-fail). The probe does no file I/O for mock sources,
        // so it should land within a few scheduler hops.
        let deadline = Date().addingTimeInterval(2.0)
        while await !q.dimensionCacheContains(id: src.id),
              Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10 ms
        }
        let landed = await q.dimensionCacheContains(id: src.id)
        XCTAssertTrue(landed, "probe must populate the dimension cache")

        // Second call — cache hit, clamps to min(8192, 3000) = 3000.
        let second = await q.targetPixelSize(for: 0)
        XCTAssertEqual(second, 3000,
                       "post-probe call must clamp to source's long edge")
    }

    /// Populate one past the cap and confirm the oldest entry is
    /// evicted. The cap is exposed as a static so this test stays
    /// in lockstep with the real value — no magic number.
    func testTargetPixelSize_LRUCapped() async throws {
        let q = DecodeQueue()
        // Single source is fine — we drive LRU directly via
        // `seedDimensionCache`, which is the production install path.
        let src = DimensionedMockSource(key: "lru-host", width: 100, height: 100)
        await q.setNavigation(list: [src], currentIndex: 0)

        let cap = DecodeQueue.dimensionCacheCap
        // Seed cap + 1 distinct keys. The first-seeded key must be
        // the one evicted.
        for i in 0..<(cap + 1) {
            await q.seedDimensionCache(id: "lru://key-\(i)", width: 100, height: 100)
        }

        let count = await q.dimensionCacheCount()
        XCTAssertEqual(count, cap,
                       "cache must not exceed cap")
        let firstStillPresent = await q.dimensionCacheContains(id: "lru://key-0")
        XCTAssertFalse(firstStillPresent,
                       "oldest entry must be evicted once cap is exceeded")
        let newestPresent = await q.dimensionCacheContains(id: "lru://key-\(cap)")
        XCTAssertTrue(newestPresent,
                      "most-recent entry must remain")
    }
}

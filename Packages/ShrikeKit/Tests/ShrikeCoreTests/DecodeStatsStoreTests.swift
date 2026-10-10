//
//  DecodeStatsStoreTests.swift
//  ShrikeCoreTests
//
//  Exercise the ring-buffer + rolling-percentile actor that feeds
//  `DecodeTimePredictor`. We care about three invariants:
//
//    1. No stats are returned below the minimum sample threshold.
//    2. p50 tracks the true median of the window as samples arrive.
//    3. Once the ring fills, old samples roll off (the window
//       follows the user's current hardware profile, not their
//       history from two months ago).
//

import XCTest
@testable import ShrikeCore

final class DecodeStatsStoreTests: XCTestCase {

    // MARK: - Sample threshold

    func testReturnsNilBelowMinimumSamples() async {
        let store = DecodeStatsStore()
        // Threshold is 4; record 3 and expect nil.
        await store.record(format: .jpeg, duration: 0.050)
        await store.record(format: .jpeg, duration: 0.050)
        await store.record(format: .jpeg, duration: 0.050)

        let stats = await store.stats(for: .jpeg)
        XCTAssertNil(stats, "store must withhold stats below minSamplesForStats")
    }

    func testReturnsStatsAtMinimumSamples() async {
        let store = DecodeStatsStore()
        for _ in 0..<DecodeStatsStore.minSamplesForStats {
            await store.record(format: .jpeg, duration: 0.100)
        }
        let stats = await store.stats(for: .jpeg)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.count, DecodeStatsStore.minSamplesForStats)
        XCTAssertEqual(stats?.p50 ?? 0, 0.100, accuracy: 1e-9)
    }

    // MARK: - p50 monotonicity

    func testP50TracksMedianOfInsertedSamples() async {
        let store = DecodeStatsStore()
        // Insert ascending samples; median of [0.10, 0.20, 0.30, 0.40]
        // under nearest-rank is the 2nd ordered element (0.20).
        for d in [0.10, 0.20, 0.30, 0.40] {
            await store.record(format: .heic, duration: d)
        }
        let stats = await store.stats(for: .heic)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.p50 ?? 0, 0.20, accuracy: 1e-9)
    }

    func testP50RisesWhenUnderlyingDistributionShiftsUp() async {
        let store = DecodeStatsStore()
        for _ in 0..<8 {
            await store.record(format: .raw, duration: 0.200)
        }
        let before = await store.stats(for: .raw)
        XCTAssertNotNil(before)
        let p50Before = before?.p50 ?? 0

        // Now the user opens a folder of bigger RAWs; decodes are
        // slower. Feed enough new samples to shift the median.
        for _ in 0..<12 {
            await store.record(format: .raw, duration: 0.500)
        }
        let after = await store.stats(for: .raw)
        let p50After = after?.p50 ?? 0

        XCTAssertGreaterThan(p50After, p50Before,
                             "median must track the shift in the underlying distribution")
    }

    func testP95GreaterThanOrEqualToP50() async {
        // Sanity: tail percentile can't fall below the median.
        let store = DecodeStatsStore()
        for d in [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.80, 1.00] {
            await store.record(format: .png, duration: d)
        }
        let stats = await store.stats(for: .png)
        XCTAssertNotNil(stats)
        XCTAssertGreaterThanOrEqual(stats?.p95 ?? 0, stats?.p50 ?? 0)
    }

    // MARK: - Ring-buffer eviction

    func testRingBufferCapsAtSampleWindow() async {
        let store = DecodeStatsStore()
        // Push 100 samples; ring should hold only the last 64.
        let total = 100
        for i in 0..<total {
            await store.record(format: .png, duration: 0.010 + Double(i) * 0.001)
        }
        let count = await store.sampleCount(for: .png)
        XCTAssertEqual(count, DecodeStatsStore.sampleWindow,
                       "ring must not grow past sampleWindow")
    }

    func testOldSamplesAreEvictedAfterWindowFill() async {
        // Fill the ring with fast samples (10 ms). Confirm median.
        // Then flood the ring with slow samples (500 ms). The old
        // fast samples must all be evicted — median jumps to 500 ms.
        let store = DecodeStatsStore()

        for _ in 0..<DecodeStatsStore.sampleWindow {
            await store.record(format: .tiff, duration: 0.010)
        }
        let fastStats = await store.stats(for: .tiff)
        XCTAssertEqual(fastStats?.p50 ?? 0, 0.010, accuracy: 1e-9)

        // Overwrite the entire ring.
        for _ in 0..<DecodeStatsStore.sampleWindow {
            await store.record(format: .tiff, duration: 0.500)
        }
        let slowStats = await store.stats(for: .tiff)
        XCTAssertEqual(slowStats?.p50 ?? 0, 0.500, accuracy: 1e-9,
                       "after full ring overwrite, no fast samples should remain")
        XCTAssertEqual(slowStats?.count, DecodeStatsStore.sampleWindow)
    }

    // MARK: - Per-format isolation

    func testSamplesAreKeyedByFormat() async {
        // Samples for JPEG must not leak into HEIC stats.
        let store = DecodeStatsStore()
        for _ in 0..<8 {
            await store.record(format: .jpeg, duration: 0.050)
        }
        // HEIC has zero samples — stats must still be nil.
        let heicStats = await store.stats(for: .heic)
        XCTAssertNil(heicStats)

        let jpegStats = await store.stats(for: .jpeg)
        XCTAssertNotNil(jpegStats)
        XCTAssertEqual(jpegStats?.p50 ?? 0, 0.050, accuracy: 1e-9)
    }

    func testNegativeDurationsAreIgnored() async {
        // Clock-skew / misbehaving monotonic source could produce
        // these. The predictor's arithmetic would still work, but
        // poisoning the median with a negative is worse than
        // dropping the sample.
        let store = DecodeStatsStore()
        await store.record(format: .jpeg, duration: -1.0)
        await store.record(format: .jpeg, duration: -0.5)
        await store.record(format: .jpeg, duration: -0.001)
        let count = await store.sampleCount(for: .jpeg)
        XCTAssertEqual(count, 0, "negative durations must be dropped, not stored")
    }

    func testZeroDurationIsAccepted() async {
        // Zero is legal — a cached/ramfs decode really can measure
        // below the wall-clock resolution. Don't drop it.
        let store = DecodeStatsStore()
        for _ in 0..<4 {
            await store.record(format: .bmp, duration: 0)
        }
        let stats = await store.stats(for: .bmp)
        XCTAssertNotNil(stats)
        XCTAssertEqual(stats?.p50 ?? -1, 0, accuracy: 1e-9)
    }
}

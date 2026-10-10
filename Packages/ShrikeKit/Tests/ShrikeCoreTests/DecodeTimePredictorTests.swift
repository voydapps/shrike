//
//  DecodeTimePredictorTests.swift
//  ShrikeCoreTests
//
//  Pins the pure-function predictor against the cold-start + stats
//  cases. These numbers are the contract: the
//  hairline grace logic on the UI side will key its 100 ms cutoff
//  off them, and regressing them silently would misalign when the
//  indicator appears.
//

import XCTest
@testable import ShrikeCore

final class DecodeTimePredictorTests: XCTestCase {

    // MARK: - Cold-start cases (no rolling stats yet)

    func testColdStart_2MB_JPEG_equals40ms() {
        let p = DecodeTimePredictor.predict(
            fileSize: 2_000_000,
            format: .jpeg,
            stats: nil
        )
        XCTAssertEqual(p, 0.040, accuracy: 1e-9,
                       "2 MB JPEG should be exactly the JPEG cold-start base (40 ms)")
    }

    func testColdStart_20MB_HEIC_equals800ms() {
        let p = DecodeTimePredictor.predict(
            fileSize: 20_000_000,
            format: .heic,
            stats: nil
        )
        // base 80 ms × (20 MB / 2 MB) = 80 ms × 10 = 800 ms.
        // Also brushes the 10× clamp boundary — result must be 800, not 1600.
        XCTAssertEqual(p, 0.800, accuracy: 1e-9,
                       "20 MB HEIC should scale to 10× base = 800 ms")
    }

    func testColdStart_8MB_RAW_equals1200ms() {
        let p = DecodeTimePredictor.predict(
            fileSize: 8_000_000,
            format: .raw,
            stats: nil
        )
        // base 300 ms × (8 / 2) = 300 ms × 4 = 1200 ms.
        // Well under the 10× clamp (which would be 3000 ms).
        XCTAssertEqual(p, 1.200, accuracy: 1e-9,
                       "8 MB RAW should scale 4× to 1200 ms")
    }

    func testColdStart_200KB_PNG_equals120ms() {
        let p = DecodeTimePredictor.predict(
            fileSize: 200_000,
            format: .png,
            stats: nil
        )
        // Below the 2 MB reference → multiplier floored at 1.0.
        XCTAssertEqual(p, 0.120, accuracy: 1e-9,
                       "sub-reference filesize must floor the multiplier at 1.0")
    }

    func testColdStart_OtherFormat_usesOtherBase() {
        // Unknown format → `.other` table entry, 150 ms base.
        let p = DecodeTimePredictor.predict(
            fileSize: 1_000_000,
            format: .other,
            stats: nil
        )
        XCTAssertEqual(p, 0.150, accuracy: 1e-9)
    }

    // MARK: - Clamp behavior at large sizes

    func testClamp_40MB_JPEG_capsAtTenTimesBase() {
        // A 40 MB JPEG is the canonical "big JPEG" case. Raw
        // multiplier would be 20×; clamp must bring it to 10×.
        // 40 ms × 10 = 400 ms — which is still an over-estimate
        // in practice, but the clamp is what keeps it from being
        // 800 ms.
        let p = DecodeTimePredictor.predict(
            fileSize: 40_000_000,
            format: .jpeg,
            stats: nil
        )
        XCTAssertEqual(p, 0.400, accuracy: 1e-9,
                       "40 MB JPEG must be clamped at 10× (= 400 ms), not 800 ms")
    }

    func testClamp_HugeRAW_capsAt3000ms() {
        // 100 MB RAW → naive multiplier is 50, clamp must bring it
        // to 10 → 300 ms × 10 = 3000 ms. This is the upper bound
        // for a RAW cold-start prediction.
        let p = DecodeTimePredictor.predict(
            fileSize: 100_000_000,
            format: .raw,
            stats: nil
        )
        XCTAssertEqual(p, 3.000, accuracy: 1e-9,
                       "100 MB RAW must be clamped at 10× = 3000 ms")
    }

    func testMultiplier_ExactlyAtReferenceSize_isOne() {
        // Boundary check: file size == referenceSize → multiplier
        // exactly 1. Want to be sure the `max(1, ratio)` doesn't
        // accidentally round up.
        let p = DecodeTimePredictor.predict(
            fileSize: DecodeTimePredictor.referenceSize,
            format: .jpeg,
            stats: nil
        )
        XCTAssertEqual(p, 0.040, accuracy: 1e-9)
    }

    func testZeroFileSize_usesFloor() {
        // A zero-byte file can still happen (iCloud placeholder).
        // The floor of 1.0 means we return the base duration — a
        // safe over-estimate, never negative.
        let p = DecodeTimePredictor.predict(
            fileSize: 0,
            format: .jpeg,
            stats: nil
        )
        XCTAssertEqual(p, 0.040, accuracy: 1e-9)
    }

    // MARK: - Stats override (rolling p50 replaces cold-start)

    func testStatsOverride_RAW_p50_320ms_8MB_equals1280ms() {
        // Named case: stats.p50 = 0.320, 8 MB RAW, expect
        // 0.320 × 4 = 1.28 s. Proves the predictor swaps the base
        // once we have a real measurement in hand.
        let stats = DecodeStats(p50: 0.320, p95: 0.500, count: 8)
        let p = DecodeTimePredictor.predict(
            fileSize: 8_000_000,
            format: .raw,
            stats: stats
        )
        XCTAssertEqual(p, 1.280, accuracy: 1e-9)
    }

    func testStatsOverride_RequiresMinimumSamples() {
        // With fewer than minSamplesForStats samples, the snapshot
        // should be ignored and cold-start used. This is defence in
        // depth — `DecodeStatsStore.stats(for:)` already filters —
        // but the pure function shouldn't trust its caller.
        let tooFew = DecodeStats(p50: 1.000, p95: 1.000, count: 2)
        let p = DecodeTimePredictor.predict(
            fileSize: 2_000_000,
            format: .jpeg,
            stats: tooFew
        )
        // Cold-start JPEG at 2 MB = 40 ms, NOT 1 s.
        XCTAssertEqual(p, 0.040, accuracy: 1e-9,
                       "predictor must ignore stats below minSamplesForStats")
    }

    func testStatsOverride_StillClampsAtTenTimes() {
        // If actual stats say this format takes 500 ms on our
        // hardware, a 40 MB file should still clamp at 10× =
        // 5.00 s, not blow past the cap.
        let stats = DecodeStats(p50: 0.500, p95: 1.000, count: 32)
        let p = DecodeTimePredictor.predict(
            fileSize: 40_000_000,
            format: .heic,
            stats: stats
        )
        XCTAssertEqual(p, 5.000, accuracy: 1e-9,
                       "clamp applies whether base came from stats or cold-start")
    }

    func testStatsOverride_BelowReferenceSize_UsesFlatBase() {
        // 500 KB file with real 80 ms stats → predictor returns
        // 80 ms flat (multiplier floored at 1).
        let stats = DecodeStats(p50: 0.080, p95: 0.150, count: 10)
        let p = DecodeTimePredictor.predict(
            fileSize: 500_000,
            format: .heic,
            stats: stats
        )
        XCTAssertEqual(p, 0.080, accuracy: 1e-9)
    }

    // MARK: - Async convenience (file I/O path)

    func testAsyncPredict_realFile_classifiesAndPredictsNonZero() async throws {
        // Drop a known-size fake image at a .jpg extension so the
        // classifier sees JPEG. We don't care about the actual
        // predicted number — just that the async wrapper resolves
        // the filesize + format path without error.
        let tmp = TempDir("predictor-async")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("fake.jpg")
        // ~1 KB of bytes. Enough that `stat` reports a real size.
        let data = Data(repeating: 0xAB, count: 1024)
        try data.write(to: url)

        let store = DecodeStatsStore()   // empty — forces cold-start
        let predicted = await DecodeTimePredictor.predict(url: url, store: store)

        // Cold JPEG at 1 KB: multiplier floors at 1 → 40 ms.
        XCTAssertEqual(predicted, 0.040, accuracy: 1e-9)
    }

    func testAsyncPredict_missingFile_fallsBackToZeroSize() async throws {
        // Missing files hit `fileSize == 0`, which goes through the
        // multiplier floor → we still get a sensible base prediction
        // rather than a crash or negative number.
        let url = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).jpg")
        let store = DecodeStatsStore()
        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertEqual(predicted, 0.040, accuracy: 1e-9)
    }
}

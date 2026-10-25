//
//  PredictiveHairlineIntegrationTests.swift
//  ShrikeUITests
//
//  Integration tests for the predictive-hairline gate.
//  Wires `DecodeTimePredictor` + `DecodeStatsStore` + `NavigationPosition
//  OverlayView` + `NavigationFeedbackState` together the same way
//  `ViewerWindow.navigateWithFeedback` does, minus the window / decode
//  plumbing. This lets the gate logic be exercised deterministically:
//
//    1. beginNavigation() bumps generation
//    2. scheduleHairlineShow(predicted:) starts the 100 ms grace timer
//       with a default `predicted` so the pre-fill math is defined.
//    3. detached Task awaits DecodeTimePredictor.predict(url:store:)
//    4. on MainActor, generation check + threshold check →
//       - predicted > 150 ms: setHairlineProgress(predicted:) skips the
//         grace and reveals at t=0.
//       - predicted ≤ 150 ms: scheduleHairlineShow(predicted:) again to
//         refine the captured value; the grace still fires at 100 ms.
//
//  The predictor itself reads file size via FileManager, so we write
//  small test fixture files to a temp dir with sizes that force the
//  predictor's output through specific branches.
//

import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PredictiveHairlineIntegrationTests: XCTestCase {

    // MARK: - Fixtures

    private var tempDir: URL!

    /// Default `predicted` seed used when the viewer scheduleS the grace
    /// before the predictor has resolved. Mirrors
    /// `ViewerWindow.hairlineDefaultPredicted`.
    private static let defaultPredicted: TimeInterval = 0.150

    override func setUp() async throws {
        try await super.setUp()
        tempDir = TestScratch.directory
            .appendingPathComponent("PredictiveHairlineIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try await super.tearDown()
    }

    /// Write a zero-padded file of the given size + extension into the
    /// test's temp dir. Contents are irrelevant — the predictor reads
    /// only file size + extension.
    private func makeFixture(name: String, bytes: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let data = Data(count: bytes)
        try data.write(to: url)
        return url
    }

    // MARK: - Predictive-skip path

    /// Slow-predicted decode (20 MB HEIC → 800 ms, well above the
    /// 150 ms threshold) must take the zero-grace path: the hairline
    /// appears immediately at t=0, not after the 100 ms grace.
    ///
    /// Mirrors `ViewerWindow.scheduleHairlinePredictiveSkip` — we
    /// schedule the grace first with the default seed, then let the
    /// predictor race. The predictor's "slow" answer cancels the grace
    /// and shows now via `setHairlineProgress(predicted:)`.
    func testSlowPrediction_SkipsGraceAndShowsImmediately() async throws {
        let url = try makeFixture(name: "big.heic", bytes: 20_000_000)
        let store = DecodeStatsStore()
        let overlay = NavigationPositionOverlayView()

        // Kick off the grace first — simulating the viewer scheduling
        // both the grace and the predictor race at beginNavigation().
        overlay.scheduleHairlineShow(predicted: Self.defaultPredicted)
        XCTAssertNotNil(overlay.pendingHairlineShowTask)
        XCTAssertFalse(overlay.isHairlineVisible)

        // Run the predictor.
        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertGreaterThan(
            predicted,
            NavigationPositionOverlayView.hairlinePredictiveShowThreshold,
            "20 MB HEIC must predict above the 150 ms threshold"
        )

        // Apply the same branch as the viewer.
        if predicted > NavigationPositionOverlayView.hairlinePredictiveShowThreshold {
            overlay.setHairlineProgress(predicted: predicted)
        }

        XCTAssertNil(
            overlay.pendingHairlineShowTask,
            "predictive-skip must have cancelled the 100 ms grace"
        )
        XCTAssertTrue(
            overlay.isHairlineVisible,
            "slow prediction must surface the hairline at t=0"
        )
    }

    /// Fast-predicted decode (2 MB JPEG → 40 ms, well below the 150 ms
    /// threshold) keeps the grace path: the hairline does NOT appear
    /// before the 100 ms grace fires. The predictor correctly declines
    /// to take the predictive-skip branch.
    func testFastPrediction_DoesNotShowBeforeGrace() async throws {
        let url = try makeFixture(name: "small.jpg", bytes: 2_000_000)
        let store = DecodeStatsStore()
        let overlay = NavigationPositionOverlayView()

        overlay.scheduleHairlineShow(predicted: Self.defaultPredicted)

        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertLessThanOrEqual(
            predicted,
            NavigationPositionOverlayView.hairlinePredictiveShowThreshold,
            "2 MB JPEG must predict below the 150 ms threshold"
        )

        if predicted > NavigationPositionOverlayView.hairlinePredictiveShowThreshold {
            overlay.setHairlineProgress(predicted: predicted)
        } else {
            // Grace path: re-seed the captured predicted so the grace
            // fire uses the refined value.
            overlay.scheduleHairlineShow(predicted: predicted)
        }

        XCTAssertFalse(
            overlay.isHairlineVisible,
            "fast prediction must not surface the hairline before the grace"
        )
        XCTAssertNotNil(
            overlay.pendingHairlineShowTask,
            "grace timer must still be pending — the predictor didn't cancel it"
        )
    }

    /// RAW files always predict above threshold (300 ms cold-start
    /// base, above 150 ms at any file size). Every RAW decode should
    /// take the predictive-skip path — which is exactly the case most
    /// in need of covering, since RAW decodes are the 2-3 s cold cases
    /// the hairline was invented to signal.
    func testRAWFile_AlwaysSkipsGrace() async throws {
        let url = try makeFixture(name: "pic.cr2", bytes: 1_000_000)
        let store = DecodeStatsStore()
        let overlay = NavigationPositionOverlayView()

        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertGreaterThan(
            predicted,
            NavigationPositionOverlayView.hairlinePredictiveShowThreshold,
            "even a small RAW must predict above the 150 ms threshold"
        )

        if predicted > NavigationPositionOverlayView.hairlinePredictiveShowThreshold {
            overlay.setHairlineProgress(predicted: predicted)
        }

        XCTAssertTrue(
            overlay.isHairlineVisible,
            "RAW files must always take the predictive-skip path"
        )
    }

    // MARK: - Stale generation

    /// A predict Task resolving after a superseding `beginNavigation()`
    /// must not paint. The generation captured at predict-dispatch time
    /// no longer matches the live one, so the predictive-skip branch is
    /// skipped entirely — the new generation owns the hairline state.
    func testStaleGeneration_DoesNotShowHairline() async throws {
        let url = try makeFixture(name: "big.heic", bytes: 20_000_000)
        let store = DecodeStatsStore()
        let overlay = NavigationPositionOverlayView()
        let feedbackState = NavigationFeedbackState()

        let generation = feedbackState.beginNavigation()
        overlay.scheduleHairlineShow(predicted: Self.defaultPredicted)

        // Simulate the user mashing another arrow key BEFORE the
        // predictor resolves — the newer beginNavigation() bumps the
        // generation counter.
        _ = feedbackState.beginNavigation()

        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertGreaterThan(
            predicted,
            NavigationPositionOverlayView.hairlinePredictiveShowThreshold
        )

        // The viewer's predict-task continuation would check this
        // generation against the live one and bail. Replicate that
        // check here.
        let isStale = feedbackState.generation != generation
        XCTAssertTrue(isStale, "generation must have moved on")

        if !isStale,
           predicted > NavigationPositionOverlayView.hairlinePredictiveShowThreshold {
            overlay.setHairlineProgress(predicted: predicted)
        }

        XCTAssertFalse(
            overlay.isHairlineVisible,
            "stale predict-task must not paint — the new generation owns the hairline"
        )
    }

    // MARK: - Predictor history (p50 supersedes cold-start)

    /// Once `DecodeStatsStore` has enough samples for a format, its p50
    /// supersedes the cold-start base. A JPEG format with a p50 of
    /// 300 ms will predict above the threshold even at sizes where the
    /// cold-start base (40 ms) would have predicted fast. This is the
    /// "learns from this hardware" property of the predictor.
    func testHistorySupersedesColdStart_SlowHardwareTakesSkipPath() async throws {
        let url = try makeFixture(name: "small.jpg", bytes: 2_000_000)
        let store = DecodeStatsStore()
        let overlay = NavigationPositionOverlayView()

        // Record enough samples to pass the min-samples-for-stats gate.
        // 300 ms p50 → predict for a 2 MB JPEG returns 300 ms, above
        // the 150 ms threshold. Without these samples the cold-start
        // base would give 40 ms and the grace path would run.
        for _ in 0..<DecodeStatsStore.minSamplesForStats {
            await store.record(format: .jpeg, duration: 0.300)
        }

        let predicted = await DecodeTimePredictor.predict(url: url, store: store)
        XCTAssertEqual(
            predicted,
            0.300,
            accuracy: 1e-6,
            "history should override cold-start with recorded p50"
        )

        if predicted > NavigationPositionOverlayView.hairlinePredictiveShowThreshold {
            overlay.setHairlineProgress(predicted: predicted)
        }

        XCTAssertTrue(
            overlay.isHairlineVisible,
            "recorded history must let the predictor take the skip path even on a small JPEG"
        )
    }

    // MARK: - Isolated store per test

    /// Two back-to-back tests using fresh `DecodeStatsStore` instances
    /// must not see each other's samples — confirms the
    /// "isolated instance per test" rule.
    func testStoreInstanceIsolation() async throws {
        let storeA = DecodeStatsStore()
        let storeB = DecodeStatsStore()

        for _ in 0..<DecodeStatsStore.minSamplesForStats {
            await storeA.record(format: .jpeg, duration: 1.000)
        }

        let statsA = await storeA.stats(for: .jpeg)
        let statsB = await storeB.stats(for: .jpeg)

        XCTAssertNotNil(statsA, "storeA must have its recorded samples")
        XCTAssertNil(
            statsB,
            "storeB must not see storeA's recordings — instances are isolated"
        )
    }
}

//
//  DecodeStats.swift
//  ShrikeCore
//
//  Rolling per-format decode duration stats surfaced to
//  `DecodeTimePredictor`. Kept as a tiny `Sendable` value so it can
//  cross the `DecodeStatsStore` actor boundary without friction.
//
//  p50 is the one we actually use for prediction — it's robust to
//  the occasional outlier (a cold-cache fluke, a throttled SSD) in a
//  way that a mean would not be. p95 is retained for future
//  telemetry (e.g., alerting if a format's tail gets worse after an
//  OS update); it's not read by the predictor today.
//
//  `count` lets callers know how many samples the stats are based on.
//  `DecodeStatsStore.stats(for:)` returns `nil` below the minimum
//  sample threshold so the predictor knows to fall through to the
//  cold-start table.
//

import Foundation

/// Snapshot of rolling decode-duration stats for a single `ImageFormat`.
///
/// Durations are in **seconds** (wall-clock). All three fields are
/// drawn from the same sample window, so they're internally
/// consistent — take the whole struct or don't, don't mix-and-match.
public struct DecodeStats: Sendable, Hashable {
    /// Median duration in seconds. The primary prediction input.
    public let p50: TimeInterval

    /// 95th-percentile duration in seconds. Reserved for telemetry;
    /// not read by the predictor.
    public let p95: TimeInterval

    /// Number of samples backing this snapshot. Bounded above by
    /// `DecodeStatsStore.sampleWindow` (64).
    public let count: Int

    public init(p50: TimeInterval, p95: TimeInterval, count: Int) {
        self.p50 = p50
        self.p95 = p95
        self.count = count
    }
}

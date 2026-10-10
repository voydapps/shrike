//
//  DecodeStatsStore.swift
//  ShrikeCore
//
//  Actor that records per-format decode wall-clock durations as a
//  ring buffer and exposes a rolling p50/p95 snapshot. The predictor
//  (`DecodeTimePredictor`) consults it to decide whether the
//  hairline progress indicator should skip its 100 ms grace.
//
//  Design notes:
//
//  - Ring-buffer, not EWMA. Ring gives a hard cap on retained state
//    (one `ContiguousArray<TimeInterval>` per format) and lets us
//    compute true percentiles from the window — EWMA estimates the
//    mean well but the median is what we actually predict on.
//
//  - Window of 64 samples per format. That's big enough to smooth
//    noise from SSD thermal throttling or intermittent file-cache
//    misses, and small enough that a user who's just plugged in an
//    external drive starts seeing adjusted predictions within ~a
//    minute of browsing.
//
//  - Minimum of 4 samples before `stats(for:)` returns non-nil. With
//    fewer samples, quantiles are noise; the caller should fall
//    through to the cold-start table.
//
//  - In-memory only. Cold launch starts fresh. Persisting
//    across launches would trade a modest first-image-of-the-day
//    prediction win against a storage/privacy consideration; defer
//    until the predictor has proven its worth.
//
//  - Singleton `.shared` for the app path (one viewer ↔ one decode
//    queue ↔ one stats store). Tests construct their own instances
//    so they don't bleed state into one another.
//

import Foundation

/// Actor that records rolling decode durations per `ImageFormat`.
///
/// Tests can instantiate their own; production code uses
/// `DecodeStatsStore.shared`.
public actor DecodeStatsStore {

    /// Shared instance used by the production decode pipeline.
    /// `DecodeQueue` records full-resolution decode durations here so
    /// the predictor can learn the user's actual hardware profile.
    public static let shared = DecodeStatsStore()

    /// Maximum number of samples retained per format. Oldest entries
    /// are overwritten in a ring. See file header for rationale.
    public static let sampleWindow = 64

    /// Minimum samples required before `stats(for:)` returns non-nil.
    /// Below this, quantiles are noise — caller falls back to the
    /// cold-start table inside `DecodeTimePredictor`.
    public static let minSamplesForStats = 4

    /// Ring buffer per format. `nil` key means "no samples yet" —
    /// stored lazily so we don't allocate for formats the user never
    /// opens.
    private var samples: [ImageFormat: [TimeInterval]] = [:]

    /// Write cursor per format. Points at the slot that will be
    /// *overwritten* next. Once `samples[format].count` reaches
    /// `sampleWindow`, we stay at max size and just cycle the cursor.
    private var cursor: [ImageFormat: Int] = [:]

    public init() {}

    // MARK: - Recording

    /// Record a successful decode's wall-clock duration for the given
    /// format. Negative durations are ignored (shouldn't happen, but
    /// it's cheap insurance against clock-skew measurements).
    public func record(format: ImageFormat, duration: TimeInterval) {
        guard duration >= 0 else { return }

        var buffer = samples[format] ?? []
        if buffer.count < Self.sampleWindow {
            buffer.append(duration)
            samples[format] = buffer
            // Cursor not meaningful until the buffer is full; keep it
            // in sync anyway so the ring logic is uniform.
            cursor[format] = buffer.count % Self.sampleWindow
        } else {
            // Ring full — overwrite at the cursor.
            let slot = cursor[format] ?? 0
            buffer[slot] = duration
            samples[format] = buffer
            cursor[format] = (slot + 1) % Self.sampleWindow
        }
    }

    // MARK: - Querying

    /// Rolling stats snapshot for `format`, or `nil` if fewer than
    /// `minSamplesForStats` samples have been recorded. A `nil`
    /// return tells the predictor to use its cold-start table.
    public func stats(for format: ImageFormat) -> DecodeStats? {
        guard let buffer = samples[format], buffer.count >= Self.minSamplesForStats else {
            return nil
        }
        let sorted = buffer.sorted()
        let p50 = Self.percentile(of: sorted, at: 0.50)
        let p95 = Self.percentile(of: sorted, at: 0.95)
        return DecodeStats(p50: p50, p95: p95, count: sorted.count)
    }

    /// Sample count for `format` — primarily a test hook.
    public func sampleCount(for format: ImageFormat) -> Int {
        samples[format]?.count ?? 0
    }

    // MARK: - Percentile math

    /// Nearest-rank percentile over a *sorted* ascending input.
    /// `p` is in [0, 1]. Empty input returns 0 (caller is expected
    /// to guard via `minSamplesForStats`).
    ///
    /// Using nearest-rank (rather than linear interpolation) because
    /// the input is small (≤ 64 samples) — interpolation's smoother
    /// tail estimate isn't worth the extra code, and nearest-rank
    /// plays nicer with the tests that assert "p50 should be
    /// exactly this recorded sample".
    private static func percentile(of sorted: [TimeInterval], at p: Double) -> TimeInterval {
        guard !sorted.isEmpty else { return 0 }
        let clampedP = max(0.0, min(1.0, p))
        // Nearest-rank: ceil(p * N), 1-indexed → index `rank - 1`.
        let rank = Int((clampedP * Double(sorted.count)).rounded(.up))
        let idx = max(0, min(sorted.count - 1, rank - 1))
        return sorted[idx]
    }
}

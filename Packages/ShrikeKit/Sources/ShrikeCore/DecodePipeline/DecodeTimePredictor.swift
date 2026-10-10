//
//  DecodeTimePredictor.swift
//  ShrikeCore
//
//  Predicts the wall-clock duration of a full-resolution decode *before*
//  we dispatch it. The viewer's hairline progress indicator uses this
//  prediction to decide whether to skip its 100 ms grace window:
//
//      predicted >= graceMS   → show hairline immediately (slow decode)
//      predicted <  graceMS   → honour the grace (fast decode, stay chrome-free)
//
//  Pipeline:
//
//     URL  ─┬─▶ fileSize (FileManager, ~µs)
//           ├─▶ ImageFormat(url:)  (string match, ~ns)
//           └─▶ DecodeStatsStore.stats(for:)  (actor hop)
//                                │
//                                ▼
//                    predict(fileSize:format:stats:)  (pure)
//                                │
//                                ▼
//                     predicted TimeInterval
//
//  The pure `predict(fileSize:format:stats:)` function is the one the
//  test suite pins; the `predict(url:store:)` convenience layers IO
//  on top. Keep the math pure so the tests stay deterministic.
//
//  Scaling model:
//
//   - Below 2 MB: base cost (from stats.p50 or cold-start table).
//     Decoder overhead dominates at this size; file length barely
//     affects wall clock.
//
//   - Above 2 MB: linear in filesize, up to a 10× multiplier.
//     Real decode cost has a roughly linear component (pixel count
//     usually scales with file bytes within a format), but header-only
//     or thumbnail paths on big files can short-circuit — capping at
//     10× is what keeps a 40 MB JPEG from predicting 400 ms when
//     ImageIO will actually return in 60 ms.
//
//  We intentionally do NOT consider:
//
//   - Image dimensions. Would require a header read, which is
//     exactly the cost we're trying to preempt.
//
//   - Current CPU load / thermal state. First-order noise in the
//     stats window; adding it doubles complexity for marginal gain.
//

import Foundation

/// Pure-function decode-time predictor. Callers typically use
/// `predict(url:store:)`; the three-argument `predict` is the
/// testable core.
public struct DecodeTimePredictor: Sendable {

    // MARK: - Constants

    /// "Reference" file size. Predictions are `base * max(1, size / 2 MB)`.
    /// Two megabytes is where ImageIO's per-decode overhead stops
    /// dominating on M-series hardware and filesize starts to matter.
    public static let referenceSize: Int64 = 2_000_000

    /// Upper bound on the size multiplier. See file header for why.
    public static let maxSizeMultiplier: Double = 10.0

    /// Cold-start durations in seconds when we have no rolling stats
    /// yet for a format. Derived baseline
    /// measurements on M-series; refined empirically once a user has
    /// browsed enough to populate `DecodeStatsStore`.
    public static let coldStart: [ImageFormat: TimeInterval] = [
        .jpeg:  0.040,
        .heic:  0.080,
        .png:   0.120,
        .gif:   0.050,
        .tiff:  0.150,
        .webp:  0.080,
        .avif:  0.100,
        .bmp:   0.080,
        .raw:   0.300,
        .psd:   0.200,
        .pdf:   0.150,
        .other: 0.150,
    ]

    // MARK: - Pure predictor

    /// Predict a full-resolution decode's wall-clock duration, in
    /// seconds, from the file size + format + optional rolling stats.
    ///
    /// - If `stats` is non-nil and has at least
    ///   `DecodeStatsStore.minSamplesForStats` samples, `stats.p50`
    ///   replaces the cold-start base.
    /// - Otherwise, the cold-start table entry for `format` is used
    ///   (or the `.other` fallback).
    /// - The resulting base is multiplied by
    ///   `max(1, fileSize / referenceSize)`, clamped at
    ///   `maxSizeMultiplier`.
    ///
    /// Deterministic — no I/O, no time source. Safe to call from
    /// any isolation domain, including `@MainActor`.
    public static func predict(
        fileSize: Int64,
        format: ImageFormat,
        stats: DecodeStats?
    ) -> TimeInterval {
        let base: TimeInterval
        if let stats, stats.count >= DecodeStatsStore.minSamplesForStats {
            base = stats.p50
        } else {
            // `.other` is guaranteed present in the table.
            base = coldStart[format] ?? coldStart[.other]!
        }

        let size = max(Int64(0), fileSize)
        let rawMultiplier = Double(size) / Double(referenceSize)
        let multiplier = min(max(1.0, rawMultiplier), maxSizeMultiplier)
        return base * multiplier
    }

    // MARK: - Convenience (async, does the I/O)

    /// Convenience wrapper that grabs the file size via
    /// `FileManager.attributesOfItem`, classifies the format by
    /// extension, and looks up rolling stats on `store`. Falls back
    /// gracefully if any of those fail — a missing file still
    /// produces a sensible generic prediction so the caller never
    /// has to handle a "couldn't predict" branch.
    ///
    /// Runs `async` because the stats lookup crosses an actor hop.
    /// The filesystem call is synchronous (a single `stat(2)`, which
    /// is fast enough that suspending for it would cost more than it
    /// saves).
    public static func predict(url: URL, store: DecodeStatsStore) async -> TimeInterval {
        let format = ImageFormat(url: url) ?? .other
        let fileSize = Self.fileSize(of: url)
        let stats = await store.stats(for: format)
        return predict(fileSize: fileSize, format: format, stats: stats)
    }

    // MARK: - Internals

    /// Read the file size without touching `URLResourceKey` — that
    /// path allocates a dictionary and can fall through to an
    /// unexpected slow path for network volumes. A direct
    /// `attributesOfItem` is a single `stat(2)`.
    private static func fileSize(of url: URL) -> Int64 {
        guard url.isFileURL else { return 0 }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attrs?[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}

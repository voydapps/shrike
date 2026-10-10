//
//  OutputDecoder.swift
//  ShrikeCore
//
//  Full-resolution decode for output: print and Copy as PNG
//  (`PhotoPasteboard`).
//  `DecodeQueue.decodeForOutput(url:)` forwards here.
//
//  - Full resolution: no subsampling, no size cap.
//  - EXIF orientation applied (all 8 values).
//  - Not cached anywhere: ImageIO's cache is off (`ShouldCache = false`)
//    and nothing is kept by Shrike. The caller owns the only reference.
//  - The file's own colour space (embedded ICC profile). 16-bit and float
//    sources keep their depth when an orientation redraw is needed.
//  - RAW files decode with ImageIO's default RAW rendering (index 0 at
//    full size), not the embedded preview.
//  - Runs on a private queue (never the main thread, never the Swift
//    cooperative pool: a 50 MP decode blocks its thread for 0.3–1 s).
//    Cancelling the calling task stops the work at the next step and
//    throws `CancellationError`.
//

import Foundation
import CoreGraphics
import ImageIO
import os

public enum OutputDecoder {

    /// Decodes `url` for output. See the file header for the contract.
    public static func decode(url: URL) async throws -> CGImage {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<CGImage, any Error>) in
                queue.addOperation {
                    cont.resume(with: Result {
                        try decodeSync(url: url, isCancelled: { cancelled.withLock { $0 } })
                    })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Blocking form, for callers already on a background thread (the
    /// pasteboard's data provider). `isCancelled` is polled between steps.
    public static func decodeSync(url: URL, isCancelled: () -> Bool = { false }) throws -> CGImage {
        decodeHook?(url)
        guard let src = CGImageSourceCreateWithURL(url as CFURL,
                                                   [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw ImageSourceError.cannotOpen }
        let status = CGImageSourceGetStatus(src)
        guard status == .statusComplete || status == .statusIncomplete else {
            throw status == .statusUnknownType ? ImageSourceError.unsupported : ImageSourceError.corrupt
        }
        guard CGImageSourceGetCount(src) > 0 else { throw ImageSourceError.unsupported }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let orientation = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        if isCancelled() { throw CancellationError() }

        // `ShouldCacheImmediately` decodes here, on this queue, instead of
        // lazily on the first draw (which could be the main thread).
        let opts: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let stored = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageSourceError.corrupt
        }
        if isCancelled() { throw CancellationError() }
        guard orientation != 1, (2...8).contains(orientation) else { return stored }

        let out = OrientedDraw.displaySize(width: stored.width, height: stored.height,
                                           orientation: orientation)
        guard let oriented = OrientedDraw.render(stored, orientation: orientation,
                                                 outWidth: out.width, outHeight: out.height,
                                                 keepDepth: true, quality: .none)
        else { throw ImageSourceError.corrupt }
        if isCancelled() { throw CancellationError() }
        return oriented
    }

    /// Two at a time: each full-resolution decode can hold hundreds of MB.
    private static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "app.shrike.output-decode"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = 2
        return q
    }()

    /// Test hook: called with the URL at the start of every decode.
    /// `nonisolated(unsafe)`: set only by tests before any decode runs;
    /// reads race only with that single test-time write.
    nonisolated(unsafe) public static var decodeHook: (@Sendable (URL) -> Void)?
}

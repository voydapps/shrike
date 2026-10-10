//
//  DecodeQueue+Output.swift
//  ShrikeCore
//
//  `decodeForOutput(url:)`. Kept out of
//  DecodeQueue.swift on purpose; the work lives in `OutputDecoder`.
//

import Foundation
import CoreGraphics

extension DecodeQueue {

    /// Full-resolution, EXIF-oriented decode in the file's colour space,
    /// not cached (print, Copy as PNG). Runs off the main actor and off
    /// this actor; cancelling the calling task throws `CancellationError`.
    public nonisolated func decodeForOutput(url: URL) async throws -> CGImage {
        try await OutputDecoder.decode(url: url)
    }
}

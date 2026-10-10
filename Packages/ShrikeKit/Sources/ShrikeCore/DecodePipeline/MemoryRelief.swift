//
//  MemoryRelief.swift
//  ShrikeCore
//
//  Decode buffers (4-45 MB each) are freed back to
//  malloc, which keeps many of them resident ("MALLOC_LARGE (empty)",
//  ~20 MB after a few navigations and a full-screen round trip). Once
//  decoding has been quiet for a moment, ask malloc to hand them back.
//

import Foundation
import Darwin

public enum MemoryRelief {
    private static let queue = DispatchQueue(label: "app.shrike.memory-relief", qos: .utility)
    nonisolated(unsafe) private static var pending: DispatchWorkItem?

    /// Quiet period after the last call before the relief runs.
    static let delay: TimeInterval = 1.5

    /// Debounced: every call pushes the relief back by `delay`.
    public static func schedule() {
        queue.async {
            pending?.cancel()
            let item = DispatchWorkItem { _ = malloc_zone_pressure_relief(nil, 0) }
            pending = item
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }
}

//
//  DecodeLane.swift
//  ShrikeCore
//
//  A small, bounded pool for blocking decode work (ImageIO + the GPU
//  upload that follows it). Blocking ImageIO
//  calls on Swift's cooperative pool (one thread per core) starve every
//  other task, including UI-driven ones, while the filmstrip and prefetch
//  decode. The hardware JPEG decoder does not scale past ~3 parallel
//  jobs, so a width of 3 loses nothing.
//
//  Cancellation: work that is cancelled before it gets a slot never runs
//  (the check happens after the slot is taken). ImageIO itself cannot be
//  interrupted once started.
//

import Foundation
import os

public final class DecodeLane: Sendable {

    /// Shared by every viewer window's `DecodeQueue`.
    public static let shared = DecodeLane(width: 3)

    private let queue: DispatchQueue
    private let slots: DispatchSemaphore

    public init(width: Int, label: String = "app.shrike.decode") {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        self.slots = DispatchSemaphore(value: max(1, width))
    }

    /// Run `work` on the lane. Throws `CancellationError` if the calling
    /// task is cancelled before the work starts.
    public func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                queue.async { [slots] in
                    slots.wait()
                    defer { slots.signal() }
                    if cancelled.withLock({ $0 }) {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    cont.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    /// Full-resolution decodes for zoom (`DecodeQueue.loadFullResolution`).
    /// Its own single slot, apart from `shared`: a 30–400 ms full-size
    /// decode never takes a slot the next/previous prefetch needs, and
    /// only one full-size image (up to hundreds of MB) is decoded at once.
    public static let fullResolution = DecodeLane(width: 1, label: "app.shrike.decode.fullres")

    /// Like `run`, but a cancelled caller stops waiting AT ONCE: it gets
    /// `CancellationError` even while `work` is still running, and the
    /// late result is dropped. `work` gets an `isCancelled` probe so it
    /// can skip its remaining steps.
    public func runInterruptible<T: Sendable>(
        _ work: @escaping @Sendable (_ isCancelled: @Sendable () -> Bool) throws -> T
    ) async throws -> T {
        let state = OSAllocatedUnfairLock(initialState: InterruptibleWaiter<T>())
        let isCancelled: @Sendable () -> Bool = { state.withLock { $0.cancelled } }
        // Hands the outcome to the waiter once; later outcomes are dropped.
        let finish: @Sendable (Result<T, any Error>) -> Void = { result in
            let cont = state.withLock { s -> CheckedContinuation<T, any Error>? in
                defer { s.continuation = nil }
                return s.continuation
            }
            cont?.resume(with: result)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, any Error>) in
                let alreadyCancelled = state.withLock { s -> Bool in
                    s.continuation = cont
                    return s.cancelled
                }
                if alreadyCancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                queue.async { [slots] in
                    slots.wait()
                    defer { slots.signal() }
                    if isCancelled() {
                        finish(.failure(CancellationError()))
                        return
                    }
                    let result = Result<T, any Error> { try work(isCancelled) }
                    finish(isCancelled() ? .failure(CancellationError()) : result)
                }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
            finish(.failure(CancellationError()))
        }
    }
}

/// Waiter state for `DecodeLane.runInterruptible`.
private struct InterruptibleWaiter<T: Sendable>: Sendable {
    var cancelled = false
    var continuation: CheckedContinuation<T, any Error>?
}

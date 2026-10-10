//
//  CanvasDimScheduler.swift
//  ShrikeUI
//
//  Bookkeeping for the canvas-dim deferred-apply in ViewerContentView.
//  Extracted from ViewerContentView so the cancellation + coalescing
//  logic is unit-testable without an NSView hierarchy.
//
//  120 ms slow-path deferral: the dim is a full-canvas 30% luminance
//  drop, which strobes unpleasantly on fast cached nav. The bar
//  (zero-grace + 250 ms min-visible) covers sub-threshold feedback;
//  the dim only has to cover genuinely slow decodes.
//
//  Contract:
//    * `scheduleApply()` arms a one-shot `DispatchWorkItem` on the main
//      queue with a `applyDelay` delay. If `cancel()` fires before the
//      delay elapses, the item is cancelled and `onApply` is never
//      invoked — fast-path nav never sees the dim.
//    * If `scheduleApply()` is called while one is already pending, it
//      is a no-op. The existing deadline stands. (Resetting the
//      deadline on every call would let a flurry of nav events
//      indefinitely push the apply into the future, defeating the
//      "slow-path signal" purpose.)
//    * `onApply` is called on the main thread when (and only when) the
//      delay elapses without a cancellation. It is the caller's job to
//      do the actual layer mutation.
//

import Foundation

/// Main-actor-bound scheduler for the canvas dim's deferred apply. Holds
/// a single pending `DispatchWorkItem` and exposes minimal public
/// surface so tests can verify the pending/cancelled state directly.
@MainActor
final class CanvasDimScheduler {

    /// How long to wait after `scheduleApply()` before firing `onApply`.
    /// Kept `let` (not `static`) so tests can inject a shorter delay.
    private let applyDelay: TimeInterval

    /// The pending work item. `internal` so tests can assert that
    /// cancellation nils it out and that coalescing does not stack two
    /// items. Never written from outside this type.
    internal private(set) var pending: DispatchWorkItem?

    /// Callback fired on the main thread when the delay elapses without
    /// a cancellation. Set once by the owning view after init.
    var onApply: (() -> Void)?

    init(applyDelay: TimeInterval) {
        self.applyDelay = applyDelay
    }

    /// Arm the deferred apply. No-op if one is already pending
    /// (coalesced) — the existing deadline stands.
    func scheduleApply() {
        if pending != nil { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Clear the reference before firing the callback. If
            // `onApply` itself triggers a re-entrant `scheduleApply()`
            // (it currently doesn't, but defensively), that call must
            // see `pending == nil` so it can arm a fresh item.
            self.pending = nil
            self.onApply?()
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + applyDelay,
            execute: work
        )
    }

    /// Cancel the pending apply. No-op if none is pending. Idempotent.
    func cancel() {
        pending?.cancel()
        pending = nil
    }
}

//
//  TrailingDebouncer.swift
//  ShrikeUI
//
//  Runs the LAST call `delay` seconds after the calls stop:
//  the Browser follows the viewer 150 ms after the last photo change, so
//  holding an arrow key does not flood it. The clock is injectable.
//

import Foundation

@MainActor
final class TrailingDebouncer {
    /// Runs `fire` after `delay` seconds; returns a cancel.
    typealias Schedule = @MainActor (_ delay: TimeInterval, _ fire: @escaping @MainActor @Sendable () -> Void) -> () -> Void

    /// The real clock: a main-actor task that sleeps.
    static let mainActorClock: Schedule = { delay, fire in
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
    }

    let delay: TimeInterval
    private let schedule: Schedule
    private var cancelPending: (() -> Void)?
    private var generation: UInt64 = 0

    init(delay: TimeInterval, schedule: @escaping Schedule = TrailingDebouncer.mainActorClock) {
        self.delay = delay
        self.schedule = schedule
    }

    var isPending: Bool { cancelPending != nil }

    /// Replaces any pending call with `action`.
    func call(_ action: @escaping @MainActor @Sendable () -> Void) {
        cancelPending?()
        generation &+= 1
        let mine = generation
        cancelPending = schedule(delay) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.cancelPending = nil
            action()
        }
    }

    func cancel() {
        cancelPending?()
        cancelPending = nil
        generation &+= 1
    }
}

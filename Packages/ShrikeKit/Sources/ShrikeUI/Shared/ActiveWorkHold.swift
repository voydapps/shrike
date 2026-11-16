//
//  ActiveWorkHold.swift
//  ShrikeUI
//
//  Work the UI keeps open for a while (an unsaved edit, a rotate
//  waiting for its delayed write) holds one `ActiveWork` token. `set(_:)` is
//  idempotent, and the token ends when the holder goes away, so a window
//  that closes on an unusual path never leaves the app unable to quit.
//

import Foundation
import os
import ShrikeCore

public final class ActiveWorkHold: Sendable {
    private let kind: ActiveWork.Kind
    private let registry: ActiveWork
    private let token = OSAllocatedUnfairLock<ActiveWork.Token?>(initialState: nil)

    public init(kind: ActiveWork.Kind, registry: ActiveWork = .shared) {
        self.kind = kind
        self.registry = registry
    }

    public var isHeld: Bool { token.withLock { $0 != nil } }

    /// Opens the token on true, ends it on false. Repeats do nothing.
    public func set(_ held: Bool, detail: String = "") {
        let registry = self.registry
        let kind = self.kind
        token.withLock { current in
            if held, current == nil {
                current = registry.begin(kind: kind, detail: detail)
            } else if !held, let open = current {
                registry.end(open)
                current = nil
            }
        }
    }

    deinit {
        if let open = token.withLock({ $0 }) { registry.end(open) }
    }
}

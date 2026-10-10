//
//  OpenRequestRouting.swift
//  ShrikeUI
//
//  File-open routing shared by the app delegate (Finder / `open` /
//  Dock drops) and the welcome window's drop target.
//
//  WHY a queue: AppKit delivers `application(_:open:)` for a cold launch
//  *before* `applicationDidFinishLaunching`, i.e. before the services
//  the viewer needs exist. Without buffering, the file the user
//  double-clicked was silently dropped and the app showed Welcome.
//

import Foundation
import ShrikeCore

/// Buffers open requests until the app is ready to open windows, then
/// delivers them (and every later request) straight through.
@MainActor
public final class OpenRequestQueue {

    private var pending: [URL] = []
    private var deliver: (([URL]) -> Void)?

    public init() {}

    /// True while requests are buffered and not yet delivered.
    public var hasPending: Bool { !pending.isEmpty }

    /// Deliver now if ready, otherwise buffer until `activate`.
    public func submit(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let deliver {
            deliver(urls)
        } else {
            pending.append(contentsOf: urls)
        }
    }

    /// Start delivering. Flushes everything buffered before readiness as
    /// one batch (so a multi-file Finder open stays one viewer window).
    /// Returns true when a buffered batch was delivered.
    @discardableResult
    public func activate(_ deliver: @escaping ([URL]) -> Void) -> Bool {
        self.deliver = deliver
        guard !pending.isEmpty else { return false }
        let batch = pending
        pending = []
        deliver(batch)
        return true
    }
}

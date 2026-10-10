//
//  ShrikeSignposts.swift
//  ShrikeCore
//
//  Centralised `os_signpost` helper. We instrument from day one so we can
//  measure against the cold-launch < 250 ms target
//
//  Usage:
//
//      let token = ShrikeSignposts.launch.begin("willFinishLaunching")
//      // ...
//      ShrikeSignposts.launch.end("willFinishLaunching", token)
//
//  Inspect in Instruments → "Points of Interest" + "os_signpost" tracks.
//

import Foundation
import os

/// Stable subsystem identifier visible in Instruments.
public enum ShrikeSignposts {

    public static let subsystem = "app.shrike"

    /// Cold-launch timing — fired across `applicationWillFinishLaunching`,
    /// `applicationDidFinishLaunching`, and first-drawable-commit.
    public static let launch = SignposterNamespace(category: "launch")

    /// Keystroke → paint latency for navigation (Space, arrows). Tag spans
    /// with pixel count via `metadata` so we can filter in Instruments.
    public static let navigation = SignposterNamespace(category: "navigation")

    /// Thumbnail decode pipeline. Tag with `hit/miss` + long-edge size.
    public static let thumbnail = SignposterNamespace(category: "thumbnail")

    /// Decode pipeline — full-resolution loads, retries, cache evictions.
    public static let decode = SignposterNamespace(category: "decode")

    /// Browser interactions (the selection-change handler: click → ring).
    public static let browser = SignposterNamespace(category: "browser")
}

/// Thin wrapper around `OSSignposter` so call sites don't deal with IDs directly.
public struct SignposterNamespace: Sendable {

    public let signposter: OSSignposter

    public init(category: String) {
        self.signposter = OSSignposter(
            subsystem: ShrikeSignposts.subsystem,
            category: category
        )
    }

    /// Begin an interval. Returned token must be passed to `end`.
    public func begin(
        _ name: StaticString,
        _ message: String? = nil
    ) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        if let message {
            return signposter.beginInterval(name, id: id, "\(message)")
        } else {
            return signposter.beginInterval(name, id: id)
        }
    }

    /// Begin an interval with structured metadata — two key/value pairs.
    /// Instruments shows these in the signpost's detail pane.
    public func beginMetadata(
        _ name: StaticString,
        _ metadata: String
    ) -> OSSignpostIntervalState {
        let id = signposter.makeSignpostID()
        return signposter.beginInterval(name, id: id, "\(metadata)")
    }

    public func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    /// End with a trailing metadata message (Instruments shows it on the span).
    public func end(_ name: StaticString, _ state: OSSignpostIntervalState, _ metadata: String) {
        signposter.endInterval(name, state, "\(metadata)")
    }

    /// Emit a single point-of-interest event (not an interval).
    public func event(_ name: StaticString, _ message: String? = nil) {
        if let message {
            signposter.emitEvent(name, "\(message)")
        } else {
            signposter.emitEvent(name)
        }
    }
}

//
//  NavigationIntent.swift
//  ShrikeUI
//
//  Synchronous, main-actor-isolated view of the user's navigation cursor.
//  Separates "where does the user intend to be right now?" (knowable the
//  instant a key is pressed) from "which image has actually finished
//  decoding?" (owned by `NavigationController` / `DecodeQueue`).
//
//  Why this exists
//  ---------------
//
//  The position overlay (`N / M — filename`) used to be painted only after
//  a full-res decode resolved on the main actor. During rapid-fire arrow
//  / Space mashing, `NavTaskCoalescer` cancels prior decode tasks on each
//  new keypress, so most of those tasks never reach the overlay update
//  call site — only the last non-cancelled decode does. Result: the
//  counter sat at whatever image *finished decoding*, potentially many
//  positions behind the user's actual target (the cumulative sum of
//  keystrokes).
//
//  The fix is to decouple the overlay from decode completion. The target
//  index is knowable synchronously from the count + current index + nav
//  kind; the filename is a synchronous lookup into the source list. The
//  decoder can catch up on its own schedule.
//
//  This type holds the list and the *intended* current index, both
//  main-actor. It deliberately does not own images, decode tasks, or
//  `DecodeQueue` — those still live in `NavigationController`. The two
//  are kept in sync by `ViewerWindow`: it calls the intent mutator
//  synchronously on keyDown, then awaits the decode path which updates
//  the actor's cursor.
//

import Foundation
import ShrikeCore

/// A resolved navigation target — the index, total, and filename the
/// overlay should display. Returned by the intent mutators so callers
/// can paint the overlay in the same main-actor tick the key was pressed.
public struct NavTarget: Sendable, Hashable {
    public let index: Int
    public let total: Int
    public let filename: String

    public init(index: Int, total: Int, filename: String) {
        self.index = index
        self.total = total
        self.filename = filename
    }
}

/// Main-actor-isolated navigation cursor. Exists in front of the
/// `NavigationController` actor so the viewer can compute + paint the
/// user's intended position synchronously on keyDown, without waiting
/// for a decode round-trip.
@MainActor
public final class NavigationIntent {

    private var sources: [any ImageSource] = []
    private(set) public var currentIndex: Int = 0

    public init() {}

    public var count: Int { sources.count }

    public var isEmpty: Bool { sources.isEmpty }

    /// Replace the list and seed the cursor. Clamps the index into range.
    /// Mirrors what `NavigationController.setNavigation` does, but
    /// synchronously so the overlay can fire from the same call site.
    public func setNavigation(list: [any ImageSource], currentIndex: Int) {
        sources = list
        self.currentIndex = list.isEmpty ? 0 : max(0, min(currentIndex, list.count - 1))
    }

    /// Synchronous lookup — matches `NavigationController.sourceAt` but
    /// without the actor hop. Used by the filmstrip + overlay paths.
    public func sourceAt(_ index: Int) -> (any ImageSource)? {
        guard sources.indices.contains(index) else { return nil }
        return sources[index]
    }

    public func currentSource() -> (any ImageSource)? {
        sourceAt(currentIndex)
    }

    /// Resolve + commit an "advance by one" intent. Returns the new target,
    /// or nil if the list is empty. Advances wrap around to match
    /// `DecodeQueue.advance`'s modular behaviour so the decode path and
    /// the overlay land on the same index.
    @discardableResult
    public func advanceIntent() -> NavTarget? {
        guard !sources.isEmpty else { return nil }
        let next = (currentIndex + 1) % sources.count
        currentIndex = next
        return target(for: next)
    }

    /// Resolve + commit a "retreat by one" intent. Wraps around (mirrors
    /// `DecodeQueue.retreat`).
    @discardableResult
    public func retreatIntent() -> NavTarget? {
        guard !sources.isEmpty else { return nil }
        let prev = (currentIndex - 1 + sources.count) % sources.count
        currentIndex = prev
        return target(for: prev)
    }

    /// Resolve + commit a "jump to index" intent. Returns nil if the
    /// index is out of range (so callers can flow into their existing
    /// error path without painting a bogus overlay).
    @discardableResult
    public func jumpIntent(to index: Int) -> NavTarget? {
        guard sources.indices.contains(index) else { return nil }
        currentIndex = index
        return target(for: index)
    }

    /// Build a `NavTarget` for the current cursor without mutating it.
    /// Used by the initial-image show path where the cursor has already
    /// been seeded by `setNavigation`.
    public func currentTarget() -> NavTarget? {
        guard !sources.isEmpty else { return nil }
        return target(for: currentIndex)
    }

    private func target(for index: Int) -> NavTarget {
        let filename = sources.indices.contains(index)
            ? sources[index].displayName
            : ""
        return NavTarget(index: index, total: sources.count, filename: filename)
    }
}

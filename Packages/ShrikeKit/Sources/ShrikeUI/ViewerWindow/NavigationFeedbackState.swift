//
//  NavigationFeedbackState.swift
//  ShrikeUI
//
//  Pure-logic state machine for the viewer's "what's happening right now"
//  layered feedback. Lives here rather than inside `ViewerWindow` so the
//  transition rules can be exercised by XCTest without instantiating an
//  NSWindow / MTLDevice / DecodeQueue stack.
//
//  There are three layered feedbacks the viewer paints during a navigation:
//
//    1. **Thumbnail bridge** — when the full-res decode isn't in
//       `DecodeQueue.current()`, grab a 1024 px thumbnail from the shared
//       `ThumbnailCache` and paint it as a placeholder. Swap to full-res
//       when the decode resolves.
//    2. **Position overlay** — "43 / 180 — DSC_0042.jpg" in the bottom-left
//       corner on every nav event, fades after ~1.2 s of idle. Integrates
//       a hairline loading indicator along its bottom edge for slow decodes
//    3. **Canvas dim** — deferred 120 ms after nav; applied only on slow
//       decodes, cleared on first paint.
//
//  The state machine tracks where we are in that sequence for the *current*
//  nav target so the UI can consult it before painting each layer. It
//  deliberately does **not** own the image bytes or the Tasks — it is a
//  scheduler-friendly record of intent that `ViewerWindow` drives.
//
//  Terminology:
//    * "generation" — a monotonically increasing token bumped on every new
//      nav event. Stale layer paints (thumb / full / hairline) check their
//      generation against the current one and no-op if mismatched. This is
//      how we avoid the "thumb from the previous nav lands after the user
//      has already moved on" race.
//

import Foundation

/// The feedback phases of a single navigation. Only one phase is live at a
/// time for the current generation.
public enum NavigationFeedbackPhase: Sendable, Hashable {
    /// Nothing in flight — no nav event has fired, or the last one fully
    /// resolved and faded out.
    case idle
    /// A nav event just fired; we haven't landed any image yet. If we stay
    /// in this phase past the position overlay's 200 ms hairline grace,
    /// the hairline fades in.
    case waiting
    /// Thumbnail placeholder is painted. The full-res decode is still in
    /// flight; when it lands we transition to `showingFull`.
    case showingThumb
    /// Full-resolution image is painted. Terminal phase for a given nav.
    case showingFull
}

/// Result of asking the state machine "should I paint this layer right now?".
/// Each layer call site uses the corresponding `should*` helper to decide.
public struct NavigationFeedbackSnapshot: Sendable, Hashable {
    public let generation: UInt64
    public let phase: NavigationFeedbackPhase

    public init(generation: UInt64, phase: NavigationFeedbackPhase) {
        self.generation = generation
        self.phase = phase
    }
}

/// The feedback state machine. Main-actor isolated — the viewer drives it
/// from user input and from the tails of its decode Tasks, both of which
/// already land on the main actor.
@MainActor
public final class NavigationFeedbackState {

    /// How long the viewer defers "is something slow?" chrome before it
    /// appears. The position overlay's hairline honors this grace on its
    /// own timer; keeping the constant here so downstream callers and
    /// tests have a single source of truth for "fast-path threshold".
    public static let defaultSpinnerDelay: TimeInterval = 0.200

    /// How long to wait before giving up on a thumbnail paint. If the
    /// thumbnail lookup takes longer than this, we skip it — the full-res
    /// decode is probably close enough to landing that a placeholder
    /// would just be noise. Matches the 200 ms budget.
    public static let defaultThumbBudget: TimeInterval = 0.200

    /// How long the position overlay stays fully visible after the last
    /// nav event before it starts fading.
    public static let defaultOverlayIdleTimeout: TimeInterval = 1.2

    public let spinnerDelay: TimeInterval
    public let thumbBudget: TimeInterval
    public let overlayIdleTimeout: TimeInterval

    /// When true, the position overlay fades out after `overlayIdleTimeout`
    /// seconds of nav inactivity (original behavior). When false, the
    /// overlay is always-on for the life of the viewer window.
    ///
    /// Mirrored from `Prefs.viewerPositionOverlayAutoHides` by the viewer at
    /// construction time so the pure-logic layer can be exercised without
    /// touching `UserDefaults` in tests.
    public let overlayAutoHides: Bool

    private var currentGeneration: UInt64 = 0
    public private(set) var phase: NavigationFeedbackPhase = .idle

    /// True while the position overlay is currently visible. Flipped to true
    /// by `didShowOverlay()` on each nav event (or initial-image show) and
    /// back to false by `overlayIdleTimeoutFired(...)` — but only if
    /// `overlayAutoHides` is true. In always-on mode the flag never returns
    /// to false short of an explicit `forceOverlayHidden()` (window teardown).
    public private(set) var overlayVisible: Bool = false

    /// Monotonic token bumped by each `didShowOverlay()` call. The idle-fade
    /// task captures the token at schedule time and refuses to fade if the
    /// token has moved on — i.e. another nav event reset the idle timer.
    private var overlayToken: UInt64 = 0

    public init(
        spinnerDelay: TimeInterval = NavigationFeedbackState.defaultSpinnerDelay,
        thumbBudget: TimeInterval = NavigationFeedbackState.defaultThumbBudget,
        overlayIdleTimeout: TimeInterval = NavigationFeedbackState.defaultOverlayIdleTimeout,
        overlayAutoHides: Bool = false
    ) {
        self.spinnerDelay = spinnerDelay
        self.thumbBudget = thumbBudget
        self.overlayIdleTimeout = overlayIdleTimeout
        self.overlayAutoHides = overlayAutoHides
    }

    public var generation: UInt64 { currentGeneration }

    public var snapshot: NavigationFeedbackSnapshot {
        NavigationFeedbackSnapshot(generation: currentGeneration, phase: phase)
    }

    // MARK: - Transitions

    /// Called when a new nav event fires. Bumps the generation token so any
    /// pending Task tails from previous events will see themselves as stale
    /// and skip their paint.
    @discardableResult
    public func beginNavigation() -> UInt64 {
        currentGeneration &+= 1
        phase = .waiting
        return currentGeneration
    }

    /// Called from the thumbnail Task tail. Returns `true` if the caller
    /// should paint the thumb (generation matches AND we're still waiting).
    /// Returns `false` if the generation has already been superseded or the
    /// full-res image has already landed.
    public func shouldPaintThumb(generation: UInt64) -> Bool {
        guard generation == currentGeneration else { return false }
        switch phase {
        case .waiting:
            return true
        case .idle, .showingThumb, .showingFull:
            return false
        }
    }

    /// Record that the thumb paint was committed. Transitions into
    /// `showingThumb` unless we're already on a full paint (defensive).
    public func didPaintThumb(generation: UInt64) {
        guard generation == currentGeneration else { return }
        if phase != .showingFull {
            phase = .showingThumb
        }
    }

    /// Called from the full-res Task tail. Returns `true` if the caller
    /// should commit the full-res paint. The only reason this would be
    /// false is if the nav event has been superseded — full-res always
    /// wins over any transient thumb of the same generation.
    public func shouldPaintFull(generation: UInt64) -> Bool {
        generation == currentGeneration
    }

    /// Record that the full-res paint was committed.
    public func didPaintFull(generation: UInt64) {
        guard generation == currentGeneration else { return }
        phase = .showingFull
    }

    /// Whether the position-overlay hairline loading indicator should be
    /// visible for the given generation. The view layer asks on every
    /// relevant event.
    ///
    /// The hairline is ambient and rides `isDecodeInFlight`, not a specific
    /// phase — it's eligible across `.waiting` and `.showingThumb` and
    /// hidden in `.showingFull` and `.idle`. The view layer owns the
    /// 200 ms show-grace and the fade-in / fade-out animation so this
    /// predicate stays pure and time-free.
    public func shouldShowLoadingIndicator(generation: UInt64) -> Bool {
        guard generation == currentGeneration else { return false }
        return isDecodeInFlight
    }

    /// True while a nav is in flight — i.e. we have dispatched a decode
    /// and it has not yet resolved with a full-res paint. `.showingThumb`
    /// counts as "in flight" because the full-res decode may still be
    /// running; the indicator hides only at `.showingFull` or `.idle`.
    public var isDecodeInFlight: Bool {
        switch phase {
        case .idle, .showingFull:
            return false
        case .waiting, .showingThumb:
            return true
        }
    }

    /// Whether the bottom-right "PREVIEW" badge should be on screen for a
    /// given generation. The view layer asks the state machine; it doesn't
    /// track phase itself.
    ///
    /// The badge is visible iff the current phase is `.showingThumb` AND
    /// the caller's generation matches the live one — a late thumb paint
    /// from a superseded nav must never surface the badge, same reason
    /// we gate the paint itself with `shouldPaintThumb`.
    public func shouldShowPreviewBadge(generation: UInt64) -> Bool {
        guard generation == currentGeneration else { return false }
        return phase == .showingThumb
    }

    /// Reset back to idle. Called when a nav error lands (error overlay is
    /// its own feedback, distinct from this pipeline) or when the window
    /// is being torn down.
    public func reset() {
        phase = .idle
    }

    // MARK: - Position overlay visibility

    /// Called every time the viewer surfaces the position overlay — either
    /// on a nav event or on the initial image load. Returns a token the
    /// caller should pass to `overlayIdleTimeoutFired(token:)` when the
    /// idle-fade task wakes up. Stale tokens are rejected so hold-to-scroll
    /// doesn't stomp on its own re-shows.
    @discardableResult
    public func didShowOverlay() -> UInt64 {
        overlayToken &+= 1
        overlayVisible = true
        return overlayToken
    }

    /// Called by the idle-fade task after `overlayIdleTimeout` elapses.
    /// Returns `true` if the caller should actually animate the fade-out.
    /// Returns `false` when:
    ///   * `overlayAutoHides` is false (always-on mode; the task should
    ///     never have been scheduled, but we guard defensively),
    ///   * a newer `didShowOverlay()` call has since reset the idle timer,
    ///   * the overlay has already been force-hidden.
    public func overlayIdleTimeoutFired(token: UInt64) -> Bool {
        guard overlayAutoHides else { return false }
        guard overlayVisible else { return false }
        guard token == overlayToken else { return false }
        overlayVisible = false
        return true
    }

    /// Explicit hide — used by the window teardown path. Bypasses the
    /// auto-hide preference; this is not user-facing fade behavior, it's
    /// cleanup.
    public func forceOverlayHidden() {
        overlayVisible = false
    }
}

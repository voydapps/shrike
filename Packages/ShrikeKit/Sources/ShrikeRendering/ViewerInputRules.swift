//
//  ViewerInputRules.swift
//  ShrikeRendering
//
//  The input rules for scroll, swipe, zoom and the pan clamp, as
//  plain value types. `MetalImageView` feeds them numbers taken from the
//  `NSEvent`; nothing here touches AppKit events, so unit tests can cover
//  every rule without real input.
//
//  Scales in this file are *pixel scales*: 1.0 = 100 % = one image pixel
//  per screen pixel (zoom 1.0 of the view is one texel per
//  point, which is not 100 %).
//

import Foundation
import CoreGraphics

// MARK: - Scroll routing

/// The parts of a scroll event the routing rules look at.
public struct ScrollInput: Sendable, Equatable {
    /// `NSEvent.hasPreciseScrollingDeltas`: trackpad / Magic Mouse.
    public var isPrecise: Bool
    public var deltaX: Double
    public var deltaY: Double
    /// `NSEvent.isDirectionInvertedFromDevice` (natural scrolling).
    public var isDirectionInverted: Bool
    /// `phase == .began`.
    public var phaseBegan: Bool
    /// `momentumPhase != []`.
    public var isMomentum: Bool
    /// `phase` is `.ended` / `.cancelled` (or the momentum ended): the
    /// gesture is over, so the step counter starts clean.
    public var phaseEnded: Bool
    /// `phase != []`. A wheel driver that sends precise deltas usually
    /// sends no phase at all; a trackpad always does.
    public var hasPhase: Bool
    /// ⌘ or ⌥ held.
    public var swapsAction: Bool
    /// `NSEvent.timestamp`, seconds.
    public var timestamp: TimeInterval

    public init(isPrecise: Bool, deltaX: Double = 0, deltaY: Double = 0,
                isDirectionInverted: Bool = false, phaseBegan: Bool = false,
                isMomentum: Bool = false, phaseEnded: Bool = false,
                hasPhase: Bool = false, swapsAction: Bool = false,
                timestamp: TimeInterval = 0) {
        self.isPrecise = isPrecise
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.isDirectionInverted = isDirectionInverted
        self.phaseBegan = phaseBegan
        self.isMomentum = isMomentum
        self.phaseEnded = phaseEnded
        self.hasPhase = hasPhase || phaseBegan
        self.swapsAction = swapsAction
        self.timestamp = timestamp
    }

    /// Physical wheel direction: `< 0` = rolled down, toward the
    /// user, whatever the natural-scrolling setting.
    public var physicalDelta: Double {
        deltaY * (isDirectionInverted ? -1 : 1)
    }
}

/// What a scroll event should do.
public enum ScrollAction: Sendable, Equatable {
    case none
    /// Change image. `forward` = next.
    case navigate(forward: Bool)
    /// Multiply the pixel scale by `factor`, anchored at the pointer.
    case zoom(factor: Double)
    /// Move the image by this many view points (y up).
    case pan(dx: Double, dy: Double)
    /// Start `trackSwipeEvent`.
    case beginSwipe
}

/// Rules. Holds the wheel accumulator and the 25 ms drop
/// window; everything else is decided from the arguments.
public struct ScrollInputRouter: Sendable {
    /// Points one wheel line pans when zoomed in.
    public static let panPointsPerLine: Double = 24
    /// Zoom per wheel notch (12 %). Audit 2026-10-13: 1.25 per line took
    /// 25 % to 1600 % in a few turns. The size of a notch does not matter
    /// (an accelerated wheel sends 3-10); a small tick counts in proportion.
    public static let zoomPerLine: Double = 1.12
    /// Events closer together than this belong to one burst. A driver that
    /// splits one notch into ticks sends them under 15 ms apart (fractions of
    /// a line); a fast spin sends whole notches 10-40 ms apart. In a burst a
    /// whole notch always steps; fractional ticks add up and step per line.
    public static let dropInterval: TimeInterval = 0.025
    /// Trackpad points counted as one "line" for ⌘/⌥ + trackpad zoom: 40 pt
    /// is two lines = 1.25x, so a short two-finger move is a clear step but
    /// six of them are not 1600 %.
    public static let precisePointsPerLine: Double = 20
    /// One precise event never zooms more than this many points (momentum
    /// bursts and fast flicks stay smooth).
    public static let preciseZoomMaxPoints: Double = 60
    /// Precise (trackpad or smooth-scrolling wheel) points that change the
    /// image at Fit. The filmstrip steps once per `cellSize + spacing`
    /// (72 + 8 = 80 pt by default); the viewer uses the same number so a
    /// scroll feels alike on the photo and on the strip.
    public static let preciseNavigatePoints: Double = 80
    /// A phase-less precise stream pauses this long = a new gesture.
    public static let preciseGestureGap: TimeInterval = 0.3

    /// Precise points collected toward the next image (signed, physical
    /// direction). Notched wheels do not use it: one notch = one image.
    public private(set) var accumulator: Double = 0
    private var lastPreciseTime: TimeInterval = -.infinity
    /// Time of the last notched-wheel event and its direction, and the
    /// fractional ticks collected in this burst (minus the notch already
    /// stepped for the burst's first event).
    private var lastWheelTime: TimeInterval = -.infinity
    private var lastWheelForward: Bool?
    public private(set) var burstPool: Double = 0

    public init() {}

    /// - Parameters:
    ///   - atFit: the view is in fit mode or within 0.5 % of the fit scale.
    ///   - wheelChangesImage: pref `shrike.input.scrollWheelNavigates`.
    ///   - swipeEnabled: `NSEvent.isSwipeTrackingFromScrollEventsEnabled`.
    public mutating func route(_ e: ScrollInput, atFit: Bool,
                               wheelChangesImage: Bool,
                               swipeEnabled: Bool) -> ScrollAction {
        if e.isPrecise {
            return routePrecise(e, atFit: atFit, wheelChangesImage: wheelChangesImage,
                                swipeEnabled: swipeEnabled)
        }

        let navigates = wheelChangesImage != e.swapsAction
        if !navigates {
            let d = e.physicalDelta
            guard d != 0 else { return .none }
            return .zoom(factor: pow(Self.zoomPerLine, max(-1, min(1, d))))   // wheel up = in
        }
        // "Changes image" without a modifier pans once zoomed in; the
        // swapped (⌘/⌥) navigation works at any zoom.
        if !atFit && !e.swapsAction {
            let dx = e.deltaX * Self.panPointsPerLine
            let dy = -e.deltaY * Self.panPointsPerLine
            return (dx == 0 && dy == 0) ? .none : .pan(dx: dx, dy: dy)
        }
        // One notch = one image, whatever its size. Many wheels send
        // 0.1-0.3 per tick at a slow turn; waiting for a full line made
        // the photo need 4-10 notches per step.
        let d = e.physicalDelta
        guard d != 0 else { return .none }
        let forward = d < 0                            // wheel down = next
        let inBurst = lastWheelForward == forward
            && e.timestamp - lastWheelTime <= Self.dropInterval
            && e.timestamp >= lastWheelTime
        lastWheelTime = e.timestamp
        lastWheelForward = forward
        let size = abs(d)
        guard inBurst else {
            // First event of a burst: a step. A fractional first tick leaves a
            // debt, so the rest of a split notch does not step again.
            burstPool = min(size - 1, 0)
            return .navigate(forward: forward)
        }
        // Inside a burst nothing is dropped: a whole notch steps, fractional
        // ticks add up and step once per line. One step per event, so the
        // queue is as long as the events, never longer.
        if size >= 1 { return .navigate(forward: forward) }
        burstPool += size
        if burstPool >= 1 {
            burstPool -= 1
            return .navigate(forward: forward)
        }
        return .none
    }

    private mutating func routePrecise(_ e: ScrollInput, atFit: Bool,
                                       wheelChangesImage: Bool,
                                       swipeEnabled: Bool) -> ScrollAction {
        if e.swapsAction && !e.isMomentum {
            let clamped = max(-Self.preciseZoomMaxPoints, min(Self.preciseZoomMaxPoints, e.physicalDelta))
            let d = clamped / Self.precisePointsPerLine
            return d == 0 ? .none : .zoom(factor: pow(Self.zoomPerLine, d))
        }
        if atFit {
            // Momentum never changes image.
            guard !e.isMomentum else { return .none }
            if e.phaseBegan { accumulator = 0 }
            defer { if e.phaseEnded { accumulator = 0 } }
            // A horizontal start hands over to the system swipe tracker.
            if e.phaseBegan, swipeEnabled, abs(e.deltaX) > abs(e.deltaY) {
                return .beginSwipe
            }
            // Vertical scroll (two-finger trackpad, smooth-scrolling
            // wheel) steps one image per `preciseNavigatePoints`.
            guard wheelChangesImage, abs(e.deltaY) > abs(e.deltaX) else { return .none }
            if !e.hasPhase, e.timestamp - lastPreciseTime > Self.preciseGestureGap {
                accumulator = 0
            }
            lastPreciseTime = e.timestamp
            let d = e.physicalDelta
            if accumulator != 0, (accumulator < 0) != (d < 0) { accumulator = 0 }
            accumulator += d
            let step = Self.preciseNavigatePoints
            guard abs(accumulator) >= step else { return .none }
            let forward = accumulator < 0              // down = next
            accumulator += forward ? step : -step
            // One image per event; never queue a long backlog.
            accumulator = min(max(accumulator, -step), step)
            return .navigate(forward: forward)
        }
        // Zoomed in: pan 1:1 with momentum; never changes image.
        if e.deltaX == 0 && e.deltaY == 0 { return .none }
        return .pan(dx: e.deltaX, dy: -e.deltaY)
    }
}

// MARK: - Swipe

public enum SwipeMapping {
    /// `trackSwipeEvent`'s gesture amount carries the sign of
    /// `scrollingDeltaX`, which follows the natural-scrolling setting.
    /// Returns true when the fingers move right on the trackpad.
    public static func fingersMoveRight(amount: Double, isDirectionInverted: Bool) -> Bool {
        (amount > 0) == isDirectionInverted
    }

    /// Dampen thresholds for `trackSwipeEvent`: 0 on a side with no image,
    /// so the swipe rubber-bands there. Fingers left = next.
    public static func thresholds(hasPrevious: Bool, hasNext: Bool,
                                  isDirectionInverted: Bool) -> (min: Double, max: Double) {
        // Positive amount = fingers right (natural) = previous.
        let positiveIsPrevious = isDirectionInverted
        let maxAllowed = positiveIsPrevious ? hasPrevious : hasNext
        let minAllowed = positiveIsPrevious ? hasNext : hasPrevious
        return (minAllowed ? -1 : 0, maxAllowed ? 1 : 0)
    }

    /// Three-finger `swipe(with:)`: true = next, false = previous, nil =
    /// not horizontal. Fingers left = next. The SDK header does not
    /// document the sign of `deltaX`; the classic AppKit behaviour is a
    /// positive `deltaX` for fingers moving left. Needs a real-trackpad
    /// check; flip here if it is the other way.
    public static func threeFingerForward(deltaX: Double) -> Bool? {
        guard deltaX != 0 else { return nil }
        return deltaX > 0
    }

    /// The change a finished swipe asks for; nil = spring back.
    public static func result(finalAmount: Double, isComplete: Bool,
                              isDirectionInverted: Bool) -> Bool? {
        guard isComplete, abs(finalAmount) >= 0.999 else { return nil }
        // Fingers left = next.
        return !fingersMoveRight(amount: finalAmount, isDirectionInverted: isDirectionInverted)
    }
}

// MARK: - Zoom ladder

public enum ZoomLadder {
    public static let steps: [Double] = [0.25, 0.33, 0.5, 0.67, 1, 1.5, 2, 3, 4, 8, 16]
    public static let maxScale: Double = 16
    /// Relative tolerance for "on a step".
    static let epsilon: Double = 0.005

    public static func ladder(fit: Double) -> [Double] {
        var all = steps
        if fit > 0, !all.contains(where: { abs($0 - fit) <= fit * epsilon }) {
            all.append(fit)
        }
        return all.sorted()
    }

    public static func lowest(fit: Double) -> Double { min(fit, 0.25) }

    /// A step closer than this ratio to the current zoom is skipped
    /// (⌘+ from Fit 66 % used to go to 67 % and looked dead).
    public static let minimumStepRatio: Double = 1.1

    /// Next step at least ~10 % above `current` (the nearest step above
    /// when none is that far, so 1600 % stays reachable), or nil at 1600 %.
    public static func stepIn(from current: Double, fit: Double) -> Double? {
        let all = ladder(fit: fit)
        return all.first { $0 >= current * minimumStepRatio * (1 - epsilon) }
            ?? all.first { $0 > current * (1 + epsilon) }
    }

    /// Next step at least ~10 % below `current` (the nearest step below
    /// when none is that far), or nil at the lowest step.
    public static func stepOut(from current: Double, fit: Double) -> Double? {
        let floor = lowest(fit: fit)
        let all = ladder(fit: fit).filter { $0 >= floor * (1 - epsilon) }
        return all.last { $0 <= current / minimumStepRatio * (1 + epsilon) }
            ?? all.last { $0 < current * (1 - epsilon) }
    }

    public static func canZoomIn(from current: Double, fit: Double) -> Bool {
        stepIn(from: current, fit: fit) != nil
    }

    public static func canZoomOut(from current: Double, fit: Double) -> Bool {
        stepOut(from: current, fit: fit) != nil
    }
}

// MARK: - Pinch

public struct PinchZoomState: Sendable {
    /// How far the pinch must move past a detent to leave it (4 %).
    public static let detentRelease: Double = 0.04
    public static let maxScale: Double = 16

    public let fit: Double
    public private(set) var scale: Double
    /// Detent currently holding the scale, with the pinch movement since.
    public private(set) var holding: (value: Double, travel: Double)?

    public init(scale: Double, fit: Double) {
        self.scale = scale
        self.fit = fit
    }

    public var minScale: Double { 0.8 * min(fit, 0.25) }

    /// Detents: 100 % and the fit scale.
    public var detents: [Double] { fit == 1 ? [1] : [1, fit] }

    /// Applies one `magnify(with:)` step. Returns true when a detent
    /// catches the scale (the caller plays the haptic).
    @discardableResult
    public mutating func apply(magnification m: Double) -> Bool {
        let factor = max(0.01, 1 + m)
        if let hold = holding {
            let travel = hold.travel * factor
            if abs(travel - 1) >= Self.detentRelease {
                holding = nil
                scale = clamp(hold.value * travel)
            } else {
                holding = (hold.value, travel)
            }
            return false
        }
        let proposed = clamp(scale * factor)
        for d in detents where crosses(from: scale, to: proposed, detent: d) {
            scale = d
            holding = (d, 1)
            return true
        }
        scale = proposed
        return false
    }

    /// The scale to settle on when the fingers lift: below Fit returns to
    /// Fit (nil = go to fit mode).
    public var releaseScale: Double? {
        scale < fit * (1 - ZoomLadder.epsilon) ? nil : scale
    }

    private func clamp(_ s: Double) -> Double { min(max(s, minScale), Self.maxScale) }

    private func crosses(from a: Double, to b: Double, detent d: Double) -> Bool {
        guard a != d else { return false }
        return (a < d && b >= d) || (a > d && b <= d)
    }
}

// MARK: - Pan clamp and anchor

public enum PanGeometry {
    /// Clamps a pan offset (view points, image centre relative to the view
    /// centre). On an axis where the image is larger than the view its
    /// edges can't come inside the view edges; where it is smaller it
    /// stays centred.
    public static func clamp(pan: CGPoint, imageSize: CGSize, viewSize: CGSize) -> CGPoint {
        func axis(_ p: CGFloat, _ image: CGFloat, _ view: CGFloat) -> CGFloat {
            let slack = (image - view) / 2
            guard slack > 0 else { return 0 }
            return min(max(p, -slack), slack)
        }
        return CGPoint(x: axis(pan.x, imageSize.width, viewSize.width),
                       y: axis(pan.y, imageSize.height, viewSize.height))
    }

    /// Pan that keeps the image point under `anchor` (view coordinates,
    /// origin bottom-left) in place when the scale goes `from` → `to`.
    public static func anchoredPan(pan: CGPoint, anchor: CGPoint, viewSize: CGSize,
                                   from oldScale: Double, to newScale: Double) -> CGPoint {
        guard oldScale > 0 else { return pan }
        let ratio = CGFloat(newScale / oldScale)
        let cx = viewSize.width / 2, cy = viewSize.height / 2
        let rx = anchor.x - cx - pan.x
        let ry = anchor.y - cy - pan.y
        return CGPoint(x: anchor.x - cx - rx * ratio, y: anchor.y - cy - ry * ratio)
    }
}

// MARK: - Double-click / smart zoom

public enum ToggleZoom {
    /// At Fit → 100 %; otherwise back to Fit (nil).
    public static func target(atFit: Bool) -> Double? { atFit ? 1.0 : nil }
}

// MARK: - VoiceOver zoom announcement

public struct ZoomAnnouncementThrottle: Sendable {
    public static let minInterval: TimeInterval = 0.5
    private var last: TimeInterval = -.infinity
    public init() {}

    /// True when an announcement may be posted at `time`.
    public mutating func allow(at time: TimeInterval) -> Bool {
        guard time - last >= Self.minInterval else { return false }
        last = time
        return true
    }

    public static func text(scale: Double, atFit: Bool) -> String {
        atFit ? "Zoom to fit" : "Zoom \(Int((scale * 100).rounded())) percent"
    }
}

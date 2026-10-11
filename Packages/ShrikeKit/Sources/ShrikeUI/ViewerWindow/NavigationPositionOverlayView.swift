//
//  NavigationPositionOverlayView.swift
//  ShrikeUI
//
//  Bottom-left "43 / 180 — DSC_0042.jpg" overlay that tells the user where
//  they are in the current folder during a navigation sequence. Separate
//  view type from `PageIndicatorView` (which is earmarked for PDF-style
//  page-within-a-file feedback) so each can evolve
//  independently.
//
//  Behaviour:
//    * appears on the first image load AND on every nav event
//    * stays visible while a hold-to-scroll is draining (updates text in
//      place instead of fading/restoring per keystroke)
//    * default (spec 24 §1.2): auto-hide, fades after 2.0 s of nav inactivity
//      (250 ms fade-out) while `Prefs.viewerPositionOverlayAutoHides` is true
//    * pref off: never fades; remains visible until window closes
//    * subtle — SF Mono 13 pt, white-on-translucent-black, 6 pt radius
//    * 8 pt inset from the corner, above the bottom-toolbar hover zone
//    * survives the pure-black-fullscreen rule (no materials outside itself)
//
//  Hairline progress indicator:
//    * A **determinate** 0→100% progress fill along the pill's bottom
//      inside edge, driven by `DecodeTimePredictor`. The previous
//      indeterminate sliding-segment architecture is deleted in full —
//      `hairlineSegmentLayer` no longer exists; the single `hairlineLayer`
//      IS the fill, with its width animated end-to-end.
//    * Four-phase state machine:
//        Phase A  0% → 80%      linear over `predicted` ms
//        Phase B  80% → 95%     linear over `2 × predicted` ms (reads
//                                as asymptotic against A's slope — 10.7×
//                                slower rate, "straining to finish")
//        Phase C  hold at 95%   indefinite, until paint or error
//        Phase D  current → 1   80 ms ease-out, then α fade 150 ms
//    * Two-path show gate:
//        predicted > 150 ms    → `setHairlineProgress()` with startWidth
//                                = 0 — predictive-skip, Phase A at t=0
//        predicted ≤ 150 ms    → `scheduleHairlineShow(predicted:)` with
//                                the 100 ms grace. When the grace fires,
//                                pre-fill to `min(0.80, (100/p) × 0.80)`
//                                so the bar catches up to where Phase A
//                                would have been, no visual restart.
//    * 180 ms min-visible floor — if a paint lands so early that the Phase
//      D tail (≈ 230 ms) would complete inside the floor, the tail's start
//      is deferred. The floor applies to both gate paths.
//    * No per-nav pulse, no slide, no reset-on-nav.
//    * Reduce Motion: Phase A linear fill is preserved (it's the signal,
//      not ornament). Phase B collapses to a snap from 80% to 95%. Phase D
//      width snap collapses to an instantaneous set; the 150 ms alpha fade
//      is retained (opacity change, not spatial motion).
//    * Increase Contrast: 1 pt → 2 pt, alpha 60% → 100%.
//    * Error state: prefix label with `⚠ `, label + hairline tinted red,
//      width set instantly to 1.0 (no 80 ms ease — error has its own beat),
//      hold 400 ms, revert. Preempted by next nav.
//    * Auto-hide is paused while the hairline is visible so the pill
//      doesn't fade out mid-decode. Resumes on hairline hide.
//

import AppKit
import ShrikeIO
import ShrikeCore
import QuartzCore

@MainActor
final class NavigationPositionOverlayView: HUDSurfaceView {

    // MARK: - Empty state

    /// True while the viewer shows its empty state: the view stays hidden
    /// whatever its own show / hide code asks for, and the asked-for state
    /// comes back when the empty state goes away.
    var isSuppressed = false {
        didSet { super.isHidden = wantsHidden || isSuppressed }
    }
    private var wantsHidden = false
    override var isHidden: Bool {
        get { super.isHidden }
        set { wantsHidden = newValue; super.isHidden = newValue || isSuppressed }
    }

    // MARK: - Pill motion tokens

    static let fadeInDuration: TimeInterval = 0.12
    static let fadeOutDuration: TimeInterval = 0.25
    static let idleTimeout: TimeInterval = 2.0

    // MARK: - Hairline motion + layout tokens

    /// 100 ms — how long a decode must be in flight before the hairline
    /// appears on the grace path. Below this threshold fast cached nav
    /// shows no hairline.
    static let hairlineShowGrace: TimeInterval = 0.100
    /// 180 ms — minimum time the hairline stays on screen once it has
    /// appeared. If a paint event lands so early that the Phase D tail
    /// (≈ 230 ms) would complete inside the floor, the tail's start is
    /// deferred so its end lands at the floor boundary. Applies to both
    /// gate paths.
    static let hairlineMinVisible: TimeInterval = 0.180
    /// 150 ms — the predictor threshold above which the 100 ms grace is
    /// skipped.
    public static let hairlinePredictiveShowThreshold: TimeInterval = 0.150
    /// 80 ms fade-in (motion.instant), concurrent with the start of Phase A.
    static let hairlineFadeInDuration: TimeInterval = 0.080
    /// 80 ms Phase D width ease-out — current → 1.0.
    static let hairlineCompletionWidthDuration: TimeInterval = 0.080
    /// 150 ms Phase D alpha fade — 1 → 0, runs *after* the width ease-out
    /// completes (sequential, not concurrent).
    static let hairlineCompletionAlphaDuration: TimeInterval = 0.150
    /// 230 ms — total Phase D tail duration (width + alpha). Used to
    /// compute whether the tail's start should be deferred to respect the
    /// min-visible floor.
    static let hairlineCompletionTailDuration: TimeInterval =
        hairlineCompletionWidthDuration + hairlineCompletionAlphaDuration
    /// Phase A confidence-band ceiling. Bar reaches this over `predicted` ms.
    static let hairlinePhaseACeiling: CGFloat = 0.80
    /// Phase B "almost done" ceiling. Bar reaches this over `2 × predicted` ms.
    static let hairlinePhaseBCeiling: CGFloat = 0.95
    /// Multiplier on `predicted` that sets Phase B's duration.
    static let hairlinePhaseBDurationMultiplier: Double = 2.0
    /// Standard hairline height in points.
    static let hairlineStandardHeight: CGFloat = 1
    /// Hairline height under Increase Contrast.
    static let hairlineIncreaseContrastHeight: CGFloat = 2
    /// Standard neutral hairline alpha (white@60 / black@60).
    static let hairlineStandardAlpha: CGFloat = 0.60
    /// Red hairline alpha during the error flash.
    static let hairlineErrorAlpha: CGFloat = 0.80

    // MARK: - Error flash tokens

    /// Hold the error state for 400 ms before reverting to normal.
    static let errorHoldDuration: TimeInterval = 0.400

    // MARK: - Accessibility tokens

    /// Minimum hairline-visible duration before a VO announcement fires.
    static let voAnnounceThreshold: TimeInterval = 0.500
    /// Gap between two VO announcements.
    static let voAnnounceThrottle: TimeInterval = 2.0

    // MARK: - Subviews / layers

    private let label = NSTextField(labelWithString: "")
    /// Hairline sublayer — the visible fill. Single layer; its width is
    /// the only animated property. Inside the pill's `masksToBounds`, so
    /// the 6 pt corner radii clip the ends of the stripe.
    private let hairlineLayer = CALayer()

    // MARK: - Pill state

    private var fadeOutWorkItem: DispatchWorkItem?

    /// When true, `show(...)` schedules a fade-out after `idleTimeout` like
    /// the spec 24 default. When false, the overlay stays
    /// fully visible until `fadeOutNow()` is called (window teardown).
    ///
    /// This is a *computed* property that re-reads the
    /// pref on every call. Previously the viewer
    /// cached the flag on its own field, so flipping Preferences mid-session
    /// never took effect until the next window was constructed. Setter
    /// still exists for back-compat with tests that want to force a
    /// deterministic value — it persists through to UserDefaults, same as
    /// the user toggling the pref.
    ///
    /// Tests can override the pref read via `autoHidesOverrideForTesting`.
    var autoHides: Bool {
        get {
            if let forced = autoHidesOverrideForTesting { return forced }
            return Prefs.viewerPositionOverlayAutoHides
        }
        set {
            Prefs.viewerPositionOverlayAutoHides = newValue
        }
    }

    /// Test-injection seam for `autoHides`. When non-nil, overrides the
    /// UserDefaults read so tests can exercise both paths without
    /// touching shared state.
    internal var autoHidesOverrideForTesting: Bool?

    // MARK: - Reduce Motion (injectable for tests)

    /// Test-injection seam. When non-nil, overrides
    /// `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` for the
    /// purposes of Phase B / Phase D motion decisions. Kept `internal` so
    /// tests can drive Reduce Motion behavior deterministically without
    /// flipping a system-wide flag.
    internal var reduceMotionOverride: Bool?

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - Hairline state

    /// Pending show-grace task scheduled by `scheduleHairlineShow()`.
    /// Cancelled by `completeHairline()` (fast-paint) and by `flashError()`.
    internal private(set) var pendingHairlineShowTask: DispatchWorkItem?

    /// Predicted duration captured by the most recent grace schedule.
    /// Updated by repeat `scheduleHairlineShow(predicted:)` calls so the
    /// predictor race can refine a default prediction with the real one
    /// before the grace fires. Read by the grace handler.
    private var pendingGracePredicted: TimeInterval = 0

    /// Pending Phase B transition task. Fires `predicted` seconds after
    /// Phase A begins — if the decode hasn't landed, we start Phase B.
    internal private(set) var pendingPhaseBTask: DispatchWorkItem?

    /// `predicted` value captured by the most recent
    /// `scheduleEnterPhaseB(predicted:)`. Retained so the test hook
    /// `firePhaseBTransitionForTesting` can invoke `enterPhaseB` with the
    /// same predicted that the real DispatchWorkItem would have used.
    private var pendingPhaseBPredicted: TimeInterval = 0

    /// Pending Phase C transition task. Fires `3 × predicted` seconds
    /// after Phase A begins — if the decode hasn't landed, we pin at 95%.
    internal private(set) var pendingPhaseCTask: DispatchWorkItem?

    /// Pending deferred fade-out task scheduled by `completeHairline()` when
    /// the paint landed early enough that the tail would complete inside
    /// the 180 ms min-visible window.
    internal private(set) var pendingHairlineHideTask: DispatchWorkItem?

    /// Pending Phase D fade-start task. Scheduled to fire 80 ms after
    /// the Phase D width ease begins (width + alpha run
    /// *sequentially*). Using an explicit `DispatchWorkItem` — rather
    /// than `CATransaction.setCompletionBlock` — guarantees the fade
    /// kicks off deterministically on the main queue regardless of
    /// whether a runloop-less context (unit tests) or a CA edge case
    /// drops the completion callback. Was the root cause of the
    /// "bar stuck at 100%" report. Cancelled by
    /// `flashError()`, `restartFreshPhasesForNewGeneration()`, and by a
    /// re-entrant `performCompletionTail()` so a second completeHairline
    /// doesn't fire two fades.
    internal private(set) var pendingPhaseDFadeTask: DispatchWorkItem?

    /// Pending final-hide task scheduled 150 ms after the fade begins.
    /// Sets `hairlineLayer.isHidden = true` + zeros model opacity so
    /// the layer is firmly down after the fade. Cancelled alongside
    /// `pendingPhaseDFadeTask` on re-entry.
    internal private(set) var pendingPhaseDFinalHideTask: DispatchWorkItem?

    /// True between `setHairlineProgress()` / `scheduleHairlineShow()` grace
    /// firing and `completeHairline()` completing. Distinct from
    /// `hairlineLayer.opacity > 0` because fade-out is animated.
    internal private(set) var isHairlineVisible: Bool = false

    /// Wall-clock instant the hairline became visible. Drives both the
    /// VO announcement throttle and the 180 ms min-visible floor check.
    private var hairlineVisibleSince: Date?

    /// Current phase. Exposed to tests for assertions.
    internal enum HairlinePhase: Sendable, Equatable {
        case idle
        case phaseA          // linear 0 → 0.80
        case phaseB          // linear 0.80 → 0.95
        case phaseC          // held at 0.95
        case phaseDWidth     // Phase D width ease-out 80 ms
        case phaseDFade      // Phase D alpha fade 150 ms
    }

    internal private(set) var hairlinePhase: HairlinePhase = .idle

    /// The *logical* width fraction for the current phase — what the
    /// tests observe via `currentProgressForTesting`, and what's used as
    /// the starting point of the next animation leg. Updated at phase
    /// transitions:
    ///   * `revealWithStartWidth` / `revealFromGrace`: set to the start
    ///     (0 for predictive-skip, pre-fill for grace)
    ///   * `enterPhaseB`: set to 0.80 (Phase A end → Phase B start) under
    ///     normal motion; set to 0.95 under Reduce Motion (snap)
    ///   * `enterPhaseC`: set to 0.95
    ///   * `performCompletionTail`: set to 1.0
    ///   * `flashError`: set to 1.0
    /// Note that this is distinct from `modelLayerTargetFraction`, which
    /// tracks the model-layer's end state for layout re-flow purposes.
    private var currentProgressFraction: CGFloat = 0

    /// The model-layer's end-state width fraction — i.e. what
    /// `hairlineLayer.bounds.size.width` is set to. Set to the *endpoint*
    /// of the current animation leg so that re-layout (e.g. window
    /// resize) keeps the rendered width consistent with the animation's
    /// target. Separate from `currentProgressFraction` because the tests
    /// want the logical phase start, not the animation target.
    private var modelLayerTargetFraction: CGFloat = 0

    /// True while the error flash is active. Cleared by the 400 ms timeout
    /// or by any new nav signal.
    internal private(set) var isInErrorState: Bool = false

    /// Pending error-hold task.
    internal private(set) var pendingErrorRevertTask: DispatchWorkItem?

    /// Previous fade-out token that was cancelled while the hairline was up.
    /// Resumed from the last nav timestamp when the hairline hides.
    private var pausedAutoHideSavedToken: Bool = false

    private var lastAnnouncementEpoch: Date?

    /// Pending 500 ms VO announcement task. Cancelled when the hairline
    /// fades out early (`completeHairline`, `flashError`, the error
    /// tail, `revealWithStartWidth` re-entry) so a deferred paint doesn't
    /// announce "Loading image" *after* the image is already up.
    internal private(set) var pendingVoiceOverAnnouncementTask: DispatchWorkItem?

    // MARK: - VO test-injection seams

    /// Test-injection seam for `NSWorkspace.shared.isVoiceOverEnabled`.
    /// Non-nil in tests so we can drive both the enabled and disabled
    /// paths deterministically without flipping a system-wide pref.
    internal var voiceOverEnabledOverride: Bool?

    /// Test-injection seam for the announcement side effect. The closure
    /// receives the localized announcement string each time the throttle
    /// + visibility gates permit. Defaults to the real
    /// `NSAccessibility.post` using the containing window as the
    /// element (see `postDefaultAnnouncement`). Tests replace this with
    /// a counter closure.
    internal lazy var voiceOverAnnouncer: @MainActor (String) -> Void = { [weak self] msg in
        self?.postDefaultAnnouncement(msg)
    }

    /// Test-injection seam for back-dating the last-announcement epoch
    /// so tests can fast-forward past the 2 s throttle without sleeping.
    /// Subtracts `seconds` from `lastAnnouncementEpoch` — e.g. calling
    /// with `3.0` makes the throttle think it's been 3 s since the
    /// last announcement, so the next fire is permitted.
    internal func backdateLastAnnouncementForTesting(by seconds: TimeInterval) {
        guard let last = lastAnnouncementEpoch else { return }
        lastAnnouncementEpoch = last.addingTimeInterval(-seconds)
    }

    private var isVoiceOverActive: Bool {
        voiceOverEnabledOverride ?? NSWorkspace.shared.isVoiceOverEnabled
    }

    /// The real announcement path — posts to `NSAccessibility` using the
    /// containing window as the element (falls back to `NSApp` when the
    /// overlay hasn't been attached to a window yet, e.g. during unit
    /// tests that don't install the view into a window). Per
    /// the throttled announcement has `priority: .medium` — VoiceOver
    /// treats `.medium` as non-interruptive, which is the right volume
    /// for a "something is loading" cue.
    private func postDefaultAnnouncement(_ message: String) {
        let element: Any = window ?? (NSApp as Any)
        NSAccessibility.post(
            element: element,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    /// Current label text sans the error prefix.
    private var baseLabelText: String = ""
    /// What the label draws now (tests).
    internal var labelTextForTesting: NSAttributedString { label.attributedStringValue }
    /// Layout seams (tests): the text label's and the marks label's frames.
    /// Alignment rects: what the constraints place (a text field's frame is
    /// 2 pt wider than that on each side).
    internal var labelFrameForTesting: NSRect {
        layoutSubtreeIfNeeded(); return label.alignmentRect(forFrame: label.frame)
    }
    internal var marksFrameForTesting: NSRect? {
        layoutSubtreeIfNeeded()
        return marksLabel.isHidden ? nil : marksLabel.alignmentRect(forFrame: marksLabel.frame)
    }
    internal var marksTextWidthForTesting: CGFloat { marksLabel.attributedStringValue.size().width }

    /// Stars, flag, tag dots, RAW chip, pencil.
    private let marksLabel = NSTextField(labelWithString: "")

    /// Spec 24 §4.3: the pair chip is the only clickable part of the pill.
    /// A transparent button over the chip (at least 28 × 22 pt).
    let chipButton = PillChipButton()
    /// The chip was clicked: switch between the primary and the RAW.
    var onToggleRAW: (() -> Void)?

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        wantsLayer = true

        label.font = PillMarks.nameFont
        label.textColor = .white
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        // Marks sit in their own label after the text and never
        // compress: when the pill hits its max width the name truncates.
        marksLabel.translatesAutoresizingMaskIntoConstraints = false
        marksLabel.maximumNumberOfLines = 1
        marksLabel.isHidden = true
        marksLabel.setAccessibilityElement(false)
        addSubview(marksLabel)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chipButton.target = self
        chipButton.action = #selector(chipClicked(_:))
        chipButton.isHidden = true
        chipButton.setAccessibilityLabel("File type")
        chipButton.setAccessibilityIdentifier("viewer.pill.fileType")
        addSubview(chipButton)
        marksLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        marksLabel.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            marksLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor),
            marksLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            marksLabel.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        // Single hairline layer — transparent when idle. Anchored to the
        // pill's bottom inside edge, left-aligned. Width = currentProgress
        // × hairlineFullWidth; when idle or not-yet-shown, width = 0.
        hairlineLayer.anchorPoint = CGPoint(x: 0, y: 0)
        hairlineLayer.opacity = 0
        hairlineLayer.masksToBounds = true
        layer?.addSublayer(hairlineLayer)
        // A capsule on macOS 26; the hairline stays on top
        // of the glass.
        glassShape = .capsule
        onLookChanged = { [weak self] in
            guard let self else { return }
            self.hairlineLayer.removeFromSuperlayer()
            self.layer?.addSublayer(self.hairlineLayer)
        }

        alphaValue = 0
        isHidden = true

        updateHairlineAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    @objc private func chipClicked(_ sender: Any?) { onToggleRAW?() }

    /// Only the chip takes clicks; the rest of the pill is passive.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === chipButton ? hit : nil
    }

    /// Puts the chip button over the chip and words its tooltip / value.
    private func layoutChipButton() {
        guard let metrics = PillMarks.pairChipMetrics(marks), !marksLabel.isHidden else {
            chipButton.isHidden = true
            return
        }
        let alignment = marksLabel.alignmentRect(forFrame: marksLabel.frame)
        let width = max(28, metrics.width)
        let height: CGFloat = 22
        let centreX = alignment.minX + metrics.offset + metrics.width / 2
        let chipFrame = NSRect(x: centreX - width / 2, y: alignment.midY - height / 2,
                               width: width, height: height)
        if chipButton.frame != chipFrame {
            chipButton.frame = chipFrame
            // The pointing-hand rect follows the chip.
            chipButton.window?.invalidateCursorRects(for: chipButton)
        }
        chipButton.isHidden = false
        let title = marks.rawShown ? "Show \(marks.pairKind == "JPG" ? "JPEG" : marks.pairKind ?? "primary") File"
                                   : "Show RAW File"
        chipButton.toolTip = LiveTooltips.text(.toggleRAWFile, context: .viewer, preset: Prefs.shortcutPreset,
                                               title: title)
        chipButton.setAccessibilityValue(marks.rawShown ? "RAW shown, \(marks.pairKind ?? "primary") available"
                                                         : "\(marks.pairKind ?? "Primary") shown, RAW available")
    }

    /// Test seams: chip hover without a pointer.
    internal func setChipHoveredForTesting(_ on: Bool) { chipButton.setHovered(on) }
    internal var chipPlatterAlphaForTesting: CGFloat { chipButton.platterAlphaForTesting }

    /// Test seam: the chip button's frame (nil when hidden).
    internal var chipButtonFrameForTesting: NSRect? {
        layoutSubtreeIfNeeded()
        return chipButton.isHidden ? nil : chipButton.frame
    }

    override func layout() {
        super.layout()
        layoutChipButton()
        layoutHairlineLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateHairlineAppearance()
    }

    override func updateLayer() {
        super.updateLayer()
        updateHairlineAppearance()
    }

    /// Resize the hairline rect to reflect the current pill width and the
    /// current progress fraction. Invoked by `layout()` and whenever the
    /// progress fraction changes. Always runs inside a disabled-actions
    /// `CATransaction` — all width motion is driven by explicit
    /// `CABasicAnimation`s (see `animateHairlineWidth(...)`).
    private func layoutHairlineLayer() {
        let cornerInset: CGFloat = 6
        let h = hairlineHeight()
        let fullWidth = max(0, bounds.width - cornerInset * 2)
        // Use the model-layer target (animation endpoint), not the logical
        // phase start. This keeps re-layout consistent with the running
        // animation — resizing the window mid-Phase-A won't snap the
        // rendered width back to 0.
        let currentWidth = fullWidth * modelLayerTargetFraction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The layer's *origin* (bottom-left) is anchored; only width moves.
        hairlineLayer.frame = CGRect(
            x: cornerInset,
            y: 0,
            width: currentWidth,
            height: h
        )
        CATransaction.commit()
    }

    private func hairlineFullWidth() -> CGFloat {
        let cornerInset: CGFloat = 6
        return max(0, bounds.width - cornerInset * 2)
    }

    private func hairlineHeight() -> CGFloat {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? Self.hairlineIncreaseContrastHeight
            : Self.hairlineStandardHeight
    }

    private func updateHairlineAppearance() {
        let isDark = (effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
                      ?? .aqua) == .darkAqua
        let increaseContrast = NSWorkspace.shared
            .accessibilityDisplayShouldIncreaseContrast
        let alpha: CGFloat = increaseContrast
            ? 1.0
            : Self.hairlineStandardAlpha
        let base: NSColor = isDark ? .white : .black
        let fill = isInErrorState
            ? NSColor.systemRed.withAlphaComponent(Self.hairlineErrorAlpha)
            : base.withAlphaComponent(alpha)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hairlineLayer.backgroundColor = fill.cgColor
        CATransaction.commit()
        needsLayout = true
    }

    // MARK: - Public pill API

    /// Update the text in place and ensure the overlay is visible.
    func show(index: Int, total: Int, filename: String?) {
        let position = "\(index + 1) / \(total)"
        let text: String
        if let filename, !filename.isEmpty {
            text = "\(position)\(PillMarks.nameSeparator)\(filename)"
        } else {
            text = position
        }
        baseLabelText = text

        if isInErrorState {
            clearErrorState(animated: false)
        }

        renderLabel()

        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil

        if isHidden {
            isHidden = false
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        } else if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }

        if autoHides && !isHairlineVisible {
            scheduleFadeOut()
        }
    }

    /// Called by the viewer whenever `Prefs.viewerPositionOverlayAutoHides`
    /// may have changed. If the pref is now off, cancel any pending fade
    /// and ensure the overlay is fully visible (the user switched to
    /// always-on mid-session). If the pref is now on and the overlay is
    /// visible, schedule a fade-out so the new setting takes effect at
    /// once rather than waiting for the next nav event.
    func autoHidesPrefDidChange() {
        if !autoHides {
            fadeOutWorkItem?.cancel()
            fadeOutWorkItem = nil
            if !isHidden {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.fadeInDuration
                    animator().alphaValue = 1
                }
            }
        } else {
            if !isHidden && alphaValue > 0 && !isHairlineVisible {
                scheduleFadeOut()
            }
        }
    }

    /// Fade out immediately without waiting for the idle timeout.
    func fadeOutNow() {
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil
        runFadeOut()
    }

    // MARK: - Public hairline API

    /// Schedule the grace-path show. Captures `predicted` so the grace-
    /// fire handler can compute the pre-fill width via
    /// `min(0.80, (100/predicted) × 0.80)`. Idempotent — a second call
    /// while a grace task is already pending preserves the first call's
    /// deadline.
    ///
    /// When the grace fires and the decode is still in flight, the
    /// hairline appears at the pre-fill width and Phase A starts from
    /// that width toward 0.80, over the *remaining* `predicted - 100` ms.
    func scheduleHairlineShow(predicted: TimeInterval) {
        // A fresh nav preempts the error hold.
        if isInErrorState {
            clearErrorState(animated: false)
        }

        // A pending deferred-hide means the hairline is still riding out
        // the 180 ms floor. Cancel it so a new nav keeps the bar up
        // continuously across the burst.
        if let pendingHide = pendingHairlineHideTask {
            pendingHide.cancel()
            pendingHairlineHideTask = nil
        }

        pauseAutoHide()

        if isHairlineVisible {
            // Already visible — a previous generation's phase animation
            // is still playing. Any overlapping fresh decode schedules its
            // own Phase A from its own generation's `beginNavigation`
            // instant, so reset the fill to 0 and start
            // a fresh Phase A for the new generation. The hairline stays
            // opaque across the restart so the bar is visually continuous
            // across a rapid-nav burst, but the *fill* resets so the user
            // doesn't see a stale mid-fill width that looks like it's
            // tracking the old target.
            restartFreshPhasesForNewGeneration(predicted: predicted)
            return
        }
        if pendingHairlineShowTask != nil {
            // Grace task already counting down — preserve the first call's
            // deadline but update the captured `predicted`. This is the
            // path the predictor-race uses: beginNavigation seeds the
            // grace with a default `predicted` so pre-fill math is
            // defined; the predictor resolves a few ms later and calls
            // through again with the refined value. The grace still fires
            // at 100 ms from the original schedule (no deadline shift),
            // but reads the refined `predicted` out of the captured
            // field. Phase A / Phase B durations then reflect reality.
            pendingGracePredicted = predicted
            return
        }

        pendingGracePredicted = predicted
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHairlineShowTask = nil
            let refined = self.pendingGracePredicted
            self.pendingGracePredicted = 0
            self.revealFromGrace(predicted: refined)
        }
        pendingHairlineShowTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hairlineShowGrace,
            execute: task
        )
    }

    /// Predictive-skip path. Cancels any pending 100 ms grace
    /// and reveals the hairline immediately at t=0 with `startWidth` (0
    /// by default — predictive-skip starts clean). Phase A begins at t=0
    /// with duration `predicted`.
    ///
    /// `startWidthOverride` is an internal escape hatch — e.g. for the
    /// grace path's deferred reveal, which computes a non-zero pre-fill
    /// before calling through. Public callers should leave it `nil`.
    func setHairlineProgress(
        predicted: TimeInterval,
        startWidthOverride: CGFloat? = nil
    ) {
        // A fresh nav preempts the error hold.
        if isInErrorState {
            clearErrorState(animated: false)
        }

        // Cancel any pending grace — the predictor got there first.
        pendingHairlineShowTask?.cancel()
        pendingHairlineShowTask = nil

        // Pending deferred-hide: cancel so the hairline stays continuous
        // into this new nav.
        if let pendingHide = pendingHairlineHideTask {
            pendingHide.cancel()
            pendingHairlineHideTask = nil
        }

        pauseAutoHide()

        if isHairlineVisible {
            // Already up — "any overlapping fresh decode
            // schedules its own Phase A from its own generation's
            // `beginNavigation` instant". Reset the fill to the override
            // (0 for public predictive-skip callers) and start a fresh
            // Phase A. Do NOT reset `hairlineVisibleSince` — the 180 ms
            // min-visible floor still dates from the original show so
            // rapid-nav bursts don't extend the bar's lifetime past
            // where the first show's floor would have ended.
            restartFreshPhasesForNewGeneration(
                predicted: predicted,
                startWidthOverride: startWidthOverride
            )
            return
        }

        let startWidth = startWidthOverride ?? 0
        revealWithStartWidth(startWidth: startWidth, predicted: predicted)
    }

    /// Triggers Phase D — cancels any running phase animation, eases width
    /// from current → 1.0 over 80 ms, then fades alpha 1 → 0 over 150 ms.
    /// Sequential, not concurrent. Honors the 180 ms min-visible floor:
    /// if the tail would complete inside the floor, its start is deferred
    /// so the tail's end lands at the floor boundary.
    ///
    /// Idempotent:
    ///   * If the hairline is not visible and no grace is pending, just
    ///     resumes auto-hide and returns.
    ///   * If only the grace is pending (no visible hairline yet), the
    ///     grace is cancelled — the hairline never appears.
    ///   * If a deferred-hide is already pending, this is a no-op.
    func completeHairline() {
        pendingHairlineShowTask?.cancel()
        pendingHairlineShowTask = nil

        // Full decode lands = cancel the pending VO announcement. A
        // deferred "Loading image" would otherwise fire *after* the
        // image is already painted, which is worse than useless for a
        // VO user (contradicts the actual current state).
        cancelPendingVoiceOverAnnouncement()

        guard isHairlineVisible else {
            resumeAutoHide()
            return
        }

        // Already deferred — let that task complete.
        if pendingHairlineHideTask != nil {
            return
        }

        // Cancel Phase A/B/C machinery — we own the hairline from here.
        cancelPhaseABCTimers()

        let elapsed = hairlineVisibleSince
            .map { Date().timeIntervalSince($0) } ?? Self.hairlineMinVisible

        // If the tail's start + full 230 ms tail would *end* before the
        // floor, defer the start so the tail's end lands at the floor.
        //   tailStartDelay = max(0, minVisible - tailDuration - elapsed)
        let tail = Self.hairlineCompletionTailDuration
        let floor = Self.hairlineMinVisible
        let tailStartDelay = max(0, floor - tail - elapsed)

        if tailStartDelay == 0 {
            performCompletionTail()
            return
        }

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingHairlineHideTask = nil
            guard self.isHairlineVisible else { return }
            self.performCompletionTail()
        }
        pendingHairlineHideTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + tailStartDelay,
            execute: task
        )
    }

    /// Snap the overlay into the error flash: prefix `⚠ `, tint label +
    /// hairline red, set hairline width **instantly to 100%** (no 80 ms
    /// ease — error has its own beat), hold 400 ms, revert.
    func flashError() {
        pendingHairlineShowTask?.cancel()
        pendingHairlineShowTask = nil
        pendingHairlineHideTask?.cancel()
        pendingHairlineHideTask = nil
        pendingErrorRevertTask?.cancel()
        pendingErrorRevertTask = nil
        pendingPhaseDFadeTask?.cancel()
        pendingPhaseDFadeTask = nil
        pendingPhaseDFinalHideTask?.cancel()
        pendingPhaseDFinalHideTask = nil
        cancelPhaseABCTimers()
        // Error has its own accessibility beat (red-tinted label +
        // accessibilityValue suffix). The "Loading image" announcement
        // would be actively misleading at this point.
        cancelPendingVoiceOverAnnouncement()

        // Error takes the layer back — ensure it's un-hidden and fully
        // opaque even if a fade / final-hide was in flight from a prior
        // completeHairline.
        hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
        hairlineLayer.isHidden = false

        isInErrorState = true

        // Ensure the pill is visible.
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil
        if isHidden {
            isHidden = false
            alphaValue = 1
        } else if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.hairlineFadeInDuration
                animator().alphaValue = 1
            }
        }

        let base = baseLabelText.isEmpty ? label.stringValue : baseLabelText
        if baseLabelText.isEmpty { baseLabelText = base }
        label.stringValue = "⚠ \(base)"
        label.textColor = .systemRed

        // Hairline: surface if not already visible, set width to 1.0
        // instantly (no animation), tint red, hold.
        if !isHairlineVisible {
            isHairlineVisible = true
            hairlineVisibleSince = Date()
            // Fade-in alpha (spatial-motion-free, retained under RM).
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = hairlineLayer.presentation()?.opacity ?? 0
            fade.toValue = 1
            fade.duration = Self.hairlineFadeInDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fade.fillMode = .forwards
            fade.isRemovedOnCompletion = false
            hairlineLayer.add(fade, forKey: "shrike.hairline.fadeIn")
            hairlineLayer.opacity = 1
        }

        // Instant width snap to 1.0 — no CABasicAnimation, no ease.
        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)
        currentProgressFraction = 1.0
        modelLayerTargetFraction = 1.0
        layoutHairlineLayer()
        hairlinePhase = .idle   // error has its own beat, not a phase
        updateHairlineAppearance()

        setAccessibilityValue(accessibilityValueString())

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingErrorRevertTask = nil
            self.clearErrorState(animated: true)
        }
        pendingErrorRevertTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.errorHoldDuration,
            execute: task
        )
    }

    // MARK: - Testing hooks

    /// Fire the pending grace-show task without sleeping. Reads the
    /// `predicted` value captured by the most recent
    /// `scheduleHairlineShow(predicted:)` call so tests see the same
    /// pre-fill behavior as the production grace handler.
    internal func fireHairlineShowForTesting() {
        guard let task = pendingHairlineShowTask else { return }
        task.cancel()
        pendingHairlineShowTask = nil
        let predicted = pendingGracePredicted
        pendingGracePredicted = 0
        revealFromGrace(predicted: predicted)
    }

    /// Fire the pending grace-show task with an explicit predicted —
    /// overrides whatever was captured during scheduling. Used by tests
    /// that want to drive the grace-path pre-fill formula with a specific
    /// `predicted` without re-scheduling.
    internal func fireHairlineShowForTesting(predicted: TimeInterval) {
        guard let task = pendingHairlineShowTask else { return }
        task.cancel()
        pendingHairlineShowTask = nil
        pendingGracePredicted = 0
        revealFromGrace(predicted: predicted)
    }

    /// Fire the pending error-revert task without sleeping 400 ms.
    internal func fireErrorRevertForTesting() {
        guard let task = pendingErrorRevertTask else { return }
        task.cancel()
        pendingErrorRevertTask = nil
        clearErrorState(animated: false)
    }

    /// Fire the pending deferred-hide task without sleeping.
    internal func fireHairlineDeferredHideForTesting() {
        guard let task = pendingHairlineHideTask else { return }
        task.cancel()
        pendingHairlineHideTask = nil
        guard isHairlineVisible else { return }
        performCompletionTail()
    }

    /// Fire the pending Phase B transition task without sleeping the
    /// full `predicted` duration. Uses the `predicted` value captured by
    /// the most recent `scheduleEnterPhaseB` call so the Phase B
    /// animation's duration (`2 × predicted`) is non-degenerate — which
    /// matters for the logical-phase-start vs. animation-target split
    /// the tests observe.
    internal func firePhaseBTransitionForTesting() {
        guard let task = pendingPhaseBTask else { return }
        task.cancel()
        pendingPhaseBTask = nil
        enterPhaseB(predictedOverride: pendingPhaseBPredicted)
    }

    /// Fire the pending Phase C transition task without sleeping the
    /// full `3 × predicted` duration.
    internal func firePhaseCTransitionForTesting() {
        guard let task = pendingPhaseCTask else { return }
        task.cancel()
        pendingPhaseCTask = nil
        enterPhaseC()
    }

    /// Fire the pending Phase D fade-start task without sleeping the
    /// 80 ms Phase D width ease. Mirrors what `performCompletionTail`'s
    /// `DispatchQueue.main.asyncAfter(+80 ms)` would do.
    internal func firePhaseDFadeForTesting() {
        guard let task = pendingPhaseDFadeTask else { return }
        task.cancel()
        pendingPhaseDFadeTask = nil
        guard hairlinePhase == .phaseDWidth else { return }
        beginPhaseDFade()
    }

    /// Fire the pending Phase D final-hide task without sleeping the
    /// 150 ms alpha fade. Sets `hairlineLayer.isHidden = true` and
    /// removes the fade animation — what the production runloop would
    /// do 150 ms after `beginPhaseDFade` started.
    internal func firePhaseDFinalHideForTesting() {
        guard let task = pendingPhaseDFinalHideTask else { return }
        task.cancel()
        pendingPhaseDFinalHideTask = nil
        guard hairlinePhase == .phaseDFade else { return }
        hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
        hairlineLayer.isHidden = true
        hairlinePhase = .idle
    }

    /// Backdate the visible-since clock so tests can drive the min-
    /// visible-satisfied path synchronously.
    internal func backdateHairlineVisibleForTesting(by seconds: TimeInterval) {
        hairlineVisibleSince = Date().addingTimeInterval(-seconds)
    }

    /// Current progress fraction — what fraction (0...1) of the full
    /// hairline width is currently filled. Tests assert this at phase
    /// boundaries.
    internal var currentProgressForTesting: CGFloat {
        currentProgressFraction
    }

    // MARK: - Hairline implementation

    private static let progressAnimKey = "shrike.hairline.progress"
    private static let fadeInKey = "shrike.hairline.fadeIn"
    private static let fadeOutKey = "shrike.hairline.fadeOut"
    private static let widthCompletionKey = "shrike.hairline.widthCompletion"

    /// Predictive-skip reveal path: shows the hairline at `startWidth`
    /// (usually 0) and starts Phase A toward 0.80 over `predicted` seconds.
    private func revealWithStartWidth(
        startWidth: CGFloat,
        predicted: TimeInterval
    ) {
        isHairlineVisible = true
        hairlineVisibleSince = Date()
        updateHairlineAppearance()

        // Defensive: if a prior completeHairline() left the layer hidden
        // or scheduled a final-hide, undo that here so this reveal
        // surfaces the layer cleanly.
        pendingPhaseDFadeTask?.cancel()
        pendingPhaseDFadeTask = nil
        pendingPhaseDFinalHideTask?.cancel()
        pendingPhaseDFinalHideTask = nil
        hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
        hairlineLayer.isHidden = false

        // Snap model layer + progress fraction to startWidth.
        let clamped = max(0, min(1, startWidth))
        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)
        currentProgressFraction = clamped
        modelLayerTargetFraction = clamped
        layoutHairlineLayer()

        // Fade in alpha 80 ms, concurrent with Phase A start.
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = hairlineLayer.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = Self.hairlineFadeInDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        hairlineLayer.add(fade, forKey: Self.fadeInKey)
        hairlineLayer.opacity = 1

        startPhaseA(from: clamped, predicted: predicted)

        setAccessibilityValue(accessibilityValueString())
        considerAnnouncingToVoiceOver()
    }

    /// Grace-path reveal: computes the pre-fill width from
    /// `min(0.80, (grace/predicted) × 0.80)` and reveals with that as the
    /// start. Phase A then runs from the pre-fill to 0.80 over the
    /// remaining `predicted - grace` ms.
    ///
    /// Edge case: `predicted < grace` makes the pre-fill clamp to 0.80
    /// (Phase A degenerate), so we jump directly into Phase B.
    private func revealFromGrace(predicted: TimeInterval) {
        let grace = Self.hairlineShowGrace
        let preFill: CGFloat
        let remaining: TimeInterval
        if predicted <= grace {
            // Phase A would be degenerate — just start Phase B.
            preFill = Self.hairlinePhaseACeiling
            remaining = 0
        } else {
            let ratio = CGFloat(grace / predicted)
            preFill = min(Self.hairlinePhaseACeiling, ratio * Self.hairlinePhaseACeiling)
            remaining = predicted - grace
        }

        isHairlineVisible = true
        hairlineVisibleSince = Date()
        updateHairlineAppearance()

        // Defensive: see revealWithStartWidth — undo any prior fade /
        // final-hide state so this reveal is clean.
        pendingPhaseDFadeTask?.cancel()
        pendingPhaseDFadeTask = nil
        pendingPhaseDFinalHideTask?.cancel()
        pendingPhaseDFinalHideTask = nil
        hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
        hairlineLayer.isHidden = false

        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)
        currentProgressFraction = preFill
        modelLayerTargetFraction = preFill
        layoutHairlineLayer()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = hairlineLayer.presentation()?.opacity ?? 0
        fade.toValue = 1
        fade.duration = Self.hairlineFadeInDuration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        hairlineLayer.add(fade, forKey: Self.fadeInKey)
        hairlineLayer.opacity = 1

        if remaining <= 0 {
            // Degenerate Phase A → enter Phase B immediately.
            hairlinePhase = .phaseA   // transient, will be overwritten
            enterPhaseB(predictedOverride: predicted)
        } else {
            startPhaseA(from: preFill, predicted: predicted, remaining: remaining)
        }

        setAccessibilityValue(accessibilityValueString())
        considerAnnouncingToVoiceOver()
    }

    /// Called when a new nav signal arrives while the hairline is still
    /// visible from a previous generation. Cancels the current phase
    /// animation and starts a **fresh** Phase A for the new generation
    /// — from the override width if provided, else from 0. The hairline
    /// stays fully opaque across the restart (no re-fade) so the bar is
    /// visually continuous across a rapid-nav burst, but the *fill* resets
    /// so the user doesn't see the bar stuck mid-fill from a superseded
    /// nav (the bar used to show loading for the old photo during fast
    /// navigation, instead of the photo that should be viewed).
    ///
    /// Any overlapping fresh decode schedules its own Phase A from its
    /// own generation's `beginNavigation` instant, and (see
    /// `test_hairline_reentryDuringCompletionTail_CancelsTail`) the
    /// new nav's own Phase A begins from width 0% (or the predictive-skip
    /// / grace pre-fill as applicable).
    ///
    /// Does NOT reset `hairlineVisibleSince` — the 180 ms min-visible
    /// floor still dates from the original show so rapid-nav bursts
    /// don't artificially extend the bar's lifetime past the boundary
    /// of when it first appeared.
    private func restartFreshPhasesForNewGeneration(
        predicted: TimeInterval,
        startWidthOverride: CGFloat? = nil
    ) {
        cancelPhaseABCTimers()

        // Cancel any Phase D fade / final-hide work items — a fresh nav
        // during the 230 ms tail should adopt the layer cleanly without
        // having a stale fade fire mid-Phase-A of the new generation.
        pendingPhaseDFadeTask?.cancel()
        pendingPhaseDFadeTask = nil
        pendingPhaseDFinalHideTask?.cancel()
        pendingPhaseDFinalHideTask = nil

        // Drop any running width animation cleanly so the snap to the
        // restart width doesn't animate.
        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)

        // Restart from the override (predictive-skip callers pass their
        // pre-fill explicitly; public callers leave it nil → 0). Clamp
        // defensively.
        let restartFraction = max(0, min(1, startWidthOverride ?? 0))
        currentProgressFraction = restartFraction
        modelLayerTargetFraction = restartFraction

        // Commit the width snap inside a disabled-actions transaction so
        // the visual reset is a single frame — no interpolated collapse
        // from the old width back to 0.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutHairlineLayer()
        // Keep opacity pinned at 1 — the bar is continuous across the
        // burst, only the fill resets. Removing any lingering fade-out
        // animation that could have been scheduled by a completeHairline()
        // we already cancelled above. Also unhide defensively in case
        // the layer was mid-final-hide (a stale DispatchWorkItem could
        // have flipped isHidden = true) — the reveal must show through.
        hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
        hairlineLayer.removeAnimation(forKey: Self.widthCompletionKey)
        hairlineLayer.opacity = 1
        hairlineLayer.isHidden = false
        CATransaction.commit()

        // Start Phase A fresh from the restart width. If the caller
        // somehow handed us a pre-fill at or above the Phase A ceiling,
        // jump to Phase B — this matches the initial-show path for the
        // `predicted < grace` degenerate case.
        if restartFraction >= Self.hairlinePhaseACeiling {
            enterPhaseB(predictedOverride: predicted)
        } else {
            startPhaseA(from: restartFraction, predicted: predicted)
        }
    }

    /// Start (or resume) Phase A: linear width animation to 0.80 ceiling,
    /// over `remaining` ms (or the full `predicted` if `remaining` is nil).
    /// Schedules Phase B + Phase C follow-up timers that fire if the decode
    /// still hasn't landed.
    private func startPhaseA(
        from startFraction: CGFloat,
        predicted: TimeInterval,
        remaining: TimeInterval? = nil
    ) {
        hairlinePhase = .phaseA
        let ceiling = Self.hairlinePhaseACeiling
        let dur = remaining ?? predicted

        // Phase A preserves startFraction as the logical observable state
        // (tests see the starting fraction during Phase A), while the
        // model layer animates toward the ceiling.
        currentProgressFraction = startFraction

        // Clamp: if startFraction is already at or past the ceiling, skip A.
        if startFraction >= ceiling || dur <= 0 {
            modelLayerTargetFraction = ceiling
            layoutHairlineLayer()
            // Schedule Phase B directly.
            scheduleEnterPhaseB(predicted: predicted, delay: 0)
            return
        }

        animateHairlineWidth(
            from: startFraction,
            to: ceiling,
            duration: dur,
            timingFunction: CAMediaTimingFunction(name: .linear),
            reduceMotion: false   // Phase A linear is preserved under RM
        )
        modelLayerTargetFraction = ceiling

        // Phase B fires at the *end* of Phase A, which is `dur` seconds
        // from now (= at absolute time `predicted` ms after show, since
        // `dur == remaining == predicted - elapsed`).
        scheduleEnterPhaseB(predicted: predicted, delay: dur)
    }

    /// Schedule the Phase B transition to fire after `delay` seconds.
    private func scheduleEnterPhaseB(predicted: TimeInterval, delay: TimeInterval) {
        pendingPhaseBTask?.cancel()
        pendingPhaseBTask = nil
        pendingPhaseBPredicted = predicted

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPhaseBTask = nil
            self.enterPhaseB(predictedOverride: predicted)
        }
        pendingPhaseBTask = task
        if delay <= 0 {
            DispatchQueue.main.async(execute: task)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: task
            )
        }
    }

    /// Enter Phase B: animate 80% → 95% linearly over `2 × predicted` ms.
    /// Under Reduce Motion, collapse to an instantaneous snap to 95%.
    /// Schedules the Phase C transition to fire at the end.
    private func enterPhaseB(predictedOverride: TimeInterval? = nil) {
        let predicted = predictedOverride ?? 0
        hairlinePhase = .phaseB
        // Phase A just ended at its ceiling (0.80). Phase B animates from
        // 0.80 (the visual state) to 0.95 (the ceiling). Read the model-
        // layer target as the start so a restart mid-Phase-B picks up
        // correctly; but expose 0.80 (Phase A ceiling) as the logical
        // phase-start for tests under normal motion.
        let animationStart = modelLayerTargetFraction
        let ceiling = Self.hairlinePhaseBCeiling
        let duration = predicted * Self.hairlinePhaseBDurationMultiplier

        if effectiveReduceMotion {
            // RM: snap to 95% instantly, no animation. Both logical and
            // model-layer targets jump to the ceiling.
            hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)
            currentProgressFraction = ceiling
            modelLayerTargetFraction = ceiling
            layoutHairlineLayer()
        } else if duration <= 0 || animationStart >= ceiling {
            currentProgressFraction = ceiling
            modelLayerTargetFraction = ceiling
            layoutHairlineLayer()
        } else {
            // Logical state = Phase A ceiling (where Phase B starts).
            currentProgressFraction = Self.hairlinePhaseACeiling
            animateHairlineWidth(
                from: animationStart,
                to: ceiling,
                duration: duration,
                timingFunction: CAMediaTimingFunction(name: .linear),
                reduceMotion: false
            )
            modelLayerTargetFraction = ceiling
        }

        // Phase C: pin at 95% after `2 × predicted` more ms.
        pendingPhaseCTask?.cancel()
        pendingPhaseCTask = nil
        let cDelay: TimeInterval = effectiveReduceMotion ? 0 : duration
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPhaseCTask = nil
            self.enterPhaseC()
        }
        pendingPhaseCTask = task
        if cDelay <= 0 {
            DispatchQueue.main.async(execute: task)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + cDelay,
                execute: task
            )
        }
    }

    /// Enter Phase C: hold at 95% indefinitely. No animation.
    private func enterPhaseC() {
        hairlinePhase = .phaseC
        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)
        currentProgressFraction = Self.hairlinePhaseBCeiling
        modelLayerTargetFraction = Self.hairlinePhaseBCeiling
        layoutHairlineLayer()
    }

    /// Phase D — the completion tail. Eases width from current to 1.0
    /// over 80 ms ease-out, then fades alpha 1 → 0 over 150 ms. Under
    /// Reduce Motion, the width portion collapses to an instant set;
    /// the alpha fade is preserved (opacity changes are below RM's
    /// threshold — only spatial/scale motion is suppressed).
    ///
    /// The 80 ms width → fade handoff is scheduled via an explicit
    /// `DispatchWorkItem` on the main queue, NOT via
    /// `CATransaction.setCompletionBlock`. The latter proved unreliable
    /// in production (the bar got stuck at 100%): if
    /// `performCompletionTail` was called a second time while the first
    /// width animation was still in flight, replacing the first
    /// animation by key could drop the first transaction's completion
    /// block, leaving the fade unscheduled. The bar then sat at width
    /// 1.0 / opacity 1.0 indefinitely. An explicit work item is
    /// cancellable, re-entrant-safe, and runs deterministically on the
    /// main queue.
    private func performCompletionTail() {
        guard isHairlineVisible else { return }

        // Cancel any running phase animation + future transitions. The
        // tail owns the hairline from here.
        cancelPhaseABCTimers()
        hairlineLayer.removeAnimation(forKey: Self.progressAnimKey)

        // Re-entry: a previous performCompletionTail may already have
        // scheduled its fade / final-hide. Cancel so we replace with
        // this call's schedule cleanly. Without this, a second
        // completeHairline() during the first's width tail would leave
        // two fade tasks racing.
        pendingPhaseDFadeTask?.cancel()
        pendingPhaseDFadeTask = nil
        pendingPhaseDFinalHideTask?.cancel()
        pendingPhaseDFinalHideTask = nil

        // Read the presentation layer so the tail starts at the *visible*
        // width, not the model-layer value which may already be at the
        // Phase A/B ceiling.
        let fullWidth = hairlineFullWidth()
        let startFrac: CGFloat
        if let pres = hairlineLayer.presentation(), fullWidth > 0 {
            startFrac = max(0, min(1, pres.bounds.width / fullWidth))
        } else {
            startFrac = modelLayerTargetFraction
        }

        hairlinePhase = .phaseDWidth

        let widthDuration: TimeInterval
        if effectiveReduceMotion {
            // Instant width set → 1.0. No CABasicAnimation.
            currentProgressFraction = 1.0
            modelLayerTargetFraction = 1.0
            layoutHairlineLayer()
            widthDuration = 0
        } else {
            animateHairlineWidth(
                from: startFrac,
                to: 1.0,
                duration: Self.hairlineCompletionWidthDuration,
                timingFunction: CAMediaTimingFunction(name: .easeOut),
                reduceMotion: false,
                animKey: Self.widthCompletionKey
            )
            currentProgressFraction = 1.0
            modelLayerTargetFraction = 1.0
            widthDuration = Self.hairlineCompletionWidthDuration
        }

        let fadeTask = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPhaseDFadeTask = nil
            // If something cleared the hairline state under us (error
            // path, or an explicit reset), don't force a fade back on.
            guard self.hairlinePhase == .phaseDWidth else { return }
            self.beginPhaseDFade()
        }
        pendingPhaseDFadeTask = fadeTask
        if widthDuration <= 0 {
            // RM: run synchronously on the next main queue tick so the
            // DispatchWorkItem is cancellable (rather than firing
            // inline here, which would race a re-entrant completeHairline
            // that wants to cancel it).
            DispatchQueue.main.async(execute: fadeTask)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + widthDuration,
                execute: fadeTask
            )
        }
    }

    /// Phase D fade portion — alpha 1 → 0 over 150 ms. Runs *after* the
    /// width ease completes.
    ///
    /// Schedules a final-hide work item that flips `hairlineLayer.isHidden`
    /// to `true` and removes the fade animation once the 150 ms fade
    /// concludes — matching "bar completes its fill, then
    /// fades, then is firmly down" progression. Without the explicit
    /// final hide, the layer would remain visible-to-CA with opacity 0
    /// which is functionally invisible but reads as in-flight state to
    /// any future debugger / hit-test pass.
    private func beginPhaseDFade() {
        guard hairlinePhase == .phaseDWidth else { return }
        hairlinePhase = .phaseDFade

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = hairlineLayer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = Self.hairlineCompletionAlphaDuration
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        hairlineLayer.add(fade, forKey: Self.fadeOutKey)
        hairlineLayer.opacity = 0

        // Fire-and-forget cleanup after the fade completes. We set state
        // now so tests + callers observe the correct `isHairlineVisible`
        // synchronously with the fade start (matches the semantics of
        // the old sliding-segment implementation).
        //
        // Intentionally do NOT reset `currentProgressFraction` here —
        // the fade is an *alpha* change, and the bar is logically at
        // 1.0 throughout. Tests asserting after completeHairline see the
        // final logical width (1.0), not 0. A subsequent
        // `setHairlineProgress` will reset both fractions explicitly
        // via the reveal path.
        isHairlineVisible = false
        hairlineVisibleSince = nil

        setAccessibilityValue(accessibilityValueString())
        resumeAutoHide()

        // 150 ms from now, flip isHidden and clear the fade animation so
        // the layer is firmly down. The work item is cancellable so a
        // fresh nav landing mid-fade can adopt the layer cleanly (the
        // reveal path will unhide + reset opacity).
        let finalHide = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPhaseDFinalHideTask = nil
            // If a fresh nav has taken over the layer during the fade,
            // don't stomp it. The reveal path's `removeAnimation` +
            // `opacity = 1` would have run already; hairlinePhase would
            // no longer be .phaseDFade.
            guard self.hairlinePhase == .phaseDFade else { return }
            self.hairlineLayer.removeAnimation(forKey: Self.fadeOutKey)
            self.hairlineLayer.isHidden = true
            self.hairlinePhase = .idle
        }
        pendingPhaseDFinalHideTask = finalHide
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.hairlineCompletionAlphaDuration,
            execute: finalHide
        )
    }

    /// Drive an explicit `CABasicAnimation` on `bounds.size.width` for
    /// the hairline layer. Uses `CATransaction.setDisableActions(true)`
    /// so we never rely on implicit animations — it is explicit
    /// about this
    ///
    /// Does NOT take a completion block — callers that need a sequential
    /// follow-up (e.g. Phase D's width → fade handoff) schedule an
    /// explicit `DispatchWorkItem` on the main queue matching
    /// `duration`. `CATransaction.setCompletionBlock` was used here
    /// previously but proved unreliable when a second animation
    /// replaced the first by key — the first transaction's completion
    /// block could be dropped, stranding the handoff.
    /// `performCompletionTail` for the explicit-work-item pattern.
    private func animateHairlineWidth(
        from startFrac: CGFloat,
        to endFrac: CGFloat,
        duration: TimeInterval,
        timingFunction: CAMediaTimingFunction,
        reduceMotion: Bool,
        animKey: String = progressAnimKey
    ) {
        let fullWidth = hairlineFullWidth()
        let startW = fullWidth * max(0, min(1, startFrac))
        let endW = fullWidth * max(0, min(1, endFrac))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Model layer: final bounds, so the animation's end state persists
        // without a `fillMode` jump at completion.
        hairlineLayer.bounds = CGRect(
            x: 0, y: 0,
            width: endW,
            height: hairlineHeight()
        )

        if reduceMotion || duration <= 0 {
            CATransaction.commit()
            return
        }

        let anim = CABasicAnimation(keyPath: "bounds.size.width")
        anim.fromValue = startW
        anim.toValue = endW
        anim.duration = duration
        anim.timingFunction = timingFunction
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = false
        hairlineLayer.add(anim, forKey: animKey)
        CATransaction.commit()
    }

    private func cancelPhaseABCTimers() {
        pendingPhaseBTask?.cancel()
        pendingPhaseBTask = nil
        pendingPhaseCTask?.cancel()
        pendingPhaseCTask = nil
    }

    private func clearErrorState(animated: Bool) {
        guard isInErrorState else { return }
        isInErrorState = false
        pendingErrorRevertTask?.cancel()
        pendingErrorRevertTask = nil

        renderLabel()

        if isHairlineVisible {
            if animated {
                performCompletionTail()
            } else {
                pendingPhaseDFadeTask?.cancel()
                pendingPhaseDFadeTask = nil
                pendingPhaseDFinalHideTask?.cancel()
                pendingPhaseDFinalHideTask = nil
                isHairlineVisible = false
                hairlineVisibleSince = nil
                hairlinePhase = .idle
                currentProgressFraction = 0
                modelLayerTargetFraction = 0
                hairlineLayer.removeAllAnimations()
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                hairlineLayer.opacity = 0
                hairlineLayer.isHidden = true
                CATransaction.commit()
                layoutHairlineLayer()
                resumeAutoHide()
            }
        } else {
            resumeAutoHide()
        }

        updateHairlineAppearance()
        setAccessibilityValue(accessibilityValueString())
    }

    // MARK: - Auto-hide interaction

    private func pauseAutoHide() {
        guard autoHides else { return }
        if fadeOutWorkItem != nil {
            fadeOutWorkItem?.cancel()
            fadeOutWorkItem = nil
            pausedAutoHideSavedToken = true
        } else {
            pausedAutoHideSavedToken = true
        }
    }

    private func resumeAutoHide() {
        guard autoHides else { return }
        guard pausedAutoHideSavedToken else { return }
        pausedAutoHideSavedToken = false
        guard !isHidden && alphaValue > 0 else { return }
        scheduleFadeOut()
    }

    // MARK: - Accessibility

    /// Marks drawn after the text.
    var marks = PillMarks() {
        didSet {
            guard marks != oldValue, !isInErrorState else { return }
            renderLabel()
        }
    }

    /// How long a mark change keeps an auto-hidden pill on screen.
    static let marksFlashDuration: TimeInterval = 1.5

    /// Text plus marks; white on the HUD.
    private func renderLabel() {
        label.attributedStringValue = PillMarks.baseText(baseLabelText)
        marksLabel.attributedStringValue = PillMarks.marksText(marks)
        marksLabel.isHidden = marks.isEmpty
        setAccessibilityValue(accessibilityValueString())
    }

    /// The pointer moved over the canvas of a window (spec 24 §5.1): an
    /// auto-hiding pill shows and fades again after 2.0 s without movement.
    /// Nothing before the first photo, while the capsule holds the pill
    /// (full screen) or while the load hairline is up.
    func pointerMoved() {
        guard autoHides, !isHeldByCapsule, !isHairlineVisible, !baseLabelText.isEmpty else { return }
        if isHidden { isHidden = false; alphaValue = 0 }
        if alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil
        scheduleFadeOut()
    }

    /// A rating / flag changed: show the pill for 1.5 s if it auto-hides.
    func flashMarks() {
        guard autoHides, !isHairlineVisible else { return }
        fadeOutWorkItem?.cancel()
        fadeOutWorkItem = nil
        if isHidden || alphaValue < 1 {
            if isHidden { isHidden = false; alphaValue = 0 }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                animator().alphaValue = 1
            }
        }
        scheduleFadeOut(after: Self.marksFlashDuration)
    }

    private func accessibilityValueString() -> String {
        let base = (baseLabelText.isEmpty ? label.stringValue : baseLabelText) + marks.accessibilitySuffix
        if isHairlineVisible || isInErrorState {
            return base + ", loading"
        }
        return base
    }

    /// Arm a 500 ms deferred VO announcement (`"Loading image"`) that
    /// fires only if the hairline is *still* visible at the 500 ms mark
    /// and the 2 s per-window throttle hasn't locked us out.
    ///
    /// Gating:
    ///   * **VO off → zero cost.** If neither VoiceOver nor a test
    ///     override is active, we bail before scheduling the work item
    ///     so non-VO users don't pay a 500 ms timer per nav.
    ///   * **Already pending.** Re-entrant reveal (rapid nav) won't
    ///     stack a second work item on top of the first.
    ///   * **Throttle lock.** At fire time we compare `now` against
    ///     `lastAnnouncementEpoch` using the injectable `voiceOverClock`
    ///     so tests can fast-forward deterministically.
    ///
    /// Cancellation: `completeHairline`, `flashError`, the error
    /// revert tail, and the Phase D fade all cancel via
    /// `cancelPendingVoiceOverAnnouncement()` — a deferred paint must
    /// not announce "Loading image" after the image is already on screen.
    private func considerAnnouncingToVoiceOver() {
        // Zero-cost gate for the common case. No timer armed, no
        // capture of `self`, no work queued when VO is off. This is
        // the critical "non-VO users pay zero cost" path
        guard isVoiceOverActive else { return }

        // Re-reveal (rapid nav or predictor refine) resets
        // `hairlineVisibleSince`, so an in-flight task scheduled against
        // the *previous* reveal's clock would bail at fire time. Cancel
        // + re-arm from the current `hairlineVisibleSince` so the
        // announcement lands 500 ms after the current reveal, not
        // hauntingly early.
        pendingVoiceOverAnnouncementTask?.cancel()

        let threshold = Self.voAnnounceThreshold
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingVoiceOverAnnouncementTask = nil
            self.fireVoiceOverAnnouncementIfPermitted()
        }
        pendingVoiceOverAnnouncementTask = task
        DispatchQueue.main.asyncAfter(
            deadline: .now() + threshold,
            execute: task
        )
    }

    /// Visibility + throttle gate — factored so tests can drive it
    /// synchronously via `fireVoiceOverAnnouncementForTesting()` without
    /// waiting on a `DispatchQueue.main.asyncAfter`.
    private func fireVoiceOverAnnouncementIfPermitted() {
        guard isVoiceOverActive else { return }
        guard isHairlineVisible else { return }
        guard let since = hairlineVisibleSince else { return }
        let now = Date()
        // Elapsed-since-show guard: if the hairline was briefly hidden
        // and re-shown inside the 500 ms window the visible-since
        // clock was reset, so the new epoch is < 500 ms. Skip — the
        // throttle handles the "already announced" half, this handles
        // the "just-became-visible" half.
        guard now.timeIntervalSince(since) >= Self.voAnnounceThreshold else {
            return
        }
        if let last = lastAnnouncementEpoch,
           now.timeIntervalSince(last) < Self.voAnnounceThrottle {
            return
        }
        lastAnnouncementEpoch = now
        let message = NSLocalizedString(
            "Loading image",
            comment: "VoiceOver announcement for viewer loading hairline"
        )
        voiceOverAnnouncer(message)
    }

    /// Cancel any in-flight 500 ms timer. Called whenever the hairline
    /// stops being visible — completeHairline, flashError, error
    /// revert, Phase D fade — so a deferred announcement doesn't fire
    /// after the image has already painted.
    private func cancelPendingVoiceOverAnnouncement() {
        pendingVoiceOverAnnouncementTask?.cancel()
        pendingVoiceOverAnnouncementTask = nil
    }

    // MARK: - VO testing hooks

    /// Drain the 500 ms deferred announcement task synchronously. Mirrors
    /// what the runloop would do 500 ms after the hairline reveal.
    internal func fireVoiceOverAnnouncementForTesting() {
        guard let task = pendingVoiceOverAnnouncementTask else {
            // No task pending — run the gate directly so tests can drive
            // the post-throttle-elapsed path without re-scheduling.
            fireVoiceOverAnnouncementIfPermitted()
            return
        }
        task.cancel()
        pendingVoiceOverAnnouncementTask = nil
        fireVoiceOverAnnouncementIfPermitted()
    }

    // MARK: - Held open by the capsule (spec 24 §1.2)

    /// The full-screen capsule shows: the pill shows with it and hides
    /// with it. While held, no idle fade is scheduled.
    private(set) var isHeldByCapsule = false

    func setHeldByCapsule(_ held: Bool) {
        guard held != isHeldByCapsule else { return }
        isHeldByCapsule = held
        if held {
            fadeOutWorkItem?.cancel()
            fadeOutWorkItem = nil
            // Nothing to show before the first photo.
            guard !baseLabelText.isEmpty else { return }
            if isHidden { isHidden = false; alphaValue = 0 }
            if alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = Self.fadeInDuration
                    animator().alphaValue = 1
                }
            }
        } else if autoHides, !isHairlineVisible, !isHidden {
            fadeOutNow()
        }
    }

    // MARK: - Private pill fade helpers

    private func scheduleFadeOut(after delay: TimeInterval = idleTimeout) {
        // Held by the capsule: it hides with the capsule, not on a timer.
        guard !isHeldByCapsule else { return }
        let item = DispatchWorkItem { [weak self] in
            self?.runFadeOut()
        }
        fadeOutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: item
        )
    }

    private func runFadeOut() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOutDuration
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.alphaValue == 0 { self.isHidden = true }
            }
        })
    }
}

// MARK: - Pair chip button

/// Spec 24 §4.3: the pill's one clickable part. Transparent over the chip;
/// on hover a white 10 % platter (radius 6) and the pointing hand.
@MainActor
final class PillChipButton: NSButton {

    static let platterAlpha: CGFloat = 0.10
    static let platterRadius: CGFloat = 6

    private let platter = CALayer()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        isTransparent = true
        wantsLayer = true
        platter.cornerRadius = Self.platterRadius
        platter.backgroundColor = NSColor.white.withAlphaComponent(Self.platterAlpha).cgColor
        platter.opacity = 0
        layer?.insertSublayer(platter, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        platter.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override var isHidden: Bool {
        didSet { if isHidden { setHovered(false) } }
    }

    func setHovered(_ on: Bool) {
        guard on != isHovered else { return }
        isHovered = on
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        platter.opacity = on ? 1 : 0
        CATransaction.commit()
    }

    /// The platter's white alpha as drawn: 0.10 hovered, else 0.
    var platterAlphaForTesting: CGFloat { platter.opacity > 0 ? Self.platterAlpha : 0 }
}

// MARK: - Pill marks

/// What the position pill draws after "43 / 180 — name": stars, flag,
/// tag dots, RAW chip, pencil. Only set values are drawn.
public struct PillMarks: Equatable, Sendable {
    public var rating: Int
    public var flagged: Bool
    public var hasRAW: Bool
    public var tags: [FinderTag]
    /// Has a backup chain: "edited, original kept".
    public var edited: Bool
    /// A pair (primary + RAW companion): the primary's kind for the chip's
    /// left part ("JPG"); nil for a single file.
    public var pairKind: String?
    /// The RAW file is the one on screen (the chip's right part is lit).
    public var rawShown: Bool

    public init(rating: Int = 0, flagged: Bool = false, hasRAW: Bool = false,
                tags: [FinderTag] = [], edited: Bool = false,
                pairKind: String? = nil, rawShown: Bool = false) {
        self.rating = rating
        self.flagged = flagged
        self.hasRAW = hasRAW
        self.tags = tags
        self.edited = edited
        self.pairKind = pairKind
        self.rawShown = rawShown
    }

    public init(_ badges: ItemBadges) {
        self.init(rating: badges.rating, flagged: badges.flagged, hasRAW: badges.hasRAW,
                  tags: badges.tags, edited: badges.edited)
    }

    static var ratingColor: NSColor { Badges.ratingColor }
    static var flagColor: NSColor { Badges.flagColor }

    /// ", 3 stars, flagged, tags: Red, Client, with RAW file, edited,
    /// original kept" for the pill's VoiceOver value.
    public var accessibilitySuffix: String {
        var parts: [String] = []
        if rating > 0 { parts.append(rating == 1 ? "1 star" : "\(rating) stars") }
        if flagged { parts.append("flagged") }
        if !tags.isEmpty { parts.append("tags: " + Badges.tagSpeech(tags)) }
        if hasRAW { parts.append("with RAW file") }
        if edited { parts.append("edited, original kept") }
        return parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
    }

    var isEmpty: Bool { rating <= 0 && !flagged && !hasRAW && tags.isEmpty && !edited }

    /// Base text followed by the marks (one string; tests and VoiceOver).
    @MainActor
    static func attributedText(base: String, marks: PillMarks) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: baseText(base))
        out.append(marksText(marks))
        return out
    }

    /// Between the counter and the name in the plain text (VoiceOver,
    /// error state); `baseText` draws it as a secondary "·".
    static let nameSeparator = " \u{00B7} "
    /// Counter 12 pt medium, monospaced digits.
    @MainActor static var counterFont: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
    /// Name 12 pt regular.
    @MainActor static var nameFont: NSFont { .systemFont(ofSize: 12, weight: .regular) }
    /// The space on each side of the "·".
    static let separatorGap: CGFloat = 6

    /// "43 / 180 · DSC_0042.jpg": the
    /// counter in 12 pt medium with monospaced digits, a secondary "·"
    /// with 6 pt on each side, the name in 12 pt regular; white on the
    /// HUD, middle truncation.
    @MainActor
    static func baseText(_ base: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let primary: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white, .paragraphStyle: paragraph,
        ]
        guard let split = base.range(of: nameSeparator) else {
            var attrs = primary
            attrs[.font] = counterFont
            return NSAttributedString(string: base, attributes: attrs)
        }
        let out = NSMutableAttributedString()
        var counter = primary
        counter[.font] = counterFont
        out.append(NSAttributedString(string: String(base[..<split.lowerBound]), attributes: counter))
        // Kern after the counter's last glyph and after the dot = the gaps.
        out.addAttribute(.kern, value: separatorGap, range: NSRange(location: out.length - 1, length: 1))
        var dot = primary
        dot[.font] = nameFont
        dot[.foregroundColor] = secondaryOnHUD
        dot[.kern] = separatorGap
        out.append(NSAttributedString(string: "\u{00B7}", attributes: dot))
        var name = primary
        name[.font] = nameFont
        out.append(NSAttributedString(string: String(base[split.upperBound...]), attributes: name))
        return out
    }

    /// `secondaryLabelColor` on the dark HUD.
    @MainActor static var secondaryOnHUD: NSColor { NSColor.white.withAlphaComponent(0.55) }

    /// Marks the pair chip's attachment in the marks text.
    static let pairChipKey = NSAttributedString.Key("shrike.pairChip")

    /// Where the pair chip sits inside the marks text: its x offset from the
    /// text start and its width; nil without a pair.
    @MainActor
    static func pairChipMetrics(_ marks: PillMarks) -> (offset: CGFloat, width: CGFloat)? {
        guard marks.pairKind != nil else { return nil }
        let text = marksText(marks)
        var found: NSRange?
        text.enumerateAttribute(pairChipKey, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if value != nil { found = range; stop.pointee = true }
        }
        guard let range = found else { return nil }
        let before = text.attributedSubstring(from: NSRange(location: 0, length: range.location)).size().width
        let width = text.attributedSubstring(from: range).size().width
        return (before, width)
    }

    /// The marks alone, each after an 8 pt gap. Empty when nothing is
    /// set. Drawn in their own label so the file name truncates first.
    @MainActor
    static func marksText(_ marks: PillMarks) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let gap = NSAttributedString(string: "  ", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .kern: 1.0,
        ])
        // Marks sit on the 12 pt text's cap-height centre line.
        let capMid = nameFont.capHeight / 2
        let secondary = secondaryOnHUD
        if marks.rating > 0 {
            out.append(gap)
            out.append(NSAttributedString(string: Badges.stars(marks.rating), attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: Badges.ratingColor, .kern: 1.0,
            ]))
        }
        if marks.flagged, let image = Badges.symbol("flag.fill", pointSize: 10, color: Badges.flagColor) {
            out.append(gap)
            out.append(attachment(image, centredOn: capMid))
        }
        let dots = Badges.dotColors(marks.tags).map { Badges.dotFill($0) }
        if let image = Badges.tagDotsImage(dots) {
            out.append(gap)
            out.append(attachment(image, centredOn: capMid))
        }
        if let kind = marks.pairKind {
            // Spec 24 §4.3: [JPG | RAW], the file on screen lit.
            out.append(gap)
            let chip = NSMutableAttributedString(attributedString: attachment(
                Badges.pairChipImage(kind: kind, rawShown: marks.rawShown), centredOn: capMid))
            chip.addAttribute(pairChipKey, value: true, range: NSRange(location: 0, length: chip.length))
            out.append(chip)
        } else if marks.hasRAW {
            out.append(gap)
            out.append(attachment(Badges.rawChipImage(fontSize: 9, color: secondary), centredOn: capMid))
        }
        if marks.edited, let image = Badges.symbol("pencil", pointSize: 10, color: secondary) {
            out.append(gap)
            out.append(attachment(image, centredOn: capMid))
        }
        return out
    }

    @MainActor
    private static func attachment(_ image: NSImage, centredOn mid: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = image.size
        attachment.bounds = CGRect(x: 0, y: (mid - size.height / 2).rounded(),
                                   width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }
}

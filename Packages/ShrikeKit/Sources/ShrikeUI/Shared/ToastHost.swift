//
//  ToastHost.swift
//  ShrikeUI
//
//  The one toast used by the viewer, the browser, compare and slideshow
//
//  * Geometry: height 32 pt, width hugs the text (160–480 pt), 12 pt side
//    padding, 8 pt between text and button, corner radius 8 pt.
//  * Durations: 1.2 s glyph-only, 2.5 s text, 4 s with an action button.
//    The timer pauses while the pointer is over the toast.
//  * A new toast replaces the current one at once (no stacking).
//  * Fade in 120 ms, fade out 200 ms. Fades are opacity-only, so Reduce
//    Motion needs no separate path.
//  * VoiceOver: every toast is announced (`.high` for errors, `.medium`
//    otherwise). The button is reachable with VoiceOver but is not in the
//    key loop — the image keeps focus.
//  * Hidden means gone: a hidden toast leaves the accessibility tree.
//

import AppKit
import ShrikeCore

/// What a toast says and how long it stays.
public struct ToastContent: Equatable, Sendable {

    public enum Kind: Sendable, Equatable {
        /// A glyph or a very short flash (e.g. a rating mark). 1.2 s.
        case glyph
        /// Plain text. 2.5 s.
        case text
        /// A failure ("Couldn't …"). 2.5 s, announced with high priority.
        case error
    }

    public var message: String
    public var kind: Kind
    /// Title of the single action button ("Undo", "Show", "Revert").
    public var actionTitle: String?
    /// 0…1 while a file operation runs: a 160 × 4 pt bar
    /// under the text, toast height 44 pt, no auto-dismiss.
    public var progress: Double?
    /// Replaces the default duration (the Trash toast stays 6 s).
    public var customDuration: TimeInterval?
    /// VoiceOver label and tooltip of the action button, when they differ
    /// from its title and the message.
    public var actionAccessibilityLabel: String?
    public var actionTooltip: String?

    /// "Moved … to the Trash." with Undo: 6 s, "Undo  ·  ⌘Z" tooltip (spec 25 §5.1).
    public static func trashed(_ message: String) -> ToastContent {
        var content = ToastContent(message, actionTitle: "Undo")
        content.customDuration = 6.0
        content.actionAccessibilityLabel = "Undo move to Trash"
        content.actionTooltip = "Undo  ·  ⌘Z"
        return content
    }

    public init(_ message: String, kind: Kind = .text, actionTitle: String? = nil) {
        self.message = message
        self.kind = kind
        self.actionTitle = actionTitle
    }

    ///
    public var duration: TimeInterval {
        if let customDuration { return customDuration }
        if actionTitle != nil { return 4.0 }
        return kind == .glyph ? 1.2 : 2.5
    }

    public var announcementPriority: NSAccessibilityPriorityLevel {
        kind == .error ? .high : .medium
    }
}

/// Where the host sits in its container.
public enum ToastPlacement: Sendable {
    /// Viewer: top-centre, `max(120, safeAreaInsets.top + 48)` below the top.
    case viewer
    /// Browser: top-centre of the content area, as the viewer:
    /// clears the title bar and the full-screen menu-bar reveal.
    case browser

    /// Distance from the container's top edge.
    public func topOffset(safeAreaTop: CGFloat) -> CGFloat {
        switch self {
        case .viewer, .browser: return max(120, safeAreaTop + 48)
        }
    }
}

/// The toast's action. Its hit area is the full pill height and at least
/// `minWidth` wide, from the label's gap to the pill's trailing edge; the
/// title is drawn right-aligned with a 12 pt trailing inset (spec 27 B2).
@MainActor
final class ToastActionButton: NSButton {
    static let minWidth: CGFloat = 44
    static let trailingInset: CGFloat = 12
    /// Called when a real mouse press starts on the button.
    var onPress: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold),
         .foregroundColor: contentTintColor ?? ShrikeAccent.mark]
    }

    override var intrinsicContentSize: NSSize {
        let text = (title as NSString).size(withAttributes: titleAttributes)
        return NSSize(width: max(Self.minWidth, ceil(text.width) + Self.trailingInset),
                      height: NSView.noIntrinsicMetric)
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let text = title as NSString
        var attributes = titleAttributes
        if isHighlighted, let tint = contentTintColor {
            attributes[.foregroundColor] = tint.withAlphaComponent(0.6)
        }
        let size = text.size(withAttributes: attributes)
        let origin = NSPoint(x: bounds.maxX - Self.trailingInset - size.width,
                             y: bounds.midY - size.height / 2)
        text.draw(at: origin, withAttributes: attributes)
    }
}

@MainActor
public final class ToastHostView: HUDSurfaceView {

    public static let height: CGFloat = 32
    public static let progressHeight: CGFloat = 44
    public static let minWidth: CGFloat = 160
    public static let maxWidth: CGFloat = 480
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.20
    /// Spec 27 N6: black 0.82 fill, 0.5 pt white 0.16 hairline, a tight shadow.
    static let pillStyle = SurfaceStyle(
        fill: NSColor.black.withAlphaComponent(0.82),
        hairline: NSColor.white.withAlphaComponent(0.16),
        hairlineWidth: 0.5,
        shadowOpacity: 0.25,
        shadowRadius: 3,
        shadowOffset: CGSize(width: 0, height: -1)
    )

    public let placement: ToastPlacement
    public private(set) var content: ToastContent?
    public var isShowing: Bool { content != nil }

    /// Test seam: VoiceOver announcements go through here.
    var announce: (String, NSAccessibilityPriorityLevel) -> Void = { text, priority in
        let target: Any = NSApp.mainWindow ?? NSApp as Any
        NSAccessibility.post(
            element: target,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: priority.rawValue,
            ]
        )
    }

    private let label = NSTextField(labelWithString: "")
    private let button = ToastActionButton(title: "", target: nil, action: nil)
    private var action: (@MainActor () -> Void)?
    private var topConstraint: NSLayoutConstraint?
    private var buttonGap: NSLayoutConstraint?
    private var buttonCollapsed: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var labelCenterY: NSLayoutConstraint?
    private let progressBar = NSProgressIndicator()

    // Timer that can pause on hover.
    private var remaining: TimeInterval = 0
    private var timerStarted: Date?
    private var dismissWork: DispatchWorkItem?
    private(set) var isPaused = false
    private var tracking: NSTrackingArea?
    /// Bumped by every `show`; a press that began on an older toast does not run the new one's action.
    private var showGeneration = 0
    private var pressGeneration: Int?
    /// The zoom HUD (or any view) the toast keeps below while it is visible.
    private weak var avoided: NSView?
    private var avoidGap: CGFloat = 12
    private var avoidConstraint: NSLayoutConstraint?
    /// Test seam: where the pointer is, in window coordinates.
    var pointerInWindowForTesting: NSPoint?

    public init(placement: ToastPlacement) {
        self.placement = placement
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule   // full-screen viewer only
        // Spec 27 N6: a flat pill, no wide soft halo.
        surfaceStyle = Self.pillStyle
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        // Accent text on the dark pill, lightened for 4.5:1.
        button.contentTintColor = ShrikeAccent.mark
        button.refusesFirstResponder = true
        button.onPress = { [weak self] in
            guard let self else { return }
            self.pressGeneration = self.showGeneration
        }
        button.target = self
        button.action = #selector(performToastAction(_:))
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.controlSize = .small
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        let gap = button.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8)
        let collapsed = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        buttonGap = gap
        buttonCollapsed = collapsed
        let height = heightAnchor.constraint(equalToConstant: Self.height)
        let centerY = label.centerYAnchor.constraint(equalTo: centerYAnchor)
        heightConstraint = height
        labelCenterY = centerY
        NSLayoutConstraint.activate([
            height,
            widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minWidth),
            widthAnchor.constraint(lessThanOrEqualToConstant: Self.maxWidth),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            centerY,
            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            progressBar.widthAnchor.constraint(equalToConstant: 160),
            progressBar.heightAnchor.constraint(equalToConstant: 4),
            progressBar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            collapsed,
        ])

        alphaValue = 0
        isHidden = true
        setAccessibilityElement(false)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Adds the host to `container`, centred at the top per `placement`.
    public func install(in container: NSView) {
        container.addSubview(self)
        let top = topAnchor.constraint(equalTo: container.topAnchor,
                                       constant: placement.topOffset(safeAreaTop: 0))
        // Below required, so a `keepBelow` rule can push the toast down.
        top.priority = .defaultHigh
        topConstraint = top
        NSLayoutConstraint.activate([
            centerXAnchor.constraint(equalTo: container.centerXAnchor),
            top,
        ])
    }

    /// The toast never sits on `other` (e.g. the viewer's zoom HUD at the
    /// top centre): its top stays at least `gap` below `other`'s bottom.
    /// Both views must share a superview, and `install(in:)` must have run.
    public func keepBelow(_ other: NSView, gap: CGFloat = 12) {
        avoided = other
        avoidGap = gap
        avoidConstraint = topAnchor.constraint(greaterThanOrEqualTo: other.bottomAnchor, constant: gap)
        avoidConstraint?.isActive = false
        applyAvoidance()
    }

    /// The rule holds only while the other view is on screen (spec 27 B2):
    /// a hidden or faded zoom HUD must not move the toast between two shows.
    /// The other view's show / hide calls this. While a toast is on screen the
    /// change waits for the toast's end (or the next `show`): a toast that
    /// slides under a resting pointer is the miss this spec fixes (B2 item 5),
    /// and that outweighs a HUD pulse (about 1 s) touching the toast.
    func refreshAvoidance() {
        if isShowing { return }
        applyAvoidance()
    }

    private func applyAvoidance() {
        guard let other = avoided, let constraint = avoidConstraint else { return }
        let visible = !other.isHidden && other.alphaValue > 0
        if constraint.isActive != visible { constraint.isActive = visible }
    }

    var avoidanceActiveForTesting: Bool { avoidConstraint?.isActive ?? false }

    // MARK: - Show / dismiss

    /// Shows `content`, replacing whatever toast is on screen.
    public func show(_ content: ToastContent, action: (@MainActor () -> Void)? = nil) {
        cancelTimer()
        showGeneration &+= 1
        if !isShowing { applyAvoidance() }
        // A progress update of the same toast is not spoken again.
        let continuing = self.content?.progress != nil && content.progress != nil
        self.content = content
        self.action = content.actionTitle == nil ? nil : action

        label.stringValue = content.message
        label.toolTip = content.message
        if let title = content.actionTitle {
            button.title = title
            button.isHidden = false
            button.setAccessibilityLabel(content.actionAccessibilityLabel ?? title)
            button.toolTip = content.actionTooltip ?? content.message
            buttonCollapsed?.isActive = false
            buttonGap?.isActive = true
        } else {
            button.isHidden = true
            buttonGap?.isActive = false
            buttonCollapsed?.isActive = true
        }

        if let progress = content.progress {
            progressBar.doubleValue = progress
            progressBar.isHidden = false
            heightConstraint?.constant = Self.progressHeight
            labelCenterY?.constant = -6
        } else {
            progressBar.isHidden = true
            heightConstraint?.constant = Self.height
            labelCenterY?.constant = 0
        }

        if let superview {
            topConstraint?.constant = placement.topOffset(safeAreaTop: superview.safeAreaInsets.top)
        }

        isHidden = false
        setAccessibilityElement(true)
        setAccessibilityLabel(content.message)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.fadeIn
            animator().alphaValue = 1
        }
        if !continuing {
            announce(content.message, content.announcementPriority)
        }

        remaining = content.duration
        isPaused = false
        if content.progress == nil { startTimer() }
        // `mouseEntered` is not sent for a pointer that already rests inside
        // the new toast, so the 6 s clock would run under the Undo button.
        superview?.layoutSubtreeIfNeeded()
        if pointerIsInside { pauseTimer() }
    }

    private var pointerIsInside: Bool {
        guard let window else { return false }
        let inWindow = pointerInWindowForTesting ?? window.mouseLocationOutsideOfEventStream
        return bounds.contains(convert(inWindow, from: nil))
    }

    /// Convenience for plain text.
    public func show(_ message: String) {
        show(ToastContent(message))
    }

    public func dismiss(animated: Bool = true) {
        cancelTimer()
        content = nil
        action = nil
        setAccessibilityElement(false)
        applyAvoidance()
        guard animated else {
            alphaValue = 0
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.fadeOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.content == nil else { return }
                self.isHidden = true
            }
        })
    }

    /// Runs the toast's action (the Undo button, or ⌘Z's twin) and hides it.
    @objc func performToastAction(_ sender: Any?) {
        // A press that began on an earlier toast must not run this one's action.
        if let started = pressGeneration, started != showGeneration {
            pressGeneration = nil
            return
        }
        pressGeneration = nil
        let run = action
        // Not user visible: tells "hit but not run" from "not hit" in Instruments.
        ShrikeSignposts.browser.event("toast.undo", run == nil ? "no action" : "run")
        dismiss()
        run?()
    }

    /// Test seam: the press that began on toast `generation`.
    func beginPressForTesting() { pressGeneration = showGeneration }

    /// Test seam: the action button.
    var actionButtonForTesting: NSButton { button }
    var labelForTesting: NSTextField { label }

    /// Test seam: the button's title when visible.
    var actionTitleForTesting: String? { button.isHidden ? nil : button.title }

    // MARK: - Timer

    private func startTimer() {
        timerStarted = Date()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func cancelTimer() {
        dismissWork?.cancel()
        dismissWork = nil
        timerStarted = nil
    }

    /// Pointer over the toast: stop the clock.
    func pauseTimer() {
        guard isShowing, !isPaused, let started = timerStarted else { return }
        remaining = max(0.5, remaining - Date().timeIntervalSince(started))
        cancelTimer()
        isPaused = true
    }

    /// Pointer left: continue with the time that was left.
    func resumeTimer() {
        guard isShowing, isPaused else { return }
        isPaused = false
        startTimer()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect, .assumeInside],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    public override func mouseEntered(with event: NSEvent) { pauseTimer() }
    public override func mouseExited(with event: NSEvent) { resumeTimer() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Clicks on the toast body must not fall through to the canvas.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        isShowing ? super.hitTest(point) : nil
    }
}

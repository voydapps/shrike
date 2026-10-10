//
//  PreviewBadgeView.swift
//  ShrikeUI
//
//  Bottom-right "PREVIEW" pill that surfaces in the viewer canvas while the
//  1024 px thumbnail bridge is on screen in place of the full-res image.
//  Without this indicator, a user staring at a sharp-enough thumb on a
//  Retina display has no way to tell whether the pixels they're looking at
//  are the real thing — user feedback during dogfooding confirmed exactly
//  that confusion.
//
//  Behaviour (phase-driven, NOT time-driven):
//    * `show()` fires the same frame the thumb bridge paints — no fade-in;
//      the badge must be visible at the moment the placeholder lands so the
//      user never perceives a window where the thumb is on screen without
//      the label.
//    * `hide()` fades out over 120 ms when full-res commits, replacing
//      the thumb with the real image.
//    * Always visible in `NavigationFeedbackPhase.showingThumb`, hidden in
//      every other phase. It does NOT respect the position-overlay
//      auto-hide preference — the badge is a correctness cue, not a
//      comfort one.
//
//  Look:
//    * 16 pt inset from the bottom-right corner of the canvas; the position
//      overlay lives bottom-left so the two do not collide in tight
//      windows.
//    * Pill: 6 pt corner radius, 8 pt horizontal padding, 4 pt vertical
//      padding, `NSColor.systemOrange.withAlphaComponent(0.85)` fill.
//    * Label: "PREVIEW" uppercase, SF Pro Rounded Semibold 11 pt, +0.5 pt
//      tracking, black for contrast against amber.
//

import AppKit

@MainActor
final class PreviewBadgeView: NSView {

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

    static let fadeOutDuration: TimeInterval = 0.12

    /// Horizontal padding between the text and the pill edge.
    private static let horizontalPadding: CGFloat = 8
    /// Vertical padding between the text and the pill edge.
    private static let verticalPadding: CGFloat = 4

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(0.85)
            .cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        // SF Pro Rounded Semibold 11 pt for a slightly softer feel than the
        // default system font; the rounded variant reads as "label / tag"
        // rather than "control text". +0.5 pt tracking pushes the letters
        // apart just enough to keep the uppercase from looking cramped.
        let baseFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let roundedDescriptor = baseFont.fontDescriptor.withDesign(.rounded)
        let font = roundedDescriptor.map { NSFont(descriptor: $0, size: 11) ?? baseFont } ?? baseFont

        let attributed = NSAttributedString(
            string: "PREVIEW",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .kern: NSNumber(value: 0.5),
            ]
        )
        label.attributedStringValue = attributed
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: Self.horizontalPadding
            ),
            label.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -Self.horizontalPadding
            ),
            label.topAnchor.constraint(
                equalTo: topAnchor,
                constant: Self.verticalPadding
            ),
            label.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -Self.verticalPadding
            ),
        ])

        alphaValue = 0
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Surface the badge immediately — no fade-in. The thumb paint and the
    /// badge should land on the same frame so the user never sees a
    /// placeholder-without-label state. Idempotent.
    func show() {
        // Cancel any in-flight fade-out so a fresh thumb paint that arrives
        // during the tail of a previous hide() snaps back to fully opaque
        // instead of continuing the fade.
        layer?.removeAllAnimations()

        isHidden = false
        alphaValue = 1
    }

    /// Fade out over 120 ms. Idempotent — subsequent calls while already
    /// fading are a no-op.
    func hide() {
        guard !isHidden, alphaValue > 0 else {
            isHidden = true
            alphaValue = 0
            return
        }
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

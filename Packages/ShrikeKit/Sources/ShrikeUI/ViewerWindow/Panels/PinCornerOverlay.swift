//
//  PinCornerOverlay.swift
//  ShrikeUI
//
//  Shared corner-pin glyph used by all four chrome panels (filmstrip,
//  toolbar, inspector). It replaces a per-panel 20 pt pin
//  strip.
//
//  Look and behaviour:
//   * 28×28 pt hit area, SF Symbol at 13 pt.
//   * Symbol: `pin` (not pinned) / `pin.fill` (pinned).
//   * Tint: `secondaryLabelColor` (not pinned) / `controlAccentColor` (pinned),
//     resolved in the HUD's dark appearance in full screen.
//   * Hover platter: rounded rect, radius 6, 24×24, drawn in
//     `updateLayer` so it follows appearance changes.
//   * Tooltip: "Pin Filmstrip" / "Unpin Filmstrip" (per panel).
//   * VoiceOver: button, label "Pin Filmstrip", value "Pinned" /
//     "Not pinned".
//
//  Pins exist only in full screen. Each panel places the glyph in its
//  own slot (filmstrip trailing slot, inspector header).
//

import AppKit

@MainActor
protocol PinCornerOverlayDelegate: AnyObject {
    func pinCornerOverlayDidToggle(_ overlay: PinCornerOverlay)
}

@MainActor
final class PinCornerOverlay: NSView {

    enum Appearance {
        case windowed
        case fullscreenHUD
    }

    weak var delegate: (any PinCornerOverlayDelegate)?

    private(set) var isPinned: Bool = false
    /// Our own appearance enum — named with a prefix to avoid shadowing
    /// `NSView.appearance: NSAppearance?` (Swift 6 strict refuses the
    /// type-mismatched override even for a stored property).
    private(set) var shrikeAppearance: Appearance

    private let imageView = NSImageView()
    private let hoverBackground = NSView()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false

    /// Accessibility identifier root — each panel passes its own suffix
    /// (e.g. "filmstrip" → `pinCorner.filmstrip`) so UI tests can locate
    /// the glyph by panel.
    private let identifierSuffix: String
    /// The panel's name in the label and tooltip ("Filmstrip").
    private let panelName: String

    /// Hit area.
    static let hitSize: CGFloat = 28

    init(identifierSuffix: String, panelName: String = "Panel", appearance: Appearance = .fullscreenHUD) {
        self.identifierSuffix = identifierSuffix
        self.panelName = panelName
        self.shrikeAppearance = appearance
        super.init(frame: NSRect(x: 0, y: 0, width: Self.hitSize, height: Self.hitSize))
        wantsLayer = true
        colorObserver = LiveColorObserver(view: self)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("pinCorner.\(identifierSuffix)")
        setAccessibilityRole(.button)
        setAccessibilityLabel("Pin \(panelName)")
        setAccessibilityValue("Not pinned")
        toolTip = "Pin \(panelName)"

        // Hover platter — 24×24 rounded rect, centred on the 28×28 hit
        // area. Starts invisible.
        hoverBackground.wantsLayer = true
        // Hover platter: radius 8, the full hit area.
        hoverBackground.layer?.cornerRadius = HUDButton.platterRadius
        hoverBackground.layer?.opacity = 0
        hoverBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hoverBackground)
        NSLayoutConstraint.activate([
            hoverBackground.centerXAnchor.constraint(equalTo: centerXAnchor),
            hoverBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            hoverBackground.widthAnchor.constraint(equalToConstant: Self.hitSize),
            hoverBackground.heightAnchor.constraint(equalToConstant: Self.hitSize),
        ])

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 13, weight: .regular
        )
        imageView.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])

        applyShrikeAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.hitSize, height: Self.hitSize) }

    /// Flip pinned state + update the glyph. Does NOT fire the delegate —
    /// use this when syncing from an external source of truth.
    func setPinned(_ flag: Bool) {
        isPinned = flag
        imageView.image = NSImage(systemSymbolName: flag ? "pin.fill" : "pin", accessibilityDescription: nil)
        setAccessibilityLabel("Pin \(panelName)")
        setAccessibilityValue(flag ? "Pinned" : "Not pinned")
        toolTip = flag ? "Unpin \(panelName)" : "Pin \(panelName)"
        updateTint()
    }

    func setAppearance(_ a: Appearance) {
        shrikeAppearance = a
        applyShrikeAppearance()
    }

    private func applyShrikeAppearance() {
        // The full-screen panels are dark HUD material: resolve the
        // system colours in the dark appearance so `labelColor` reads.
        appearance = shrikeAppearance == .fullscreenHUD ? NSAppearance(named: .darkAqua) : nil
        updateTint()
        updateHoverBackground()
    }

    private func updateTint() {
        // Dynamic system colours: resolved at draw time.
        // Spec 24 §1.4: a pin must read as a pin: accent when pinned.
        imageView.contentTintColor = isPinned ? .controlAccentColor : .secondaryLabelColor
    }

    private var colorObserver: LiveColorObserver?

    override var wantsUpdateLayer: Bool { true }

    /// The platter colour resolves at draw time.
    override func updateLayer() {
        guard let layer = hoverBackground.layer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.backgroundColor = NSColor.labelColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func updateHoverBackground() {
        guard let layer = hoverBackground.layer else { return }
        needsDisplay = true
        layer.opacity = isHovered
            ? Float(isPressed ? HUDButton.pressedAlpha : HUDButton.hoverAlpha) : 0
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let opts: NSTrackingArea.Options = [
            .activeAlways, .mouseEnteredAndExited, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        animateHover(to: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        animateHover(to: false)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateHoverBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        updateHoverBackground()
        // Click-through only if the mouseUp is still inside our bounds —
        // matches NSButton's .momentaryPushIn semantics.
        let localPoint = convert(event.locationInWindow, from: nil)
        if wasPressed, bounds.contains(localPoint) {
            setPinned(!isPinned)
            delegate?.pinCornerOverlayDidToggle(self)
        }
    }

    private func animateHover(to visible: Bool) {
        guard let layer = hoverBackground.layer else { return }
        needsDisplay = true
        let targetOpacity: Float = visible ? Float(HUDButton.hoverAlpha) : 0
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = layer.opacity
        anim.toValue = targetOpacity
        anim.duration = visible ? 0.08 : 0.12
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = targetOpacity
        CATransaction.commit()
        layer.add(anim, forKey: "shrike.pinCorner.hoverFade")
    }

    override func accessibilityPerformPress() -> Bool {
        setPinned(!isPinned)
        delegate?.pinCornerOverlayDidToggle(self)
        return true
    }

    // MARK: - Test seams

    internal var isPinnedForTesting: Bool { isPinned }
    internal var appearanceForTesting: Appearance { shrikeAppearance }
    internal var identifierSuffixForTesting: String { identifierSuffix }
    internal var symbolNameForTesting: String { isPinned ? "pin.fill" : "pin" }
    internal var glyphTintForTesting: NSColor? { imageView.contentTintColor }
    internal var glyphPointSizeForTesting: CGFloat { 13 }
    internal func simulateClickForTesting() {
        setPinned(!isPinned)
        delegate?.pinCornerOverlayDidToggle(self)
    }
}

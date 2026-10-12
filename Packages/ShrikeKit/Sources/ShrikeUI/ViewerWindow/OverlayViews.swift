//
//  OverlayViews.swift
//  ShrikeUI
//
//  Small floating overlays on top of the viewer canvas: zoom badge,
//  histogram overlay, toast, error overlay, page indicator.
//

import AppKit

// MARK: - Zoom badge

@MainActor
final class ZoomBadgeView: HUDSurfaceView {

    private let label = NSTextField(labelWithString: "100 %")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule

        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// `z` is the pixel scale (1.0 = one image pixel per screen pixel).
    func setZoom(_ z: Double) {
        label.stringValue = "\(Int((z * 100).rounded())) %"
    }

    var textForTesting: String { label.stringValue }
}

// MARK: - Toast (neutral feedback)

@MainActor
final class ToastView: HUDSurfaceView {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(message: String) {
        label.stringValue = message
    }
}

// MARK: - Error overlay

@MainActor
final class ErrorOverlayView: NSView {

    static let message = "This file appears to be damaged or isn't a supported format."

    /// The wrapped height of the message at 272 pt (at most 3 lines), so the
    /// card sizes right in one layout pass.
    static let bodyHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 12, weight: .regular)
        let rect = (message as NSString).boundingRect(
            with: NSSize(width: 272, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return min(ceil(rect.height), ceil(font.boundingRectForFont.height) * 3)
    }()

    private let title = NSTextField(labelWithString: "Can't open")
    private let body = NSTextField(wrappingLabelWithString: ErrorOverlayView.message)
    let nextButton = NSButton(title: "Next", target: nil, action: nil)
    let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let container = NSView()

    /// Same action as the → key.
    var onNext: (() -> Void)?
    /// The Reveal in Finder command.
    var onReveal: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.15, alpha: 0.85).cgColor
        container.layer?.cornerRadius = 12
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                             accessibilityDescription: "Error")
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .white
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false

        // Wraps inside the 320 pt card (272 pt of text), up to 3 lines.
        body.font = .systemFont(ofSize: 12, weight: .regular)
        body.textColor = NSColor.white.withAlphaComponent(0.75)
        body.alignment = .center
        body.preferredMaxLayoutWidth = 272
        body.maximumNumberOfLines = 3
        // Word wrap: a truncating mode made AppKit draw ONE line ending in "…".
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        body.cell?.usesSingleLineMode = false
        body.setContentCompressionResistancePriority(.required, for: .vertical)
        body.translatesAutoresizingMaskIntoConstraints = false

        for button in [nextButton, revealButton] {
            button.bezelStyle = .rounded
            button.refusesFirstResponder = true   // the keys stay with the window
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        nextButton.action = #selector(nextTapped(_:))
        revealButton.action = #selector(revealTapped(_:))
        nextButton.useAccentFill()
        nextButton.keyEquivalent = ""   // a stray Return must not skip
        LiveTooltips.shared.bind(nextButton, command: .nextImage, context: .viewer)
        LiveTooltips.shared.bind(revealButton, command: .revealInFinder, context: .viewer)

        let buttons = NSStackView(views: [nextButton, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(icon)
        container.addSubview(title)
        container.addSubview(body)
        container.addSubview(buttons)

        // VoiceOver: one group with the two buttons inside.
        container.setAccessibilityElement(true)
        container.setAccessibilityRole(.group)
        container.setAccessibilityLabel("Can't open. \(Self.message)")
        container.setAccessibilityChildren([nextButton, revealButton])

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 320),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            icon.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            title.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            title.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            body.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            body.widthAnchor.constraint(equalToConstant: 272),
            body.heightAnchor.constraint(equalToConstant: Self.bodyHeight),
            buttons.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 12),
            buttons.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Only the card takes clicks; the rest of the overlay lets them through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    func setNextEnabled(_ enabled: Bool) { nextButton.isEnabled = enabled }

    /// On show: VoiceOver says what happened.
    func announce() {
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "Can't open this file.",
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func nextTapped(_ sender: Any?) { onNext?() }
    @objc private func revealTapped(_ sender: Any?) { onReveal?() }

    var cardFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return container.frame }
    var bodyLineCountForTesting: Int {
        layoutSubtreeIfNeeded()
        return Int((body.frame.height / (body.font?.boundingRectForFont.height ?? 14)).rounded())
    }
    var bodyFrameForTesting: NSRect { body.frame }
    /// Height the text needs at the card's text width (tests): two lines or more.
    var bodyNeededHeightForTesting: CGFloat {
        body.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 272, height: 10_000)).height ?? 0
    }
    var bodyForTesting: NSTextField { body }
}

// MARK: - Page indicator

@MainActor
final class PageIndicatorView: HUDSurfaceView {

    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule

        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(text: String) {
        label.stringValue = text
        alphaValue = 1
    }

    func hideAnimated() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = 0
        }
    }
}

// MARK: - Live Photo badge

/// Small "LIVE" badge shown top-left of the canvas when the displayed
/// photo has a Live Photo movie (`ImageGroup.livePhotoMovie`).
/// It is a button. Resting the pointer on it 300 ms, clicking it
/// (⌥-click: with sound) or the VoiceOver action "Play Live Photo"
/// plays the movie. When the photo is zoomed in it is dimmed and does
/// nothing. The canvas decides whether a play may start (fit, Reduce
/// Motion for hover); the badge only reports what the user did.
@MainActor
final class LivePhotoBadgeView: HUDSurfaceView {

    static let playTooltip = "Live Photo — hover to play"
    static let zoomedTooltip = "Zoom to fit to play"
    static let playActionName = "Play Live Photo"
    /// How long the pointer rests on the badge before it plays.
    static let hoverDelay: TimeInterval = 0.3
    static let dimmedAlpha: CGFloat = 0.45

    /// The user asked to play: `withSound` for ⌥-click, `fromHover` for
    /// the 300 ms rest (Reduce Motion blocks only that one).
    var onPlay: ((_ withSound: Bool, _ fromHover: Bool) -> Void)?

    /// Zoomed in: dimmed, tooltip "Zoom to fit to play", plays nothing.
    var isDimmed = false {
        didSet {
            guard isDimmed != oldValue else { return }
            alphaValue = isDimmed ? Self.dimmedAlpha : 1
            toolTip = isDimmed ? Self.zoomedTooltip : Self.playTooltip
            setAccessibilityHelp(toolTip)
            if isDimmed { cancelHover() }
        }
    }

    private let label = NSTextField(labelWithString: "LIVE")
    private let icon = NSImageView()
    private var hoverTimer: Timer?
    private var hoverArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        glassShape = .capsule

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "livephoto",
            accessibilityDescription: "Live Photo"
        )
        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyUpOrDown

        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        toolTip = Self.playTooltip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Live Photo")
        setAccessibilityHelp(Self.playTooltip)
        icon.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: Self.playActionName) { [weak self] in
                self?.requestPlay(withSound: false, fromHover: false) ?? false
            },
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Hover (300 ms rest)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { beginHover() }
    override func mouseExited(with event: NSEvent) { cancelHover() }

    /// Starts the 300 ms rest; the play goes out when it ends.
    func beginHover() {
        cancelHover()
        guard !isDimmed, !isHidden else { return }
        let timer = Timer(timeInterval: Self.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverTimer = nil
                _ = self.requestPlay(withSound: false, fromHover: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    var isHoverPending: Bool { hoverTimer != nil }

    override var isHidden: Bool {
        didSet { if isHidden { cancelHover() } }
    }

    // MARK: Click, VoiceOver

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Handled on mouse up (a click), like a button.
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        _ = requestPlay(withSound: event.modifierFlags.contains(.option), fromHover: false)
    }

    override func accessibilityPerformPress() -> Bool {
        requestPlay(withSound: false, fromHover: false)
    }

    /// A click on the badge (tests and the paths above).
    @discardableResult
    func requestPlay(withSound: Bool, fromHover: Bool) -> Bool {
        cancelHover()
        guard !isDimmed, !isHidden else { return false }
        onPlay?(withSound, fromHover)
        return true
    }
}

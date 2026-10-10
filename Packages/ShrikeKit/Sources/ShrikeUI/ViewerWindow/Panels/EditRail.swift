//
//  EditRail.swift
//  ShrikeUI
//
//  Left-edge vertical rail of edit entry-point buttons.
//
//  Inventory:
//    1. Crop     `crop`
//    2. Rotate   `crop.rotate`  (edit mode, straighten / rotate tool)
//    3. Resize   `arrow.up.left.and.arrow.down.right.square`
//    4. Color    `slider.horizontal.3`
//    5. Levels   `slider.horizontal.below.rectangle` (the slot after
//       Color). Rotate Left / Right are file actions
//       (toolbar, menu, keys); Undo and Reset live in the edit chrome.
//  Pins exist only in full screen: the glyph is hidden
//  in a window.
//
//  Geometry:
//   * Content column: 56 pt (buttons 36×36 centred with 10 pt padding).
//   * Full screen: a 24 pt header row above the first
//     tool holds the pin glyph, centred (28×28 hit area). A window has
//     no pin and no header row.
//   * Total width: **56 pt in both modes** (windowed and fullscreen).
//

import AppKit
import ShrikeCore

@MainActor
final class EditRail: HUDSurfaceView {

    var actionDispatcher: ((ViewerAction) -> Void)?

    /// Fired when the user clicks the pin corner overlay (fullscreen mode).
    var onTogglePin: (() -> Void)?

    // Content column (full width of the rail removes the strip).
    private let contentContainer = NSView()
    private let stack = NSStackView()

    // Pin glyph: centred in a 24 pt header row.
    // The row is the tool stack's first arranged view (full screen
    // only), so it always sits inside the rail's backdrop.
    private let pinOverlay: PinCornerOverlay
    private let pinRow = NSView()

    /// Labelled cells 48 × 50 (symbol in the top 48 × 32,
    /// 10 pt label below), 4 pt apart, 4 pt side padding.
    static let cellWidth: CGFloat = 48
    static let cellHeight: CGFloat = 50
    static let cellSpacing: CGFloat = 4
    /// The compact rail: icons only, 36 × 36, 8 pt apart.
    static let compactCell: CGFloat = 36
    static let compactSpacing: CGFloat = 8
    static let toolCount: CGFloat = 5
    /// 8 + 5 × 50 + 4 × 4 + 8 = 282 pt.
    static let labeledHeight: CGFloat = plainTopPadding * 2 + toolCount * cellHeight + (toolCount - 1) * cellSpacing
    /// 8 + 5 × 36 + 4 × 8 + 8 = 228 pt.
    static let compactHeight: CGFloat = plainTopPadding * 2 + toolCount * compactCell + (toolCount - 1) * compactSpacing
    /// The full-screen pin row adds 4 + 24 + 6 and drops the 8 pt top pad.
    static let pinRowExtra: CGFloat = pinRowTopPadding + pinRowHeight + pinRowGap - plainTopPadding

    /// Icons only (the band is too short for labels).
    private(set) var isCompact = false

    /// Header row: 4 pt top padding, 24 pt row, 6 pt gap
    /// before the first tool.
    static let pinRowTopPadding: CGFloat = 4
    static let pinRowHeight: CGFloat = 24
    static let pinRowGap: CGFloat = 6
    /// Stack top padding with no pin row (a window).
    static let plainTopPadding: CGFloat = 8

    private(set) var pinned: Bool = false

    /// Content column width — also the total rail width
    /// since there's no longer an edge-adjacent strip.
    static let contentColumnWidth: CGFloat = 56
    /// Rail total width.
    static let totalWidth: CGFloat = 56

    init() {
        self.pinOverlay = PinCornerOverlay(
            identifierSuffix: "editRail",
            panelName: "Edit Rail",
            appearance: .fullscreenHUD
        )
        super.init(frame: .zero)
        wantsLayer = true
        buildContentColumn()
        installPinOverlay()
        applyAppearance(.fullscreenHUD)
        // One group, "Edit Tools".
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Edit Tools")
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Labelled cells, or the compact icon-only rail.
    func setCompact(_ compact: Bool) {
        guard compact != isCompact else { return }
        isCompact = compact
        stack.spacing = compact ? Self.compactSpacing : Self.cellSpacing
        let side = compact ? (Self.contentColumnWidth - Self.compactCell) / 2
                           : (Self.contentColumnWidth - Self.cellWidth) / 2
        stack.edgeInsets.left = side
        stack.edgeInsets.right = side
        for case let button as RailButton in stack.arrangedSubviews { button.setLabeled(!compact) }
        needsLayout = true
    }

    /// A decode error shows the rail with its buttons off.
    func setToolsEnabled(_ enabled: Bool) {
        for case let button as RailButton in stack.arrangedSubviews where button.isEnabled != enabled {
            button.isEnabled = enabled
            button.alphaValue = enabled ? 1 : 0.4
        }
    }

    func setPinned(_ flag: Bool) {
        pinned = flag
        pinOverlay.setPinned(flag)
    }

    /// Pins exist only in full screen. A window hides the
    /// glyph (the rail is shown or hidden by View › Show Edit Rail).
    func setPinGlyphHidden(_ hidden: Bool) {
        pinOverlay.isHidden = hidden
        pinRow.isHidden = hidden
        stack.edgeInsets.top = hidden ? Self.plainTopPadding : Self.pinRowTopPadding
        needsLayout = true
    }

    /// Flip between windowed + fullscreen presentation — adjusts button
    /// tint (labelColor windowed, white@0.85 fullscreen)
    /// and the pin overlay's hover colour.
    func applyAppearance(_ appearance: PinCornerOverlay.Appearance) {
        pinOverlay.setAppearance(appearance)
        let baseTint: NSColor
        switch appearance {
        case .windowed:
            baseTint = NSColor.labelColor.withAlphaComponent(0.85)
        case .fullscreenHUD:
            baseTint = NSColor.labelColor.withAlphaComponent(0.85)
        }
        for case let btn as RailButton in stack.arrangedSubviews {
            btn.applyAppearance(appearance, restingTint: baseTint)
        }
    }

    // MARK: - Build

    private func buildContentColumn() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentContainer)

        // Content column fills the entire rail now that the strip is gone.
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        stack.orientation = .vertical
        stack.spacing = Self.cellSpacing
        stack.alignment = .centerX
        stack.detachesHiddenViews = true
        // 8 pt top padding (4 pt above the full-screen pin row). Sides:
        // 4 pt, so a 48 pt cell sits in the 56 pt column.
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(stack)
        // A floating rail (full screen) hugs its tools; a docked rail
        // (window) stretches past them.
        let hug = stack.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        hug.priority = .defaultLow
        NSLayoutConstraint.activate([
            hug,
            stack.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])

        // The pin row is the first arranged view.
        pinRow.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            pinRow.widthAnchor.constraint(equalToConstant: Self.contentColumnWidth),
            pinRow.heightAnchor.constraint(equalToConstant: Self.pinRowHeight),
        ])
        stack.addArrangedSubview(pinRow)
        stack.setCustomSpacing(Self.pinRowGap, after: pinRow)

        // Inventory, top to bottom. Each button enters edit
        // mode with its tool (or switches tool in edit mode). Levels sits
        // after Color; Curves is gone.
        stack.addArrangedSubview(iconButton(EditChromeTools.symbol(.crop), "Crop", .crop))
        stack.addArrangedSubview(iconButton(
            EditChromeTools.symbol(.rotate), "Rotate", .selectEditTool(.rotate),
            identifierOverride: "editRail.rotate"
        ))
        stack.addArrangedSubview(iconButton(EditChromeTools.symbol(.resize), "Resize", .resize))
        stack.addArrangedSubview(iconButton(EditChromeTools.symbol(.color), "Color", .colorAdjust))
        stack.addArrangedSubview(iconButton(
            EditChromeTools.symbol(.levels), "Levels", .selectEditTool(.levels),
            identifierOverride: "editRail.levels"
        ))
    }

    private func installPinOverlay() {
        // Centred in the pin row (the stack's first view),
        // so it shares the tools' coordinates inside the glass host. The
        // old frame code placed it against the rail's bounds, 240 pt off.
        pinOverlay.translatesAutoresizingMaskIntoConstraints = false
        pinOverlay.delegate = self
        pinRow.addSubview(pinOverlay)
        NSLayoutConstraint.activate([
            pinOverlay.centerXAnchor.constraint(equalTo: pinRow.centerXAnchor),
            pinOverlay.centerYAnchor.constraint(equalTo: pinRow.centerYAnchor),
            pinOverlay.widthAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
            pinOverlay.heightAnchor.constraint(equalToConstant: PinCornerOverlay.hitSize),
        ])
    }

    /// The command whose title and live key a rail tooltip shows.
    static func tooltipCommand(for action: ViewerAction) -> (ShrikeCommand, ShortcutContext)? {
        switch action {
        case .crop: return (.editCrop, .editMode)
        case .selectEditTool(.rotate): return (.editRotate, .editMode)
        case .resize: return (.editResize, .editMode)
        case .colorAdjust: return (.editColor, .editMode)
        case .selectEditTool(.levels): return (.levels, .viewer)
        default: return nil
        }
    }

    private func iconButton(
        _ symbol: String,
        _ label: String,
        _ action: ViewerAction,
        disabledInV1: Bool = false,
        identifierOverride: String? = nil
    ) -> RailButton {
        let btn = RailButton(action: action)
        btn.setSymbol(symbol, accessibilityLabel: label)
        btn.setLabel(label)
        if !disabledInV1, let (command, context) = Self.tooltipCommand(for: action) {
            LiveTooltips.shared.bind(btn, command: command, context: context, title: label)
        } else {
            btn.toolTip = label
        }
        btn.setAccessibilityIdentifier(
            identifierOverride ?? "editRail.\(action)"
        )
        btn.target = self
        btn.onClick = { [weak self] act in
            self?.actionDispatcher?(act)
        }
        if disabledInV1 {
            btn.isEnabled = false
            btn.alphaValue = 0.4
        }
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setLabeled(true)
        return btn
    }

    // MARK: - Active tool

    /// The tool a rail button opens.
    static func tool(for action: ViewerAction) -> EditTool? {
        switch action {
        case .crop: return .crop
        case .selectEditTool(let tool): return tool
        case .resize: return .resize
        case .colorAdjust: return .color
        default: return nil
        }
    }

    /// Highlights the active edit tool's button, as the capsule and the
    /// toolbar's tool picker do; nil outside edit mode.
    func setActiveTool(_ tool: EditTool?) {
        for case let button as RailButton in stack.arrangedSubviews {
            button.isActiveTool = tool != nil && Self.tool(for: button.viewerAction) == tool
        }
    }

    /// Test seam: the tools whose buttons show as active.
    internal func activeToolsForTesting() -> [EditTool] {
        stack.arrangedSubviews.compactMap { view in
            guard let button = view as? RailButton, button.isActiveTool else { return nil }
            return Self.tool(for: button.viewerAction)
        }
    }

    // MARK: - Test seams

    /// Test seam — ordered titles of the visible entry buttons (uses toolTip).
    internal func buttonTitlesForTesting() -> [String] {
        stack.arrangedSubviews.compactMap { ($0 as? RailButton)?.toolTip }
    }

    /// Test seam — ordered ViewerActions of the buttons in rail order.
    internal func buttonActionsForTesting() -> [ViewerAction] {
        stack.arrangedSubviews.compactMap { ($0 as? RailButton)?.viewerAction }
    }

    /// Test seam — current rail tint (tracks `applyAppearance`).
    internal func buttonTintColorForTesting() -> NSColor? {
        stack.arrangedSubviews.lazy.compactMap { $0 as? RailButton }.first?.restingTintForTesting
    }

    /// Test seam — the rail buttons in order.
    internal var buttonsForTesting: [RailButton] {
        stack.arrangedSubviews.compactMap { $0 as? RailButton }
    }

    /// Test seam — current frame of the content column. Post
    /// the column fills the full rail width.
    internal var contentColumnFrameForTesting: CGRect { contentContainer.frame }

    /// Test seam — the pin glyph is drawn (full screen only).
    internal var pinGlyphShownForTesting: Bool { !pinOverlay.isHidden }

    /// Test seam — button frames in rail coordinates, in rail order.
    internal func buttonFramesForTesting() -> [NSRect] {
        layoutSubtreeIfNeeded()
        return stack.arrangedSubviews.compactMap { v in
            (v as? RailButton).map { convert($0.frame, from: $0.superview) }
        }
    }

    /// Test seam — pin corner overlay for layout assertions.
    internal var pinOverlayForTesting: PinCornerOverlay { pinOverlay }

    /// Test seam — pin overlay's current pinned state.
    internal var pinOverlayPinnedForTesting: Bool { pinOverlay.isPinnedForTesting }
}

// MARK: - PinCornerOverlayDelegate

extension EditRail: PinCornerOverlayDelegate {
    func pinCornerOverlayDidToggle(_ overlay: PinCornerOverlay) {
        onTogglePin?()
    }
}

// MARK: - RailButton

/// NSButton subclass for rail tools. Renders a rounded-rect hover /
/// pressed background behind the SF Symbol glyph
@MainActor
final class RailButton: NSButton {

    let viewerAction: ViewerAction
    var onClick: ((ViewerAction) -> Void)?

    private let hoverBackground = CALayer()
    private var trackingArea: NSTrackingArea?
    private var isHovered: Bool = false
    private var isPressed: Bool = false
    /// Our own appearance mode — prefixed to avoid shadowing NSView's
    /// built-in `appearance: NSAppearance?` property.
    private var shrikeAppearance: PinCornerOverlay.Appearance = .fullscreenHUD
    private var restingTintColor: NSColor = .labelColor

    /// The edit tool this button opens is the active one: a platter
    /// stays behind the glyph and the glyph takes the accent colour.
    var isActiveTool = false {
        didSet {
            guard isActiveTool != oldValue else { return }
            contentTintColor = isActiveTool ? .labelColor : restingTintColor
            setAccessibilityValue(isActiveTool ? "Selected" : nil)
            updateBackground()
        }
    }

    /// The symbol in the top 48 × 32 and the tool name
    /// under it (10 pt medium, 13 pt line, 1 pt gap, 4 pt bottom pad).
    private let glyphView = NSImageView()
    let labelField = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private(set) var isLabeled = false

    /// The label and the glyph take the button's tint.
    override var contentTintColor: NSColor? {
        didSet {
            glyphView.contentTintColor = contentTintColor
            labelField.textColor = contentTintColor
        }
    }

    func setLabel(_ text: String) {
        labelField.stringValue = text
        setAccessibilityLabel(text)
    }

    /// Labelled 48 × 50 cell, or the compact 36 × 36 icon button.
    func setLabeled(_ labeled: Bool) {
        if widthConstraint == nil {
            widthConstraint = widthAnchor.constraint(equalToConstant: 36)
            heightConstraint = heightAnchor.constraint(equalToConstant: 36)
            widthConstraint?.isActive = true
            heightConstraint?.isActive = true
        }
        isLabeled = labeled
        widthConstraint?.constant = labeled ? EditRail.cellWidth : EditRail.compactCell
        heightConstraint?.constant = labeled ? EditRail.cellHeight : EditRail.compactCell
        // (A1): the button never draws a title. A labelled
        // cell draws its glyph and label in its own views, so the
        // button's image is off there; compact keeps the image.
        imagePosition = .imageOnly
        image = labeled ? nil : symbolImage
        glyphView.isHidden = !labeled
        labelField.isHidden = !labeled
        hoverBackground.cornerRadius = labeled ? 8 : 6
    }

    private func installLabelViews() {
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        glyphView.imageScaling = .scaleNone
        glyphView.setAccessibilityElement(false)
        labelField.translatesAutoresizingMaskIntoConstraints = false
        labelField.font = .systemFont(ofSize: 10, weight: .medium)
        labelField.alignment = .center
        labelField.lineBreakMode = .byClipping
        labelField.setAccessibilityElement(false)
        glyphView.isHidden = true
        labelField.isHidden = true
        addSubview(glyphView)
        addSubview(labelField)
        NSLayoutConstraint.activate([
            glyphView.topAnchor.constraint(equalTo: topAnchor),
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.widthAnchor.constraint(equalToConstant: EditRail.cellWidth),
            glyphView.heightAnchor.constraint(equalToConstant: 32),
            labelField.topAnchor.constraint(equalTo: glyphView.bottomAnchor, constant: 1),
            labelField.centerXAnchor.constraint(equalTo: centerXAnchor),
            labelField.heightAnchor.constraint(equalToConstant: 13),
            labelField.widthAnchor.constraint(lessThanOrEqualToConstant: EditRail.cellWidth),
        ])
    }

    init(action: ViewerAction) {
        self.viewerAction = action
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        // (A1): NSButton's default title is "Button"; it
        // showed over every icon.
        title = ""
        alternateTitle = ""
        setAccessibilityTitle(nil)
        setButtonType(.momentaryPushIn)
        focusRingType = .default
        target = self
        self.action = #selector(handleClick(_:))

        // Hover-background layer inserted BELOW the button's own imageView
        // so the glyph draws on top. Matches 36×36 bounds with 6 pt
        // corner radius
        hoverBackground.cornerRadius = 6
        hoverBackground.opacity = 0
        layer?.insertSublayer(hoverBackground, at: 0)
        colorObserver = LiveColorObserver(view: self) { [weak self] in self?.updateBackground() }
        installLabelViews()
    }

    private var colorObserver: LiveColorObserver?

    /// NSButton draws its glyph in `draw(_:)`, so it cannot
    /// switch to `updateLayer()`; the platter colour is resolved again on
    /// every appearance or system colour change instead.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    /// Test seam: the platter colour as drawn.
    var platterColorForTesting: CGColor? { hoverBackground.backgroundColor }

    required init?(coder: NSCoder) { fatalError() }

    /// The symbol, drawn by the button itself only in the compact rail.
    private var symbolImage: NSImage?

    func setSymbol(_ name: String, accessibilityLabel: String) {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityLabel)
        symbolImage = symbol
        // Glyph 17 pt regular.
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        image = isLabeled ? nil : symbol
        glyphView.image = symbol
        glyphView.symbolConfiguration = symbolConfiguration
    }

    func applyAppearance(_ a: PinCornerOverlay.Appearance, restingTint: NSColor) {
        shrikeAppearance = a
        restingTintColor = restingTint
        contentTintColor = isActiveTool ? .labelColor : restingTint
        updateBackground()
    }

    override func layout() {
        super.layout()
        // Keep the hover background locked to the button bounds even
        // after AppKit lays us out inside a stack view.
        hoverBackground.frame = bounds
    }

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
        guard isEnabled else { return }
        isHovered = true
        animateBackground(duration: 0)   // instant on
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        animateBackground(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateBackground()
        super.mouseDown(with: event)
        // `super.mouseDown` tracks until mouseUp internally; isPressed
        // resets in mouseUp override.
    }

    override func mouseUp(with event: NSEvent) {
        isPressed = false
        updateBackground()
        super.mouseUp(with: event)
    }

    @objc private func handleClick(_ sender: Any?) {
        onClick?(viewerAction)
    }

    private func animateBackground(duration: TimeInterval) {
        let targetOpacity = computedOpacity()
        guard duration > 0 else {
            hoverBackground.removeAnimation(forKey: "shrike.railButton.hoverFade")
            updateBackground()
            return
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = hoverBackground.opacity
        anim.toValue = targetOpacity
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackground.opacity = targetOpacity
        CATransaction.commit()
        hoverBackground.add(anim, forKey: "shrike.railButton.hoverFade")
    }

    /// Hover = white at 10 % (pressed 18 %); the active tool
    /// = the accent at 30 % (the glyph and label stay `labelColor`).
    private func updateBackground() {
        let color: NSColor = isActiveTool ? .controlAccentColor : .white
        hoverBackground.backgroundColor = color.resolvedCGColor(for: effectiveAppearance)
        hoverBackground.opacity = computedOpacity()
    }

    private func computedOpacity() -> Float {
        guard isEnabled else { return 0 }
        if isActiveTool { return isPressed ? 0.40 : (isHovered ? 0.36 : 0.30) }
        return isHovered ? (isPressed ? 0.18 : 0.10) : 0
    }

    override var allowsVibrancy: Bool { false }

    /// The 36×36 frame is the button (hit area and hover platter): the
    /// borderless symbol button's own alignment insets would grow the
    /// frame past it and into the pin row.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// A labelled cell's content, not the image-only button's.
    override var intrinsicContentSize: NSSize {
        isLabeled ? NSSize(width: EditRail.cellWidth, height: EditRail.cellHeight) : super.intrinsicContentSize
    }

    // MARK: - Test seams

    internal var restingTintForTesting: NSColor { restingTintColor }
    internal var platterOpacityForTesting: Float { hoverBackground.opacity }
}

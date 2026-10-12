//
//  HUDSurface.swift
//  ShrikeUI
//
//  The HUD surfaces.
//
//  * Tall panels (inspector, filmstrip, histogram, edit card,
//    transfer panel) are SOLID: `hud.surface` (#1C1C1E at 95 %), a 1 pt
//    hairline, a soft shadow, radius 16. They sample nothing, so a bright
//    or coloured photo behind them can never tint them (the brown
//    inspector / histogram once did).
//  * Small chrome (the full-screen capsule, pill, toast, zoom badge) is
//    a capsule: dark-tinted `NSGlassEffectView` on macOS 26 (built on
//    the first reveal), the same solid recipe on macOS 14 / 15.
//  * The docked filmstrip in a window is `.plain`: opaque fill, no
//    hairline, no shadow, no radius.
//  * `HUDSurfaceView` keeps the surface layer unclipped (it owns the
//    shadow). The `fillLayer` child draws the look and clips.
//  * `HUDGlassContainerView` is the one `NSGlassEffectContainerView` per
//    full-screen viewer (`spacing = 0`).
//  * Every HUD forces `darkAqua` (the canvas is black).
//  * Increase Contrast: the hairline is white at 35 % in
//    full screen, `separatorColor` in a window, resolved at draw time.
//

import AppKit
import ShrikeCore

/// Tokens and the macOS 26 switch.
@MainActor
public enum HUDGlass {
    /// `radius.panel`: every rectangular HUD, in every mode.
    static let panelRadius: CGFloat = 16
    /// Full screen: HUDs float this far from the screen edges.
    static let edgeInset: CGFloat = 12
    /// `inset.window`: floating HUDs in a window.
    static let windowInset: CGFloat = 16
    /// `gap`: the least space between two HUDs.
    static let gap: CGFloat = 12
    /// Increase Contrast border in full screen: white at 35 %.
    static let fullScreenBorderAlpha: CGFloat = 0.35
    /// The border width (hairline and Increase Contrast).
    static let contrastBorderWidth: CGFloat = 1

    /// `hud.surface`: sRGB #1C1C1E at 0.95.
    static let surfaceColor = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.95)
    /// `hud.surface.opaque`.
    static let opaqueSurfaceColor = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 1)
    /// `hud.hairline`: white at 0.12.
    static let hairlineAlpha: CGFloat = 0.12
    /// `hud.glassTint`: sRGB (20, 20, 22) at 0.70.
    static let glassTintColor = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 22 / 255, alpha: 0.70)
    /// `hud.shadow`.
    static let shadowOpacity: Float = 0.35
    static let shadowRadius: CGFloat = 18
    static let shadowOffset = CGSize(width: 0, height: -6)
    /// The glass capsule's lighter shadow.
    static let glassShadowOpacity: Float = 0.30
    static let glassShadowRadius: CGFloat = 12

    /// Tests run the macOS 14 / 15 path on macOS 26.
    static var forceFallbackForTesting = false
    /// Glass views built so far (none before a reveal).
    static var glassViewsBuiltForTesting = 0
    /// Glass containers built so far.
    static var containersBuiltForTesting = 0

    /// True on macOS 26 unless a test forces the fallback.
    static var isAvailable: Bool {
        if forceFallbackForTesting { return false }
        if #available(macOS 26, *) { return true }
        return false
    }
}

/// Base view of the HUDs.
@MainActor
public class HUDSurfaceView: NSView {

    /// How the surface draws its background.
    enum Look: Equatable {
        /// Nothing built yet (built on the first reveal).
        case unbuilt
        /// The solid fill layer (`hud.surface`).
        case solid
        /// Opaque fill, no hairline, no shadow, no radius (the docked
        /// filmstrip in a window).
        case plain
        /// `NSGlassEffectView` `.regular`, dark tint (full-screen
        /// capsules on macOS 26).
        case glass
    }

    /// `height / 2` or `radius.panel`.
    enum GlassShape: Equatable { case capsule, panel }

    var glassShape: GlassShape = .panel {
        didSet {
            guard glassShape != oldValue, look != .unbuilt else { return }
            applyLook()
            updateShape()
        }
    }

    /// Every subview the surface adds lives in here.
    let contentHost = HUDContentHostView()

    private(set) var look: Look = .unbuilt
    /// The host wants the glass look (full screen).
    private(set) var wantsGlassLook = false
    /// `false`: the `.plain` look (the docked filmstrip).
    private(set) var showsMaterial = true
    /// `hud.surface.opaque` instead of `hud.surface` (panels over the
    /// black canvas band: the edit-tool card, the transfer panel).
    var usesOpaqueFill = false {
        didSet { if usesOpaqueFill != oldValue { applyContrastBorder() } }
    }
    /// A full-screen HUD: the Increase Contrast border is white at 35 %.
    var isFullScreenHUD = false {
        didSet { if isFullScreenHUD != oldValue { applyContrastBorder() } }
    }

    /// Called after the look changed (the pill re-stacks its hairline).
    var onLookChanged: (() -> Void)?

    /// The child layer that draws the fill and the hairline.
    private var fillLayer: CALayer?
    /// `NSGlassEffectView` on macOS 26, built on the first glass reveal.
    private var glassView: NSView?
    private var colorObserver: LiveColorObserver?
    private var addingStructure = false
    /// Content constraints read by `leaveGlass` while the host is out of
    /// every parent; the next `rehomeContentHost` puts them back.
    private var keptWhileDetached: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // The HUDs are dark in every system appearance.
        appearance = NSAppearance(named: .darkAqua)
        // The surface layer owns the shadow, so it must not clip.
        layer?.masksToBounds = false
        contentHost.frame = bounds
        contentHost.autoresizingMask = [.width, .height]
        // The content is clipped to the rounded shape (the fill layer
        // clips only itself); `updateShape` sets the radius.
        contentHost.wantsLayer = true
        contentHost.layer?.masksToBounds = true
        contentHost.layer?.cornerCurve = .continuous
        addStructural(contentHost, above: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Subviews go to the content host

    public override func addSubview(_ view: NSView) {
        if addingStructure { super.addSubview(view) } else { contentHost.addSubview(view) }
    }

    public override func addSubview(_ view: NSView,
                                    positioned place: NSWindow.OrderingMode,
                                    relativeTo otherView: NSView?) {
        if addingStructure {
            super.addSubview(view, positioned: place, relativeTo: otherView)
        } else {
            contentHost.addSubview(view, positioned: place, relativeTo: otherView)
        }
    }

    private func addStructural(_ view: NSView, above other: NSView?) {
        addingStructure = true
        defer { addingStructure = false }
        super.addSubview(view, positioned: .above, relativeTo: other)
    }

    /// Clicks on the background land on the surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === contentHost { return self }
        if let glass = glassView, hit === glass
            || (hit.isDescendant(of: glass) && !hit.isDescendant(of: contentHost)) {
            return self
        }
        return hit
    }

    // MARK: - Reveal

    public override var isHidden: Bool {
        didSet { if isHidden != oldValue { revealChanged() } }
    }

    public override var alphaValue: CGFloat {
        didSet { if (alphaValue > 0) != (oldValue > 0) { revealChanged() } }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { revealChanged() }
    }

    /// Shown and not faded out.
    var isRevealed: Bool { !isHidden && alphaValue > 0 }

    private func revealChanged() {
        guard isRevealed else { return }
        // Colours follow the system from the first reveal on.
        if colorObserver == nil {
            colorObserver = LiveColorObserver(view: self) { [weak self] in
                self?.applyContrastBorder()
            }
        }
        if look != targetLook { applyLook() }
    }

    // MARK: - Look

    /// The host enters or leaves full screen. The glass (capsules only)
    /// is built on the next reveal, or now when the surface shows.
    func setGlassLook(_ on: Bool) {
        guard on != wantsGlassLook else { return }
        wantsGlassLook = on
        applyLook()
    }

    /// `false`: the `.plain` look (the docked filmstrip).
    func setShowsMaterial(_ on: Bool) {
        guard on != showsMaterial else { return }
        showsMaterial = on
        applyLook()
    }

    private var targetLook: Look {
        if !showsMaterial { return .plain }
        if glassShape == .capsule, wantsGlassLook, HUDGlass.isAvailable { return .glass }
        return .solid
    }

    private func applyLook() {
        let target = targetLook
        guard target != look else { return }
        // Lazy: nothing is built until the surface shows.
        guard isRevealed || look != .unbuilt else { return }
        // The pins would be read as content constraints by the moves below.
        unpinContentHost()
        if look == .glass { leaveGlass() }
        switch target {
        case .solid, .plain:
            buildFillLayerIfNeeded()
            fillLayer?.isHidden = false
            if contentHost.superview !== self {
                rehomeContentHost { addStructural(contentHost, above: nil) }
            }
            pinContentHost()
        case .glass:
            guard #available(macOS 26, *) else { return }
            fillLayer?.isHidden = true
            enterGlass()
        case .unbuilt:
            break
        }
        look = target
        updateShape()
        applyContrastBorder()
        onLookChanged?()
    }

    // MARK: Content host pins
    //
    // In the solid and plain looks the host fills the surface through four
    // real constraints. With autoresizing alone, a host that came back from
    // the glass could keep a stale origin and width (seen on the position
    // pill: host at (10, 5) and 8 pt narrower than the pill after a longer
    // string), and the host clips its content, so the text lost its first
    // digit. Content constraints that tie a label to the surface now have
    // one fixed frame to land in.

    private var hostPins: [NSLayoutConstraint] = []

    private func pinContentHost() {
        guard hostPins.isEmpty, contentHost.superview === self else { return }
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        hostPins = [
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostPins)
    }

    private func unpinContentHost() {
        guard !hostPins.isEmpty else { return }
        NSLayoutConstraint.deactivate(hostPins)
        hostPins = []
        contentHost.translatesAutoresizingMaskIntoConstraints = true
        contentHost.autoresizingMask = [.width, .height]
    }

    /// Test seam: the host is pinned to the surface.
    var contentHostPinnedForTesting: Bool { !hostPins.isEmpty }

    private func buildFillLayerIfNeeded() {
        guard fillLayer == nil, let layer else { return }
        let fill = CALayer()
        fill.masksToBounds = true
        fill.cornerCurve = .continuous
        fill.frame = bounds
        // Below every subview layer.
        layer.insertSublayer(fill, at: 0)
        fillLayer = fill
    }

    @available(macOS 26, *)
    private func enterGlass() {
        // The first build of this surface's glass.
        let signpost = glassView == nil
            ? ShrikeSignposts.navigation.begin("glassBuild", String(describing: type(of: self))) : nil
        defer { if let signpost { ShrikeSignposts.navigation.end("glassBuild", signpost) } }
        let glass: NSGlassEffectView
        if let built = glassView as? NSGlassEffectView {
            glass = built
        } else {
            glass = NSGlassEffectView(frame: bounds)
            glass.style = .regular
            // A dark tint, so a white photo cannot light it.
            glass.tintColor = HUDGlass.glassTintColor
            glass.autoresizingMask = [.width, .height]
            glassView = glass
            HUDGlass.glassViewsBuiltForTesting += 1
        }
        glass.frame = bounds
        addStructural(glass, above: nil)
        rehomeContentHost {
            contentHost.frame = glass.bounds
            glass.contentView = contentHost
        }
        Self.silenceSizePreferences(of: glass, keeping: contentHost)
    }

    /// The glass renders through views of its own that hug a zero size at
    /// the default priority (250). That ties with the HUDs' own low-priority
    /// "preferred size" constraints (the histogram's 320 pt), and Auto Layout
    /// then picks the small size. The HUD's content decides its size, so the
    /// glass's own views get the lowest hugging and compression priorities.
    private static func silenceSizePreferences(of glass: NSView, keeping content: NSView) {
        let lowest = NSLayoutConstraint.Priority(1)
        var stack = [glass]
        while let view = stack.popLast() {
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                view.setContentHuggingPriority(lowest, for: orientation)
                view.setContentCompressionResistancePriority(lowest, for: orientation)
            }
            stack += view.subviews.filter { $0 !== content && !$0.isDescendant(of: content) }
        }
    }

    private func leaveGlass() {
        guard let glass = glassView else { return }
        // The constraints that tie the content
        // to the surface are read now, while the host still sits in the
        // glass, and handed to the next move. Read after the host left
        // its parent, they are gone.
        // The glass's own constraints on the host go with the glass.
        keptWhileDetached = HUDReparenting.crossingConstraints(of: [contentHost]).filter { c in
            ![c.firstItem, c.secondItem].contains { item in
                let view = (item as? NSView) ?? (item as? NSLayoutGuide)?.owningView
                guard let view, view !== contentHost, !view.isDescendant(of: contentHost) else { return false }
                return view === glass || view.isDescendant(of: glass)
            }
        }
        if #available(macOS 26, *) { (glass as? NSGlassEffectView)?.contentView = nil }
        contentHost.removeFromSuperview()
        glass.removeFromSuperview()
    }

    /// Moves `contentHost` and keeps the constraints that tie its content
    /// to the surface (AppKit drops them when a view changes parent).
    private func rehomeContentHost(_ move: () -> Void) {
        let kept = keptWhileDetached + HUDReparenting.crossingConstraints(of: [contentHost])
        keptWhileDetached = []
        move()
        if contentHost.superview != nil {
            contentHost.frame = contentHost.superview?.bounds ?? bounds
            NSLayoutConstraint.activate(kept)
        }
    }

    /// The corner radius as drawn: `height / 2` for a capsule, else
    /// `radius.panel` (0 for the docked strip).
    var cornerRadiusForDisplay: CGFloat {
        if look == .plain { return 0 }
        return glassShape == .capsule ? bounds.height / 2 : HUDGlass.panelRadius
    }

    /// Radius, fill frame and shadow path for the current bounds.
    private func updateShape() {
        guard look != .unbuilt, let layer else { return }
        let radius = cornerRadiusForDisplay
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let fill = fillLayer {
            fill.frame = bounds
            if fill.cornerRadius != radius { fill.cornerRadius = radius }
        }
        if contentHost.layer?.cornerRadius != radius { contentHost.layer?.cornerRadius = radius }
        if #available(macOS 26, *), let glass = glassView as? NSGlassEffectView,
           glass.cornerRadius != radius {
            glass.cornerRadius = radius
        }
        if look == .plain {
            layer.shadowOpacity = 0
            layer.shadowPath = nil
            return
        }
        layer.cornerRadius = look == .glass ? radius : 0
        // The surface layer owns the shadow, so it never clips.
        if layer.masksToBounds { layer.masksToBounds = false }
        layer.cornerCurve = .continuous
        layer.shadowColor = NSColor.black.cgColor
        if look == .glass {
            layer.shadowOpacity = HUDGlass.glassShadowOpacity
            layer.shadowRadius = HUDGlass.glassShadowRadius
        } else {
            layer.shadowOpacity = HUDGlass.shadowOpacity
            layer.shadowRadius = HUDGlass.shadowRadius
        }
        layer.shadowOffset = HUDGlass.shadowOffset
        layer.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    public override func layout() {
        super.layout()
        updateShape()
    }

    // MARK: - Hairline and Increase Contrast

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        applyContrastBorder()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyContrastBorder()
    }

    /// Fill colour and the 1 pt border: white at 12 % always; under
    /// Increase Contrast white at 35 % in full screen, `separatorColor`
    /// in a window. The docked strip (`.plain`) has no border.
    func applyContrastBorder() {
        guard let layer, look != .unbuilt else { return }
        let borderColor: CGColor
        if ShrikeTokens.increaseContrast {
            borderColor = (isFullScreenHUD
                ? NSColor.white.withAlphaComponent(HUDGlass.fullScreenBorderAlpha)
                : NSColor.separatorColor).resolvedCGColor(for: effectiveAppearance)
        } else {
            borderColor = NSColor.white.withAlphaComponent(HUDGlass.hairlineAlpha).cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch look {
        case .solid, .plain:
            fillLayer?.backgroundColor = (look == .plain || usesOpaqueFill
                ? HUDGlass.opaqueSurfaceColor : HUDGlass.surfaceColor).cgColor
            if look == .plain {
                fillLayer?.borderWidth = 0
                fillLayer?.borderColor = nil
            } else {
                fillLayer?.borderWidth = HUDGlass.contrastBorderWidth
                fillLayer?.borderColor = borderColor
            }
            layer.borderWidth = 0
            layer.borderColor = nil
        case .glass:
            layer.borderWidth = HUDGlass.contrastBorderWidth
            layer.borderColor = borderColor
        case .unbuilt:
            break
        }
    }

    // MARK: - Test seams

    /// The glass view (`NSGlassEffectView` on macOS 26), once built.
    var glassViewForTesting: NSView? { glassView }
    /// The fill layer, once built.
    var fillLayerForTesting: CALayer? { fillLayer }
}

/// The view that holds a HUD's content.
@MainActor
public final class HUDContentHostView: NSView {}

/// Moves views between parents without losing their layout.
@MainActor
enum HUDReparenting {

    /// Active constraints held by the views' ancestors that tie a view
    /// (or layout guide) inside one of `views`' subtrees to a view
    /// outside it. AppKit removes these when a view changes parent;
    /// activate them again after the move. Autoresizing constraints are
    /// rebuilt by AppKit and skipped.
    static func crossingConstraints(of views: [NSView]) -> [NSLayoutConstraint] {
        var out: [NSLayoutConstraint] = []
        var seen = Set<ObjectIdentifier>()
        for view in views {
            var ancestor = view.superview
            while let holder = ancestor {
                for c in holder.constraints where c.isActive {
                    guard !seen.contains(ObjectIdentifier(c)), !isAutoresizing(c) else { continue }
                    if isInside(c.firstItem, view) || isInside(c.secondItem, view) {
                        seen.insert(ObjectIdentifier(c))
                        out.append(c)
                    }
                }
                ancestor = holder.superview
            }
        }
        return out
    }

    private static func isAutoresizing(_ c: NSLayoutConstraint) -> Bool {
        NSStringFromClass(type(of: c)).contains("Autoresizing")
    }

    private static func isInside(_ item: AnyObject?, _ root: NSView) -> Bool {
        let view: NSView?
        if let v = item as? NSView { view = v } else { view = (item as? NSLayoutGuide)?.owningView }
        guard let view else { return false }
        return view === root || view.isDescendant(of: root)
    }
}

/// The one glass container per full-screen viewer. It
/// fills the viewer and passes clicks on its empty parts to the canvas.
@available(macOS 26, *)
@MainActor
final class HUDGlassContainerView: NSGlassEffectContainerView {

    let content = HUDPassthroughView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spacing = 0
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        contentView = content
        HUDGlass.containersBuiltForTesting += 1
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), hit !== content, hit.isDescendant(of: content) else {
            return nil
        }
        return hit
    }
}

/// A view that is never the target of a click itself.
@MainActor
final class HUDPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A button inside a HUD: borderless, 28 × 28 pt hit
/// area, 15 pt symbol, `labelColor` glyph, and a hover platter (radius 8,
/// `labelColor` at 10 %, 18 % while pressed). Same on macOS 14 / 15; no
/// `.glass` bezel (glass on glass).
@MainActor
final class HUDButton: NSButton {

    static let size: CGFloat = 28
    static let symbolPointSize: CGFloat = 15
    static let platterRadius: CGFloat = 8
    static let hoverAlpha: CGFloat = 0.10
    static let pressedAlpha: CGFloat = 0.18

    private let platter = CALayer()
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private(set) var isPressed = false

    init(symbol: String, accessibility: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Self.symbolPointSize, weight: .regular)
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        contentTintColor = .labelColor
        setButtonType(.momentaryPushIn)
        platter.cornerRadius = Self.platterRadius
        platter.opacity = 0
        layer?.insertSublayer(platter, at: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The frame is the 28 × 28 hit area. An image-only borderless button
    /// otherwise takes its symbol's alignment insets, and each button in a
    /// row ends up a different size (30–38 pt).
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// The platter opacity as drawn (tests).
    var platterAlphaForTesting: CGFloat {
        platter.opacity == 0 ? 0 : (platter.backgroundColor?.alpha ?? 0)
    }

    override func layout() {
        super.layout()
        platter.frame = bounds
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePlatter()
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

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        updatePlatter()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updatePlatter()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updatePlatter()
        super.mouseDown(with: event)   // tracks until the mouse is up
        isPressed = false
        updatePlatter()
    }

    /// Test seam: hover / press without a pointer.
    func setPointerStateForTesting(hovered: Bool, pressed: Bool) {
        isHovered = hovered
        isPressed = pressed
        updatePlatter()
    }

    private func updatePlatter() {
        let alpha: CGFloat = isPressed ? Self.pressedAlpha : (isHovered ? Self.hoverAlpha : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        platter.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha)
            .resolvedCGColor(for: effectiveAppearance)
        platter.opacity = alpha > 0 ? 1 : 0
        CATransaction.commit()
    }
}

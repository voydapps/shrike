//
//  ViewerContentView.swift
//  ShrikeUI
//
//  The root AppKit view that fills the viewer window. Hosts MetalImageView
//  plus four chrome panels plus the histogram/loupe/zoom-badge overlays.
//
//  Windowed vs. fullscreen
//  -----------------------
//  The same four panels live in the view tree but behave differently by
//  `windowMode`:
//
//    * `.windowed`   — the filmstrip docks UNDER the canvas (takes real
//                      estate from the MetalImageView). Toolbar / editRail /
//                      inspector are not built into the hierarchy; they are
//                      surfaced via the windowed-mode NSToolbar + menus.
//                      The inspector also uses the
//                      right-edge hover panel in windowed mode (no
//                      NSSplitViewController.inspector surgery).
//    * `.fullscreen` — all four panels are edge-activated overlays (top
//                      filmstrip, bottom toolbar, left edit rail, right
//                      inspector). Cursor-idle auto-hide at
//                      `Prefs.chromeFadeOutDelayMs`. Pin glyph per panel.
//
//  Z-order (bottom → top):
//    imageView < livePhotoMovie (only while a Live Photo plays)
//    < canvasDim < [filmstrip, toolbar, editRail, inspector]
//    < zoomBadge < histogramOverlay < loupeView < toastView < pageIndicator
//    < livePhotoBadge < navPositionOverlay < previewBadge < errorOverlay
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeRendering

@MainActor
public final class ViewerContentView: NSView {

    // MARK: - Activation-zone widths

    /// Reveal zones (full screen). The top edge belongs to
    /// the macOS menu bar: nothing of ours reveals there.
    enum Zone {
        static let bottomHeight: CGFloat = 96
        static let sideWidth: CGFloat = 56
        /// A panel leaves when the pointer is out of its zone and out of
        /// its frame grown by this margin.
        static let bodyMargin: CGFloat = 24
        /// The pointer rests this long in a zone before it reveals.
        static let restMs: Int = 120
    }

    /// Fades (opacity only).
    static let fadeInDuration: TimeInterval = 0.08
    static let fadeOutDuration: TimeInterval = 0.12
    /// Bottom stack metrics.
    static let fullscreenFilmstripHeight: CGFloat = 88
    static let capsuleHeight: CGFloat = 44
    static let capsuleGapAboveFilmstrip: CGFloat = 12
    static let capsuleBottomInset: CGFloat = 16

    // MARK: - Panels

    public enum PanelKind: Sendable, Hashable, CaseIterable {
        case filmstrip
        case toolbar
        case editRail
        case inspector
    }

    /// Which layout regime the view is currently in. Drives zone
    /// evaluation, filmstrip docking, and whether the chrome panels run
    /// as edge-activated overlays. Flipped by the window's fullscreen
    /// notifications.
    public enum WindowMode: Sendable, Hashable {
        case windowed
        case fullscreen
    }

    private let services: ShrikeServices

    public let imageView: MetalImageView
    private let filmstrip: FilmstripView
    /// The full-screen capsule. A window
    /// never shows it, so it is built the first time full screen (or a
    /// test, or Share) asks for it, not before the first frame.
    private var capsuleStorage: ViewerToolbar?
    private var toolbar: ViewerToolbar {
        if let capsule = capsuleStorage { return capsule }
        let capsule = ViewerToolbar()
        capsuleStorage = capsule
        installCapsule(capsule)
        return capsule
    }
    /// True once the capsule exists (tests).
    internal var isCapsuleBuiltForTesting: Bool { capsuleStorage != nil }
    private let editRail: EditRail
    private let inspector: InspectorPanel

    private let zoomBadge: ZoomBadgeView
    /// The floating histogram, built on its first show: most
    /// windows never show it, so `init` no longer pays for it.
    private var histogramStorage: HistogramOverlayView?
    /// The empty state's hold, kept for an overlay built later.
    private var histogramSuppressed = false
    /// Where `placeBottomStack` last put the overlay (trailing, bottom),
    /// so one built later starts there.
    private var histogramPlacement: (trailing: CGFloat, bottom: CGFloat) = (-16, -16)
    /// Feeds the overlay and the inspector band.
    let histogram = HistogramController()
    private var histogramTrailing: NSLayoutConstraint?
    private var histogramBottomToSelf: NSLayoutConstraint?
    private var histogramBottomToImage: NSLayoutConstraint?
    /// File of the last full image (edit-mode exit recomputes from it).
    private var histogramURL: URL?
    private let loupeView: LoupeView
    /// Shared toast host.
    let toastHost: ToastHostView
    private let errorOverlay: ErrorOverlayView
    private let pageIndicator: PageIndicatorView
    private let livePhotoBadge: LivePhotoBadgeView
    /// The badge follows the photo's top-left corner.
    private var liveBadgeLeading: NSLayoutConstraint?
    private var liveBadgeTopPreferred: NSLayoutConstraint?
    private let navPositionOverlay: NavigationPositionOverlayView
    private let previewBadge: PreviewBadgeView

    /// Black `NSView` stacked directly above `MetalImageView` used as the
    /// canvas-dim overlay. See the file-level comment + the
    /// original commentary below.
    private let canvasDim: NSView

    /// Edit-mode shell. Not mounted until `enterEditMode(…)`.
    public let editModeController: EditModeController = EditModeController()
    private var editPanelConstraints: [NSLayoutConstraint] = []
    private var editOverlayConstraints: [NSLayoutConstraint] = []
    private(set) var isEditModeActive: Bool = false

    static let canvasDimApplyDelay: TimeInterval = 0.120

    private let dimScheduler: CanvasDimScheduler

    private var pinnedPanels: Set<PanelKind> = []
    private var hoveredPanels: Set<PanelKind> = []

    /// Per-panel exit-grace timers. When the
    /// cursor leaves a panel's hot zone AND leaves its body, we don't
    /// hide it immediately — instead schedule a 200 ms timer. If the
    /// cursor re-enters either zone or body before the timer fires,
    /// the timer is cancelled. Prevents panels from flickering shut
    /// when the user slides the pointer along a panel edge.
    private var panelExitGraceWorkItems: [PanelKind: DispatchWorkItem] = [:]

    /// Grace period (ms) before a panel whose cursor has left its zone
    /// AND body is considered for hiding.

    /// Hide after `shrike.viewer.chromeFadeOutDelayMs` once
    /// the pointer left the zone and the panel. Tests shorten it.
    internal var exitGraceMsOverrideForTesting: Int?
    private var exitGraceMs: Int { exitGraceMsOverrideForTesting ?? Prefs.chromeFadeOutDelayMs }

    /// Zone rest timers (120 ms rest before a reveal).
    private var zoneRestWorkItems: [PanelKind: DispatchWorkItem] = [:]
    private var lastZonePoint: NSPoint?
    /// Tests: 0 reveals at once.
    internal var zoneRestMs: Int = Zone.restMs

    /// Capsule bottom: 12 pt above the filmstrip while the strip shows,
    /// else 16 pt above the bottom edge.
    private var toolbarBottomToSelf: NSLayoutConstraint?
    private var toolbarBottomToFilmstrip: NSLayoutConstraint?
    /// The pill's leading edge: 16 pt in full screen, or 16 pt past the
    /// rail when it shows.
    private var navOverlayLeading: NSLayoutConstraint?
    private var navOverlayMaxWidth: NSLayoutConstraint?

    /// Test seam: false makes panel show/hide immediate (no 0.15 / 0.3 s
    /// alpha fade), so tests can assert `isHidden` synchronously.
    internal var animatesPanelFades = true

    /// Test seam: cursor position (window coordinates) that
    /// `applyExitGrace` uses instead of the live pointer, so tests don't
    /// depend on where the real mouse happens to sit on screen.
    internal var cursorLocationOverrideForTesting: NSPoint?

    private var trackingArea: NSTrackingArea?
    private var cursorHideTimer: Timer?

    /// Cursor-idle auto-hide timer for hover-revealed panels. Bumped by
    /// every `mouseMoved` inside the canvas area; when the deadline
    /// passes without a kick, hover panels fade out. Pinned panels
    /// ignore this timer.
    private var chromeIdleTimer: Timer?

    /// Bookkeeping for geometry that depends on window mode. Rebuilt by
    /// `configureForMode` whenever the mode flips.
    private var filmstripWindowedConstraints: [NSLayoutConstraint] = []
    private var filmstripFullscreenConstraints: [NSLayoutConstraint] = []
    private var imageViewWindowedBottomConstraint: NSLayoutConstraint?
    private var imageViewFullscreenBottomConstraint: NSLayoutConstraint?
    private var filmstripHeightConstraint: NSLayoutConstraint?

    // Edit rail geometry
    // Fullscreen: floating overlay, 56 pt wide, centred vertically.
    // Windowed: docked left strip, 56 pt wide, full height. Pin glyph lives
    // in a shared PinCornerOverlay at top-right in both modes.
    private var editRailFullscreenConstraints: [NSLayoutConstraint] = []
    private var editRailWindowedConstraints: [NSLayoutConstraint] = []
    private var editRailWidthFullscreen: NSLayoutConstraint?
    private var editRailWidthWindowed: NSLayoutConstraint?
    /// The windowed rail faded on the pointer clock.
    private(set) var railIdleHidden = false
    /// The first frame is on screen; the rail waits for it.
    private(set) var hasPresentedFirstFrame = false
    /// Band too short or canvas too narrow: no rail.
    private(set) var railSqueezedOut = false
    /// The windowed rail's last applied target (nil: not applied yet).
    private var railAppliedTarget: Bool?
    private var railShownOnce = false
    /// The window starts its pointer clock when the rail first shows.
    var onRailShownFirst: (() -> Void)?
    /// Test seam: VoiceOver on / off without the system setting.
    internal var voiceOverOverrideForTesting: Bool?
    /// Gap between the rail's band and the titlebar / the pill.
    static let railBandGap: CGFloat = HUDGlass.gap
    /// The narrowest canvas that keeps the rail.
    static let railMinCanvasWidth: CGFloat = 480
    /// The HUD inspector's trailing edge: 16 pt in, 12 pt as glass.
    private var inspectorTrailing: NSLayoutConstraint?
    /// The inspector ends 12 pt above the floating strip
    /// while it shows, else 12 pt above the bottom.
    private var inspectorBottomToSelf: NSLayoutConstraint?
    private var inspectorBottomToFilmstrip: NSLayoutConstraint?

    // MARK: Glass

    /// The one `NSGlassEffectContainerView` (macOS 26), built at the
    /// first full screen; the HUD surfaces move into its content view.
    private var glassContainerStorage: NSView?
    private var glassContentStorage: NSView?
    /// Where the HUD surfaces live.
    private var hudParent: NSView { glassContentStorage ?? self }
    /// In full screen the HUDs float 12 pt from the screen
    /// edges, on every macOS version (the panels are solid now).
    private var usesGlassGeometry: Bool {
        windowMode == .fullscreen
    }
    /// Test seam: the glass container, once built.
    internal var glassContainerForTesting: NSView? { glassContainerStorage }

    // imageView leading — swapped by `configureForMode` when the docked
    // edit rail is visible in windowed mode.
    private var imageViewLeadingToSelf: NSLayoutConstraint?
    private var imageViewLeadingToEditRail: NSLayoutConstraint?

    // Filmstrip leading — same swap; in windowed mode the filmstrip starts
    // past the docked edit rail so the rail isn't overlaid by thumbs.
    private var filmstripLeadingToSelf: NSLayoutConstraint?
    private var filmstripLeadingToEditRail: NSLayoutConstraint?

    // Navigation position overlay bottom — swapped per mode.
    // In windowed mode with the filmstrip docked, the pill sits
    // ABOVE the filmstrip; otherwise it stays at a fixed offset from the
    // panel bottom.
    private var navOverlayBottomToPanel: NSLayoutConstraint?
    private var navOverlayBottomToFilmstrip: NSLayoutConstraint?

    // KVO token for live pref observation (position overlay auto-hide
    // + edit-rail windowed visibility). Wrapped so the deinit can hand
    // it off without touching MainActor state.
    private let prefsObservationBox: PrefsObservationBox = PrefsObservationBox()

    /// The current window mode. Writing this property is a no-op if
    /// unchanged; otherwise it re-configures layout + panel visibility.
    public var windowMode: WindowMode = .windowed {
        didSet {
            guard oldValue != windowMode else { return }
            configureForMode()
            if isEditModeActive { installEditChrome() }
        }
    }

    var actionDispatcher: ((ViewerAction) -> Void)?

    /// Called when the user clicks a filmstrip cell. Receives the global
    /// image index. `ViewerWindow` wires this to `navigate(to:)` via the
    /// nav coalescer.
    var onFilmstripJump: ((Int) -> Void)?

    /// Called when the user scroll-wheel-scrubs the filmstrip. Receives
    /// +1 / -1 increments. `ViewerWindow` wires this to advance/retreat.
    var onFilmstripScrub: ((Int) -> Void)?

    /// The long edge, in pixels, display textures should have: the
    /// canvas long edge at the backing scale, never above the "Max
    /// decoded long edge" pref. The window
    /// passes it to its decode queue. A 1200 x 800 pt window on a 2x
    /// screen needs 2400 px textures, not 4096 px (~130 MB less).
    var onMaxLongEdgeChanged: ((Int) -> Void)?
    private var lastMaxLongEdge = Prefs.maxDisplayLongEdge
    /// Last value sent through `onMaxLongEdgeChanged` (nil = none yet).
    private(set) var requestedTextureLongEdge: Int?

    /// The texture long edge for the canvas as it is now; nil before the
    /// view has a window and a size.
    var canvasTextureLongEdge: Int? {
        guard let window, bounds.width > 0, bounds.height > 0 else { return nil }
        let px = Int((max(bounds.width, bounds.height) * window.backingScaleFactor).rounded(.up))
        return max(256, min(Prefs.maxDisplayLongEdge, px))
    }

    /// Sends the canvas texture size when it changed. Called on the first
    /// layout, at the end of a live resize, when the backing scale
    /// changes, on full-screen enter and exit, and when the pref changes.
    /// Not during a live resize or a full-screen animation (one decode
    /// size per settled size).
    func updateTextureLongEdge() {
        guard let edge = canvasTextureLongEdge, edge != requestedTextureLongEdge else { return }
        requestedTextureLongEdge = edge
        onMaxLongEdgeChanged?(edge)
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        updateTextureLongEdge()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if requestedTextureLongEdge != nil { updateTextureLongEdge() }
    }

    /// `surface.base`: #1C1C1E dark / #F5F5F7 light.
    static var surfaceBase: NSColor { ShrikeTokens.surfaceBase }

    /// Canvas table: full screen and "Background always
    /// black" are #000; otherwise `surface.base`.
    static func canvasColor(windowed: Bool, alwaysBlack: Bool) -> NSColor {
        windowed && !alwaysBlack ? surfaceBase : .black
    }

    /// Applies the canvas colour and, when windowed, the docked
    /// filmstrip's forced-dark appearance.
    func applyCanvasColour() {
        let windowed = windowMode == .windowed
        let black = Prefs.viewerBackgroundAlwaysBlack
        imageView.canvasColor = Self.canvasColor(windowed: windowed, alwaysBlack: black)
        if windowed {
            filmstrip.appearance = black ? NSAppearance(named: .darkAqua) : nil
        }
    }

    /// Wheel or swipe navigation from the canvas.
    /// `true` = next image.
    var onCanvasNavigate: ((Bool) -> Void)?

    /// Whether an image exists in that direction (`true` = next). Sets
    /// the swipe thresholds so the ends rubber-band.
    var canNavigate: ((Bool) -> Bool)?
    /// A swipe wants the neighbour's texture.
    var onSwipeNeighbourWanted: ((Bool) -> Void)?
    /// A swipe completed toward `forward`, leaving `handOver` on screen.
    var onSwipeCompleted: ((Bool, SwipeHandOver) -> Void)?
    /// A swipe stretched past an end of the list (shows a toast).
    var onSwipeStretchedPastEnd: ((Bool) -> Void)?

    /// At most one VoiceOver zoom announcement per 500 ms.
    private var zoomAnnouncementThrottle = ZoomAnnouncementThrottle()

    /// Posts "Zoom 200 percent" / "Zoom to fit" for VoiceOver after a
    /// keyboard, menu, wheel or pinch zoom.
    func announceZoom() {
        guard NSWorkspace.shared.isVoiceOverEnabled,
              zoomAnnouncementThrottle.allow(at: ProcessInfo.processInfo.systemUptime) else { return }
        let text = ZoomAnnouncementThrottle.text(scale: imageView.pixelScale, atFit: imageView.isAtFit)
        NSAccessibility.post(
            element: window ?? self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    // MARK: - Init

    public init(services: ShrikeServices) {
        self.services = services
        self.imageView = MetalImageView(frame: .zero)
        self.filmstrip = FilmstripView()
        self.editRail = EditRail()
        self.inspector = InspectorPanel()
        self.zoomBadge = ZoomBadgeView()
        self.loupeView = LoupeView()
        self.toastHost = ToastHostView(placement: .viewer)
        self.errorOverlay = ErrorOverlayView()
        self.pageIndicator = PageIndicatorView()
        self.livePhotoBadge = LivePhotoBadgeView()
        self.navPositionOverlay = NavigationPositionOverlayView()
        self.previewBadge = PreviewBadgeView()
        self.canvasDim = NSView(frame: .zero)
        self.dimScheduler = CanvasDimScheduler(
            applyDelay: Self.canvasDimApplyDelay
        )
        super.init(frame: .zero)
        dimScheduler.onApply = { [weak self] in
            self?.performCanvasDimApply()
        }
        wireHistogram()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // Disable Core Animation's implicit animations on the root view's
        // backing layer for the SAME reasons as MetalImageView's metalLayer
        // (see commentary in MetalImageView.init under `layer.actions =
        // [...]`): during AppKit's multi-tick fullscreen-enter / -exit
        // animation, AppKit drives this view's `bounds` to interpolate
        // between the windowed and fullscreen sizes. Each intermediate
        // value triggers CA's default implicit tween on the layer's
        // `bounds`/`position`/`frame`, which establishes an animating
        // coordinate system for every sublayer underneath — including
        // MetalImageView's metalLayer. Even though metalLayer's OWN frame
        // jumps instantly to the final value (its actions are NSNull
        // already), the parent's interpolating coordinate system
        // visually rescales the rendered drawable, producing the
        // "shrink then un-shrink" pulse the user sees on every
        // fullscreen toggle. Suppressing CA actions HERE makes the
        // parent's geometry change atomic, so the rendered drawable in
        // the child layer no longer gets visually scaled by an
        // animating ancestor transform. `sublayers` is included
        // defensively in case AppKit reorders sublayers during a layout
        // swap. See FullscreenExitLayoutTests.testParentLayerActions_…
        layer?.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "frame": NSNull(),
            "contents": NSNull(),
            "sublayers": NSNull(),
        ]

        // Seed pin state + windowed-filmstrip visibility from Prefs so
        // that a freshly opened viewer window picks up the user's last
        // sticky choices without a round-trip through the window's
        // construction code.
        if Prefs.filmstripPinnedFullscreen { pinnedPanels.insert(.filmstrip) }
        if Prefs.editRailPinnedFullscreen { pinnedPanels.insert(.editRail) }
        if Prefs.exifPanelPinnedFullscreen { pinnedPanels.insert(.inspector) }

        setupSubviews()
        setupTracking()
        wirePanelCallbacks()
        configureForMode()
        syncPinGlyphs()
        wireEditMode()
    }

    // MARK: - Edit mode

    private func wireEditMode() {
        editModeController.onPresentImage = { [weak self] image in
            guard let self else { return }
            self.imageView.setPlaceholderImage(image)
            self.syncCropOverlayFrame()
            self.histogram.editImageRendered(image)
        }
        editModeController.onExitedEditMode = { [weak self] restore in
            self?.exitEditMode(restoreImage: restore)
        }
        editModeController.onChromeStateChanged = { [weak self] state in
            self?.applyEditChromeState(state)
        }
        // Reset left the rail; it lives in the edit chrome.
    }

    /// Mount edit mode chrome over the current viewer. The chrome stays
    /// in the view tree until `exitEditMode()` — the controller fires
    /// `onExitedEditMode` when it finalises, which routes here.
    public func enterEditMode(image: CGImage,
                              url: URL?,
                              landOn tool: EditTool?) {
        guard !isEditModeActive else {
            if let tool { editModeController.selectTool(tool) }
            return
        }
        isEditModeActive = true
        stopLivePhoto()
        imageView.fileDragEnabled = false   // drags belong to the tool
        // Discard shows this again directly, with no
        // preview frame in between.
        imageBeforeEdit = imageView.image.map { ($0, imageView.sourceID) }

        // Parameter panel on the right, below the edit toolbar (the
        // safe area ends under the titlebar + toolbar in a window).
        let ePanel = editModeController.parameterPanel
        ePanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ePanel)
        // The panel ends above the docked filmstrip (the image
        // area's bottom in a window), 32 pt above the bottom otherwise.
        let panelBottom = ePanel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -32)
        panelBottom.priority = .defaultHigh
        editPanelConstraints = [
            ePanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            panelBottom,
            ePanel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -32),
            ePanel.bottomAnchor.constraint(lessThanOrEqualTo: imageView.bottomAnchor, constant: -8),
            ePanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            ePanel.widthAnchor.constraint(
                equalToConstant: EditParameterPanel.panelWidth
            ),
        ]
        // The histogram stays clear of the panel; one
        // built later in edit mode adds this itself.
        if let overlay = histogramStorage {
            editPanelConstraints.append(histogramClearOfEditPanel(overlay))
        }
        NSLayoutConstraint.activate(editPanelConstraints)

        // Crop overlay sits on top of the image canvas but *below* the
        // feedback pipeline (navPositionOverlay / previewBadge /
        // errorOverlay). Rationale: the position pill must stay legible
        // while editing (the user can still see "3 / 124" while
        // cropping), and the error overlay still wins the z-order when
        // a save fails. The chrome panels (filmstrip/toolbar/editRail/
        // inspector, histogram) sit ABOVE the overlay: the
        // overlay's dim outside the crop rect covered the edit rail and
        // the histogram, so the rail's glyphs, the active tool's accent
        // included, looked disabled. The overlay goes just under the
        // first chrome panel (or under the glass container that holds
        // them in full screen on macOS 26), above the canvas and its dim.
        let eOverlay = editModeController.cropOverlay
        eOverlay.translatesAutoresizingMaskIntoConstraints = false
        let firstChrome: NSView = glassContainerStorage ?? filmstrip
        (firstChrome.superview ?? self)
            .addSubview(eOverlay, positioned: .below, relativeTo: firstChrome)
        editOverlayConstraints = [
            eOverlay.topAnchor.constraint(equalTo: imageView.topAnchor),
            eOverlay.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            eOverlay.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            eOverlay.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
        ]
        NSLayoutConstraint.activate(editOverlayConstraints)
        eOverlay.imagePixelSize = CGSize(width: image.width, height: image.height)

        // No filmstrip in edit mode (window: the docked
        // strip hides and the canvas takes its height, joined with the
        // edit re-fit below; full screen: never revealed).
        applyWindowedFilmstripDock()
        if windowMode == .fullscreen { updatePanelVisibility() }

        editModeController.hostWindow = window
        editModeController.enter(image: image, url: url, landOn: tool)
        updateHistogramVisibility(animated: true)
        installEditChrome()
        // The frame sits on the image as drawn after the re-fit
        // below the edit toolbar, never on the view bounds.
        layoutSubtreeIfNeeded()
        syncCropOverlayFrame()
    }

    // MARK: - Edit chrome

    /// Windowed: the edit toolbar. Full screen: the edit capsule.
    private(set) lazy var editToolbarController: EditToolbarController = {
        let c = EditToolbarController()
        c.onAction = { [weak self] in self?.editModeController.perform($0) }
        return c
    }()

    private(set) lazy var editCapsule: EditCapsuleView = {
        let v = EditCapsuleView()
        v.onAction = { [weak self] in self?.editModeController.perform($0) }
        return v
    }()

    /// The image on screen when edit mode began (restored on Discard).
    private var imageBeforeEdit: (CGImage, String?)?

    /// "Loading full image…" while edit mode waits for the full decode.
    private(set) lazy var editLoadingView: HUDSurfaceView = {
        let v = HUDSurfaceView()
        v.glassShape = .capsule
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Loading full image…")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .white
        let stack = NSStackView(views: [spinner, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            stack.topAnchor.constraint(equalTo: v.topAnchor),
            stack.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        v.setAccessibilityElement(true)
        v.setAccessibilityLabel("Loading full image")
        return v
    }()

    func setEditLoadingVisible(_ visible: Bool) {
        if visible {
            guard editLoadingView.superview == nil else { return }
            editLoadingView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(editLoadingView, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                editLoadingView.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
                editLoadingView.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            ])
        } else {
            editLoadingView.removeFromSuperview()
        }
    }

    /// The toolbar the window had before edit mode (restored on exit).
    private var toolbarBeforeEdit: NSToolbar?
    /// Whether that toolbar was shown (the user's setting).
    private var toolbarBeforeEditWasShown = true

    /// True while the edit toolbar stands in for the viewer toolbar.
    var isEditToolbarInstalled: Bool { editToolbarInstalled }

    /// The user's viewer-toolbar state while the edit toolbar stands in
    /// for it (full-screen switches read and write it, not the edit
    /// toolbar's). Nil when the edit toolbar is not installed.
    var viewerToolbarShownUnderEdit: Bool? {
        get { editToolbarInstalled ? toolbarBeforeEditWasShown : nil }
        set { if editToolbarInstalled, let newValue { toolbarBeforeEditWasShown = newValue } }
    }

    /// Puts the viewer toolbar back exactly as the user had it. AppKit
    /// may hand the edit toolbar's "shown" state to the toolbar that
    /// replaces it; the viewer toolbar autosaves, so its autosave is
    /// paused while the state is put back, and "shown" is never saved
    /// into the user's setting.
    private func restoreViewerToolbarAfterEdit() {
        let viewerToolbar = toolbarBeforeEdit
        let autosaves = viewerToolbar?.autosavesConfiguration ?? false
        viewerToolbar?.autosavesConfiguration = false
        window?.toolbar = viewerToolbar
        // Full screen has no NSToolbar: the window puts
        // the user's state back when it leaves full screen.
        let wanted = windowMode == .fullscreen ? false : toolbarBeforeEditWasShown
        if let viewerToolbar, viewerToolbar.isVisible != wanted {
            viewerToolbar.isVisible = wanted
        }
        viewerToolbar?.autosavesConfiguration = autosaves
        toolbarBeforeEdit = nil
        editToolbarInstalled = false
    }
    private var editToolbarInstalled = false
    private var editCapsuleConstraints: [NSLayoutConstraint] = []
    private var imageViewTopToSafeArea: NSLayoutConstraint?
    private var imageViewTopToSelf: NSLayoutConstraint?

    /// Fires with the edit subtitle while editing, nil on exit.
    var onEditSubtitleChanged: ((EditChromeState?) -> Void)?

    /// Mounts the chrome that fits the current window mode and removes
    /// the other. Called on entry, on exit and on a full-screen switch.
    func installEditChrome() {
        let editing = isEditModeActive
        let windowed = windowMode == .windowed
        // Windowed: swap `window.toolbar`.
        if editing && windowed {
            if !editToolbarInstalled, let window {
                toolbarBeforeEdit = window.toolbar
                toolbarBeforeEditWasShown = window.toolbar?.isVisible ?? true
                window.toolbar = editToolbarController.toolbar
                // The edit toolbar shows for the whole
                // session even when the user hid the viewer toolbar.
                // It does not autosave, so
                // this writes nothing to the user's setting.
                editToolbarController.toolbar.isVisible = true
                editToolbarInstalled = true
            }
        } else if editToolbarInstalled {
            restoreViewerToolbarAfterEdit()
        }
        // The image fits below the toolbar while editing in a window, so
        // crop handles never sit under it (one re-fit on entry and exit).
        if imageViewTopToSafeArea == nil {
            imageViewTopToSafeArea = imageView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor)
        }
        let fitBelowToolbar = editing && windowed
        if fitBelowToolbar {
            imageViewTopToSelf?.isActive = false
            imageViewTopToSafeArea?.isActive = true
        } else {
            imageViewTopToSafeArea?.isActive = false
            imageViewTopToSelf?.isActive = true
        }

        // Full screen: the edit capsule replaces the viewer toolbar.
        NSLayoutConstraint.deactivate(editCapsuleConstraints)
        editCapsuleConstraints = []
        if editing && !windowed {
            // In the glass container on macOS 26.
            if editCapsule.superview !== hudParent {
                hudParent.addSubview(editCapsule, positioned: .above, relativeTo: nil)
            }
            editCapsule.translatesAutoresizingMaskIntoConstraints = false
            editCapsuleConstraints = [
                editCapsule.centerXAnchor.constraint(equalTo: centerXAnchor),
                editCapsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            ]
            NSLayoutConstraint.activate(editCapsuleConstraints)
            applySurfaceLook(editCapsule)
            setPanelVisibleImmediate(.toolbar, visible: false)
        } else {
            editCapsule.removeFromSuperview()
        }
        applyEditChromeState(editModeController.chromeState)
    }

    private func applyEditChromeState(_ state: EditChromeState) {
        editToolbarController.apply(state)
        editCapsule.apply(state)
        editRail.setActiveTool(isEditModeActive ? state.tool : nil)
        onEditSubtitleChanged?(isEditModeActive ? state : nil)
        updateHistogramVisibility(animated: true)
    }

    /// Tear down edit-mode chrome. Called by the controller's exit
    /// callback after the user accepts or discards.
    /// Puts the crop frame on the displayed image
    /// rect (overlay coordinates, top-left origin). The overlay is pinned
    /// to the canvas, so the image rect only needs a flip.
    func syncCropOverlayFrame() {
        guard isEditModeActive else { return }
        let overlay = editModeController.cropOverlay
        let shown = imageView.drawnImageRect
        guard shown.width > 0, shown.height > 0 else { return }
        let flipped = CGRect(x: shown.minX, y: imageView.bounds.height - shown.maxY,
                             width: shown.width, height: shown.height)
        overlay.imageFrame = flipped
    }

    public override func layout() {
        layoutPassesForTesting &+= 1
        onLayoutForTesting?()
        Self.onAnyLayoutForTesting?()
        super.layout()
        layoutWindowedRail()
        layoutFullscreenRail()
        applyFitInsets()
        if isEditModeActive { syncCropOverlayFrame() }
        livePhotoPlayback?.updateFrame()
        layoutLiveBadge()
        updateHistogramForCanvasSize()
        // The first layout sets the texture size.
        if requestedTextureLongEdge == nil { updateTextureLongEdge() }
        refreshWindowedRail()
    }

    /// Layout passes so far (none inside the window's init).
    internal var layoutPassesForTesting = 0
    internal var onLayoutForTesting: (() -> Void)?
    nonisolated(unsafe) static var onAnyLayoutForTesting: (() -> Void)?

    // MARK: - Fit area

    /// Room kept around the photo in edit mode so every crop handle
    /// (10 pt square + 6 pt hit slop) is on screen and clickable.
    static let editHandleMargin: CGFloat = 16
    /// Gap between the titlebar / toolbar and the LIVE badge.
    static let liveBadgeChromeGap: CGFloat = 12
    /// The LIVE badge's inset from the photo's top-left corner.
    static let liveBadgeInset: CGFloat = 20

    /// The LIVE badge sits at
    /// the top-left of the photo as drawn (of its visible part when zoomed
    /// in), inset `liveBadgeInset`. The constraints keep it at least
    /// `liveBadgeChromeGap` below the safe area (titlebar, toolbar, notch).
    /// Where it shares rows with a shown edit rail it moves
    /// right of it. Runs on layout (resize, full screen), zoom, pan, a
    /// view turn and a new photo; nothing while the badge is hidden.
    func layoutLiveBadge() {
        guard !livePhotoBadge.isHidden,
              let leading = liveBadgeLeading, let top = liveBadgeTopPreferred else { return }
        let canvas = imageView.frame
        guard canvas.width > 0, canvas.height > 0 else { return }
        var photo = convert(imageView.drawnImageRect, from: imageView).intersection(canvas)
        if photo.isNull || photo.width < 1 || photo.height < 1 { photo = canvas }
        let inset = Self.liveBadgeInset
        var x = photo.minX + inset
        // Distance from this view's top (y down), as the top constraint.
        let preferredTop = (bounds.maxY - photo.maxY) + inset
        if isEditRailShown {
            let height = livePhotoBadge.frame.height > 0
                ? livePhotoBadge.frame.height : livePhotoBadge.fittingSize.height
            let badgeTop = max(preferredTop, inset, safeAreaInsets.top + Self.liveBadgeChromeGap)
            let gap = Self.liveBadgeChromeGap
            let band = NSRect(x: bounds.minX, y: bounds.maxY - badgeTop - height - gap,
                              width: bounds.width, height: height + 2 * gap)
            let rail = railFrameInSelf
            if rail.width < 1 || rail.height < 1 {
                // Not laid out yet: 16 pt from the left, 56 wide.
                x = max(x, bounds.minX + 16 + 56 + gap)
            } else if rail.intersects(band) {
                x = max(x, rail.maxX + gap)
            }
        }
        x = x.rounded()
        let y = preferredTop.rounded()
        if abs(leading.constant - x) > 0.25 { leading.constant = x }
        if abs(top.constant - y) > 0.25 { top.constant = y }
    }

    /// The part of the canvas the photo fits in.
    /// Edit mode: clear of the side panel, a shown rail and the
    /// full-screen capsule, with the handle margin on every side. At rest
    /// in a window with auto-hide off: below the titlebar/toolbar
    /// (`contentLayoutRect`). Otherwise the whole canvas.
    func currentFitInsets() -> NSEdgeInsets {
        let iv = imageView.frame
        guard iv.width > 0, iv.height > 0 else { return NSEdgeInsets() }
        if isEditModeActive {
            let m = Self.editHandleMargin
            var e = NSEdgeInsets(top: m, left: m, bottom: m, right: m)
            let panel = editModeController.parameterPanel
            if panel.superview === self, !panel.isHidden {
                e.right += max(0, iv.maxX - panel.frame.minX)
            }
            if isEditRailShown {
                e.left += max(0, editRail.frame.maxX - iv.minX)
            }
            if editCapsule.superview != nil, !editCapsule.isHidden {
                e.bottom += max(0, editCapsule.frame.maxY - iv.minY)
            }
            return e
        }
        return NSEdgeInsets(top: restTopInset(), left: 0, bottom: 0, right: 0)
    }

    /// Auto-hide off (or its titlebar lookup failed): the titlebar never
    /// hides, so the photo fits below it.
    private func restTopInset() -> CGFloat {
        guard windowMode == .windowed, let window = window as? ViewerWindow,
              !window.styleMask.contains(.fullScreen) else { return 0 }
        let autoHides = window.autoHider?.isActive ?? Prefs.viewerToolbarAutoHide
        guard !autoHides else { return 0 }
        let top = convert(imageView.frame, to: nil).maxY
        return max(0, top - window.contentLayoutRect.maxY)
    }

    private func applyFitInsets() {
        let insets = currentFitInsets()
        if !NSEdgeInsetsEqual(imageView.fitInsets, insets) { imageView.fitInsets = insets }
    }

    public func exitEditMode(restoreImage: Bool = true) {
        guard isEditModeActive else { return }
        isEditModeActive = false
        editRail.setActiveTool(nil)
        imageView.fileDragEnabled = true
        applyFitInsets()   // the rest fit area before the photo comes back
        if restoreImage, let (image, sourceID) = imageBeforeEdit {
            imageView.setImage(image, sourceID: sourceID)
            histogram.imageShown(image, url: histogramURL)
        }
        imageBeforeEdit = nil

        NSLayoutConstraint.deactivate(editPanelConstraints)
        NSLayoutConstraint.deactivate(editOverlayConstraints)
        editPanelConstraints = []
        editOverlayConstraints = []

        editModeController.parameterPanel.removeFromSuperview()
        editModeController.cropOverlay.removeFromSuperview()
        installEditChrome()
        needsLayout = true

        // The strip comes back per the setting, and the
        // photo frame equals the one before entry.
        applyWindowedFilmstripDock()
        if windowMode == .fullscreen { updatePanelVisibility() }
        updateHistogramVisibility(animated: true)
    }

    /// A window's docked filmstrip shows when the setting
    /// is on and edit mode is off; the canvas (and the pill) bind to it,
    /// otherwise to the window's bottom.
    private func applyWindowedFilmstripDock() {
        guard windowMode == .windowed else { return }
        let docked = Prefs.filmstripVisibleInWindowed && !isEditModeActive
        imageViewWindowedBottomConstraint?.isActive = false
        imageViewFullscreenBottomConstraint?.isActive = false
        navOverlayBottomToFilmstrip?.isActive = false
        navOverlayBottomToPanel?.isActive = false
        if docked {
            imageViewWindowedBottomConstraint?.isActive = true
            filmstrip.isHidden = false
            filmstrip.alphaValue = 1
            // Position overlay anchors 8 pt above the filmstrip so it
            // never overlaps the docked strip.
            navOverlayBottomToFilmstrip?.isActive = true
            histogramBottomToImage?.constant = -HUDGlass.gap
        } else {
            imageViewFullscreenBottomConstraint?.isActive = true
            filmstrip.isHidden = true
            filmstrip.alphaValue = 0
            navOverlayBottomToPanel?.isActive = true
            histogramBottomToImage?.constant = -HUDGlass.windowInset
        }
        needsLayout = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewerContentView is programmatic only.")
    }

    public override var acceptsFirstResponder: Bool { true }
    public override var isFlipped: Bool { false }
    public override var isOpaque: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        true
    }

    // MARK: - Setup

    private func setupSubviews() {
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        // Top + trailing are anchored unconditionally; the bottom + leading
        // edges are swapped by `configureForMode` (leading depends on
        // whether the docked edit rail is visible in windowed mode).
        imageViewLeadingToSelf =
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor)
        imageViewTopToSelf = imageView.topAnchor.constraint(equalTo: topAnchor)
        NSLayoutConstraint.activate([
            imageViewTopToSelf!,
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageViewLeadingToSelf!,
        ])
        imageView.delegate = self

        // Canvas dim — covers imageView.
        canvasDim.translatesAutoresizingMaskIntoConstraints = false
        canvasDim.wantsLayer = true
        canvasDim.layer?.backgroundColor = NSColor.black.cgColor
        canvasDim.layer?.opacity = 0
        canvasDim.isHidden = true
        addSubview(canvasDim)
        NSLayoutConstraint.activate([
            canvasDim.topAnchor.constraint(equalTo: imageView.topAnchor),
            canvasDim.bottomAnchor.constraint(equalTo: imageView.bottomAnchor),
            canvasDim.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            canvasDim.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
        ])

        // Chrome panels — added in z-order: filmstrip < toolbar < editRail
        // < inspector. Their layout is configured per-mode by
        // `configureForMode`. In both modes they live in the view tree;
        // the fullscreen overlays are hidden until hover, and the
        // windowed filmstrip is gated by `Prefs.filmstripVisibleInWindowed`.

        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.alphaValue = 0
        filmstrip.isHidden = true
        addSubview(filmstrip)

        // The capsule (between the filmstrip and the edit rail) is built
        // on first use: `installCapsule`.

        editRail.translatesAutoresizingMaskIntoConstraints = false
        editRail.alphaValue = 0
        editRail.isHidden = true
        addSubview(editRail)
        // Constraints are installed/activated per-mode in `configureForMode`
        // so the fullscreen floating overlay (60 pt wide — 40 content + 20
        // pin strip) and the windowed docked rail (40 pt wide, pin strip
        // hidden, full height) can coexist without fighting.

        inspector.translatesAutoresizingMaskIntoConstraints = false
        inspector.alphaValue = 0
        inspector.isHidden = true
        addSubview(inspector)
        let inspectorTrailing = inspector.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16)
        self.inspectorTrailing = inspectorTrailing
        // "<=": the inspector is as tall as its content (its own weak
        // height), never lower than the limit.
        let inspectorBottom = inspector.bottomAnchor.constraint(
            lessThanOrEqualTo: bottomAnchor, constant: -HUDGlass.edgeInset)
        inspectorBottomToSelf = inspectorBottom
        inspectorBottomToFilmstrip = inspector.bottomAnchor.constraint(
            lessThanOrEqualTo: filmstrip.topAnchor, constant: -HUDGlass.gap)
        NSLayoutConstraint.activate([
            inspectorTrailing,
            inspector.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor,
                                           constant: HUDGlass.edgeInset),
            inspectorBottom,
            inspector.widthAnchor.constraint(equalToConstant: 280),
        ])

        // Zoom badge.
        zoomBadge.translatesAutoresizingMaskIntoConstraints = false
        zoomBadge.alphaValue = 0
        addSubview(zoomBadge)
        NSLayoutConstraint.activate([
            zoomBadge.centerXAnchor.constraint(equalTo: centerXAnchor),
            zoomBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -96),
        ])

        // Histogram overlay: built on its first show (`installHistogramOverlay`).

        // Loupe.
        loupeView.translatesAutoresizingMaskIntoConstraints = true
        loupeView.isHidden = true
        addSubview(loupeView)

        // Toast.
        toastHost.install(in: self)

        // Page indicator.
        pageIndicator.translatesAutoresizingMaskIntoConstraints = false
        pageIndicator.alphaValue = 0
        addSubview(pageIndicator)
        NSLayoutConstraint.activate([
            pageIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            pageIndicator.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])

        // LIVE badge.
        livePhotoBadge.translatesAutoresizingMaskIntoConstraints = false
        livePhotoBadge.isHidden = true
        livePhotoBadge.onPlay = { [weak self] withSound, fromHover in
            self?.playLivePhoto(withSound: withSound, fromHover: fromHover)
        }
        addSubview(livePhotoBadge)
        // Below the titlebar and toolbar. The safe
        // area ends under them in a window (shown or hidden toolbar, even
        // while auto-hide fades the titlebar out), and at the notch in
        // full screen; the badge keeps 20 pt from the top where the safe
        // area starts higher. Its hover area is its own frame.
        // The preferred top and the leading edge follow the
        // photo's top-left corner (`layoutLiveBadge`).
        let badgeBelowChrome = livePhotoBadge.topAnchor.constraint(
            greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: Self.liveBadgeChromeGap)
        let badgeTopFloor = livePhotoBadge.topAnchor.constraint(
            greaterThanOrEqualTo: topAnchor, constant: Self.liveBadgeInset)
        let badgeTopPreferred = livePhotoBadge.topAnchor.constraint(
            equalTo: topAnchor, constant: Self.liveBadgeInset)
        badgeTopPreferred.priority = .defaultLow
        let badgeLeading = livePhotoBadge.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: Self.liveBadgeInset)
        liveBadgeLeading = badgeLeading
        liveBadgeTopPreferred = badgeTopPreferred
        NSLayoutConstraint.activate([
            badgeLeading, badgeBelowChrome, badgeTopFloor, badgeTopPreferred,
        ])

        // Navigation position overlay. Bottom anchor flips per-mode so it
        // never overlaps the docked filmstrip in windowed mode. Default (fullscreen) is a fixed 72 pt inset from
        // the panel bottom; windowed with filmstrip docked pins it 8 pt
        // above the filmstrip.
        navPositionOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(navPositionOverlay)
        navOverlayBottomToPanel =
            navPositionOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -72)
        // This ViewerContentView uses AppKit's default (non-flipped) layout
        // semantics for its subviews, so a bottomAnchor-to-topAnchor
        // constraint with a NEGATIVE constant places the overlay ABOVE the
        // filmstrip (i.e. 8 pt of clearance between overlay.bottom and
        // filmstrip.top). A positive constant would push it INTO the strip.
        navOverlayBottomToFilmstrip =
            navPositionOverlay.bottomAnchor.constraint(equalTo: filmstrip.topAnchor, constant: -HUDGlass.gap)
        navOverlayLeading = navPositionOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        NSLayoutConstraint.activate([
            navOverlayLeading!,
            navOverlayBottomToPanel!,
            // Max 60 % of the window: the file
            // name truncates, the marks stay whole.
            navPositionOverlay.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
        ])

        // PREVIEW badge.
        previewBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewBadge)
        NSLayoutConstraint.activate([
            previewBadge.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -16
            ),
            previewBadge.bottomAnchor.constraint(
                equalTo: bottomAnchor,
                constant: -16
            ),
        ])

        // Error overlay — LAST so it wins the sibling z-order.
        errorOverlay.translatesAutoresizingMaskIntoConstraints = false
        errorOverlay.isHidden = true
        addSubview(errorOverlay)
        NSLayoutConstraint.activate([
            errorOverlay.topAnchor.constraint(equalTo: topAnchor),
            errorOverlay.bottomAnchor.constraint(equalTo: bottomAnchor),
            errorOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            errorOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Prepare per-mode constraint sets. `configureForMode` activates
        // whichever set matches `windowMode`.
        buildFilmstripConstraints()
        buildEditRailConstraints()

        // Live pref observation — issues #4 (position overlay auto-hide)
        // and the windowed edit-rail visibility need to respond the
        // moment Prefs flips, not on the next mode switch.
        prefsObservationBox.token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.onPrefsChanged()
            }
        }
    }

    deinit {
        // `prefsObservationBox` is a final class whose only job is to
        // strong-ref the token and unregister it on deallocation —
        // keeping deinit MainActor-free under Swift 6 strict concurrency.
    }

    private func onPrefsChanged() {
        // Bugfix #4 — position overlay's auto-hide flag must
        // respond to UserDefaults flips immediately, not on next
        // show/hide. The overlay now reads the pref each time; this hook
        // gives it a chance to cancel a pending fade or schedule a new
        // one when the pref toggles mid-session.
        navPositionOverlay.autoHidesPrefDidChange()
        applyCanvasColour()
        let edge = Prefs.maxDisplayLongEdge
        if edge != lastMaxLongEdge {
            lastMaxLongEdge = edge
            updateTextureLongEdge()
        }
        // Windowed edit-rail docked visibility is read inside
        // `configureForMode`, so only re-run layout if something that
        // affects it has changed. Cheap enough to run unconditionally in
        // windowed mode since it's a no-op when nothing moved.
        if windowMode == .windowed {
            configureForMode()
        }
    }

    private func buildFilmstripConstraints() {
        // Windowed: docked strip BELOW the canvas. Height comes from
        // Prefs.filmstripHeightPt. Takes real estate from the canvas by
        // pinning imageView.bottom to filmstrip.top.
        let heightConstant = CGFloat(Prefs.filmstripHeightPt)
        let height = filmstrip.heightAnchor.constraint(equalToConstant: heightConstant)
        self.filmstripHeightConstraint = height

        // Filmstrip leading can be either the panel's leading or the edit
        // rail's trailing (in windowed mode with the rail
        // docked, the filmstrip starts past the rail so the rail isn't
        // overlaid by thumbs). Both constraints pre-built; `configureForMode`
        // activates one.
        filmstripLeadingToSelf =
            filmstrip.leadingAnchor.constraint(equalTo: leadingAnchor)
        filmstripLeadingToEditRail =
            filmstrip.leadingAnchor.constraint(equalTo: editRail.trailingAnchor)

        filmstripWindowedConstraints = [
            filmstrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            height,
        ]
        imageViewWindowedBottomConstraint =
            imageView.bottomAnchor.constraint(equalTo: filmstrip.topAnchor)

        // Fullscreen: docked at the BOTTOM edge, 88 pt,
        // full width, over the canvas (the image never moves).
        filmstripFullscreenConstraints = [
            filmstrip.bottomAnchor.constraint(equalTo: bottomAnchor),
            filmstrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            // Distinct constant; 88 pt per spec. Kept as its own constraint
            // so we can reuse `filmstripHeightConstraint` for the windowed
            // mode alone.
            filmstrip.heightAnchor.constraint(equalToConstant: Self.fullscreenFilmstripHeight),
        ]
        imageViewFullscreenBottomConstraint =
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
    }

    private func buildEditRailConstraints() {
        // Rail total width is 56 pt in both modes
        // (windowed and fullscreen). The earlier split (60 pt fullscreen
        // / 40 pt windowed) is gone; the old 20 pt pin strip is gone and
        // the pin glyph lives in a PinCornerOverlay at top-right.
        let wFull = editRail.widthAnchor.constraint(
            equalToConstant: EditRail.totalWidth
        )
        editRailWidthFullscreen = wFull
        editRailFullscreenConstraints = [
            editRail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            editRail.centerYAnchor.constraint(equalTo: centerYAnchor),
            wFull,
        ]

        // Windowed: docked full-height at the leading edge.
        // Rail extends floor-to-ceiling, filmstrip starts
        // past the rail's trailing edge.
        let wDock = editRail.widthAnchor.constraint(
            equalToConstant: EditRail.totalWidth
        )
        editRailWidthWindowed = wDock
        editRailWindowedConstraints = [
            editRail.leadingAnchor.constraint(equalTo: leadingAnchor),
            editRail.topAnchor.constraint(equalTo: topAnchor),
            editRail.bottomAnchor.constraint(equalTo: bottomAnchor),
            wDock,
        ]

        imageViewLeadingToEditRail =
            imageView.leadingAnchor.constraint(equalTo: editRail.trailingAnchor)
    }

    private func configureForMode() {
        defer { applyCanvasColour() }
        // Glass in full screen on macOS 26 (built on each
        // surface's first reveal), the HUD material otherwise. The looks
        // switch at the end, once the panels have their new visibility, so
        // a panel that hides on the way in builds no glass.
        if windowMode == .fullscreen { installGlassContainerIfNeeded() }
        applyGlassGeometry()
        // Tear down whichever set is active.
        NSLayoutConstraint.deactivate(filmstripWindowedConstraints)
        NSLayoutConstraint.deactivate(filmstripFullscreenConstraints)
        NSLayoutConstraint.deactivate(editRailFullscreenConstraints)
        NSLayoutConstraint.deactivate(editRailWindowedConstraints)
        imageViewWindowedBottomConstraint?.isActive = false
        imageViewFullscreenBottomConstraint?.isActive = false
        imageViewLeadingToEditRail?.isActive = false
        filmstripLeadingToSelf?.isActive = false
        filmstripLeadingToEditRail?.isActive = false
        navOverlayBottomToPanel?.isActive = false
        navOverlayBottomToFilmstrip?.isActive = false
        histogramBottomToSelf?.isActive = windowMode == .fullscreen
        histogramBottomToImage?.isActive = windowMode == .windowed

        switch windowMode {
        case .windowed:
            filmstrip.setMode(.windowed)
            let pt = CGFloat(Prefs.filmstripHeightPt)
            filmstripHeightConstraint?.constant = pt
            // Interior cell size = total height minus top+bottom insets (4 each).
            filmstrip.setCellSize(max(48, pt - 8))
            NSLayoutConstraint.activate(filmstripWindowedConstraints)

            // Edit rail: floats over the canvas (leading
            // 16 pt, vertically centred, 56 pt wide). In a window it shows
            // only when View › Show Edit Rail is on; no hover reveal and
            // no pin glyph.
            NSLayoutConstraint.activate(editRailFullscreenConstraints)
            // The window tint is the label colour, not the full-screen white at 85 %.
            editRail.applyAppearance(.windowed)
            editRail.setPinGlyphHidden(true)
            imageViewLeadingToSelf?.isActive = true
            filmstripLeadingToSelf?.isActive = true

            // Canvas bottom binds to filmstrip when the strip is docked,
            // otherwise it fills the window (never docked in edit mode).
            applyWindowedFilmstripDock()

            // Toolbar + inspector remain hidden in windowed mode — they're
            // surfaced via NSToolbar / Inspector shortcut, not edge-hover.
            hoveredPanels.removeAll()
            cancelAllPanelExitGrace()
            cancelAllZoneRest()
            navOverlayLeading?.constant = HUDGlass.windowInset
            navOverlayBottomToPanel?.constant = -HUDGlass.windowInset
            navOverlayMaxWidth?.constant = 10_000
            toolbarBottomToFilmstrip?.isActive = false
            toolbarBottomToSelf?.isActive = true
            // The rail waits for the first frame, and fits
            // its band (labelled, compact, or none).
            layoutWindowedRail()
            let railTarget = windowedRailTarget()
            railAppliedTarget = railTarget
            setPanelVisibleImmediate(.editRail, visible: railTarget)
            if railTarget { noteRailShown() }
            for panel in [PanelKind.toolbar, .inspector] {
                setPanelVisibleImmediate(panel, visible: false)
            }

        case .fullscreen:
            filmstrip.setMode(.fullscreen)
            // Fullscreen cell size is driven by the filmstrip's own
            // `applyMode()`. 88 pt total / 72 pt cells / 8 pt
            // top + bottom insets now that the 20 pt pin strip is gone.
            NSLayoutConstraint.activate(filmstripFullscreenConstraints)
            imageViewFullscreenBottomConstraint?.isActive = true
            imageViewLeadingToSelf?.isActive = true
            filmstripLeadingToSelf?.isActive = true

            // Edit rail fullscreen form — 56 pt floating
            // overlay with the pin glyph in its top-right corner.
            NSLayoutConstraint.activate(editRailFullscreenConstraints)
            editRail.applyAppearance(.fullscreenHUD)
            editRail.setPinGlyphHidden(false)
            // Full screen keeps the labelled rail, centred.
            editRail.setCompact(false)
            editRail.setToolsEnabled(true)
            railAppliedTarget = nil
            if editRailFullscreenConstraints.count > 1 { editRailFullscreenConstraints[1].constant = 0 }
            fullscreenRowBottom = HUDGlass.windowInset

            // Position overlay: bottom-left, moves with the bottom stack
            navOverlayBottomToPanel?.isActive = true

            // All panels start hidden; edge hover (or pin) reveals.
            for panel in PanelKind.allCases {
                setPanelVisibleImmediate(panel, visible: fullscreenTarget(panel))
            }
            placeBottomStack(animated: false)
        }

        for surface in hudSurfaces { applySurfaceLook(surface) }
        needsLayout = true
        positionHistogram(animated: false)
        updateHistogramVisibility(animated: false)
    }

    // MARK: - Glass

    /// Every HUD surface that exists now.
    private var hudSurfaces: [HUDSurfaceView] {
        var out: [HUDSurfaceView] = [filmstrip, editRail, inspector, zoomBadge,
                                     toastHost, navPositionOverlay]
        if let capsule = capsuleStorage { out.append(capsule) }
        if let histogram = histogramStorage { out.append(histogram) }
        return out
    }

    /// Glass in full screen (on its next reveal), the HUD material in a
    /// window; the Increase Contrast border follows the mode.
    private func applySurfaceLook(_ surface: HUDSurfaceView) {
        let fullScreen = windowMode == .fullscreen
        surface.isFullScreenHUD = fullScreen
        surface.setGlassLook(fullScreen)
    }

    /// One glass container per full-screen viewer, the
    /// root of the HUD overlay. Built at the first full screen (never on
    /// the first-pixel path: a viewer opens in a window); the HUDs from
    /// the filmstrip up to the pill move into it once, in order, with
    /// their constraints. It holds no glass until a HUD shows.
    private func installGlassContainerIfNeeded() {
        guard glassContainerStorage == nil, HUDGlass.isAvailable else { return }
        guard #available(macOS 26, *) else { return }
        guard let lo = subviews.firstIndex(of: filmstrip),
              let hi = subviews.firstIndex(of: navPositionOverlay), lo <= hi else { return }
        let signpost = ShrikeSignposts.navigation.begin("glassContainer")
        defer { ShrikeSignposts.navigation.end("glassContainer", signpost) }
        let moving = Array(subviews[lo...hi])
        let kept = HUDReparenting.crossingConstraints(of: moving)
        let container = HUDGlassContainerView(frame: bounds)
        container.autoresizingMask = [.width, .height]
        addSubview(container, positioned: .below, relativeTo: filmstrip)
        for view in moving { container.content.addSubview(view) }
        NSLayoutConstraint.activate(kept)
        glassContainerStorage = container
        glassContentStorage = container.content
    }

    /// In full screen on macOS 26 the rail, inspector and
    /// filmstrip float 12 pt from the screen edges (the filmstrip on
    /// three sides); elsewhere they sit as before.
    private func applyGlassGeometry() {
        let glass = usesGlassGeometry
        let inset: CGFloat = glass ? HUDGlass.edgeInset : 0
        if filmstripFullscreenConstraints.count >= 2 {
            filmstripFullscreenConstraints[0].constant = -inset   // bottom
            filmstripFullscreenConstraints[1].constant = -inset   // trailing
        }
        filmstripLeadingToSelf?.constant = windowMode == .fullscreen ? inset : 0
        // 16 pt from the canvas edge in a window.
        editRailFullscreenConstraints.first?.constant = glass && windowMode == .fullscreen ? HUDGlass.edgeInset : 16
        inspectorTrailing?.constant = glass ? -HUDGlass.edgeInset : -16
    }

    /// Subviews bottom to top, with the glass container's HUDs in its place.
    private var flatSubviews: [NSView] {
        subviews.flatMap { view -> [NSView] in
            if view === glassContainerStorage, let content = glassContentStorage {
                return content.subviews
            }
            return [view]
        }
    }

    private func wirePanelCallbacks() {
        filmstrip.onSelectGlobal = { [weak self] globalIndex in
            self?.onFilmstripJump?(globalIndex)
            self?.kickIdleTimer()
        }
        filmstrip.onScrollScrub = { [weak self] delta in
            self?.onFilmstripScrub?(delta)
            self?.kickIdleTimer()
        }
        filmstrip.actionDispatcher = { [weak self] action in
            self?.actionDispatcher?(action)
        }
        filmstrip.onTogglePin = { [weak self] in
            self?.togglePanel(.filmstrip)
        }

        editRail.actionDispatcher = { [weak self] action in
            self?.actionDispatcher?(action)
        }
        editRail.onTogglePin = { [weak self] in
            self?.togglePanel(.editRail)
        }

        inspector.onTogglePin = { [weak self] in
            self?.togglePanel(.inspector)
        }
    }

    private func syncPinGlyphs() {
        filmstrip.setPinned(pinnedPanels.contains(.filmstrip))
        editRail.setPinned(pinnedPanels.contains(.editRail))
        inspector.setPinned(pinnedPanels.contains(.inspector))
    }

    private func setupTracking() {
        let opts: NSTrackingArea.Options = [
            .activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let opts: NSTrackingArea.Options = [
            .activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: bounds, options: opts, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Public API

    /// Every zoom change (the window asks for the full-resolution
    /// texture past the display texture).
    var onZoomChanged: (() -> Void)?

    public func setImage(
        _ image: CGImage, index: Int, total: Int,
        sourceID: String? = nil, prepared: DisplayTexture? = nil
    ) {
        errorOverlay.isHidden = true
        imageView.setImage(image, sourceID: sourceID, prepared: prepared)
        histogram.markStale()
        layoutLiveBadge()
        inspector.updatePlaceholder(index: index, total: total, image: image)
        filmstrip.updateSelection(index)
        // No zoom HUD on a photo change: only a zoom the user makes shows
        // it.
        previewBadge.hide()
        pageIndicator.hideAnimated()
    }

    /// Surface the filmstrip selection immediately on `beginNavigation()`,
    /// independently of decode completion: the selection follows
    /// generations, not paints.
    public func updateFilmstripSelectionOnIntent(_ index: Int) {
        filmstrip.updateSelection(index)
    }

    /// The empty state ("No more images", folder
    /// gone) shows no position pill, filmstrip, histogram or preview badge.
    /// `false` gives each one back the state its own code asked for.
    public func setEmptyStateChrome(_ empty: Bool) {
        navPositionOverlay.isSuppressed = empty
        filmstrip.isSuppressed = empty
        histogramSuppressed = empty
        histogramStorage?.isSuppressed = empty
        previewBadge.isSuppressed = empty
        guard empty else { return }
        navPositionOverlay.completeHairline()
        clearCanvasDim()
        errorOverlay.isHidden = true
        histogram.reset()
    }

    /// Test seam: what the empty state hides.
    var emptyStateChromeHiddenForTesting: (pill: Bool, filmstrip: Bool, histogram: Bool, badge: Bool) {
        (navPositionOverlay.isHidden, filmstrip.isHidden, histogramStorage?.isHidden ?? true, previewBadge.isHidden)
    }

    /// The window closed: let go of every image and texture now,
    /// even if something still references this view.
    public func releaseImages() {
        releaseLivePhoto()
        histogram.reset()
        loupeView.sourceImage = nil
        imageView.releaseResources()
    }

    public func setPlaceholderImage(_ image: CGImage, sourceID: String? = nil) {
        errorOverlay.isHidden = true
        imageView.setPlaceholderImage(image, sourceID: sourceID)
        histogram.markStale()
        layoutLiveBadge()
    }

    public func showNavigationPosition(index: Int, total: Int, filename: String?) {
        navPositionOverlay.show(index: index, total: total, filename: filename)
    }

    /// Rating / flag / RAW marks in the position pill.
    /// `flash` shows an auto-hidden pill for 1.5 s.
    public func setPositionMarks(_ marks: PillMarks, flash: Bool = false) {
        navPositionOverlay.marks = marks
        inspector.updateMarks(marks)
        if flash { navPositionOverlay.flashMarks() }
    }

    public func setPositionOverlayAutoHides(_ autoHides: Bool) {
        navPositionOverlay.autoHides = autoHides
    }

    public func scheduleHairlineIndicator(predicted: TimeInterval) {
        navPositionOverlay.scheduleHairlineShow(predicted: predicted)
    }

    public func showHairlineIndicatorImmediately(predicted: TimeInterval) {
        navPositionOverlay.setHairlineProgress(predicted: predicted)
    }

    public func completeHairlineIndicator() {
        navPositionOverlay.completeHairline()
    }

    public func flashPositionOverlayError() {
        navPositionOverlay.flashError()
    }

    public func applyCanvasDim() {
        guard let dimLayer = canvasDim.layer else { return }
        if !canvasDim.isHidden && dimLayer.opacity >= 0.29 {
            return
        }
        dimScheduler.scheduleApply()
    }

    private func performCanvasDimApply() {
        guard let dimLayer = canvasDim.layer else { return }
        if !canvasDim.isHidden && dimLayer.opacity >= 0.29 {
            return
        }
        canvasDim.isHidden = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.opacity = 0.30
        CATransaction.commit()
    }

    public func clearCanvasDim() {
        dimScheduler.cancel()

        guard let dimLayer = canvasDim.layer else { return }
        if canvasDim.isHidden || dimLayer.opacity == 0 {
            return
        }
        if reducesMotion {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            dimLayer.opacity = 0
            CATransaction.commit()
            canvasDim.isHidden = true
            return
        }
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = dimLayer.opacity
        anim.toValue = 0
        anim.duration = 0.120
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let l = self.canvasDim.layer, l.opacity == 0 {
                    self.canvasDim.isHidden = true
                }
            }
        }
        dimLayer.add(anim, forKey: "shrike.canvasDim.fadeOut")
        dimLayer.opacity = 0
        CATransaction.commit()
    }

    /// Surface the system share sheet anchored on the
    /// toolbar's share button. Called from `ViewerWindow.dispatch(.share)`.
    /// Requires the view to be mounted in a window (needed for picker
    /// positioning). In windowed mode the toolbar isn't visible so the
    /// picker anchors to the share button's eventual hidden location —
    /// callers should route to an NSToolbar item in windowed mode if they
    /// want a visible anchor, but the picker itself still works.
    public func showShare(url: URL) {
        guard let window else { return }
        toolbar.showShare(from: window, url: url)
    }

    public func showPreviewBadge() {
        previewBadge.show()
    }

    public func hidePreviewBadge() {
        previewBadge.hide()
    }

    public func setCurrentURL(_ url: URL?) {
        inspector.updateForURL(url)
        imageView.dragSourceURL = url
    }

    // MARK: - Live Photo playback

    /// The displayed photo's movie (`ImageGroup.livePhotoMovie`).
    private(set) var livePhotoMovie: URL?
    /// The movie failed to load: the badge stays hidden for this photo.
    private var livePhotoFailed = false
    /// Made at the first play; freed on navigation and close.
    private(set) var livePhotoPlayback: LivePhotoPlayback?
    /// Test seam: stands in for the system Reduce Motion setting.
    internal var reduceMotionOverrideForTesting: Bool?

    /// Reduce Motion, read each time from the shared source.
    private var reducesMotion: Bool {
        reduceMotionOverrideForTesting ?? ReduceMotion.isOn
    }

    /// The window shows a photo: its movie, or nil. A new photo (or a new
    /// movie) stops and frees any playback; the still is back at once.
    func setLivePhotoMovie(_ url: URL?, newPhoto: Bool) {
        if newPhoto || url != livePhotoMovie {
            releaseLivePhoto()
            livePhotoFailed = false
        }
        livePhotoMovie = url
        refreshLivePhotoBadge()
    }

    private func refreshLivePhotoBadge() {
        livePhotoBadge.isHidden = livePhotoMovie == nil || livePhotoFailed
        livePhotoBadge.isDimmed = !imageView.isAtFit
        layoutLiveBadge()
    }

    /// The badge asked to play (hover, click, VoiceOver). Only at fit,
    /// never in edit mode; with Reduce Motion a hover does not play.
    func playLivePhoto(withSound: Bool, fromHover: Bool) {
        guard let url = livePhotoMovie, !livePhotoFailed, !isEditModeActive,
              imageView.image != nil, imageView.isAtFit else { return }
        if fromHover, reducesMotion { return }
        let playback: LivePhotoPlayback
        if let existing = livePhotoPlayback {
            playback = existing
        } else {
            playback = LivePhotoPlayback(host: self, above: imageView) { [weak self] in
                guard let self else { return .zero }
                return self.imageView.convert(self.imageView.drawnImageRect, to: self)
            }
            playback.onLoadFailed = { [weak self] failed in
                guard let self, failed == self.livePhotoMovie else { return }
                self.livePhotoFailed = true
                self.refreshLivePhotoBadge()
            }
            livePhotoPlayback = playback
        }
        playback.play(url, withSound: withSound)
    }

    /// Stops a playing movie at once; the still shows (key, pointer out,
    /// zoom, edit mode). Keeps the player for a replay of this photo.
    func stopLivePhoto() {
        livePhotoPlayback?.stop()
    }

    /// Stops and frees the player (navigation, window close).
    func releaseLivePhoto() {
        livePhotoPlayback?.release()
        livePhotoPlayback = nil
    }

    /// The pointer moved on the canvas: leaving the photo (and the badge)
    /// stops the movie.
    private func livePhotoPointerMoved(to point: CGPoint) {
        guard let playback = livePhotoPlayback, playback.isActive else { return }
        let photo = imageView.convert(imageView.drawnImageRect, to: self)
        if photo.contains(point) || (!livePhotoBadge.isHidden && livePhotoBadge.frame.contains(point)) { return }
        playback.stop()
    }

    var livePhotoBadgeForTesting: LivePhotoBadgeView { livePhotoBadge }
    /// The edit rail's frame in this view (it may sit in the glass host).
    internal var editRailFrameInContentForTesting: NSRect { railFrameInSelf }
    func livePhotoPointerMovedForTesting(to point: CGPoint) { livePhotoPointerMoved(to: point) }

    /// The decode-error overlay is up.
    var isShowingDecodeError: Bool { !errorOverlay.isHidden }

    public func showDecodeError() {
        errorOverlay.isHidden = false
        needsLayout = true   // the rail shows, buttons off
        histogram.showNoData()
    }

    /// Test seam — feedback-pipeline surfaces bottom→top.
    /// extends this with the four chrome panels between `canvasDim` and
    /// the nav/preview/error stack.
    internal func feedbackPipelineSubviewOrderForTesting() -> [String] {
        var out: [String] = []
        for v in flatSubviews {
            switch v {
            case imageView: out.append("imageView")
            case canvasDim: out.append("canvasDim")
            case filmstrip: out.append("filmstrip")
            case toolbar: out.append("toolbar")
            case editRail: out.append("editRail")
            case inspector: out.append("inspector")
            case navPositionOverlay: out.append("navPositionOverlay")
            case previewBadge: out.append("previewBadge")
            case errorOverlay: out.append("errorOverlay")
            default: continue
            }
        }
        return out
    }

    /// Test seam — ordering of the edit-mode surfaces relative to the
    /// image canvas and feedback pipeline. The
    /// crop overlay must paint above the canvas but *below* the position
    /// overlay so the "N of M" pill remains legible during editing.
    /// Filters to just imageView, cropOverlay, navPositionOverlay so
    /// the assertion is minimal and doesn't couple to chrome-panel
    /// sibling order (those are alpha'd to 0 or 40% in edit mode).
    internal func editModeSubviewOrderForTesting(includingChrome: Bool = false) -> [String] {
        var out: [String] = []
        for v in flatSubviews {
            if v === imageView { out.append("imageView") }
            else if v === editModeController.cropOverlay { out.append("cropOverlay") }
            else if v === navPositionOverlay { out.append("navPositionOverlay") }
            else if includingChrome, v === editRail { out.append("editRail") }
            else if includingChrome, v === filmstrip { out.append("filmstrip") }
            else if includingChrome, let h = histogramStorage, v === h { out.append("histogram") }
        }
        return out
    }

    /// Test seam — the panel's current pin state (a mirror of Prefs).
    internal func isPinnedForTesting(_ panel: PanelKind) -> Bool {
        pinnedPanels.contains(panel)
    }

    /// Test seam — the panel's current hover state.
    internal func isHoveredForTesting(_ panel: PanelKind) -> Bool {
        hoveredPanels.contains(panel)
    }

    /// Test seam — the panel view's current alpha value.
    internal func alphaForTesting(_ panel: PanelKind) -> CGFloat {
        view(for: panel).alphaValue
    }

    /// Test seam — call through to the zone evaluator with a given point.
    /// `rested: true` (the default) treats the pointer as having rested
    /// its 120 ms; pass false to see the rest timer.
    internal func evaluateZonesForTesting(at p: NSPoint, rested: Bool = true) {
        evaluateZones(at: p, restSatisfied: rested)
    }

    /// Test seam — fire the idle deadline as if the timer had expired.
    internal func forceIdleFireForTesting() {
        handleIdleExpired()
    }

    /// Test seam — fire `panel`'s exit-grace deadline as if its 200 ms
    /// `DispatchWorkItem` had reached the main queue. Mirrors the runtime
    /// path: cancel the queued work item, then run `applyExitGrace` so
    /// the test exercises the same hide decision the production timer
    /// would.
    internal func forceExitGraceFireForTesting(_ panel: PanelKind) {
        panelExitGraceWorkItems[panel]?.cancel()
        applyExitGrace(for: panel)
    }

    /// Test seam — opaque identity for `panel`'s pending exit-grace work
    /// item. Lets a regression test detect when `scheduleExitGrace` resets
    /// an existing timer on every `evaluateZones` tick (the fix for the
    /// "panels never hide if cursor jitters in the canvas" bug must keep
    /// the same work item across successive ticks while a panel is in
    /// `leavingNow`).
    internal func panelExitGraceWorkItemIdentityForTesting(
        _ panel: PanelKind
    ) -> ObjectIdentifier? {
        panelExitGraceWorkItems[panel].map(ObjectIdentifier.init)
    }

    /// Test seam — access to the filmstrip view.
    internal var filmstripForTesting: FilmstripView { filmstrip }
    /// The floating histogram, once built (nil before its first show).
    internal var histogramOverlayForTesting: NSView? { histogramStorage }

    /// Test seam: a photo's first frame is on screen (the
    /// windowed rail waits for it). Offscreen windows may never present.
    internal func simulateFirstFrameForTesting() {
        if imageView.image == nil {
            let ctx = CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(gray: 0.5, alpha: 1)
            ctx?.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
            imageView.image = ctx?.makeImage()
        }
        metalImageViewDidPresentFirstDrawable(imageView)
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
    }

    /// Test seam — access to the edit rail view.
    internal var editRailForTesting: EditRail { editRail }

    /// Test seam — access to the toolbar view.
    internal var toolbarForTesting: ViewerToolbar { toolbar }

    /// Test seam — access to the inspector view.
    internal var inspectorForTesting: InspectorPanel { inspector }
    /// The inspector panel (the window wires its row actions).
    var inspectorPanel: InspectorPanel { inspector }

    /// Test seam — access to the navigation position overlay.
    internal var navigationPositionOverlayForTesting: NavigationPositionOverlayView {
        navPositionOverlay
    }

    /// Test seam — forces a layout pass then returns the edit rail's
    /// computed frame. Used by windowed-rail tests that assert the dock
    /// spans floor-to-ceiling at 40 pt wide.
    internal func layoutAndReturnEditRailFrameForTesting() -> NSRect {
        layoutSubtreeIfNeeded()
        return editRail.frame
    }

    /// Test seam — forces a layout pass then returns the imageView frame.
    internal func layoutAndReturnImageViewFrameForTesting() -> NSRect {
        layoutSubtreeIfNeeded()
        return imageView.frame
    }

    public func updateFilmstripNeighbors(
        _ neighbors: [(idx: Int, source: any ImageSource)],
        current: Int,
        services: ShrikeServices
    ) {
        filmstrip.updateNeighbors(neighbors, current: current, services: services)
    }

    /// The group per filmstrip cell, for drag out.
    var filmstripGroups: ((Int) -> ImageGroup?)? {
        get { filmstrip.groupProvider }
        set { filmstrip.groupProvider = newValue }
    }

    /// Test seam: the drag item of the filmstrip cell at `index`.
    func filmstripDragItemForTesting(_ index: Int) -> NSPasteboardItem? { filmstrip.dragItem(for: index) }
    var filmstripDragSourceForTesting: String { filmstrip.dragSourceID }

    /// Stars + flag per filmstrip cell, keyed by list index.
    public var filmstripMarks: ((Int) -> (rating: Int, flagged: Bool))? {
        get { filmstrip.marksProvider }
        set { filmstrip.marksProvider = newValue }
    }

    /// Redraws the filmstrip's stars and flags after a rating change.
    public func refreshFilmstripMarks() {
        filmstrip.refreshMarks()
    }

    /// Test seam: the filmstrip cell's drawn marks.
    func filmstripMarksForTesting(_ index: Int) -> (rating: Int, flagged: Bool, flagDrawn: Bool, starsDrawn: Bool)? {
        layoutSubtreeIfNeeded()
        return filmstrip.cellMarksForTesting(index)
    }

    /// Visible width of the filmstrip's scrolling region in points.
    /// Returns 0 before the strip has been laid out. Used by
    /// `ViewerWindow.updateFilmstrip(centeredOn:)` to scale the neighbor
    /// radius to the actual strip width — a fixed radius left ultra-wide
    /// displays half-empty.
    public func filmstripVisibleWidth() -> CGFloat {
        filmstrip.visibleWidth()
    }

    /// Current filmstrip cell height in points. The cell's *width* is
    /// `height × aspect` clamped to `[0.5×, 1.6×]`; callers estimating
    /// how many cells fit in a given width should use `cellSize × 1.0`
    /// as the *average* expected width (the clamp band is symmetric
    /// around 1.0×).
    public func filmstripCellSize() -> CGFloat {
        filmstrip.currentCellSize()
    }

    /// Toggle a panel's pin state.
    ///
    /// In windowed mode:
    ///   * Filmstrip — "pin" maps to `Prefs.filmstripVisibleInWindowed`
    ///     (the docked-strip toggle); the `pinnedPanels` set is not
    ///     touched. Filmstrip stays a docked, pref-gated strip in
    ///     windowed mode.
    ///   * Edit rail — toggles the SHARED pin state (same
    ///     `pinnedPanels` set + `editRailPinnedFullscreen` pref used by
    ///     fullscreen). The rail
    ///     is an edge-activated overlay in both modes, and pinning
    ///     is the user's "keep this rail visible" action regardless of
    ///     mode. The pref name retains "Fullscreen" suffix for backward
    ///     compat with stored prefs.
    ///   * Toolbar / inspector — no-op (not addressable in windowed mode).
    ///
    /// In fullscreen mode every panel toggles its `*PinnedFullscreen`
    /// pref + the `pinnedPanels` set.
    public func togglePanel(_ panel: PanelKind) {
        // A shown rail changes the edit-mode fit area.
        needsLayout = true
        if windowMode == .windowed && panel == .filmstrip {
            Prefs.filmstripVisibleInWindowed.toggle()
            configureForMode()
            return
        }
        if windowMode == .windowed && (panel == .toolbar || panel == .inspector) {
            // No-op: these panels aren't addressable in windowed mode.
            return
        }
        // The capsule is never pinned.
        if panel == .toolbar { return }
        if windowMode == .windowed && panel == .editRail {
            // ⇧⌘E in a window shows or hides the rail.
            Prefs.editRailVisibleInWindowed.toggle()
            railIdleHidden = false
            updatePanelVisibility()
            return
        }

        // Any fullscreen panel — flip the pin state.
        if pinnedPanels.contains(panel) {
            pinnedPanels.remove(panel)
        } else {
            pinnedPanels.insert(panel)
        }
        persistPinState(panel)
        updatePanelVisibility()
        syncPinGlyphs()
    }

    /// The bottom of the capsule / pill row in full screen (set by
    /// `placeBottomStack`).
    private var fullscreenRowBottom: CGFloat = HUDGlass.windowInset

    /// The full-screen rail sits in the band between the
    /// top inset (below the safe area) and 12 pt over the pill, centred.
    private func layoutFullscreenRail() {
        guard windowMode == .fullscreen, editRailFullscreenConstraints.count > 1,
              bounds.height > 0 else { return }
        let pillHeight = max(28, navPositionOverlay.frame.height)
        let bottom = fullscreenRowBottom + pillHeight + HUDGlass.gap
        let top = bounds.maxY - (safeAreaInsets.top + HUDGlass.edgeInset)
        guard top > bottom else { return }
        let constant = (bounds.midY - (top + bottom) / 2).rounded()
        let centerY = editRailFullscreenConstraints[1]
        if abs(centerY.constant - constant) > 0.25 { centerY.constant = constant }
    }

    /// Place the windowed rail in its band (from 8 pt under
    /// the titlebar to 8 pt over the pill), labelled or compact, or none
    /// when even the compact rail doesn't fit.
    private func layoutWindowedRail() {
        guard windowMode == .windowed, editRailFullscreenConstraints.count > 1 else { return }
        var top = bounds.maxY
        if let window {
            // The titlebar's bottom, even while it is hidden.
            top = min(top, convert(NSPoint(x: 0, y: window.contentLayoutRect.maxY), from: nil).y)
        }
        top -= Self.railBandGap
        let pillView = navPositionOverlay
        let pill = pillView.superview.map { convert(pillView.frame, from: $0) } ?? .zero
        let bottom = (pill.height > 0 ? pill.maxY : imageView.frame.minY) + Self.railBandGap
        let band = top - bottom
        editRail.setCompact(band < EditRail.labeledHeight)
        railSqueezedOut = band < EditRail.compactHeight || imageView.frame.width < Self.railMinCanvasWidth
        // Auto Layout constants run y-down: a positive constant moves the
        // rail down from the view's centre to the band's centre.
        let constant = (bounds.midY - (top + bottom) / 2).rounded()
        let centerY = editRailFullscreenConstraints[1]
        if abs(centerY.constant - constant) > 0.25 { centerY.constant = constant }
    }

    /// The rail's frame in this view (it may sit in the glass host).
    private var railFrameInSelf: NSRect {
        editRail.superview.map { convert(editRail.frame, from: $0) } ?? editRail.frame
    }

    /// What keeps the windowed rail on screen when the
    /// pointer clock runs out.
    func railHeld() -> Bool {
        if isEditModeActive || isShowingDecodeError { return true }
        if voiceOverOverrideForTesting ?? NSWorkspace.shared.isVoiceOverEnabled { return true }
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: editRail) { return true }
        if !editRail.isHidden, let p = pointerInView(),
           railFrameInSelf.insetBy(dx: -8, dy: -8).contains(p) { return true }
        return false
    }

    /// The windowed rail shows when the setting is on,
    /// it fits, and a photo (after its first frame) or a decode error is
    /// on screen; the pointer clock fades it unless something holds it.
    func windowedRailTarget() -> Bool {
        guard Prefs.editRailVisibleInWindowed, !railSqueezedOut else { return false }
        if isEditModeActive || isShowingDecodeError { return true }
        guard hasPresentedFirstFrame, imageView.image != nil else { return false }
        return !railIdleHidden || railHeld()
    }

    private func refreshWindowedRail() {
        guard windowMode == .windowed else { return }
        editRail.setToolsEnabled(!isShowingDecodeError)
        let target = windowedRailTarget()
        guard target != railAppliedTarget else { return }
        railAppliedTarget = target
        setPanel(.editRail, visible: target)
        if target { noteRailShown() }
    }

    private func noteRailShown() {
        guard !railShownOnce else { return }
        railShownOnce = true
        onRailShownFirst?()
    }

    /// The window's pointer clock: the pointer moved.
    func railPointerMoved() {
        guard railIdleHidden else { return }
        railIdleHidden = false
        refreshWindowedRail()
    }

    /// The window's pointer clock ran out (2 s still, or 0.5 s after the
    /// pointer left the window).
    func railIdleFired() {
        guard windowMode == .windowed, !railHeld() else { return }
        railIdleHidden = true
        refreshWindowedRail()
    }

    /// View › Show Edit Rail check mark: shown in a window (the pref),
    /// pinned in full screen.
    var isEditRailShown: Bool {
        windowMode == .windowed ? Prefs.editRailVisibleInWindowed : pinnedPanels.contains(.editRail)
    }

    private func persistPinState(_ panel: PanelKind) {
        let isPinned = pinnedPanels.contains(panel)
        switch panel {
        case .filmstrip: Prefs.filmstripPinnedFullscreen = isPinned
        case .toolbar:   break   // never pinned
        case .editRail:  Prefs.editRailPinnedFullscreen = isPinned
        case .inspector: Prefs.exifPanelPinnedFullscreen = isPinned
        }
    }

    /// The histogram is
    /// 320 × 180 at most and never under 132 × 74, same 16:9 shape. Its
    /// width shrinks faster than the canvas: at most 0.36 × canvas width
    /// − 112 pt, which is 22 % of an 800 pt canvas and full size from
    /// 1200 pt. Its height is at most 30 % of the canvas's height.
    static let histogramWidthSlope: CGFloat = 0.36
    static let histogramWidthOffset: CGFloat = -112
    static let histogramCanvasHeightShare: CGFloat = 0.3
    static let histogramMinimumWidth: CGFloat = 132
    /// On a smaller canvas the floating histogram hides; the
    /// setting (and the toggle) stay on, and it comes back when the
    /// window grows.
    static let histogramMinimumCanvas = NSSize(width: 600, height: 340)

    static func histogramSizeConstraints(_ view: NSView, canvas: NSView) -> [NSLayoutConstraint] {
        let full = HistogramOverlayView.size
        let minWidth = histogramMinimumWidth
        let ratio = full.height / full.width
        let preferred = view.widthAnchor.constraint(equalToConstant: full.width)
        preferred.priority = .defaultLow
        let shareOfWidth = view.widthAnchor.constraint(
            lessThanOrEqualTo: canvas.widthAnchor, multiplier: histogramWidthSlope,
            constant: histogramWidthOffset)
        // Just under the window's stay-put priority (500): above it, a
        // small window grew to fit the floor instead of the cap giving way.
        shareOfWidth.priority = NSLayoutConstraint.Priority(490)
        let shareOfHeight = view.heightAnchor.constraint(
            lessThanOrEqualTo: canvas.heightAnchor, multiplier: histogramCanvasHeightShare)
        shareOfHeight.priority = NSLayoutConstraint.Priority(490)
        let floor = view.widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth)
        floor.priority = NSLayoutConstraint.Priority(999)
        return [
            view.widthAnchor.constraint(lessThanOrEqualToConstant: full.width),
            view.heightAnchor.constraint(equalTo: view.widthAnchor, multiplier: ratio),
            preferred, shareOfWidth, shareOfHeight, floor,
        ]
    }

    /// ⇧⌘J / ⌃H / View ▸ Show Histogram. Persisted.
    public func toggleHistogramOverlay() {
        Prefs.viewerHistogramVisible.toggle()
        updateHistogramVisibility(animated: true)
        histogram.wantedDidChange()
    }

    /// View ▸ Show Histogram check mark, the toolbar toggle and its
    /// VoiceOver value: the setting. Full screen: the floating copy stays
    /// until toggled off (no idle fade) and floats beside the inspector;
    /// the inspector's own histogram section is
    /// separate. In a window the docked inspector's section replaces it.
    var isHistogramShown: Bool { Prefs.viewerHistogramVisible }

    /// The windowed split inspector is open. Set by the window.
    private(set) var windowedInspectorShown = false

    /// Edit mode with the Crop tool: the floating histogram steps aside
    /// so it never sits on the crop frame's handles.
    /// The setting stays on; it comes back when Crop ends.
    var isCropToolActive: Bool { isEditModeActive && editModeController.currentTool == .crop }

    /// The canvas is big enough for the floating histogram.
    /// Before the first layout (no size yet) it counts as big enough.
    private var canvasFitsHistogram: Bool {
        let canvas = imageView.frame.size
        guard canvas.width > 0, canvas.height > 0 else { return true }
        return canvas.width >= Self.histogramMinimumCanvas.width
            && canvas.height >= Self.histogramMinimumCanvas.height
    }
    private var lastCanvasFitsHistogram = true

    /// Called from `layout()`: hide or bring back the histogram when the
    /// canvas crosses the minimum size.
    private func updateHistogramForCanvasSize() {
        guard canvasFitsHistogram != lastCanvasFitsHistogram else { return }
        // At once: this runs inside a layout pass (often a live resize).
        updateHistogramVisibility(animated: false)
    }

    func setWindowedInspectorShown(_ shown: Bool) {
        guard shown != windowedInspectorShown else { return }
        windowedInspectorShown = shown
        updateHistogramVisibility(animated: true)
        histogram.wantedDidChange()
    }

    /// The docked strip in a window; the pinned strip in full screen.
    var isFilmstripShown: Bool {
        windowMode == .windowed ? Prefs.filmstripVisibleInWindowed : pinnedPanels.contains(.filmstrip)
    }

    /// The full image is on screen (after `setImage`): recompute.
    func histogramImageShown(_ image: CGImage, url: URL?) {
        histogramURL = url
        histogram.imageShown(image, url: url)
    }

    /// The photo on the canvas feeds the
    /// histogram unless it already did. The ready first photo goes on the
    /// canvas before the first navigation, which fed the histogram only
    /// when it got to the end; when it was superseded (a texture-size
    /// change, a list reload) the first photo never had a histogram, and
    /// the overlay stayed away until the next photo.
    func feedHistogramIfMissing(url: URL?) {
        guard let url, histogram.lastShownURL != url,
              let image = imageView.image, !imageView.isCurrentImagePlaceholder else { return }
        histogramImageShown(image, url: url)
    }

    private func wireHistogram() {
        histogram.isWanted = { [weak self] in
            guard let self else { return false }
            return Prefs.viewerHistogramVisible || !self.inspector.isHidden
                || (self.windowMode == .windowed && self.windowedInspectorShown)
        }
        histogram.onChange = { [weak self] state in
            self?.histogramStorage?.apply(state)
            self?.inspector.updateHistogram(state)
        }
        inspector.updateHistogram(histogram.state)
    }

    /// The overlay, built now if it wasn't yet.
    private var histogramOverlay: HistogramOverlayView {
        histogramStorage ?? installHistogramOverlay()
    }

    /// Bottom-right, 16 pt in; moves with the
    /// bottom stack and the inspector; capped to the canvas.
    /// Built hidden at alpha 0 and laid out at once (no
    /// animation), so its first fade-in starts in place, never from the
    /// corner. The z-order is the header's: above the zoom badge, below
    /// the loupe.
    private func installHistogramOverlay() -> HistogramOverlayView {
        let view = HistogramOverlayView()
        histogramStorage = view
        view.translatesAutoresizingMaskIntoConstraints = false
        view.alphaValue = 0
        view.isHidden = true
        view.isSuppressed = histogramSuppressed
        hudParent.addSubview(view, positioned: .above, relativeTo: zoomBadge)
        applySurfaceLook(view)
        let trailing = view.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: histogramPlacement.trailing)
        // Below required: the edit panel's "stay clear" rule wins.
        trailing.priority = .defaultHigh
        histogramTrailing = trailing
        let toSelf = view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: histogramPlacement.bottom)
        let toImage = view.bottomAnchor.constraint(equalTo: imageView.bottomAnchor,
                                                   constant: -windowedHistogramBottomGap)
        histogramBottomToSelf = toSelf
        histogramBottomToImage = toImage
        trailing.isActive = true
        toSelf.isActive = windowMode == .fullscreen
        toImage.isActive = windowMode == .windowed
        NSLayoutConstraint.activate(Self.histogramSizeConstraints(view, canvas: imageView))
        if isEditModeActive {
            let clear = histogramClearOfEditPanel(view)
            clear.isActive = true
            editPanelConstraints.append(clear)
        }
        view.onCycleMode = { [weak self] in self?.histogram.cycleMode() }
        view.apply(histogram.state)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.layoutSubtreeIfNeeded()
        }
        return view
    }

    /// Edit mode: the overlay ends 12 pt left of the parameter panel.
    private func histogramClearOfEditPanel(_ view: HistogramOverlayView) -> NSLayoutConstraint {
        view.trailingAnchor.constraint(lessThanOrEqualTo: editModeController.parameterPanel.leadingAnchor,
                                       constant: -12)
    }

    /// Shown when toggled on; in full screen it also fades with the
    /// chrome (hidden after the idle delay, back on pointer movement).
    private func updateHistogramVisibility(animated: Bool) {
        // Windowed: the docked split inspector shows its own histogram, so
        // the floating one steps aside. Full screen: the floating one is a
        // user toggle; it stays until toggled off and sits beside the
        // inspector.
        let fits = canvasFitsHistogram
        lastCanvasFitsHistogram = fits
        let show = Prefs.viewerHistogramVisible && fits && !isCropToolActive
            && (windowMode == .windowed
                ? !windowedInspectorShown
                : true)
        // Built on the first show; never built just to stay hidden.
        guard let view = show ? histogramOverlay : histogramStorage else { return }
        // Building the overlay lays the view out, which can size the
        // canvas: decide again with the new size.
        if show, !canvasFitsHistogram {
            updateHistogramVisibility(animated: false)
            return
        }
        if show == !view.isHidden, !show || view.alphaValue == 1 { return }
        if !animated || reducesMotion || !animatesPanelFades {
            view.isHidden = !show
            view.alphaValue = show ? 1 : 0
            return
        }
        if show {
            if view.isHidden { view.alphaValue = 0; view.isHidden = false }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                view.animator().alphaValue = 1
            }
        } else if !view.isHidden {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fadeOutDuration
                view.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak view] in
                    guard let view else { return }
                    if view.alphaValue == 0 { view.isHidden = true }
                }
            })
        }
    }

    /// 16 pt from the right edge (the inspector's left
    /// edge when it shows); 12 pt above the bottom stack while it shows
    /// in full screen, else 16 pt above the bottom. Windowed: 16 pt
    /// above the docked filmstrip (the image area's bottom).
    private func positionHistogram(animated: Bool) {
        placeBottomStack(animated: animated)
    }

    /// Full screen: the capsule sits 12 pt above a
    /// showing filmstrip (else 16 pt above the bottom). The pill (left)
    /// and the histogram (right) sit 12 pt above the top of the stack
    /// while it shows, else 16 pt above the bottom; the pill starts past
    /// the rail and the histogram ends before the inspector. They move
    /// with the stack's fades (same timing). Worked out from the panels'
    /// target state, not their frames, so a fading panel never counts.
    /// Window: the histogram floats 12 pt above the docked strip, 16 pt
    /// above the canvas bottom without one.
    private var windowedHistogramBottomGap: CGFloat {
        Prefs.filmstripVisibleInWindowed && !isEditModeActive ? HUDGlass.gap : HUDGlass.windowInset
    }

    private func placeBottomStack(animated: Bool) {
        guard windowMode == .fullscreen else {
            histogramPlacement = (-16, -16)
            histogramTrailing?.constant = -16
            histogramBottomToSelf?.constant = -16
            histogramBottomToImage?.constant = -windowedHistogramBottomGap
            return
        }
        let stripShown = fullscreenTarget(.filmstrip)
        let capsuleShown = fullscreenTarget(.toolbar)
        toolbarBottomToSelf?.isActive = !stripShown
        toolbarBottomToFilmstrip?.isActive = stripShown
        inspectorBottomToSelf?.isActive = !stripShown
        inspectorBottomToFilmstrip?.isActive = stripShown
        // The HUDs float 12 pt from the screen edges; the
        // strip is 88 pt high, the capsule sits 12 pt above it.
        let stripInset = HUDGlass.edgeInset
        let panelEdge = HUDGlass.edgeInset
        let stripTop: CGFloat = stripShown ? stripInset + Self.fullscreenFilmstripHeight : 0
        // The row of the capsule and the pill: 12 pt above the strip, else
        // 16 pt above the bottom.
        let rowBottom: CGFloat = stripShown ? stripTop + Self.capsuleGapAboveFilmstrip
                                            : Self.capsuleBottomInset
        // The histogram clears the capsule: above it while it shows.
        let histogramBottom: CGFloat = capsuleShown
            ? rowBottom + Self.capsuleHeight + HUDGlass.gap : rowBottom
        let bottom: CGFloat = -histogramBottom
        let pillBottom: CGFloat = -rowBottom
        let leading: CGFloat = panelEdge
        let inspectorShown = fullscreenTarget(.inspector)
        let trailing: CGFloat = inspectorShown ? -(panelEdge + 280 + HUDGlass.gap) : -panelEdge
        // The pill never reaches under the capsule; the name
        // truncates in the middle.
        if navOverlayMaxWidth == nil {
            let c = navPositionOverlay.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000)
            c.isActive = true
            navOverlayMaxWidth = c
        }
        let capsuleWidth = toolbar.fittingSize.width
        let maxPill = capsuleShown
            ? max(120, (bounds.width - capsuleWidth) / 2 - HUDGlass.gap - leading)
            : 10_000
        histogramPlacement = (trailing, bottom)
        let apply = {
            self.histogramTrailing?.constant = trailing
            self.histogramBottomToSelf?.constant = bottom
            self.navOverlayBottomToPanel?.constant = pillBottom
            self.fullscreenRowBottom = rowBottom
            self.layoutFullscreenRail()
            self.navOverlayLeading?.constant = leading
            self.navOverlayMaxWidth?.constant = maxPill
        }
        if animated && animatesPanelFades && !reducesMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = (stripShown || capsuleShown) ? Self.fadeInDuration : Self.fadeOutDuration
                ctx.allowsImplicitAnimation = true
                apply()
                self.layoutSubtreeIfNeeded()
            }
        } else {
            apply()
            needsLayout = true
        }
    }

    /// Whether `panel` should show in full screen right now:
    /// hovered or pinned; the capsule shows with the bottom zone, with a
    /// pinned filmstrip, or while one of its menus is open.
    private func fullscreenTarget(_ panel: PanelKind) -> Bool {
        switch panel {
        case .filmstrip where isEditModeActive:
            // Never in edit mode; the pin is kept for later.
            return false
        case .editRail where isEditModeActive:
            // Held open for the whole edit session.
            return true
        case .toolbar:
            if isEditModeActive { return false }
            return hoveredPanels.contains(.toolbar) || pinnedPanels.contains(.filmstrip)
                || (capsuleStorage?.holdsOpen ?? false)
        default:
            return hoveredPanels.contains(panel) || pinnedPanels.contains(panel)
        }
    }

    /// Test seams.
    internal var capsuleFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return toolbar.frame }
    internal var pillFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return navPositionOverlay.frame }

    /// Tests: the overlay's placement (built if it wasn't) and visibility.
    internal func histogramOverlayFrameForTesting() -> NSRect {
        layoutSubtreeIfNeeded()
        return histogramOverlay.frame
    }
    internal var histogramOverlayVisibleForTesting: Bool {
        guard let view = histogramStorage else { return false }
        return !view.isHidden && view.alphaValue > 0
    }
    /// Nil until the first show.
    internal var histogramOverlayIfBuiltForTesting: HistogramOverlayView? { histogramStorage }

    /// View ▸ Loupe checkmark.
    var isLoupeActive: Bool { !loupeView.isHidden }

    public func setLoupeActive(_ active: Bool) {
        if active {
            loupeView.isHidden = false
            if let point = window?.mouseLocationOutsideOfEventStream {
                moveLoupe(to: convert(point, from: nil))
            }
        } else {
            loupeView.isHidden = true
        }
    }

    /// Re-reads the image, where it is drawn and the view's turn and
    /// mirrors (all may change while the loupe is up: navigation, zoom,
    /// Rotate Left / Right), then centres the loupe on `localPoint`.
    func moveLoupe(to localPoint: NSPoint) {
        loupeView.sourceImage = imageView.image
        loupeView.drawnRect = convert(imageView.drawnImageRect, from: imageView)
        loupeView.rotationDegrees = imageView.rotationDegrees
        loupeView.flippedHorizontally = imageView.isFlippedHorizontally
        loupeView.flippedVertically = imageView.isFlippedVertically
        loupeView.updateCursor(at: localPoint)
    }

    internal var loupeViewForTesting: LoupeView { loupeView }

    /// The position pill: where the Tags popover points.
    var positionPillView: NSView { navPositionOverlay }

    public func toast(_ message: String) {
        toastHost.show(ToastContent(message))
    }

    /// Shows a toast, optionally with one action button.
    public func toast(_ content: ToastContent, action: (@MainActor () -> Void)? = nil) {
        toastHost.show(content, action: action)
    }

    /// Bumped on every pulse so an older pulse's fade-out does not hide
    /// a newer one early.
    private var zoomBadgePulse = 0

    /// Shows the zoom HUD for 1.5 s. The number is the photo's pixel
    /// percent (`pixelScale`: 100 % = one image pixel per screen pixel),
    /// the same as the title, the toolbar Zoom menu and VoiceOver, never
    /// the texture zoom.
    private func pulseZoomBadge() {
        zoomBadge.setZoom(imageView.pixelScale)
        zoomBadge.alphaValue = 1
        zoomBadgePulse &+= 1
        let pulse = zoomBadgePulse
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.zoomBadgePulse == pulse else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                self.zoomBadge.animator().alphaValue = 0
            }
        }
    }

    /// The user changed the zoom (menu, key, toolbar, double-click,
    /// wheel, pinch): show the zoom HUD and tell VoiceOver. Re-fits the
    /// app does on its own (window resize, edit mode, a new photo, a
    /// panel) never call this, so the HUD stays quiet.
    func userChangedZoom() {
        pulseZoomBadge()
        announceZoom()
    }

    internal var zoomBadgeTextForTesting: String { zoomBadge.textForTesting }
    internal var zoomBadgeShownForTesting: Bool { zoomBadge.alphaValue > 0 }
    internal func hideZoomBadgeForTesting() { zoomBadge.alphaValue = 0 }
    internal var zoomBadgeForTesting: HUDSurfaceView { zoomBadge }

    // MARK: - Hover / panel reveal

    public override func mouseEntered(with event: NSEvent) {
        scheduleCursorHide()
    }

    public override func mouseExited(with event: NSEvent) {
        cursorHideTimer?.invalidate()
        NSCursor.unhide()
        stopLivePhoto()   // the pointer left the canvas
        // The pointer left the view (another screen, the Dock, out of the
        // window), so no more mouseMoved will arrive to run evaluateZones.
        // Start the normal exit grace for every hover-revealed panel, or
        // it would stay up until the pointer comes back.
        for panel in hoveredPanels {
            scheduleExitGrace(for: panel)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        NSCursor.unhide()
        scheduleCursorHide()

        let localPoint = convert(event.locationInWindow, from: nil)
        evaluateZones(at: localPoint)
        kickIdleTimer()
        livePhotoPointerMoved(to: localPoint)

        if !loupeView.isHidden {
            moveLoupe(to: localPoint)
        }
    }

    /// Schedule the 2 s idle-cursor-hide. Suppressed while any chrome
    /// panel is hover-visible or pinned — the user wants to click
    /// something.
    private func scheduleCursorHide() {
        cursorHideTimer?.invalidate()
        // Suppress hide while any panel is pending user interaction.
        if !hoveredPanels.isEmpty || !pinnedPanels.isEmpty {
            return
        }
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { _ in
            Task { @MainActor in
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    /// Kick the chrome-idle timer — bumps the fade-out deadline to
    /// `now + chromeFadeOutDelayMs`. Called on every `mouseMoved` inside
    /// the view, on panel callbacks (so clicking a filmstrip cell keeps
    /// the strip visible), and by `ViewerWindow` on every nav keypress
    /// (so holding an arrow doesn't let the panel strobe out mid-nav).
    func kickIdleTimer() {
        chromeIdleTimer?.invalidate()
        // Idle auto-hide applies wherever an edge-hover panel can be on
        // screen. That includes windowed mode (editRail
        // overlay), not just fullscreen. The exit-grace path also drives
        // hides on its own; this is the secondary "user idled away" timer.
        let delay = TimeInterval(Prefs.chromeFadeOutDelayMs) / 1000.0
        chromeIdleTimer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { _ in
            Task { @MainActor [weak self] in
                self?.handleIdleExpired()
            }
        }
    }

    private func handleIdleExpired() {
        // Hide only the panels that are hover-visible but not pinned.
        // Pinned panels stay.
        let dismissible = hoveredPanels.subtracting(pinnedPanels)
        guard !dismissible.isEmpty else { return }
        // A panel under the pointer stays (it hides only
        // once the pointer leaves the zone and the panel).
        let pointer = pointerInView()
        let kept = hoveredPanels.filter { panel in
            guard let pointer else { return false }
            return pointerKeeps(panel, pointer)
        }
        guard kept != hoveredPanels else { return }
        hoveredPanels = kept
        updatePanelVisibility()
    }

    private func zoneRestElapsed(_ panel: PanelKind) {
        guard zoneRestWorkItems.removeValue(forKey: panel) != nil, let p = lastZonePoint else { return }
        evaluateZones(at: p, restSatisfied: true)
    }

    private func cancelAllZoneRest() {
        for (_, item) in zoneRestWorkItems { item.cancel() }
        zoneRestWorkItems.removeAll()
    }

    /// Test seam: a zone reveal is waiting for its rest.
    internal func zoneRestPendingForTesting(_ panel: PanelKind) -> Bool { zoneRestWorkItems[panel] != nil }

    private func evaluateZones(at p: NSPoint, restSatisfied: Bool = false) {
        // Edge-activated chrome:
        //  * Fullscreen — all four panels (filmstrip, toolbar, editRail,
        //    inspector) participate in the edge-hover machinery.
        //  * Windowed — nothing (the rail has no hover
        //    reveal; View › Show Edit Rail shows it). Filmstrip is docked,
        //    toolbar/inspector are surfaced via NSToolbar / menus.
        if windowMode == .windowed {
            // Clear any residual hover state and bail.
            if !hoveredPanels.isEmpty {
                hoveredPanels.removeAll()
                cancelAllPanelExitGrace()
                updatePanelVisibility()
            }
            return
        }

        let b = bounds
        lastZonePoint = p

        // 1. Zone hits. AppKit view coord: origin
        //    bottom-left. The bottom zone reveals the filmstrip and the
        //    capsule together; the top edge reveals nothing of ours.
        var zoneHits = Self.zonePanels(at: p, in: b)

        // 1b. 120 ms rest: a zone that is not showing yet reveals only
        //     after the pointer rested in it. Leaving the zone first
        //     cancels the reveal.
        let waiting = zoneHits.subtracting(hoveredPanels)
        for panel in Array(zoneRestWorkItems.keys) where !zoneHits.contains(panel) {
            zoneRestWorkItems.removeValue(forKey: panel)?.cancel()
        }
        if !restSatisfied && zoneRestMs > 0 && !waiting.isEmpty {
            zoneHits.subtract(waiting)
            for panel in waiting where zoneRestWorkItems[panel] == nil {
                let item = DispatchWorkItem { [weak self] in
                    Task { @MainActor [weak self] in self?.zoneRestElapsed(panel) }
                }
                zoneRestWorkItems[panel] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(zoneRestMs), execute: item)
            }
        }

        // 2. Body hits. Once a panel is visible,
        //    the cursor is allowed to wander off the zone into the panel
        //    body itself and still count as hovering. Otherwise the user
        //    crosses the zone boundary the instant they move from the edge
        //    band into the panel's content area, and the panel flashes
        //    away before they can click anything.
        //
        //    For filmstrip, toolbar, editRail, inspector we use the
        //    panel's own frame in our coord space. This is the same
        //    frame AppKit uses for hit testing, so the math is
        //    symmetric with the visible chrome.
        //    In windowed mode only editRail body-hits count (filmstrip is
        //    permanently docked when visible — body-hit would lock it on
        //    forever; toolbar/inspector are not in the edge-hover model).
        var bodyHits: Set<PanelKind> = []
        let bodyHitCandidates: [PanelKind] =
            (windowMode == .fullscreen) ? PanelKind.allCases : [.editRail]
        for panel in bodyHitCandidates {
            let v = view(for: panel)
            // Only check body hit if the panel is actually on-screen.
            // `alphaValue` may be transiently 0 while a reveal animation
            // is queued — `!isHidden` is the authoritative signal.
            guard !v.isHidden else { continue }
            // The panel frame plus a 24 pt margin.
            if v.frame.insetBy(dx: -Zone.bodyMargin, dy: -Zone.bodyMargin).contains(p) {
                bodyHits.insert(panel)
            }
        }
        // The bottom stack is one unit: on the capsule or the strip keeps
        // both (the capsule would drop under the pointer otherwise).
        if windowMode == .fullscreen,
           !bodyHits.isDisjoint(with: [.filmstrip, .toolbar]) {
            bodyHits.formUnion([.filmstrip, .toolbar])
        }

        // 3. Union — either a zone hit OR a body hit keeps the panel
        //    visible. Pinned panels are always kept in `pinnedPanels`
        //    separately and don't need to appear in hoveredPanels; they
        //    render via `updatePanelVisibility`'s OR.
        let newHover = zoneHits.union(bodyHits)

        // 4. Diff — for panels that WERE hovered but would drop out,
        //    start a 200 ms exit-grace timer instead of hiding them
        //    immediately. For panels that remain or join, cancel any
        //    pending grace timer.
        //
        //    IMPORTANT: cancel grace for every panel in `stillHovered`,
        //    not just the newly-entering ones. A panel with a pending
        //    grace timer is still in `hoveredPanels` (we keep it there
        //    via the `immediateSet` union below), so on re-entry it
        //    wouldn't show up in `stillHovered.subtracting(hoveredPanels)`
        //    — yet its timer is exactly what we need to cancel.
        let stillHovered = newHover
        let leavingNow = hoveredPanels.subtracting(stillHovered)

        for panel in stillHovered {
            cancelPanelExitGrace(panel)
        }

        for panel in leavingNow {
            scheduleExitGrace(for: panel)
        }

        // Commit the "currently wants visible" set directly, but DON'T
        // remove the leaving ones yet — they're deferred into their
        // grace timers. Union keeps them visible for now.
        let immediateSet = stillHovered.union(leavingNow)
        if immediateSet != hoveredPanels {
            hoveredPanels = immediateSet
            updatePanelVisibility()
        }
        if !stillHovered.isEmpty {
            // Re-kick the idle timer — the user is interacting with
            // a panel (zone or body).
            kickIdleTimer()
        }
    }

    /// Fix #6. Queue a 200 ms hide for `panel`. If the
    /// cursor re-enters either the panel's edge zone or body before the
    /// timer fires, `cancelPanelExitGrace(_:)` aborts it.
    ///
    /// **Idempotent**: if a grace timer is already pending for this
    /// panel, leave the existing deadline alone. The
    /// previous behaviour cancelled-and-replaced on every call, which
    /// `evaluateZones` triggers on every `mouseMoved` while the cursor
    /// is in the canvas (the panel keeps showing up in `leavingNow`
    /// because we deliberately keep it in `hoveredPanels` until the
    /// timer fires). Cursor jitter alone was enough to slide the 200 ms
    /// deadline forward indefinitely, so the panel never hid. The
    /// re-entry path through `cancelPanelExitGrace(_:)` for `stillHovered`
    /// in `evaluateZones` still aborts a pending timer when the user
    /// moves back onto the panel — so this idempotency only suppresses
    /// the redundant reschedule, not the cancel-on-re-entry path.
    private func scheduleExitGrace(for panel: PanelKind) {
        if panelExitGraceWorkItems[panel] != nil { return }

        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.applyExitGrace(for: panel)
            }
        }
        panelExitGraceWorkItems[panel] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(exitGraceMs),
            execute: workItem
        )
    }

    private func cancelPanelExitGrace(_ panel: PanelKind) {
        panelExitGraceWorkItems[panel]?.cancel()
        panelExitGraceWorkItems.removeValue(forKey: panel)
    }

    private func cancelAllPanelExitGrace() {
        for (_, item) in panelExitGraceWorkItems { item.cancel() }
        panelExitGraceWorkItems.removeAll()
    }

    private func applyExitGrace(for panel: PanelKind) {
        panelExitGraceWorkItems.removeValue(forKey: panel)
        // Only actually drop the panel if it's still in the hovered set
        // AND the cursor isn't over its zone/body right now.
        guard hoveredPanels.contains(panel) else { return }
        // Recompute body hit one more time — the cursor may have
        // slipped back onto the body while the timer was coasting and
        // we didn't get a mouseMoved event (e.g. during a decode).
        if let local = pointerInView(), pointerKeeps(panel, local) {
            return
        }
        hoveredPanels.remove(panel)
        updatePanelVisibility()
    }

    /// Reveal zones: the bottom 96 pt reveals the filmstrip
    /// and the capsule together; the left and right 56 pt reveal the rail
    /// and the inspector. The bottom corners belong to the bottom zone
    ///: a pointer resting at the bottom edge near a
    /// corner never slides the inspector in as well.
    static func zonePanels(at p: NSPoint, in b: NSRect) -> Set<PanelKind> {
        var hits: Set<PanelKind> = []
        let inBottom = p.y <= b.minY + Zone.bottomHeight
        if inBottom { hits.formUnion([.filmstrip, .toolbar]) }
        if !inBottom, p.x >= b.maxX - Zone.sideWidth { hits.insert(.inspector) }
        if !inBottom, p.x <= b.minX + Zone.sideWidth { hits.insert(.editRail) }
        return hits
    }

    /// The pointer keeps `panel` up: it is in the panel's reveal zone or
    /// on the panel (plus the margin). A pointer
    /// resting at the bottom edge keeps the bottom stack, however long.
    private func pointerKeeps(_ panel: PanelKind, _ p: NSPoint) -> Bool {
        if windowMode == .fullscreen, Self.zonePanels(at: p, in: bounds).contains(panel) { return true }
        return bodyContains(panel, p)
    }

    /// The pointer in view coordinates, or nil without a window.
    private func pointerInView() -> NSPoint? {
        guard let window else { return nil }
        let mouseLoc = cursorLocationOverrideForTesting ?? window.mouseLocationOutsideOfEventStream
        return convert(mouseLoc, from: nil)
    }

    /// The pointer is over `panel` or within 24 pt of it.
    /// In full screen the filmstrip and the capsule count as one stack.
    private func bodyContains(_ panel: PanelKind, _ p: NSPoint) -> Bool {
        var panels: [PanelKind] = [panel]
        if windowMode == .fullscreen, panel == .filmstrip || panel == .toolbar {
            panels = [.filmstrip, .toolbar]
        }
        return panels.contains { kind in
            if kind == .toolbar, capsuleStorage == nil { return false }
            let v = view(for: kind)
            return !v.isHidden && v.frame.insetBy(dx: -Zone.bodyMargin, dy: -Zone.bodyMargin).contains(p)
        }
    }

    /// Test seam — whether there's an active exit-grace timer for `panel`.
    internal func panelExitGraceActiveForTesting(_ panel: PanelKind) -> Bool {
        panelExitGraceWorkItems[panel] != nil
    }

    private func updatePanelVisibility() {
        for panel in PanelKind.allCases {
            let shouldShow: Bool
            if windowMode == .windowed && panel == .editRail {
                shouldShow = windowedRailTarget()
                railAppliedTarget = shouldShow
                if shouldShow { noteRailShown() }
            } else {
                shouldShow = fullscreenTarget(panel)
            }
            setPanel(panel, visible: shouldShow)
        }
        updateHistogramVisibility(animated: true)
        positionHistogram(animated: true)
        histogram.wantedDidChange()
    }

    /// Mounts the capsule in its z-order slot (above the filmstrip, below
    /// the edit rail), hidden, with these constraints: 44 pt,
    /// centred, 12 pt above the filmstrip (16 pt above the bottom edge
    /// without it).
    private func installCapsule(_ capsule: ViewerToolbar) {
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.alphaValue = 0
        capsule.isHidden = true
        hudParent.addSubview(capsule, positioned: .above, relativeTo: filmstrip)
        applySurfaceLook(capsule)
        let toSelf = capsule.bottomAnchor.constraint(
            equalTo: bottomAnchor, constant: -Self.capsuleBottomInset)
        let toStrip = capsule.bottomAnchor.constraint(
            equalTo: filmstrip.topAnchor, constant: -Self.capsuleGapAboveFilmstrip)
        toolbarBottomToSelf = toSelf
        toolbarBottomToFilmstrip = toStrip
        let stripShown = windowMode == .fullscreen && fullscreenTarget(.filmstrip)
        NSLayoutConstraint.activate([
            stripShown ? toStrip : toSelf,
            capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
            capsule.heightAnchor.constraint(equalToConstant: Self.capsuleHeight),
        ])
        capsule.actionDispatcher = { [weak self] action in
            self?.actionDispatcher?(action)
        }
        capsule.onHoldChanged = { [weak self] in
            self?.updatePanelVisibility()
        }
    }

    private func view(for panel: PanelKind) -> NSView {
        switch panel {
        case .filmstrip: return filmstrip
        case .toolbar:   return toolbar
        case .editRail:  return editRail
        case .inspector: return inspector
        }
    }

    /// The bottom stack rises this far as it fades in.
    static let stackRiseDistance: CGFloat = 8
    static let stackRiseKey = "shrike.stackRise"

    /// An additive 8 pt rise (from below to its place), with
    /// the fade-in's 80 ms and ease-out. Layout is untouched: the layer
    /// only draws lower at first.
    private func addStackRise(to view: NSView) {
        guard let layer = view.layer else { return }
        let rise = CABasicAnimation(keyPath: "position.y")
        rise.fromValue = -Self.stackRiseDistance
        rise.toValue = 0
        rise.isAdditive = true
        rise.duration = Self.fadeInDuration
        rise.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(rise, forKey: Self.stackRiseKey)
    }

    /// Set a panel visible or hidden immediately, without animation.
    /// Used by `configureForMode` during mode swaps; also the target of
    /// Reduce Motion fades.
    private func setPanelVisibleImmediate(_ panel: PanelKind, visible: Bool) {
        // Nothing to hide on a capsule that was never built.
        if panel == .toolbar, !visible, capsuleStorage == nil { return }
        let view = view(for: panel)
        if !visible { view.layer?.removeAnimation(forKey: Self.stackRiseKey) }
        view.isHidden = !visible
        view.alphaValue = visible ? 1 : 0
    }

    private func setPanel(_ panel: PanelKind, visible: Bool) {
        if panel == .toolbar, !visible, capsuleStorage == nil { return }
        // Skip the filmstrip here when in windowed mode — its visibility
        // is controlled by the pref, not by hover. (Pinned fullscreen
        // panels bleed through into `pinnedPanels`, so `updatePanelVisibility`
        // could try to show the filmstrip above an already-docked one;
        // the mode guard prevents a stray alpha stomp.)
        if windowMode == .windowed && panel == .filmstrip {
            return
        }
        // Windowed mode: editRail participates in the edge-hover model
        // (see configureForMode).
        // Toolbar + inspector are NOT addressable in windowed mode; hold
        // them hidden regardless of hover/pin state.
        if windowMode == .windowed && panel != .editRail {
            setPanelVisibleImmediate(panel, visible: false)
            return
        }
        // Full-screen edit mode: the edit capsule stands in for the
        // viewer toolbar for the whole session.
        if isEditModeActive && panel == .toolbar {
            setPanelVisibleImmediate(panel, visible: false)
            return
        }

        let view = view(for: panel)
        let reduceMotion = reducesMotion
        // The bottom stack (filmstrip + capsule) fades in
        // with an 8 pt rise, ease-out; under Reduce Motion it still fades
        // (no rise). The other panels show at once under Reduce Motion.
        let isStack = panel == .filmstrip || panel == .toolbar
        if !animatesPanelFades || (reduceMotion && !isStack) {
            setPanelVisibleImmediate(panel, visible: visible)
            return
        }
        if visible {
            let appearing = view.isHidden || view.alphaValue == 0
            if view.isHidden {
                view.alphaValue = 0
                view.isHidden = false
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Self.fadeInDuration
                if isStack { ctx.timingFunction = CAMediaTimingFunction(name: .easeOut) }
                view.animator().alphaValue = 1
            }
            if isStack, appearing, !reduceMotion { addStackRise(to: view) }
        } else {
            view.layer?.removeAnimation(forKey: Self.stackRiseKey)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Self.fadeOutDuration
                if isStack { ctx.timingFunction = CAMediaTimingFunction(name: .easeOut) }
                view.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor [weak view] in
                    guard let view else { return }
                    if view.alphaValue == 0 { view.isHidden = true }
                }
            })
        }
    }
}

// MARK: - Delegate hook

/// Holds a `NotificationCenter` observation token and removes it on
/// dealloc. The wrapper exists so `ViewerContentView`'s `deinit` does
/// not need to touch MainActor-isolated state — this class is final
/// and has no isolation, so Swift 6 strict concurrency is satisfied.
private final class PrefsObservationBox: @unchecked Sendable {
    var token: (any NSObjectProtocol)?
    deinit {
        if let t = token {
            NotificationCenter.default.removeObserver(t)
        }
    }
}

extension ViewerContentView: MetalImageViewDelegate {
    public func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double) {
        onZoomChanged?()
        if isEditModeActive { syncCropOverlayFrame() }
        // Live Photos play only at fit.
        livePhotoBadge.isDimmed = !view.isAtFit
        layoutLiveBadge()
        if !view.isAtFit { stopLivePhoto() } else { livePhotoPlayback?.updateFrame() }
        // `zoom` is the pixel percent. The label follows every change, but
        // the HUD only shows for a zoom the user made: a
        // live pinch here, the rest through `userChangedZoom()`.
        zoomBadge.setZoom(zoom)
        if view.isPinching { pulseZoomBadge() }
    }

    public func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint) {
        layoutLiveBadge()
    }

    public func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool) {
        guard !isEditModeActive else { return }
        onCanvasNavigate?(forward)
    }

    public func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool {
        !isEditModeActive && (canNavigate?(forward) ?? false)
    }

    public func metalImageViewDidFinishUserZoom(_ view: MetalImageView) {
        userChangedZoom()
    }

    public func metalImageView(_ view: MetalImageView, wantsSwipeNeighbour forward: Bool) {
        onSwipeNeighbourWanted?(forward)
    }

    public func metalImageView(_ view: MetalImageView, didCompleteSwipe forward: Bool,
                               handOver: SwipeHandOver) {
        if let onSwipeCompleted {
            onSwipeCompleted(forward, handOver)
        } else {
            onCanvasNavigate?(forward)
        }
    }

    public func metalImageView(_ view: MetalImageView, didStretchPastEndOfList forward: Bool) {
        onSwipeStretchedPastEnd?(forward)
    }

    public func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) {
        ShrikeSignposts.launch.event("viewerFirstDrawable")
        // The rail shows on the first layout after this.
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
            needsLayout = true
        }
    }
}

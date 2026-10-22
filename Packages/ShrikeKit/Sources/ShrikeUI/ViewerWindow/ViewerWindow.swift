//
//  ViewerWindow.swift
//  ShrikeUI
//
//  Top-level AppKit window for the single-image viewer.
//
//  State machine: idle → hover → pinned (per edge).
//  * Idle: fullscreen black canvas, no chrome, cursor auto-hides.
//  * Hover: cursor within an activation zone reveals that edge's panel.
//  * Pinned: panel sticks until explicitly unpinned (Cmd+K/T/I/E toggle).
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeIO
import ShrikeRendering
import UniformTypeIdentifiers
import os

@MainActor
public final class ViewerWindow: NSWindow {

    let services: ShrikeServices
    let navigation: NavigationController
    let contentRoot: ViewerContentView

    /// The window's list, as groups. Parallel to the
    /// decode list: index i of one is index i of the other.
    internal var list = GroupList()

    /// What is on screen right now. Set in the same
    /// main-actor turn that hands pixels to the Metal view, or shows the
    /// error overlay. Every file action reads it.
    public internal(set) var displayedItem: DisplayedItem?

    /// Rating and flag of the listed files, read in one batch per list.
    /// Feeds the pill marks and the menu check marks.
    var cullingRecords: [URL: FileRecord] = [:]
    /// Finder tags + pencil state per primary, read with
    /// the records.
    var fileBadges: [URL: FileBadgeExtras] = [:]
    /// A batched read never replaces a newer write.
    var cullingReadGuard = LateReadGuard()
    var badgeReadGuard = LateReadGuard()
    /// Test seams: run after the records read / in place of the badge
    /// read, to hold a batched read in flight.
    var cullingReadGateForTesting: (@Sendable () async -> Void)?
    var badgeExtrasReaderForTesting: (@Sendable ([URL]) async -> [URL: FileBadgeExtras])?

    /// Own undo stack, kept for the life of the window.
    let windowUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.levelsOfUndo = 50
        return manager
    }()

    /// Its own writes are ignored by this window's (and its partner's) watcher only;
    /// a second window on the folder hears about trash / move / rename.
    lazy var fileOps = FileOps(metadata: services.metadataStore, backups: services.backupStore,
                               watchers: watcherScope)
    /// Copy / Move to folder: slots, panel, conflicts, HUD.
    lazy var transfers: FileTransferCoordinator = makeTransferCoordinator()
    /// Trashes run one after another, in press order.
    var trashChain: Task<Void, Never>?
    /// The latest Open in External Editor launch (tests wait on it).
    var externalEditorLaunch: Task<Void, Never>?
    /// The displayed file's GPS once read (Show in Maps).
    var displayedLocation: KnownLocation?
    /// The GPS read for the displayed file (tests wait on it).
    var locationLookup: Task<Void, Never>?
    /// Right-click menu; items are built on first open.
    lazy var contextMenu = ViewerContextMenu(window: self)
    /// "No more images in …" / "… is no longer available".
    var emptyStateView: ViewerEmptyStateView?
    /// Tests answer file alerts here (button index) instead of a sheet.
    var alertResponderForTesting: ((String) -> Int?)?
    /// Tests answer the Rename sheet here (new stem; nil = Cancel).
    var renameResponderForTesting: ((RenameSheetModel) -> String?)?
    /// Tests get the Tags session here instead of a popover.
    var tagPopoverPresenterForTesting: ((TagEditSession) -> Void)?

    /// The Browser this viewer was opened from. Weak: the
    /// `WindowCoordinator` owns windows; closing either side drops the pair.
    public weak var pairedBrowser: BrowserWindowController? {
        didSet { watcherScope.setPartner(pairedBrowser?.watcherScope) }
    }
    var reviewDecisionSerial: UInt64 = 0
    var reviewAutomaticMove = false
    var reviewPersistenceBanner: PersistenceBanner?
    var returnHintPopover: NSPopover?
    var browserReturnHintReady = false
    var imagePressureObservation: ImagePressureObservation?
    var onImagePressureHandledForTesting: (() -> Void)?
    /// End-of-folder cue in progress.
    var endOfFolderCue: EndOfFolderCue?
    /// What a just-completed swipe left on screen, for the navigation to
    /// that index. Used once.
    var pendingSwipeHandOver: (index: Int, handOver: SwipeHandOver)?
    /// Trims the decode cache a while after the viewer is hidden.
    var hiddenTrimTask: Task<Void, Never>?
    /// The ⌥R readability check (spec 24 §4).
    var rawSwitchTask: Task<Void, Never>?
    /// FastStone preset: Esc in paired full screen also returns to the Browser.
    var returnToBrowserAfterFullScreenExit = false
    /// Go ▸ Go to Folder… while its sheet is up.
    var goToFolderSheet: GoToFolderSheet?
    /// The user's toolbar setting, read as full screen starts and
    /// put back in `didExitFullScreen`. AppKit restores the
    /// toolbar it saw at the start of the transition (already hidden by
    /// us), so a value set in `willExit` was undone on the way out.
    var toolbarShownBeforeFullScreen: Bool?
    /// Watches the displayed item's folder for outside changes.
    var folderWatcher: FolderWatcher? {
        didSet { watcherScope.setWatcher(folderWatcher) }
    }
    /// Who ignores this window's own file writes: its watcher and its
    /// paired Browser's (both are updated explicitly). Other windows'
    /// watchers still report the change. See `WindowWatcherScope`.
    let watcherScope = WindowWatcherScope()
    var folderWatchTask: Task<Void, Never>?
    /// Standardized path of the watched folder (cheap compare per paint).
    var watchedFolderPath: String?
    /// Tests answer the Save panel here (suggested URL, message).
    var savePanelResponderForTesting: ((URL, String?) -> URL?)?
    var savePanelAsyncResponderForTesting: ((URL, String?) async -> URL?)?
    var exportCheckpointForTesting: (@Sendable (ImageExporter.Checkpoint) async throws -> Void)?
    /// The latest Undo / Redo Save or Revert file swap.
    var pendingFileVersionTask: Task<Void, Never>?
    /// Bumps when a pencil state read lands (tests).
    var backupStateGeneration: UInt64 = 0
    /// Bumps each time the displayed file is redrawn in place (tests).
    var redrawCount: UInt64 = 0
    /// Overrides the async header-size read in tests that exercise a redraw
    /// while metadata is still loading.
    var headerPixelSizeReaderForTesting: (@Sendable (URL) -> CGSize?)?
    /// The larger-texture fetch after the canvas grew.
    var textureRefetchTask: Task<Void, Never>?
    var textureRefetchCount = 0
    var textureLongEdgeForTesting: Int?
    /// Rotations / flips waiting for the 500 ms quiet period.
    var pendingOrientation: PendingOrientation?
    var orientationTimer: Task<Void, Never>?
    /// Orientation writes run one after another.
    var orientationWriteChain: Task<Void, Never>?
    /// `LosslessRotator.isSupported` per file (a header read).
    var orientationSupport: [URL: Bool] = [:]
    /// One-per-window toasts already shown ("Rotated for viewing only…").
    var shownOnceToasts: Set<String> = []

    /// Edit ▸ Undo/Redo read the window's own stack.
    public override var undoManager: UndoManager? { windowUndoManager }

    /// Custom full-screen enter/exit animation (no stale snapshot flash —
    /// see `ViewerFullScreenTransition`). Also the window's delegate.
    internal let fullScreenTransition = ViewerFullScreenTransition()

    /// Synchronous, main-actor cursor. Drives the position overlay so it
    /// tracks the user's *intended* position instantly on every keyDown —
    /// independently of whether the underlying decode task gets cancelled
    /// by `navCoalescer`. See `NavigationIntent` for the full rationale.
    internal let intent = NavigationIntent()

    /// Chord state. Non-nil when a prefix like `C` or `M` has been pressed;
    /// expires after 1.5 s.
    private(set) var chordPrefix: Character?
    /// Edit mode waiting for the full decode.
    var editLoadTask: Task<Void, Never>?
    private var editLoadGeneration: UInt64 = 0
    private var editReentryTask: Task<Void, Never>?
    private var editReentryGeneration: UInt64 = 0
    private var embeddedPreviewTask: Task<Void, Never>?
    private var thumbnailBridgeTask: Task<Void, Never>?
    private var navigationPreviewGeneration: UInt64 = 0
    var editSourceLoaderForTesting: (@MainActor (URL) async -> CGImage?)?
    private var chordExpiryTask: Task<Void, Never>?

    /// Coalesces rapid navigation keypresses. Each new Space / arrow / Home
    /// / End cancels the pending decode task so the user always sees the
    /// *latest* target instead of draining a serialized backlog through
    /// the DecodeQueue actor. Hold-to-advance
    /// used to queue every auto-repeat, making the first tap feel
    /// unresponsive and long holds zip through the whole folder on release.
    internal let navCoalescer = NavTaskCoalescer()

    /// Drives the layered feedback pipeline (thumb bridge, position
    /// overlay, hairline loading indicator). Navigation events bump the
    /// generation, and late-arriving thumb tails check their generation
    /// against the current one before painting.
    ///
    /// The overlay auto-hide flag is sampled once at window construction so
    /// toggling the pref in-flight doesn't produce weird half-states; the
    /// next window open picks up the new value.
    internal let feedbackState = NavigationFeedbackState(
        overlayAutoHides: Prefs.viewerPositionOverlayAutoHides
    )

    /// Max-pixel size for the thumbnail bridge paint. 1024 px HEICs load in
    /// a few ms from the memory tier and ~20 ms from the disk tier — big
    /// enough to look decent in a full-screen 5K window (a 1024 px thumb
    /// scales to ~2.5x on retina, acceptable as a momentary placeholder),
    /// small enough to stay cheap.
    static let thumbBridgeMaxPixelSize: Int = 1024

    /// Default predicted decode duration used by the grace path before the
    /// async predictor resolves. 150 ms — at the predictive-skip
    /// threshold, so if the predictor never resolves (network source, no
    /// URL), the pre-fill math stays reasonable (`(100/150) × 0.80 =
    /// 0.53`, bar catches up to just past halfway at grace-fire, then
    /// Phase A runs to 0.80 over the remaining 50 ms). The predictor
    /// race in `scheduleHairlinePredictiveSkip` refines this value to
    /// reality as soon as it resolves.
    private static let hairlineDefaultPredicted: TimeInterval = 0.150

    /// Opens a viewer on a list of groups.
    public convenience init(
        groups: [ImageGroup],
        startIndex: Int,
        services: ShrikeServices
    ) {
        self.init(
            imageSources: groups.map { FileImageSource(url: $0.primary) },
            startIndex: startIndex,
            services: services,
            groups: groups
        )
    }

    public init(
        imageSources: [any ImageSource],
        startIndex: Int,
        services: ShrikeServices,
        groups: [ImageGroup]? = nil
    ) {
        self.services = services
        self.list = GroupList(groups ?? imageSources.map { source in
            if let file = source as? FileImageSource { return ImageGroup(primary: file.url) }
            return ImageGroup(primary: URL(fileURLWithPath: "/shrike-source/\(source.id)"))
        })
        self.navigation = NavigationController(
            queue: services.makeDisplayDecodeQueue(),
            thumbnailCache: services.thumbnailCache
        )
        // Hand the list to the decode queue
        // BEFORE building the views (~70 ms), so the first decode runs
        // in parallel with them. The coalesced setNavigation below sends
        // the same list again; files already decoding are kept.
        let earlyNav = self.navigation
        let earlyList = imageSources
        let earlyIndex = max(0, min(startIndex, imageSources.count - 1))
        // Until the first layout knows the canvas, no
        // texture needs to be larger than the screen (a 1512 x 982 pt 2x
        // screen needs 3024 px, not 4096). The first layout then sets the
        // canvas size, which is never larger, so the photo is not fetched
        // twice.
        // The window's size, not the screen's.
        let earlyEdge = Self.takeInitialTextureLongEdge()
        if !earlyList.isEmpty {
            Task.detached(priority: .userInitiated) {
                await earlyNav.decodeQueue.setMaxLongEdge(earlyEdge)
                await earlyNav.setNavigation(list: earlyList, currentIndex: earlyIndex)
            }
        }
        let viContent = ShrikeSignposts.launch.begin("viContentView")
        self.contentRoot = ViewerContentView(services: services)
        ShrikeSignposts.launch.end("viContentView", viContent)

        // A generous default size; the user can fullscreen with `F` or ⌃⌘F.
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: 1200, height: 800)
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2
        )
        let frame = NSRect(origin: origin, size: size)

        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable,
            .fullSizeContentView,
        ]

        let viSuper = ShrikeSignposts.launch.begin("viSuperInit")
        super.init(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        ShrikeSignposts.launch.end("viSuperInit", viSuper)

        title = "Shrike"
        isReleasedWhenClosed = false
        // No window animation on the first-pixel path.
        animationBehavior = .none
        collectionBehavior = [.fullScreenPrimary, .managed]
        // No window tabs (hides View › Show Tab Bar).
        tabbingMode = .disallowed
        // The system titlebar blur keeps the title readable
        // over the photo; title and subtitle stack in a unified toolbar.
        titlebarAppearsTransparent = false
        titleVisibility = .visible
        toolbarStyle = .unified
        minSize = EditLayout.windowMinSize
        backgroundColor = .black

        // Canvas + system inspector item. The inspector view is built
        // on first expand (no EXIF read on the first-pixel path).
        let viSplit = ShrikeSignposts.launch.begin("viSplit")
        let split = ViewerSplitController(canvas: contentRoot, model: contentRoot.inspectorPanel.viewModel)
        splitController = split
        // The split view gets the window's content size
        // before it becomes the content view controller, so no
        // `setContentSize` (a frame change that laid out the whole view
        // tree inside init, before anything was on screen) is needed.
        // AppKit lays the tree out once, before the first display.
        split.view.setFrameSize(size)
        contentViewController = split
        split.onInspectorShownChanged = { [weak self] shown in
            if shown { self?.contentRoot.inspectorPanel.headerReadsEnabled = true }
            self?.contentRoot.setWindowedInspectorShown(shown)
        }
        // Edit mode on a narrow canvas: the inspector steps aside (spec 26 §5).
        contentRoot.onEditModeActiveChanged = { [weak self] active in
            self?.editModeLayoutChanged(active: active)
        }
        // 0.2.10 audit item 3: a resize that bypasses `contentMinSize` (a programmatic
        // or Accessibility `setFrame`) must not leave edit mode under 648 pt.
        NotificationCenter.default.addObserver(
            self, selector: #selector(editWindowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: self)
        contentRoot.onEditCanvasWidth = { [weak split] width in
            DispatchQueue.main.async { split?.editCanvasWidth(width) }
        }
        // The split read the pref in viewDidLoad, before this callback; assigning
        // the callback replays that state (so the header reads are on). This call
        // only syncs the content view's layout with it.
        contentRoot.setWindowedInspectorShown(split.isInspectorShown)
        ShrikeSignposts.launch.end("viSplit", viSplit)
        // The toolbar, built once per window.
        let viBar = ShrikeSignposts.launch.begin("viToolbar")
        let bar = ViewerWindowToolbar(host: nil)
        toolbarController = bar
        // The Edit item's tooltip says why Edit is off (RAW shown, decode error).
        contentRoot.onEditEntryReasonChanged = { [weak bar] reason in bar?.setEditExtraLine(reason) }
        bar.setEditExtraLine(contentRoot.editEntryReason)
        toolbar = bar.toolbar
        bar.host = self
        toolbarHover = ToolbarHover.install(in: self)
        ShrikeSignposts.launch.end("viToolbar", viBar)
        acceptsMouseMovedEvents = true
        contentRoot.menu = contextMenu.menu
        delegate = fullScreenTransition
        fullScreenTransition.onEnterFailed = { [weak self] in
            self?.contentRoot.windowMode = .windowed
            self?.installScrimIfNeeded()
        }
        fullScreenTransition.onExitFailed = { [weak self] in
            self?.contentRoot.windowMode = .fullscreen
            self?.installScrimIfNeeded()
        }
        wireInspectorActions()
        installAutoHide()
        // Edit mode owns the subtitle and the close-button dot.
        configureReview()
        contentRoot.onDecodeErrorNext = { [weak self] in self?.dispatch(.nextImage) }
        contentRoot.onDecodeErrorReveal = { [weak self] in self?.dispatch(.revealInFinder) }
        contentRoot.onEditSubtitleChanged = { [weak self] state in
            guard let self else { return }
            if let state {
                self.subtitle = state.subtitle
                self.isDocumentEdited = state.hasEdits
            } else {
                self.isDocumentEdited = false
                // Any exit outcome: the size is read again (spec 25 §1.1).
                self.forgetDrawnSizes()
                self.updateTitle()
            }
        }
        contentRoot.onZoomChanged = { [weak self] in
            self?.requestFullResolutionIfNeeded()
        }
        contentRoot.actionDispatcher = { [weak self] action in
            self?.dispatch(action)
        }
        contentRoot.capsuleZoomMenu.host = self
        contentRoot.onToggleRAW = { [weak self] in self?.toggleRAWFile() }
        // New decodes use the canvas size
        // (under the long-edge ceiling); a grown canvas fetches the shown
        // photo again at the larger size.
        contentRoot.onMaxLongEdgeChanged = { [weak self] px in
            self?.textureLongEdgeChanged(to: px)
        }
        // Wheel notch / trackpad swipe on the canvas.
        contentRoot.onCanvasNavigate = { [weak self] forward in
            self?.dispatch(forward ? .nextImage : .prevImage)
        }
        // The neighbour's prefetched texture for the paging
        // slide. Asked once per swipe, never waited for.
        contentRoot.onSwipeNeighbourWanted = { [weak self] forward in
            self?.supplySwipeNeighbour(forward: forward)
        }
        contentRoot.onSwipeCompleted = { [weak self] forward, handOver in
            self?.completeSwipe(forward: forward, handOver: handOver)
        }
        contentRoot.onSwipeStretchedPastEnd = { [weak self] forward in
            _ = self?.handleEdgeOfFolder(forward ? .next : .previous, fromSwipe: true)
        }
        contentRoot.canNavigate = { [weak self] forward in
            guard let self, let item = self.displayedItem else { return false }
            return forward ? item.listIndex < self.list.count - 1 : item.listIndex > 0
        }
        // Filmstrip click-to-jump The cell emits its
        // global index; we route it through the nav coalescer so a
        // click in the middle of a rapid key-mash still "wins".
        // Drag a filmstrip cell out (the whole group).
        contentRoot.filmstripGroups = { [weak self] index in self?.list[index] }
        contentRoot.editModeController.canStartToolTransition = { [weak self] in
            self?.editExitTask == nil && self?.didTearDown == false
        }
        contentRoot.onFilmstripJump = { [weak self] globalIndex in
            guard let self else { return }
            guard let target = self.list[globalIndex], target.primary != self.displayedItem?.group.primary else { return }
            self.reviewDecisionSerial &+= 1
            let wasEditing = self.contentRoot.isEditModeActive
            let windowed = self.contentRoot.windowMode == .windowed
            self.leaveEditModeThen(reason: .navigation) { [weak self] in
                guard let self else { return }
                guard let index = self.list.groups.firstIndex(where: { $0.primary == target.primary }) else {
                    self.contentRoot.toast(ToastContent("That photo is no longer available."))
                    return
                }
                self.coalesceNav { [weak self] in await self?.navigate(to: index) }
                if wasEditing && windowed { self.reenterEditModeAfterNavigation() }
            }
        }
        // Filmstrip scroll-wheel scrub Positive delta =
        // advance, negative = retreat. Dispatched as one advance/retreat
        // per whole-cell crossing (the filmstrip accumulates sub-threshold
        // pixels internally).
        contentRoot.onFilmstripScrub = { [weak self] delta in
            guard let self else { return }
            self.reviewDecisionSerial &+= 1
            if self.contentRoot.isEditModeActive {
                // A scrub is many small steps: ask once, then stop.
                self.leaveEditModeThen(reason: .navigation) {}
                return
            }
            if delta > 0 {
                self.coalesceNav { [weak self] in await self?.advance() }
            } else if delta < 0 {
                self.coalesceNav { [weak self] in await self?.retreat() }
            }
        }
        // The pill reads `Prefs.viewerPositionOverlayAutoHides` live. Do not
        // push the value back into it here: its setter stores the pref, so
        // every window open would save the default as a user choice.

        // Register for NSWindow fullscreen notifications so we can flip
        // `contentRoot.windowMode`. windowed mode docks the
        // filmstrip under the canvas; fullscreen turns all four panels
        // into edge-activated overlays. Pinned state is persisted in
        // Prefs and re-read on each mode entry (seeded in
        // ViewerContentView's init).
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(handleWillEnterFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: self
        )
        nc.addObserver(
            self,
            selector: #selector(handleDidEnterFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: self
        )
        nc.addObserver(
            self,
            selector: #selector(handleWillExitFullScreen(_:)),
            name: NSWindow.willExitFullScreenNotification,
            object: self
        )
        nc.addObserver(
            self,
            selector: #selector(handleDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: self
        )

        // Wire up the navigation: pass the list, then jump to the start index.
        // Route the opening decode through the nav coalescer so that if the
        // user starts mashing Space / → before the first image has decoded,
        // those inputs cleanly supersede this initial jump instead of racing
        // serial decodes through the DecodeQueue actor.
        let list = imageSources
        let idx = max(0, min(startIndex, list.count - 1))

        // Seed the main-actor intent cursor synchronously so the first
        // paint of the overlay (and any rapid keypresses issued before
        // `setNavigation` has landed on the actor) have a valid cursor
        // to work with.
        intent.setNavigation(list: list, currentIndex: idx)

        navCoalescer.run { [weak self] in
            guard let self else { return }
            await self.navigation.setNavigation(list: list, currentIndex: idx)
            // A new window never read its ratings, flags and tags,
            // so the filmstrip had no marks provider and drew no marks
            // (only a later list change loaded them). One batched read,
            // after the first photo is up: nothing on the first-pixel path.
            if !Task.isCancelled { await self.navigate(to: idx) }
            if self.contentRoot.filmstripMarks == nil { self.loadCullingRecords() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ViewerWindow is programmatic only.")
    }

    public override var canBecomeKey: Bool { true }

    // MARK: - Close

    private(set) var didTearDown = false

    // Windowed chrome (ViewerWindow+Chrome.swift).
    var splitController: ViewerSplitController?
    var toolbarController: ViewerWindowToolbar?
    /// The visible hover platter of the toolbar (macOS 26+).
    var toolbarHover: ToolbarHover?
    var autoHider: TitlebarAutoHider?
    /// Spec 27 V7: the frames before and after the window widened for edit mode.
    var editWidenRestore: (original: NSRect, widened: NSRect)?
    /// True while `setEditWidthFrame` runs (scopes the 150 ms resize time).
    var editWidthResizing = false
    /// Tests: pretend the window is (not) in full screen for the edit-width logic.
    var fullScreenOverrideForTesting: Bool?
    /// Edit ended in full screen: the pre-edit size comes back when full screen ends.
    var editWidenReturnPending = false
    /// Edit mode is on (as the layout last heard).
    var editLayoutActive = false
    /// Tests: the screen area the widened window must stay inside.
    var editScreenVisibleFrameForTesting: NSRect?
    var titlebarScrim: TitlebarScrimView?
    /// Step 1 (reveal the hidden titlebar on a strip click).
    /// Tests switch it off to reach the canvas safety net.
    var stripRevealEnabled = true

    /// The running full-resolution decode, at most
    /// one per window. Cancelled on navigation.
    var fullResTask: Task<Void, Never>?
    /// Oriented pixel sizes read from file headers, by URL, so "100 %" is
    /// known at once when a photo comes back.
    var headerPixelSizes: [URL: CGSize] = [:]
    /// Files turned for viewing only (types that can't be written): the
    /// turn is dropped on navigation, so their cached size is too.
    var viewOnlyTurnedURLs: Set<URL> = []
    var fullResHairlineShown = false
    /// The edit exit alert asked by a close or a
    /// navigation. One at a time; a second request while it runs is dropped.
    var editExitTask: Task<Void, Never>?
    /// Close-time asynchronous queue/cache teardown. Kept so tests and
    /// coordinated shutdown paths can observe completion instead of
    /// guessing with a delay.
    private var closeResourceTeardownTask: Task<Void, Never>?

    /// Closing a viewer frees its decode cache,
    /// neighbour textures and on-screen image at once. Measured before:
    /// 4 windows 1487 MB, close 3 → still 951 MB. Whatever may still
    /// hold the window object (AppKit, accessibility clients, a late
    /// task), the pixels are gone.
    public override func close() {
        // Final close is already authorized by windowShouldClose. Retire the
        // attached canvas before AppKit orders the window out; afterwards its
        // live-drawable guard must (correctly) refuse an invisible window.
        tearDownAfterClose()
        super.close()
    }

    func tearDownAfterClose() {
        guard !didTearDown else { return }
        didTearDown = true
        cancelNavigationPreviews()
        reviewDecisionSerial &+= 1
        returnHintPopover?.close(); returnHintPopover = nil
        imagePressureObservation?.cancel(); imagePressureObservation = nil
        onImagePressureHandledForTesting = nil
        reviewPersistenceBanner?.dispose(); reviewPersistenceBanner = nil
        _ = cancelEditLoad()
        editReentryGeneration &+= 1
        editReentryTask?.cancel()
        editReentryTask = nil
        cancelFullResolution()
        textureRefetchTask?.cancel()
        textureRefetchTask = nil
        editExitTask?.cancel()
        editExitTask = nil
        navCoalescer.cancel()
        hiddenTrimTask?.cancel()
        chordExpiryTask?.cancel()
        chordExpiryTask = nil
        flushPendingOrientation()
        stopWatching()
        autoHider?.stop()
        NotificationCenter.default.removeObserver(self)
        contentRoot.releaseImages()
        contentRoot.imageView.disposeAfterClose()
        let nav = navigation
        closeResourceTeardownTask = Task.detached(priority: .utility) {
            await nav.teardown()
            DisplayTextureFactory.releaseCaches()
        }
    }

    /// Test seam: waits until the decode queue and shared image caches have
    /// completed their close-time release work.
    func waitForResourceTeardownForTesting() async {
        await closeResourceTeardownTask?.value
    }

    /// While our custom full-screen animation runs, the frame must be free
    /// to cover the menu bar (the exit starts from the screen frame).
    public override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        if fullScreenTransition.isAnimating { return frameRect }
        return super.constrainFrameRect(frameRect, to: screen)
    }

    /// Test seam: the Metal view the viewer paints into.
    internal var imageViewForTesting: MetalImageView { contentRoot.imageView }
    /// Test seam: the content root (mode flips, filmstrip).
    internal var contentRootForTesting: ViewerContentView { contentRoot }
    /// The canvas view that takes the keys (Compare hands them back here).
    var canvasResponder: NSView { contentRoot }
    public override var canBecomeMain: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Navigation

    /// Kinds of nav a dispatch can request. Each resolves to an index + a
    /// decode action — we handle the feedback pipeline (position overlay,
    /// thumb bridge, spinner) uniformly for all of them.
    private enum NavKind {
        case jump(Int)
        case advance
        case retreat
    }

    public func navigate(to index: Int) async {
        cancelFullResolution()
        await navigateWithFeedback(.jump(index))
    }

    func advance() async {
        cancelFullResolution()
        await navigateWithFeedback(.advance)
    }

    func retreat() async {
        cancelFullResolution()
        await navigateWithFeedback(.retreat)
    }

    /// Unified nav entry point that drives the layered feedback pipeline
    /// around whichever DecodeQueue call the `kind` maps to:
    ///
    ///   1. Bump the feedback generation and show the position overlay
    ///      as soon as we know the target index.
    ///   2. Schedule the position overlay's hairline indicator (200 ms
    ///      grace) + apply the deferred canvas dim (120 ms grace). Both
    ///      are cancelled by first-paint so fast cached nav sees neither.
    ///   3. Fire two sub-tasks in parallel:
    ///      - a thumbnail fetch (best-effort; drops silently if full-res
    ///        wins the race or the generation is superseded),
    ///      - the real full-res decode (awaits NavigationController).
    ///   4. Whichever lands first paints its layer; later layers check
    ///      their generation before painting (via
    ///      `NavigationFeedbackState.shouldPaintThumb` /
    ///      `shouldPaintFull`) so a slow thumb can't stomp on a fast
    ///      full-res result.
    ///
    /// Errors still flow through `showDecodeError()`; the feedback
    /// state is reset to `.idle` on error so a subsequent nav starts
    /// fresh.
    private func cancelNavigationPreviews() {
        navigationPreviewGeneration &+= 1
        embeddedPreviewTask?.cancel(); embeddedPreviewTask = nil
        thumbnailBridgeTask?.cancel(); thumbnailBridgeTask = nil
    }

    private func navigateWithFeedback(_ kind: NavKind) async {
        guard !didTearDown else { return }
        cancelNavigationPreviews()
        _ = cancelEditLoad()
        let previewGeneration = navigationPreviewGeneration
        // 1. Resolve target from the synchronous main-actor intent cursor.
        //    This is the crux of the bug fix: by committing the user's
        //    intent *here* — before any actor await or decode work — the
        //    position overlay tracks the cumulative keystroke count
        //    even when intermediate decode tasks are cancelled by
        //    `navCoalescer`. The previous implementation awaited
        //    `navigation.index()` (an actor hop), which never advanced
        //    during rapid-fire navigation because `NavigationController`
        //    only updates its cursor on decode success — and most
        //    decodes during a key-mash get cancelled.
        let target: NavTarget?
        switch kind {
        case .jump(let i): target = intent.jumpIntent(to: i)
        case .advance:     target = intent.advanceIntent()
        case .retreat:     target = intent.retreatIntent()
        }

        guard let target else {
            // List empty or jump out of range — no overlay to show. Flow
            // into the decode path so the existing error handling reports
            // it consistently.
            await performNavigationOnly(kind)
            return
        }

        // Leaving a photo that shows its RAW: its slot is the primary again.
        await restorePrimarySourcesBeforeLeaving(to: target.index)
        guard !Task.isCancelled, !didTearDown, previewGeneration == navigationPreviewGeneration else { return }
        let generation = feedbackState.beginNavigation()
        // What a completed swipe already put on screen.
        let handOver = takeSwipeHandOver(for: target.index)

        // 2. Position overlay — paints synchronously from the intent
        //    we just resolved. No actor hop, no decode dependency.
        contentRoot.showNavigationPosition(
            index: target.index,
            total: target.total,
            filename: target.filename
        )
        contentRoot.setPositionMarks(positionMarks(for: target.index))
        // Filmstrip selection follows generations, not decode paints —
        // Rapid arrow-key nav should move the highlighted
        // cell as fast as the intent cursor moves, even if the full-res
        // decode is still in flight.
        contentRoot.updateFilmstripSelectionOnIntent(target.index)

        // Move the filmstrip neighbor rebuild
        // AHEAD of the decode. Previously the strip only updated on
        // `applyNavigated` (post-decode), so during a key-mash the
        // selection highlight would drift outside the visible window
        // before new cells loaded. Rebuilding on intent keeps the
        // strip in sync with the cursor. The post-decode call at
        // `applyNavigated` remains but is a cheap no-op because
        // `updateNeighbors` diffs by global index — surviving cells
        // skip rebuild, only entering/leaving cells churn.
        // Filmstrip refresh must not delay the main decode (it used to be
        // awaited here, before the decode even started). Run it after, at
        // low priority.
        let stripIndex = target.index
        Task(priority: .utility) { @MainActor [weak self] in
            await self?.updateFilmstrip(centeredOn: stripIndex)
        }
        feedbackState.didShowOverlay()

        // 3. Hairline loading indicator + canvas dim — both deferred for
        //    fast-path decodes:
        //    * Hairline: 100 ms grace inside the position overlay.
        //      Fast decodes cancel the grace and the hairline never
        //      appears; slow decodes (cold RAWs, iCloud-pending) grow
        //      the hairline along the pill's bottom edge.
        //    * Predictive-skip race: kick off `DecodeTimePredictor` for
        //      the target URL in parallel with the 100 ms grace timer.
        //      If the predictor resolves first with an estimate above
        //      the 150 ms threshold, the grace is cancelled and the
        //      hairline is shown immediately at t=0. If it resolves
        //      after the grace has fired (hairline already visible),
        //      the predictor call is a no-op. If it predicts fast, the
        //      existing grace path runs unchanged.
        //    * Canvas dim: 120 ms grace, cleared by first paint.
        //    Per-nav distinctness is carried by the image swap + the
        //    overlay text update — no per-keystroke chrome pulse.
        // A target the decode queue already holds (the usual
        // case for next/prev — neighbours are prefetched and GPU-ready)
        // paints in the same turn. Skip the hairline, the dim and both
        // stand-ins, so a cached photo never flashes a low-res preview.
        // A swipe that handed over the prefetched texture counts as cached
        // even if the window moved since: no stand-in may cover it.
        var cachedHit = handOver == .photo
        if !cachedHit { cachedHit = await navigation.cachedEntry(at: target.index) != nil }
        guard !Task.isCancelled, !didTearDown, previewGeneration == navigationPreviewGeneration else { return }
        if handOver == .standIn || handOver == .nothing {
            // The swipe's picture (thumbnail or empty canvas) is the new
            // photo's: title, subtitle and inspector follow it now.
            markDisplayed(target.index)
        }
        if handOver == .standIn {
            // The thumbnail is already the current picture: no bridge
            // stand-in replaces it (both bridges check this phase).
            feedbackState.didPaintThumb(generation: generation)
            contentRoot.showPreviewBadge()
        }
        if cachedHit {
            ShrikeSignposts.navigation.event("cachedTarget", "idx=\(target.index)")
        }
        if !cachedHit, feedbackState.shouldShowLoadingIndicator(generation: generation) {
            // Start the grace path with a conservative default `predicted`
            // so the bar pre-fill math is defined even if the
            // predictor is slow to resolve or the source can't be stat'd
            // (synthetic / network sources). The predictor race below
            // refines this: if it resolves with predicted > 150 ms it
            // takes the zero-grace path; if ≤ 150 ms it re-seeds the
            // grace path with the actual value so pre-fill + Phase A
            // duration reflect reality.
            contentRoot.scheduleHairlineIndicator(
                predicted: Self.hairlineDefaultPredicted
            )
            scheduleHairlinePredictiveSkip(
                for: target.index,
                generation: generation
            )
        }
        // The dim is for the previous photo still on screen; after a
        // swipe it is already gone.
        if !cachedHit, handOver == nil { contentRoot.applyCanvasDim() }

        // 5. Best-effort placeholder bridge — TWO racing paths, first to
        //    land wins:
        //
        //    a) Embedded preview (camera-instant path). Reads the source
        //       container's embedded JPEG via `FileImageSource.loadEmbeddedPreview`
        //       — the same data path the camera body's LCD uses for instant
        //       review. For an Olympus 5184×3888 JPG this returns a
        //       1920×1440 sub-image in 10-30 ms (vs the 80-200 ms cold
        //       full-res decode). When present, this is uniformly faster
        //       AND sharper than the ThumbnailCache 1024 px bridge.
        //
        //    b) ThumbnailCache bridge (1024 px). Existing path — best for
        //       the second visit to an image (memory-tier hit, ~few ms)
        //       and for sources that don't expose an embedded preview at
        //       all (small JPGs, generated content, archive members).
        //
        //    Both paths are gated by `shouldPaintThumb(generation:)` so:
        //    * Whichever lands first paints the placeholder + shows the
        //      PREVIEW badge.
        //    * The loser's late paint is dropped because `shouldPaintThumb`
        //      returns false once we transition from `.waiting` to
        //      `.showingThumb`.
        //    * A late paint from a superseded nav is also dropped because
        //      its `generation` no longer matches `currentGeneration`.
        //    * The full-res decode (step 6) always wins over either
        //      placeholder via `shouldPaintFull`, which doesn't care
        //      about the phase — only the generation.
        //
        //    Why both paths in parallel rather than "embedded first,
        //    thumb-cache as fallback"? Three reasons:
        //      1. ThumbnailCache memory hits return in <2 ms, faster
        //         than even an embedded-preview ImageIO call. Letting
        //         them race means the SECOND visit to an image is
        //         instant from the cache.
        //      2. We don't know which (if either) is available without
        //         doing the work. Sequential probing would add at least
        //         one extra round-trip in the failure case.
        //      3. Both paths are cheap to lose — the embedded-preview
        //         CGImage just gets released on `shouldPaintThumb`
        //         returning false. No retained state to clean up.
        let thumbTargetIndex = target.index
        // Stand-in rules:
        //  * none at all for a cached target (above);
        //  * none when the full decode is expected in < 40 ms — a preview
        //    that shows for one or two frames reads as a flash;
        //  * no embedded preview smaller than 1/4 of the window's long
        //    edge in pixels (a 160 px EXIF thumb blown up is worse than
        //    one more frame of the previous photo).
        // Optional work owns only its source/shared cache, never the window's
        // navigation controller or decode queue while suspended.
        let thumbSource = intent.sourceAt(thumbTargetIndex)
        let thumbnailCache = services.thumbnailCache
        let targetURL = (thumbSource as? FileImageSource)?.url
        let minPreviewLongEdge = Self.minEmbeddedPreviewLongEdge(
            windowLongEdgePixels: max(frame.width, frame.height) * backingScaleFactor
        )

        // (a) Embedded preview. No artificial budget — the read either
        //     returns in 10-30 ms or returns `nil` (no embedded preview
        //     in the container). Errors become nil for this best-effort path.
        embeddedPreviewTask = Task { [weak self, cachedHit] in
            defer {
                if self?.navigationPreviewGeneration == previewGeneration { self?.embeddedPreviewTask = nil }
            }
            guard !cachedHit, let thumbSource, !Task.isCancelled else { return }
            if self?.feedbackState.shouldPaintThumb(generation: generation) != true {
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewSkipped",
                    "idx=\(thumbTargetIndex) reason=generation"
                )
                return
            }
            if await Self.fullDecodeLikelyFast(targetURL) {
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewSkipped", "idx=\(thumbTargetIndex) reason=fast"
                )
                return
            }
            guard !Task.isCancelled else { return }
            ShrikeSignposts.thumbnail.event(
                "embeddedPreviewStart",
                "idx=\(thumbTargetIndex) gen=\(generation)"
            )
            let preview = try? await thumbSource.loadEmbeddedPreview()
            guard let preview else {
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewSkipped",
                    "idx=\(thumbTargetIndex) reason=nil"
                )
                return
            }
            guard max(preview.width, preview.height) >= minPreviewLongEdge else {
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewSkipped", "idx=\(thumbTargetIndex) reason=tiny"
                )
                return
            }
            guard !Task.isCancelled, let self, !self.didTearDown else { return }
            if self.feedbackState.shouldPaintThumb(generation: generation) {
                self.contentRoot.setPlaceholderImage(
                    preview,
                    sourceID: thumbSource.id
                )
                self.markDisplayed(thumbTargetIndex)
                self.feedbackState.didPaintThumb(generation: generation)
                self.contentRoot.clearCanvasDim()
                self.contentRoot.showPreviewBadge()
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewDone",
                    "idx=\(thumbTargetIndex) painted=true size=\(preview.width)x\(preview.height)"
                )
            } else {
                ShrikeSignposts.thumbnail.event(
                    "embeddedPreviewSkipped",
                    "idx=\(thumbTargetIndex) reason=superseded"
                )
            }
        }

        // (b) ThumbnailCache bridge. We call the thumbnail cache
        //    directly — no artificial time budget, no `Task.yield()` head
        //    start for full-res. The generation check
        //    (`shouldPaintThumb`) is the only gate we need: if full-res
        //    has already committed to screen by the time the thumb
        //    resolves, the paint is skipped silently. If the user has
        //    already pressed another arrow key, the generation mismatch
        //    drops the stale thumb just as cleanly. Same gate also drops
        //    a thumb that arrives after the embedded preview already
        //    painted (since `didPaintThumb` flips phase to `.showingThumb`).
        //
        //    The 2 s branch inside `timeBoundedThumbnail` requests
        //    cancellation; a cancellation-resistant cache child can keep
        //    the task group waiting longer. That work owns only the source
        //    and shared cache, so it cannot keep a closed viewer alive.
        //    Under normal operation the fetch
        //    returns in a few ms (memory tier) to a few hundred ms (cold
        //    cache on a large HEIC/RAW), and the signposts below let us
        //    measure exactly that in Instruments.
        thumbnailBridgeTask = Task { [weak self, cachedHit] in
            defer {
                if self?.navigationPreviewGeneration == previewGeneration { self?.thumbnailBridgeTask = nil }
            }
            guard !cachedHit, let thumbSource, !Task.isCancelled else { return }
            if self?.feedbackState.shouldPaintThumb(generation: generation) != true {
                ShrikeSignposts.thumbnail.event(
                    "bridgeFetchSkipped",
                    "idx=\(thumbTargetIndex) reason=generation"
                )
                return
            }
            if await Self.fullDecodeLikelyFast(targetURL) {
                ShrikeSignposts.thumbnail.event(
                    "bridgeFetchSkipped", "idx=\(thumbTargetIndex) reason=fast"
                )
                return
            }
            guard !Task.isCancelled else { return }
            ShrikeSignposts.thumbnail.event(
                "bridgeFetchStart",
                "idx=\(thumbTargetIndex) gen=\(generation)"
            )
            let thumb = await Self.timeBoundedThumbnail(
                source: thumbSource,
                cache: thumbnailCache,
                maxPixelSize: Self.thumbBridgeMaxPixelSize
            )
            guard let thumb else {
                ShrikeSignposts.thumbnail.event(
                    "bridgeFetchSkipped",
                    "idx=\(thumbTargetIndex) reason=nil"
                )
                return
            }
            guard !Task.isCancelled, let self, !self.didTearDown else { return }
            if self.feedbackState.shouldPaintThumb(generation: generation) {
                self.contentRoot.setPlaceholderImage(
                    thumb,
                    sourceID: thumbSource.id
                )
                self.markDisplayed(thumbTargetIndex)
                self.feedbackState.didPaintThumb(generation: generation)
                // Thumb paint clears the canvas dim (the image canvas
                // is now showing SOMETHING of the new target) but does
                // NOT cancel the hairline progress fill. The full decode
                // is still running and IS the event the bar is
                // actually tracking; the thumb bridge is a separate
                // layer. Cancelling the hairline here was the root
                // cause of the "no bar at all during rapid
                // nav" bug: every cached thumb paint fired within the
                // 100 ms grace window and cancelled the pending show,
                // so for burst navs the grace never fired.
                self.contentRoot.clearCanvasDim()
                // Surface the "PREVIEW" pill the same frame as the
                // thumb paint so the user sees the cue from frame 0.
                self.contentRoot.showPreviewBadge()
                ShrikeSignposts.thumbnail.event(
                    "bridgeFetchDone",
                    "idx=\(thumbTargetIndex) painted=true"
                )
            } else {
                ShrikeSignposts.thumbnail.event(
                    "bridgeFetchSkipped",
                    "idx=\(thumbTargetIndex) reason=superseded"
                )
            }
        }

        // 6. The actual decode. We funnel every nav kind through
        //    `jump(to: target.index)` so the decoder follows the
        //    synchronously-resolved intent, not its own separate cursor.
        //    This keeps decode in lockstep with what the overlay is
        //    already showing — advance/retreat's modular arithmetic has
        //    already been applied above by the intent layer.
        do {
            let entry = try await navigation.jumpEntry(to: target.index)
            let (image, idx) = (entry.image, target.index)
            if Task.isCancelled { return }
            if feedbackState.shouldPaintFull(generation: generation) {
                feedbackState.didPaintFull(generation: generation)
                contentRoot.hidePreviewBadge()
                // Full-res paint — clear the dim (no-op if thumb already
                // did it) and cancel/fade the hairline indicator. Both
                // are cheap no-ops if they never appeared (fast path).
                contentRoot.clearCanvasDim()
                contentRoot.completeHairlineIndicator()
                await applyNavigated(
                    image: image, index: idx,
                    prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy
                )
            }
        } catch is CancellationError {
            // Supersession — a newer nav request is already in flight
            // behind us and will paint its own result. Cancellations
            // are *routine* during rapid arrow/Space nav (see the
            // DecodeQueue generation-counter fix): if we flashed the
            // error overlay here we'd strobe every time the user
            // held an arrow key. The successor owns the feedback
            // state from here — don't touch it. Don't hide the
            // hairline either: letting it carry from stale gen →
            // successor gen avoids a per-press chrome flicker.
            return
        } catch {
            if Task.isCancelled { return }
            feedbackState.reset()
            contentRoot.hidePreviewBadge()
            // Lift the dim so the error overlay is legible against the
            // canvas, and fire the position overlay's red flash —
            // 400 ms hold, then revert, preempted by the next nav.
            contentRoot.clearCanvasDim()
            contentRoot.flashPositionOverlayError()
            showContextualDecodeError(index: target.index)
            contentRoot.updateInspectorPosition(index: target.index, total: list.count)
            markDisplayed(target.index)
            ShrikeSignposts.navigation.event(
                "navigateFailed",
                "\(error.localizedDescription)"
            )
        }
    }

    /// Race `DecodeTimePredictor` against the 100 ms grace timer. If the
    /// predictor returns an estimate above
    /// `hairlinePredictiveShowThreshold` (150 ms), cancel
    /// the grace and show the hairline immediately. Otherwise do
    /// nothing — the grace timer keeps running and the existing
    /// fast-path contract is preserved.
    ///
    /// The predictor itself is fast (a `stat(2)` plus a single actor
    /// hop — typically < 2 ms), so the race is almost always won by the
    /// predictor when the decode is slow. When it loses (the grace
    /// fired first), `showHairlineImmediately()` is a no-op, so we
    /// never double-show.
    ///
    /// Only issues a predictive-skip when the target `ImageSource` is a
    /// `FileImageSource` (the only kind we can `stat(2)`). Synthetic /
    /// network sources stay on the pure-grace path, which is the
    /// correct conservative behavior: without a URL we have no cheap
    /// predictor signal, and the 100 ms grace covers the slow case
    /// via its own timer firing.
    /// Full decodes predicted under this skip the stand-ins.
    nonisolated static let fastDecodeThreshold: TimeInterval = 0.040

    /// True when `DecodeTimePredictor` expects the full decode of `url`
    /// to land within `fastDecodeThreshold`. Unknown sources: false.
    nonisolated static func fullDecodeLikelyFast(_ url: URL?) async -> Bool {
        guard let url else { return false }
        let predicted = await DecodeTimePredictor.predict(url: url, store: .shared)
        return predicted < fastDecodeThreshold
    }

    /// Smallest embedded preview worth painting: 1/4 of the window's
    /// long edge in pixels.
    nonisolated static func minEmbeddedPreviewLongEdge(windowLongEdgePixels: CGFloat) -> Int {
        Int((windowLongEdgePixels / 4).rounded(.up))
    }

    /// Test seam.
    internal var navigationForTesting: NavigationController { navigation }

    private func scheduleHairlinePredictiveSkip(
        for index: Int,
        generation: UInt64
    ) {
        // Resolve the URL synchronously from the intent cursor. If the
        // source isn't a FileImageSource, skip — no predictor signal.
        // The grace path with the default predicted still runs so the
        // slow case is covered by its own 100 ms timer firing.
        guard let source = intent.sourceAt(index) as? FileImageSource else {
            return
        }
        let url = source.url

        Task.detached { [weak self] in
            let predicted = await DecodeTimePredictor.predict(
                url: url,
                store: .shared
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Two gates to clear before surfacing the hairline:
                //
                // 1. Generation must still match — a newer nav has already
                //    taken over otherwise, and the new generation owns the
                //    hairline state.
                //
                // 2. The full-res decode for this generation must still be
                //    in flight (`shouldShowLoadingIndicator` checks both 1
                //    AND `isDecodeInFlight`, i.e. phase ∈ {.waiting,
                //    .showingThumb}). Without this gate the predictor's
                //    detached Task could lose its race against a fast
                //    decode — small PNG, warm cache hit, embedded preview
                //    bridging, anything in the < ~10 ms range — and
                //    surface the hairline AFTER `completeHairlineIndicator()`
                //    has already run as a no-op (because the bar wasn't
                //    visible yet to cancel). The bar would then sit in
                //    Phase A → B → C with no subsequent decode landing to
                //    fire `completeHairline()`, and the user sees the
                //    "loading bar is stuck" bug. The race got tighter
                //    once `handleImageChange` became non-blocking
                //    (CIContext.render queues GPU work instead of waiting
                //    on `MTKTextureLoader`), and tighter again once
                //    the embedded-preview Task was added; it
                //    competes for the main actor on the same nav.
                //
                // Both gates are necessary AND together — neither alone
                // is sufficient. The predictive skip only has authority over
                // "decodes still in flight"; this check restores that contract.
                guard self.feedbackState.shouldShowLoadingIndicator(
                    generation: generation
                ) else {
                    return
                }
                if predicted >
                    NavigationPositionOverlayView.hairlinePredictiveShowThreshold
                {
                    // Predictive-skip path — show now at width 0, Phase A
                    // runs linearly over `predicted` seconds.
                    self.contentRoot.showHairlineIndicatorImmediately(
                        predicted: predicted
                    )

                    let predictedMs = Int((predicted * 1000).rounded())
                    let format = ImageFormat(url: url)?.rawValue ?? "other"
                    ShrikeSignposts.navigation.event(
                        "hairlinePredictiveShow",
                        "predicted_ms=\(predictedMs) format=\(format)"
                    )
                } else {
                    // Grace path — re-seed with the actual predicted value
                    // so the pre-fill math + Phase A duration reflect
                    // reality. Idempotent: if the grace task is already
                    // pending (normal case), this is a no-op on timing
                    // but updates the captured `predicted` that the grace
                    // handler will read. If the hairline is already
                    // visible (grace fired with the default predicted
                    // between beginNavigation and the predictor resolving),
                    // the view's `restartPhasesFromCurrent` re-aligns the
                    // phase animation with the updated duration without
                    // resetting the min-visible clock.
                    self.contentRoot.scheduleHairlineIndicator(
                        predicted: predicted
                    )
                }
            }
        }
    }

    private func decodeResult(
        for kind: NavKind
    ) async throws -> (image: CGImage, index: Int) {
        switch kind {
        case .jump(let i): return try await navigation.jump(to: i)
        case .advance:     return try await navigation.advance()
        case .retreat:     return try await navigation.retreat()
        }
    }

    /// Fallback decode with no feedback layering (used when the target
    /// index is out of range so we can't set up a meaningful overlay).
    private func performNavigationOnly(_ kind: NavKind) async {
        do {
            let (image, idx) = try await decodeResult(for: kind)
            if Task.isCancelled { return }
            await applyNavigated(image: image, index: idx)
        } catch is CancellationError {
            // Superseded by a newer nav — successor will paint.
            return
        } catch {
            if Task.isCancelled { return }
            let index = displayedItem?.listIndex ?? intent.currentIndex
            showContextualDecodeError(index: index)
        }
    }

    /// Thumbnail fetch with a 2 s leak-protection ceiling. Returns `nil` if
    /// the cache lookup fails outright (unsupported format, disk fault) or
    /// if the fetch somehow doesn't return within 2 s — the latter is a
    /// safety net against a hung `ThumbnailCache` actor, not a UX budget.
    /// Under normal operation the fetch finishes well inside the ceiling:
    /// a few ms on memory-tier hits and a few hundred ms on a cold cache
    /// decoding a large HEIC/JPEG/RAW. The generation guard in
    /// `NavigationFeedbackState.shouldPaintThumb` is what actually
    /// coordinates thumb-vs-full ordering — this helper just prevents a
    /// stuck task from accumulating across many navs.
    ///
    /// We deliberately don't cancel the underlying cache task — it may
    /// still populate the memory tier for the next time this index is hit.
    private static let thumbBridgeSafetyCeiling: TimeInterval = 2.0

    private static func timeBoundedThumbnail(
        source: any ImageSource,
        cache: ThumbnailCache,
        maxPixelSize: Int,
        budget: TimeInterval = thumbBridgeSafetyCeiling
    ) async -> CGImage? {
        await withTaskGroup(of: CGImage?.self) { group in
            group.addTask {
                try? await cache.thumbnail(for: source, maxPixelSize: maxPixelSize)
            }
            group.addTask {
                try? await Task.sleep(
                    nanoseconds: UInt64(budget * 1_000_000_000)
                )
                return nil
            }
            // First finisher chooses the result. Leaving the group still
            // waits for the cancelled child to finish safely; this is not
            // a hard deadline for cancellation-resistant work.
            // `group.next()` returns `Element?` — i.e. `CGImage??`. The
            // outer Optional is only nil if the group is empty (we added
            // two tasks, so never); flattening picks the real value.
            let first: CGImage?
            switch await group.next() {
            case .some(let inner): first = inner
            case .none:            first = nil
            }
            group.cancelAll()
            return first
        }
    }

    /// Shared post-navigation tail: pushes the new image into the content
    /// view, refreshes filmstrip neighbours, then surfaces the file-level
    /// metadata (path, EXIF via inspector, Live Photo companion detection,
    /// drag-out source URL).
    private func applyNavigated(
        image: CGImage, index: Int, prepared: DisplayTexture? = nil,
        resourceLease: ImageResourceLease? = nil, imageIsLazy: Bool = false
    ) async {
        let total = await navigation.count()
        contentRoot.setImage(
            image, index: index, total: total,
            sourceID: intent.sourceAt(index)?.id,
            prepared: prepared, resourceLease: resourceLease, imageIsLazy: imageIsLazy
        )
        markDisplayed(index)
        await updateFilmstrip(centeredOn: index)

        let url = await currentFileURL()
        contentRoot.setCurrentURL(url)
        contentRoot.histogramImageShown(image, url: url)
        refreshInspectorFileState()
    }

    func updateFilmstrip(centeredOn index: Int) async {
        let count = await navigation.count()
        var neighbors: [(idx: Int, source: any ImageSource)] = []
        let radius = Self.filmstripNeighborRadius(
            visibleWidth: contentRoot.filmstripVisibleWidth(),
            cellSize: contentRoot.filmstripCellSize()
        )
        let start = max(0, index - radius)
        let end = min(count - 1, index + radius)
        if start <= end {
            // NavigationController owns the list; it's the source of truth.
            for i in start...end {
                if let src = await navigation.sourceAt(i) {
                    neighbors.append((i, src))
                }
            }
        }
        contentRoot.updateFilmstripNeighbors(
            neighbors,
            current: index,
            services: services
        )
    }

    /// Compute the filmstrip neighbor radius from the visible strip width.
    ///
    /// This used to be hardcoded to 10 (21-cell window),
    /// which on a 3440 pt ultra-wide display left the right half of the
    /// strip empty — ~1500 pt of cells packed flush-left inside a
    /// ~3400 pt visible area. Making it dynamic
    /// fixes fullscreen and windowed strips uniformly because the same
    /// call site feeds both.
    ///
    /// - Floor at 10 so small windows keep the historical behavior and
    ///   the function stays defined when `visibleWidth == 0` (first call,
    ///   pre-layout — the next navigation picks up the real width).
    /// - Ceiling at 80 so an 8K display doesn't blow the thumbnail cache.
    ///   160 cells is already well past "enough to cover the screen" for
    ///   any realistic cell width, and ThumbnailCache's own memory
    ///   pressure eviction handles the eventual trim.
    /// - Uses `cellSize × 1.0` as the *average* expected cell width. The
    ///   aspect clamp band is `[0.5×, 1.6×]`, symmetric around 1.0×; using
    ///   the minimum (0.5×) would over-fetch for portraits, using the
    ///   maximum (1.6×) would under-fetch on landscape-heavy folders.
    ///   The `+4` safety covers the worst-case wide run.
    internal static func filmstripNeighborRadius(
        visibleWidth: CGFloat,
        cellSize: CGFloat
    ) -> Int {
        let floorRadius = 10
        let ceilingRadius = 80
        guard visibleWidth > 0, cellSize > 0 else { return floorRadius }
        let estWidth = cellSize            // average cell width (aspect 1.0)
        let cellsPerHalfStrip = Int(ceil((visibleWidth / 2) / estWidth))
        let radius = max(floorRadius, cellsPerHalfStrip + 4)
        return min(ceilingRadius, radius)
    }

    // MARK: - Key handling

    public override func keyDown(with event: NSEvent) {
        // Kick the chrome idle timer on every keypress so holding an
        // arrow key in fullscreen doesn't let the edge panels strobe
        // out mid-nav.
        contentRoot.kickIdleTimer()
        // t=0 anchor for key → glass latency (pairs with the
        // `imageFrame` event MetalImageView emits when a new image
        // texture reaches the screen).
        ShrikeSignposts.navigation.event("keyDown", "code=\(event.keyCode)")

        let snapshot = KeyEventSnapshot.from(event, isKeyUp: false)
        if handleKeySnapshot(snapshot) { return }
        super.keyDown(with: event)
    }

    /// The key path without an `NSEvent` (tests drive it directly).
    /// Returns false when the key is not ours.
    @discardableResult
    func handleKeySnapshot(_ snapshot: KeyEventSnapshot) -> Bool {
        let context: ShortcutContext =
            contentRoot.isEditModeActive ? .editMode : .viewer
        if snapshot.key == "\u{1b}", cancelEditLoad() { return true }
        // Esc while a copy / move shows its progress: stop the rest.
        if chordPrefix == nil, snapshot.key == "\u{1b}", transfers.cancelRunning() {
            return true
        }
        var resolved = ViewerKeyMap.action(
            for: snapshot,
            context: context,
            preset: ShortcutTable.livePreset,
            chordPrefix: chordPrefix
        )
        // Any key that doesn't continue the chord cancels it and is then
        // handled normally (`M` then `→` still navigates).
        if resolved == nil, chordPrefix != nil {
            clearChord()
            resolved = ViewerKeyMap.action(
                for: snapshot, context: context, preset: ShortcutTable.livePreset, chordPrefix: nil
            )
        }
        if let action = resolved {
            // Chord consumed — clear it.
            if chordPrefix != nil {
                clearChord()
            }
            dispatch(action)
            return true
        }

        // Mac preset: a plain ⌫ / ⌦ trashes nothing; one hint per run.
        if context == .viewer,
           TrashKeyHint.handle(snapshot, preset: ShortcutTable.livePreset, responder: firstResponder,
                               toast: { [weak self] in self?.contentRoot.toast($0) }) {
            return true
        }
        // Navigation keys in edit mode are in the edit keymap now: they
        // reach `dispatch`, which asks through the exit alert.
        return false
    }

    // MARK: - Fullscreen notifications

    @objc private func handleWillEnterFullScreen(_ notification: Notification) {
        // The windowed inspector collapses (state kept);
        // No NSToolbar in full screen.
        splitController?.willEnterFullScreen()
        autoHider?.show(animated: false)
        if toolbarShownBeforeFullScreen == nil {
            // While editing, the user's state is the viewer toolbar's,
            // not the edit toolbar's.
            toolbarShownBeforeFullScreen = contentRoot.viewerToolbarShownUnderEdit
                ?? toolbar?.isVisible ?? true
        }
        toolbar?.isVisible = false
        // Flip to fullscreen mode *before* the animation lands so the
        // edge-activated panels are mounted (still hidden) by the time
        // AppKit finishes the zoom.
        contentRoot.windowMode = .fullscreen
        installScrimIfNeeded()
    }

    @objc private func handleDidEnterFullScreen(_ notification: Notification) {
        // Textures follow the full-screen canvas.
        contentRoot.updateTextureLongEdge()
        contentRoot.refitAfterFullScreenChange()
        contentRoot.fullScreenDidEnter()
    }

    @objc private func handleWillExitFullScreen(_ notification: Notification) {
        splitController?.willExitFullScreen()
        contentRoot.windowMode = .windowed
    }

    @objc private func handleDidExitFullScreen(_ notification: Notification) {
        // The toolbar comes back to the user's setting only once the
        // window is out of full screen.
        restoreToolbarAfterFullScreen()
        installScrimIfNeeded()
        contentRoot.updateTextureLongEdge()
        contentRoot.refitAfterFullScreenChange()
        finishEditWidthReturnAfterFullScreen()
        if returnToBrowserAfterFullScreenExit {
            returnToBrowserAfterFullScreenExit = false
            returnToBrowser()
        }
    }

    /// View › Show/Hide Toolbar moves `contentLayoutRect`: the fit area
    /// follows when auto-hide is off.
    public override func toggleToolbarShown(_ sender: Any?) {
        super.toggleToolbarShown(sender)
        contentRoot.needsLayout = true
    }

    func restoreToolbarAfterFullScreen() {
        let shown = toolbarShownBeforeFullScreen ?? true
        toolbarShownBeforeFullScreen = nil
        if contentRoot.isEditToolbarInstalled {
            // Still editing: the edit toolbar stays shown; the user's
            // state waits for the edit exit.
            contentRoot.viewerToolbarShownUnderEdit = shown
            return
        }
        toolbar?.isVisible = shown
        if shown { autoHider?.show(animated: false) }
    }

    public override func keyUp(with event: NSEvent) {
        let snapshot = KeyEventSnapshot.from(event, isKeyUp: true)
        // Only case we care about on keyUp: releasing Z for loupe dismissal.
        if snapshot.key == "z" {
            contentRoot.setLoupeActive(false)
        }
        super.keyUp(with: event)
    }

    // MARK: - Action dispatch

    private func zoomTo(pixelScale: Double) {
        let view = contentRoot.imageView
        view.setPixelScale(pixelScale, anchor: view.pointerAnchorOverImage())
        contentRoot.userChangedZoom()
    }

    internal func dispatch(_ action: ViewerAction) {
        if action == .slideshow { reviewDecisionSerial &+= 1 }
        if Self.leavesPhoto(action), !reviewAutomaticMove { reviewDecisionSerial &+= 1 }
        // RAW files are never written: refuse edits and rotates on that view.
        if refuseWriteWhileRAWShown(action) { return }
        // Any action during a swipe finishes it at once.
        contentRoot.imageView.finishActiveSwipe()
        // Leaving the photo while editing asks first
        // (Save / Don't Save / Cancel), then goes on.
        if contentRoot.isEditModeActive, Self.leavesPhoto(action) {
            let targetIndex: Int
            switch action {
            case .nextImage:
                if handleEdgeOfFolder(.next) { return }
                targetIndex = intent.currentIndex + 1
            case .prevImage:
                if handleEdgeOfFolder(.previous) { return }
                targetIndex = intent.currentIndex - 1
            case .firstImage: targetIndex = 0
            case .lastImage: targetIndex = list.count - 1
            case .nextFolder: goToAdjacentFolder(.next); return
            case .prevFolder: goToAdjacentFolder(.previous); return
            default: return
            }
            guard let target = list[targetIndex], target.primary != displayedItem?.group.primary else { return }
            let windowed = contentRoot.windowMode == .windowed
            leaveEditModeThen(reason: .navigation) { [weak self] in
                guard let self else { return }
                guard let index = self.list.groups.firstIndex(where: { $0.primary == target.primary }) else {
                    self.contentRoot.toast(ToastContent("That photo is no longer available."))
                    return
                }
                self.coalesceNav { [weak self] in await self?.navigate(to: index) }
                if windowed { self.reenterEditModeAfterNavigation() }
            }
            return
        }
        switch action {
        case .nextImage:
            if handleEdgeOfFolder(.next) { return }
            coalesceNav { [weak self] in await self?.advance() }
        case .prevImage:
            if handleEdgeOfFolder(.previous) { return }
            coalesceNav { [weak self] in await self?.retreat() }
        case .firstImage:
            coalesceNav { [weak self] in await self?.navigate(to: 0) }
        case .lastImage:
            coalesceNav { [weak self] in
                guard let self else { return }
                let last = await self.navigation.count() - 1
                if last >= 0 { await self.navigate(to: last) }
            }
        // Zoom scales are pixel percent: 1.0 = one image pixel per screen
        // pixel. Anchor: the pointer when it is over the
        // image, else the view centre.
        case .zoomActualSize, .zoom100:
            zoomTo(pixelScale: 1.0)
        case .zoomBestFit, .fitToWindow:
            contentRoot.imageView.zoomToFit()
            contentRoot.userChangedZoom()
        case .zoom200:
            zoomTo(pixelScale: 2.0)
        case .zoom300:
            zoomTo(pixelScale: 3.0)
        case .zoom1000:
            zoomTo(pixelScale: 10.0)
        case .zoomIn:
            contentRoot.imageView.stepZoom(in: true)
            contentRoot.userChangedZoom()
        case .zoomOut:
            contentRoot.imageView.stepZoom(in: false)
            contentRoot.userChangedZoom()
        case .fitWidth:
            contentRoot.imageView.contentMode = .fitWidth
            contentRoot.userChangedZoom()
        case .fitHeight:
            contentRoot.imageView.contentMode = .fitHeight
            contentRoot.userChangedZoom()
        case .rotateLeft:
            orientFile(.rotate(quarters: -1))
        case .rotateRight:
            orientFile(.rotate(quarters: 1))
        case .rotate180:
            orientFile(.rotate(quarters: 2))
        case .flipHorizontal:
            orientFile(.flipHorizontal)
        case .flipVertical:
            orientFile(.flipVertical)
        case .toggleFullscreen:
            toggleFullScreen(nil)
        case .showInBrowser:
            showInBrowser()
        case .exitFullscreen:
            handleEscape()
        case .toggleInspector, .toggleExif:
            // The system inspector in a window, the HUD
            // inspector in full screen.
            if contentRoot.windowMode == .fullscreen || splitController == nil {
                contentRoot.togglePanel(.inspector)
            } else {
                splitController?.toggleInspector(nil)
            }
        case .toggleFilmstrip:
            // ⌘K works in a window's edit mode; full screen has no strip there.
            guard !(contentRoot.isEditModeActive && contentRoot.windowMode == .fullscreen) else { break }
            contentRoot.togglePanel(.filmstrip)
        case .toggleHistogram:
            contentRoot.toggleHistogramOverlay()
        case .zoomMenu:
            break   // the capsule opens its own menu
        case .toggleRAWFile:
            toggleRAWFile()
        case .unpinAllPanels:
            contentRoot.unpinAllPanels()
        case .toggleMagnifierHold(let pressed):
            contentRoot.setLoupeActive(pressed)
        case .rate(let stars):
            rateDisplayed(stars)
        case .toggleFlag:
            toggleFlagDisplayed()
        case .editTags:
            showTagEditor()
        case .copyToFolder:
            startChord("c")
        case .moveToFolder:
            startChord("m")
        case .fileToFolder(let verb, let choice):
            fileToFolder(verb, choice)
        case .cancelChord:
            clearChord()
        case .copyPath:
            copyCurrentPath()
        case .copyBitmap:
            copyCurrentBitmap()
        case .paste, .cut:
            break
        case .deleteToTrash:
            deleteCurrentToTrash()
        case .rename:
            renameDisplayed()
        case .revealInFinder:
            revealCurrentInFinder()
        case .undo, .redo:
            break
        case .openExternalEditor(let slot):
            openDisplayedInExternalEditor(slot: slot)
        case .openEditMode:
            enterEditMode(landOn: nil)   // no tool
        case .slideshow:
            startSlideshow()
        case .batch:
            openBatch()
        case .compare:
            openCompare()
        case .print:
            printDisplayed()
        case .crop:
            enterEditMode(landOn: .crop)
        case .resize:
            enterEditMode(landOn: .resize)
        case .colorAdjust:
            enterEditMode(landOn: .color)
        case .showInMaps:
            showDisplayedInMaps()
        case .beginCopyChord:
            startChord("c")
        case .beginMoveChord:
            startChord("m")
        case .beginEditToolChord:
            break // The ⌘K tool chord is gone.
        case .enterEditMode:
            enterEditMode(landOn: nil)   // no tool
        case .exitEditMode:
            contentRoot.editModeController.attemptExit(reason: .userToggled)
        case .selectEditTool(let tool):
            if contentRoot.isEditModeActive {
                contentRoot.editModeController.selectTool(tool)
            } else {
                enterEditMode(landOn: tool)
            }
        case .applyCurrentEditTool:
            contentRoot.editModeController.done()
        case .resetCurrentEditTool:
            contentRoot.editModeController.resetCurrentTool()
        case .undoEdit:
            contentRoot.editModeController.performUndo()
        case .redoEdit:
            contentRoot.editModeController.performRedo()
        case .saveEditedFile:
            Task { [weak self] in await self?.saveEditedFile(asPanel: false) }
        case .saveEditedFileAs:
            Task { [weak self] in await self?.saveEditedFile(asPanel: true) }
        case .rotateLossless(let quarters), .editRotate90(let quarters):
            // One rotate concept. Edit mode turns the recipe;
            // otherwise it is the file rotate.
            if contentRoot.isEditModeActive {
                contentRoot.editModeController.appendSnapped90(quarters: quarters)
            } else {
                orientFile(.rotate(quarters: quarters))
            }
        case .share:
            // Route to the system share picker anchored
            // on the toolbar's share button. No-op if the current source
            // is not a file on disk (e.g., archived sources).
            Task { [weak self] in
                guard let self else { return }
                guard let url = await self.currentFileURL() else { return }
                await MainActor.run {
                    self.contentRoot.showShare(url: url)
                }
            }
        case .autoLevels(let kind):
            // Land on Levels (entering edit mode first),
            // then apply. Nothing is written to disk until Done / ⌘S.
            if contentRoot.isEditModeActive {
                contentRoot.editModeController.applyLevelsAuto(kind)
            } else {
                enterEditMode(landOn: .levels) { [weak self] in
                    self?.contentRoot.editModeController.applyLevelsAuto(kind)
                }
            }
        case .resetEdits:
            // Edit › Reset Edits (the edit chrome).
            contentRoot.editModeController.revertPendingEdits()
        case .prevFolder:
            goToAdjacentFolder(.previous)
        case .nextFolder:
            goToAdjacentFolder(.next)
        }
    }

    // MARK: - Edit mode orchestration

    /// Enter edit mode on the currently-displayed image. Waits for the
    /// full-resolution decode: the display texture may
    /// be a preview or subsampled, and `sourcePixelSize` must be the
    /// file's. Over 150 ms shows "Loading full image…"; Esc cancels.
    func editSourceMatchesDisplayed(_ source: URL, item: DisplayedItem) -> Bool {
        guard !didTearDown, displayedItem == item, !item.isRAWShown,
              list.generation == item.generation, list[item.listIndex] == item.group,
              intent.currentIndex == item.listIndex,
              (source == item.group.primary || GroupList.canonical(source) == GroupList.canonical(item.group.primary)),
              let intended = intent.sourceAt(item.listIndex) else { return false }
        if let file = intended as? FileImageSource {
            return file.url == source || GroupList.canonical(file.url) == GroupList.canonical(source)
        }
        return intended.id == FileImageSource(url: source).id
    }

    var canBeginEditingDisplayedPhoto: Bool {
        guard navCoalescer.isIdle, let item = displayedItem,
              editSourceMatchesDisplayed(item.group.primary, item: item),
              let intended = intent.sourceAt(item.listIndex) else { return false }
        return contentRoot.imageView.sourceID == intended.id
    }

    func enterEditMode(landOn tool: EditTool?, then afterEnter: (@MainActor () -> Void)? = nil) {
        if contentRoot.isEditModeActive {
            if let tool { contentRoot.editModeController.selectTool(tool) }
            afterEnter?()
            return
        }
        // A photo that cannot be opened has nothing to edit. The image view still holds the
        // previous photo's pixels behind the error card, so without this the keys (E, C, R...)
        // would edit and save the wrong pixels over the broken file (spec 26 §2).
        if contentRoot.isShowingDecodeError {
            contentRoot.toast(ViewerContentView.decodeErrorEditReason)
            return
        }
        guard contentRoot.imageView.image != nil else {
            contentRoot.toast("No image to edit")
            return
        }
        guard !didTearDown, editLoadTask == nil else { return }
        guard canBeginEditingDisplayedPhoto, let item = displayedItem,
              !contentRoot.editModeController.isActive else {
            contentRoot.toast("Wait for the current photo to finish loading before editing.")
            return
        }
        reviewDecisionSerial &+= 1
        editLoadGeneration &+= 1
        let request = editLoadGeneration
        let url = item.group.primary
        let sourceLoader = editSourceLoaderForTesting
        let spinner = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.editLoadingDelay)
            guard !Task.isCancelled, self?.didTearDown == false, self?.editLoadGeneration == request else { return }
            self?.contentRoot.setEditLoadingVisible(true)
        }
        editLoadTask = Task { @MainActor [weak self] in
            // A turn or flip pressed in the viewer is on screen but maybe not in the file
            // yet. Write it first and show the file's pixels, so the editor and the view
            // agree and nothing is turned twice (or not at all).
            await self?.settleViewerOrientationForEdit()
            let full: CGImage?
            var fullLease: ImageResourceLease?
            if let sourceLoader {
                full = await sourceLoader(url)
            } else if url.isFileURL {
                let loaded = try? await EditSourceLoader.loadForEditing(at: url, resources: .shared, owner: ImageResourceOwner())
                full = loaded?.image; fullLease = loaded?.lease
            } else {
                full = nil
            }
            spinner.cancel()
            guard let self, self.editLoadGeneration == request else { return }
            self.contentRoot.setEditLoadingVisible(false)
            self.editLoadTask = nil
            guard !Task.isCancelled, !self.didTearDown, self.navCoalescer.isIdle,
                  self.editSourceMatchesDisplayed(url, item: item),
                  !self.contentRoot.isEditModeActive, !self.contentRoot.editModeController.isActive else { return }
            guard let image = full ?? self.contentRoot.imageView.image else { return }
            do {
                self.contentRoot.editModeController.loadedOriginalLease = fullLease
                self.contentRoot.enterEditMode(
                    image: image,
                    url: url,
                    landOn: tool
                )
                self.contentRoot.editModeController.onSaveRequested = { [weak self] in
                    Task { [weak self] in
                        await self?.saveEditedFile(asPanel: false)
                    }
                }
                self.contentRoot.editModeController.onSaveAsRequested = { [weak self] in
                    Task { [weak self] in
                        await self?.saveEditedFile(asPanel: true)
                    }
                }
                self.contentRoot.editModeController.onExitOutcome = { [weak self] outcome in
                    self?.handleEditExitOutcome(outcome)
                }
                afterEnter?()
            }
        }
    }

    /// Writes a pending Rotate / Flip and, when the view still carries a turn, replaces
    /// the displayed pixels with a fresh decode of the file (which resets the view turn).
    func settleViewerOrientationForEdit() async {
        let view = contentRoot.imageView
        guard view.rotationDegrees != 0 || view.isFlippedHorizontally || view.isFlippedVertically else { return }
        flushPendingOrientation()
        await orientationWriteChain?.value
        guard !didTearDown else { return }
        await redrawDisplayedKeepingViewNow()
        view.resetOrientation()
        for url in viewOnlyTurnedURLs { headerPixelSizes[url] = nil }
        viewOnlyTurnedURLs.removeAll()
    }

    /// Delay before "Loading full image…" shows.
    static var editLoadingDelay: Duration = .milliseconds(150)

    /// Esc while edit mode waits for the full image: stop waiting.
    func cancelEditLoad() -> Bool {
        editLoadGeneration &+= 1
        guard let task = editLoadTask else { return false }
        task.cancel()
        editLoadTask = nil
        contentRoot.setEditLoadingVisible(false)
        return true
    }

    /// Waits for a pending edit-mode entry (tests).
    func waitForEditLoad() async { await editLoadTask?.value }

    private func handleEditExitOutcome(_ outcome: EditExitOutcome) {
        switch outcome {
        case .exited, .cancelled: break
        case .needsSave, .needsSaveAs:
            guard let departure = contentRoot.editModeController.departureToken else { return }
            Task { [weak self] in
                guard let self else { return }
                if await !self.saveEditedFile(asPanel: outcome == .needsSaveAs, departure: departure) {
                    await self.contentRoot.editModeController.restoreCancelledDeparture(for: departure)
                }
            }
        }
    }

    // MARK: - Navigation task coalescing

    /// Replace any in-flight navigation task with a new one.
    ///
    /// WHY: Prior to this, each keyDown spawned a detached `Task` that awaited
    /// the `NavigationController` / `DecodeQueue` actor chain. Because those
    /// actors serialize work, five quick Space presses would queue five
    /// sequential decodes — the first press appeared to do nothing while the
    /// slow first decode ran, then after release all five targets drained in
    /// order, making the viewer zip past the intended image. Cancelling the
    /// outstanding task and starting a new one preserves the invariant
    /// "latest keystroke wins" and keeps hold-to-advance responsive.
    ///
    /// `DecodeQueue` coalesces in-flight decodes by index, so cancelling here
    /// doesn't cancel the actual GPU/ImageIO work — it just drops this
    /// window's *interest* in the stale target. The prefetch window keeps
    /// cached neighbours warm so single taps remain near-instant.
    /// After a move that left edit mode: wait for the new photo, then start
    /// edit mode again with no tool, so a run of photos can be edited in turn.
    func reenterEditModeAfterNavigation() {
        editReentryTask?.cancel()
        editReentryGeneration &+= 1
        let generation = editReentryGeneration
        editReentryTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.editReentryGeneration == generation { self.editReentryTask = nil }
            }
            var waited = 0
            while let self, !Task.isCancelled, !self.navCoalescer.isIdle, waited < 300 {
                try? await Task.sleep(for: .milliseconds(10))
                waited += 1
            }
            guard !Task.isCancelled, let self, !self.didTearDown,
                  !self.contentRoot.isEditModeActive, self.displayedItem != nil else { return }
            self.enterEditMode(landOn: nil)
        }
    }

    /// Awaits scheduled post-navigation edit entry and its source load.
    /// Tests must observe the final mode, rather than the first decode paint.
    func waitForEditReentryForTesting() async {
        await editReentryTask?.value
        await editLoadTask?.value
    }

    func coalesceNav(_ body: @escaping @MainActor @Sendable () async -> Void) {
        navCoalescer.run(body)
    }

    // MARK: - File ops

    /// The displayed file — never the decode cursor.
    private func currentFileURL() async -> URL? {
        displayedItem?.shownURL
    }

    private func copyCurrentPath() {
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.currentFileURL() else { return }
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(url.path, forType: .string)
                self.contentRoot.toast("Copied path")
            }
        }
    }

    /// ⌘C: the displayed file and its image. In edit mode
    /// this is the file as it is on disk, not the unsaved recipe.
    private func copyCurrentBitmap() {
        guard let item = displayedItem else { return }
        PhotoPasteboard.write([item.group], to: .general)
        contentRoot.toast("Copied")
    }

    private func deleteCurrentToTrash() {
        // Edit mode: ignored, with a beep.
        if contentRoot.isEditModeActive { NSSound.beep(); return }
        guard let item = displayedItem else { return }
        trash(item)
    }

    private func revealCurrentInFinder() {
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.currentFileURL() else { return }
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: - Responder-chain selectors (menu / first-responder targets)
    //
    // MainMenu.swift wires the Image and Edit submenus to these selectors
    // via untyped `Selector(("…"))` strings. The menu item is enabled
    // when a viewer window is key (per `validateUserInterfaceItem` below)
    // and disabled when focus is on, e.g., the Preferences window.
    //
    // Each selector routes through the same `dispatch(_:)` path that
    // keyboard shortcuts use so behaviour stays in one place.
    //
    // Note on `@objc dynamic`: we deliberately avoid declaring these with
    // `@objc dynamic` overrides on NSWindow-typed signatures because the
    // menu items use `Selector(("name:"))` strings (not `#selector`).
    // The Objective-C runtime resolves them by name at send time.

    @objc public func enterEditMode(_ sender: Any?) {
        dispatch(.enterEditMode)
    }

    @objc public func exitEditMode(_ sender: Any?) {
        dispatch(.exitEditMode)
    }

    @objc public func imageRotateLosslessCW(_ sender: Any?) {
        dispatch(.rotateLossless(quarters: 1))
    }

    @objc public func imageRotateLosslessCCW(_ sender: Any?) {
        dispatch(.rotateLossless(quarters: -1))
    }

    @objc public func imageRotateLossless180(_ sender: Any?) {
        dispatch(.rotateLossless(quarters: 2))
    }

    @objc public func editSelectCrop(_ sender: Any?) {
        dispatch(.selectEditTool(.crop))
    }

    @objc public func editSelectRotate(_ sender: Any?) {
        dispatch(.selectEditTool(.rotate))
    }

    @objc public func editSelectResize(_ sender: Any?) {
        dispatch(.selectEditTool(.resize))
    }

    @objc public func editSelectColor(_ sender: Any?) {
        dispatch(.selectEditTool(.color))
    }

    @objc public func editSave(_ sender: Any?) {
        dispatch(.saveEditedFile)
    }

    @objc public func editSaveAs(_ sender: Any?) {
        dispatch(.saveEditedFileAs)
    }

    @objc public func editUndo(_ sender: Any?) {
        dispatch(.undoEdit)
    }

    @objc public func editRedo(_ sender: Any?) {
        dispatch(.redoEdit)
    }

    // MARK: - Chord handling

    func startChord(_ prefix: Character) {
        chordPrefix = prefix
        chordExpiryTask?.cancel()
        chordExpiryTask = nil
        // `C` / `M`: no timeout; the HUD shows after 250 ms.
        if let verb = FileChord.verb(for: prefix) {
            transfers.armHUD(verb)
            return
        }
        contentRoot.toast("\(prefix) + …")
        chordExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run {
                self?.clearChord()
            }
        }
    }

    func clearChord() {
        chordPrefix = nil
        chordExpiryTask?.cancel()
        chordExpiryTask = nil
        transfers.dismissHUD()
    }
}


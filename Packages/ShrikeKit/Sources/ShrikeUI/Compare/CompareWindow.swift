//
//  CompareWindow.swift
//  ShrikeUI
//
//  The Compare window: 2–4 images side by side, each in the
//  viewer's `MetalImageView`, with Lock (shared zoom and pan), focus,
//  rating / flag / rotate / trash on the focused pane, and undo.
//
//  * One window, lazy, reused: a second ⌘4 replaces its images. It opens
//    at the origin window's frame; full screen is allowed.
//  * Each pane has its own small `DecodeQueue` (radius 1) aimed at the
//    pane's size × backing scale: the panes move through the list on
//    their own, and one shared queue would cancel one pane's jump with
//    the next pane's. Past fit, a pane swaps in its full-resolution
//    decode (`loadFullResolution`), as the viewer does.
//  * `close()` frees every texture and decode at once (like
//    `ViewerWindow.close()`); the window is not used again.
//  * Culling goes through `CullingUndo.perform` (ordered writes); trash
//    goes through undo; rotate turns the view now and writes the
//    lossless file 500 ms after the last press.
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeIO
import ShrikeRendering

/// The window Compare was opened from. It hears about changes Compare
/// makes, so its list and marks stay right.
@MainActor
protocol CompareOrigin: AnyObject {
    func compareDidChangeCulling(_ values: [URL: FileRecord])
    /// Files Compare moved to the Trash (primaries).
    func compareDidRemove(_ primaries: Set<URL>)
    /// Files an undo put back.
    func compareDidRestore(_ groups: [ImageGroup])
    /// Files whose bytes changed (rotate and its undo).
    func compareDidChangeFiles(_ urls: [URL])
    /// Compare closed while it had the keys: the origin takes them back
    /// at once.
    func compareDidClose()
    /// The origin's watcher scope: Compare's own writes are ignored there
    /// too, because the origin is told directly (above).
    var compareWatcherScope: WindowWatcherScope { get }
}

/// One pane's state.
@MainActor
final class ComparePane {
    let view: ComparePaneView
    let queue: DecodeQueue
    /// Index into the window's list.
    var index: Int
    var listTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    var infoTask: Task<Void, Never>?
    var fullResTask: Task<Void, Never>?
    var info: PhotoInfo?
    var record = FileRecord()
    var loadedURL: URL?
    var decodedLongEdge = 0
    var pendingOrientation: PendingOrientation?
    var orientationTimer: Task<Void, Never>?
    var pressureObservation: ImagePressureObservation?
    private(set) var pressureHandledCount = 0

    func didHandlePressure() { pressureHandledCount &+= 1 }

    init(view: ComparePaneView, queue: DecodeQueue, index: Int) {
        self.view = view
        self.queue = queue
        self.index = index
    }

    func cancelWork() {
        pressureObservation?.cancel(); pressureObservation = nil
        listTask?.cancel()
        loadTask?.cancel()
        infoTask?.cancel()
        fullResTask?.cancel()
        orientationTimer?.cancel()
        loadTask = nil
        infoTask = nil
        fullResTask = nil
        orientationTimer = nil
    }
}

@MainActor
public final class CompareWindow: NSWindow, NSToolbarDelegate, MetalImageViewDelegate {

    /// The open Compare window (one at a time).
    public private(set) static var current: CompareWindow?
    /// Tests build the window offscreen and never order it in.
    nonisolated(unsafe) static var presentsWindows = true

    let services: ShrikeServices
    private(set) var list: [ImageGroup] = []
    private(set) var panes: [ComparePane] = []
    private(set) var focusedIndex = 0
    private(set) var isLocked = true
    private(set) weak var referencePane: ComparePane?
    private var referenceGeneration: UInt64 = 0
    private var chromeObservation: ChromeTextObservation?
    private var persistenceBanner: PersistenceBanner?
    weak var origin: (any CompareOrigin)? {
        didSet { watcherScope.setPartner(origin?.compareWatcherScope) }
    }
    /// Compare watches no folder. Its writes are ignored only in the
    /// origin's watcher (the origin is told directly); every other window's
    /// watcher reports them.
    let watcherScope = WindowWatcherScope()
    lazy var fileOps = FileOps(metadata: services.metadataStore, backups: services.backupStore,
                               watchers: watcherScope)
    let compareUndoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = true
        return manager
    }()
    private let root = CompareRootView()
    let toastHost = ToastHostView(placement: .viewer)
    private var isSyncing = false
    private var isApplyingImage = false
    var trashChain: Task<Void, Never>?
    private var orientationWriteChain: Task<Void, Never>?
    private var sizeRefetchTask: Task<Void, Never>?
    private var shownOnceToasts: Set<String> = []
    private var isClosed = false
    /// The footer's record read must not undo a rating that lands while
    /// it runs.
    private var recordGuard = LateReadGuard()
    /// Tests answer the no-Trash alert here.
    var alertResponderForTesting: ((String) -> Int?)?
    private(set) var toastsForTesting: [String] = []

    private static let lockItem = NSToolbarItem.Identifier("shrike.compare.lock")
    private static let fitAllItem = NSToolbarItem.Identifier("shrike.compare.fitAll")
    nonisolated static let minimumWindowSize = NSSize(width: 480, height: 320)

    // MARK: Open

    /// Opens (or refills) the Compare window with `request`.
    @discardableResult
    static func open(_ request: CompareRequest, services: ShrikeServices, origin: (any CompareOrigin)?,
                     frame: NSRect?) -> CompareWindow {
        let window: CompareWindow
        if let existing = current, !existing.isClosed {
            window = existing
        } else {
            window = CompareWindow(services: services, frame: frame)
            current = window
        }
        window.origin = origin
        window.configure(list: request.list, shown: request.shown)
        if presentsWindows {
            window.makeKeyAndOrderFront(nil)
        }
        if request.truncated { window.toast(ToastContent(CompareSources.truncatedToast)) }
        return window
    }

    private init(services: ShrikeServices, frame: NSRect?) {
        self.services = services
        let rect = frame ?? NSRect(x: 0, y: 0, width: 1200, height: 760)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        collectionBehavior = [.fullScreenPrimary]
        minSize = NSSize(width: min(Self.minimumWindowSize.width, rect.width),
                         height: min(Self.minimumWindowSize.height, rect.height))
        title = "Compare"
        tabbingMode = .disallowed
        root.frame = NSRect(origin: .zero, size: contentRect(forFrameRect: self.frame).size)
        root.onLayout = { [weak self] in self?.layoutPanes() }
        contentView = root
        chromeObservation = ChromeTextObservation(root: root)
        toastHost.install(in: root)
        let banner = PersistenceBanner(store: services.metadataStore); persistenceBanner = banner
        banner.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(banner)
        NSLayoutConstraint.activate([banner.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            banner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8)])
        banner.onRecovered = { [weak self] in
            guard let self, !self.isClosed else { return }
            for pane in self.panes where self.list.indices.contains(pane.index) { self.readInfo(pane, url: self.list[pane.index].primary) }
        }
        let toolbar = NSToolbar(identifier: "shrike.compare.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
        toolbarStyle = .unified
        // After the toolbar: adding it grows the window by its height.
        if let frame { setFrame(frame, display: false) }
        makeFirstResponder(nil)
    }

    public override var undoManager: UndoManager? { compareUndoManager }
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    // MARK: Panes

    private func configure(list: [ImageGroup], shown: [Int]) {
        referencePane = nil; referenceGeneration &+= 1
        for pane in panes { tearDown(pane) }
        panes = []
        self.list = list
        for index in shown.prefix(CompareSources.maxPanes) { addPane(index: index, at: panes.count) }
        focusedIndex = 0
        layoutPanes()
        updateFocus()
        updateSubtitle()
        for pane in panes { load(pane) }
    }

    @discardableResult
    private func addPane(index: Int, at slot: Int) -> ComparePane {
        let view = ComparePaneView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.imageView.delegate = self
        let owner = ImageResourceOwner()
        let queue = DecodeQueue(windowRadius: 1, preparer: DisplayTextureFactory.preparer(resources: .shared, owner: owner), resourceOwner: owner)
        let pane = ComparePane(view: view, queue: queue, index: index)
        view.imageView.resources = queue.resources; view.imageView.resourceOwner = queue.resourceOwner
        view.onKeep = { [weak self, weak pane] in if let pane { self?.toggleReference(pane) } }
        view.onPrevious = { [weak self, weak pane] in self?.stepPane(pane, delta: -1) }
        view.onNext = { [weak self, weak pane] in self?.stepPane(pane, delta: 1) }
        pane.pressureObservation = queue.resources.observePressure { [weak pane] pressure in
            guard pressure != .normal else { return }
            Task { @MainActor [weak pane] in
                guard let pane else { return }
                let view = pane.view.imageView
                if view.isAtFit, !view.isZoomAnimating {
                    pane.fullResTask?.cancel(); pane.fullResTask = nil
                    view.dropFullResolution()
                }
                pane.didHandlePressure()

            }
        }
        root.addSubview(view, positioned: .below, relativeTo: toastHost)
        panes.insert(pane, at: min(slot, panes.count))
        pane.listTask = queueList(for: pane)
        return pane
    }

    private func queueList(for pane: ComparePane) -> Task<Void, Never> {
        let sources: [any ImageSource] = list.map { FileImageSource(url: $0.primary) }
        let queue = pane.queue
        let index = pane.index
        let previous = pane.listTask
        return Task {
            await previous?.value
            await queue.setNavigation(list: sources, currentIndex: index)
        }
    }

    private func tearDown(_ pane: ComparePane) {
        flushPendingOrientation(pane)
        pane.cancelWork()
        pane.view.imageView.delegate = nil
        pane.view.imageView.disposeAfterClose()
        pane.view.removeFromSuperview()
        let queue = pane.queue
        Task { await queue.purge() }
    }

    private func removePane(_ pane: ComparePane) {
        guard let slot = panes.firstIndex(where: { $0 === pane }) else { return }
        tearDown(pane)
        panes.remove(at: slot)
        guard !panes.isEmpty else {
            close()
            return
        }
        focusedIndex = min(focusedIndex, panes.count - 1)
        layoutPanes()
        updateFocus()
        updateSubtitle()
    }

    func layoutPanes() {
        let frames = CompareLayout.frames(count: panes.count, in: root.bounds)
        for (pane, frame) in zip(panes, frames) where pane.view.frame != frame {
            pane.view.frame = frame
        }
        scheduleSizeRefetch()
    }

    private func updateSubtitle() {
        subtitle = Self.subtitle(paneCount: panes.count)
    }

    /// "2 images · Tab switches pane · ← → change its photo"; no hint for one pane.
    static func subtitle(paneCount: Int) -> String {
        paneCount == 1 ? "1 photo" : "\(paneCount) photos · Tab switches pane · arrows change candidates"
    }

    /// Tab / ⇧Tab: the next or previous pane, wrapping. Nothing with one pane.
    func stepFocus(_ delta: Int) {
        guard panes.count > 1, attachedSheet == nil else { return }
        focus((focusedIndex + delta + panes.count) % panes.count)
        let index = panes[focusedIndex].index
        let name = list.indices.contains(index) ? list[index].displayName : ""
        Culling.announce("Pane \(focusedIndex + 1) of \(panes.count), \(name)")
    }

    private func updateFocus() {
        for (i, pane) in panes.enumerated() { pane.view.isFocused = i == focusedIndex }
    }

    var focusedPane: ComparePane? { panes.indices.contains(focusedIndex) ? panes[focusedIndex] : nil }

    func focus(_ slot: Int) {
        guard panes.indices.contains(slot) else { return }
        focusedIndex = slot
        updateFocus()
    }

    // MARK: Loading

    /// Long edge, in pixels, a pane's display decode aims for.
    private func targetLongEdge(_ pane: ComparePane) -> Int {
        let size = pane.view.bounds.size
        let scale = backingScaleFactor
        return max(256, Int((max(size.width, size.height) * scale).rounded(.up)))
    }

    func load(_ pane: ComparePane) {
        guard list.indices.contains(pane.index) else { return }
        pane.loadTask?.cancel()
        pane.fullResTask?.cancel()
        pane.fullResTask = nil
        let index = pane.index
        let group = list[index]
        let url = group.primary
        pane.view.showError(nil)
        pane.info = nil
        pane.record = FileRecord()
        updateFooter(pane)
        let edge = targetLongEdge(pane)
        let queue = pane.queue
        let listTask = pane.listTask
        pane.loadTask = Task { @MainActor [weak self, weak pane] in
            await listTask?.value
            await queue.setMaxLongEdge(edge)
            do {
                let entry = try await queue.jumpToEntry(index: index)
                guard !Task.isCancelled, let self, let pane, pane.index == index, !self.isClosed else { return }
                self.present(entry, in: pane, url: url, edge: edge)
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, let self, let pane,
                      pane.index == index, !self.isClosed else { return }
                pane.loadedURL = nil
                pane.view.imageView.setImage(nil, sourceID: nil)
                pane.view.showError(CompareFooter.errorText(group.displayName))
            }
        }
        readInfo(pane, url: url)
    }

    private func present(_ entry: DecodedImage, in pane: ComparePane, url: URL, edge: Int) {
        let view = pane.view.imageView
        isApplyingImage = true
        defer { isApplyingImage = false }
        view.setImage(entry.image, sourceID: entry.sourceID, prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy)
        view.resetOrientation()
        if let size = drawnSize(of: pane) { view.sourcePixelSize = size }
        pane.loadedURL = url
        pane.decodedLongEdge = max(entry.image.width, entry.image.height)
        if isLocked, let leader = panes.first(where: { $0 !== pane && $0.view.imageView.image != nil }) {
            copyView(from: leader, to: pane)
        } else {
            view.contentMode = .bestFit
        }
    }

    private func readInfo(_ pane: ComparePane, url: URL) {
        pane.infoTask?.cancel()
        let store = services.metadataStore
        let urls = [url]
        let token = recordGuard.begin()
        pane.infoTask = Task { @MainActor [weak self, weak pane] in
            let info = await Task.detached(priority: .utility) { try? PhotoInfo.readSync(url) }.value
            let record = await store.records(for: urls)[url]
            guard !Task.isCancelled, let self, let pane, self.list.indices.contains(pane.index),
                  self.list[pane.index].primary == url else { return }
            pane.info = info
            if let record {
                let merged = self.recordGuard.merge(read: [url: record], current: [url: pane.record], since: token)
                pane.record = merged[url] ?? record
            }
            if let size = self.drawnSize(of: pane), pane.loadedURL == url {
                pane.view.imageView.sourcePixelSize = size
                self.requestFullResolutionIfNeeded(pane)
            }
            self.updateFooter(pane)
        }
    }

    /// The size of the photo as drawn: the file's size with the pane's
    /// quarter turns applied (an odd count swaps width and height).
    func drawnSize(of pane: ComparePane) -> CGSize? {
        guard let size = pane.info?.pixelSize else { return nil }
        let quarters = Int((pane.view.imageView.rotationDegrees / 90).rounded())
        return quarters % 2 != 0 ? CGSize(width: size.height, height: size.width) : size
    }

    private func updateFooter(_ pane: ComparePane) {
        guard list.indices.contains(pane.index) else { return }
        let info = pane.info
        pane.view.setFooter(CompareFooter.text(
            name: list[pane.index].displayName, rating: pane.record.rating, flagged: pane.record.flagged,
            pixelSize: drawnSize(of: pane), aperture: info?.aperture, shutter: info?.shutter, iso: info?.iso),
            name: list[pane.index].displayName)
        pane.view.setReference(pane === referencePane, canPrevious: pane.index > 0, canNext: pane.index + 1 < list.count)
        if pane === referencePane { pane.view.setFooter("Reference · " + CompareFooter.text(name: list[pane.index].displayName, rating: pane.record.rating, flagged: pane.record.flagged, pixelSize: drawnSize(of: pane), aperture: info?.aperture, shutter: info?.shutter, iso: info?.iso)) }
    }

    /// A larger pane (full screen, resize) gets a larger display texture.
    private func scheduleSizeRefetch() {
        sizeRefetchTask?.cancel()
        guard !panes.isEmpty else { return }
        sizeRefetchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self, !self.isClosed else { return }
            for pane in self.panes { self.refetchIfSmall(pane) }
        }
    }

    private func refetchIfSmall(_ pane: ComparePane) {
        let edge = targetLongEdge(pane)
        let view = pane.view.imageView
        guard let url = pane.loadedURL, pane.decodedLongEdge > 0, pane.decodedLongEdge < edge,
              pane.loadTask == nil || view.image != nil else { return }
        if let src = view.sourcePixelSize, Int(max(src.width, src.height)) <= pane.decodedLongEdge { return }
        let index = pane.index
        let queue = pane.queue
        // The task holds the pane weakly and looks the view up after the
        // decode: a strong `view` here kept a closed window's Metal view
        // (and its textures) alive until a slow decode finished.
        Task { @MainActor [weak pane] in
            await queue.setMaxLongEdge(edge)
            guard let entry = try? await queue.jumpToEntry(index: index), let pane,
                  pane.index == index, pane.loadedURL == url,
                  max(entry.image.width, entry.image.height) > pane.decodedLongEdge else { return }
            let view = pane.view.imageView
            if view.swapInLargerDisplayTexture(entry.image, prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy,
                                               sourceID: entry.sourceID) {
                pane.decodedLongEdge = max(entry.image.width, entry.image.height)
            }
        }
    }

    // MARK: Full resolution

    func requestFullResolutionIfNeeded(_ pane: ComparePane) {
        let view = pane.view.imageView
        if view.isShowingFullResolution {
            if view.isAtFit, !view.isZoomAnimating { view.dropFullResolution() }
            return
        }
        guard pane.fullResTask == nil, view.wantsFullResolution else { return }
        let index = pane.index
        let sourceID = view.sourceID
        let queue = pane.queue
        pane.fullResTask = Task { @MainActor [weak pane] in
            let entry = try? await queue.loadFullResolution(at: index)
            guard let pane else { return }
            pane.fullResTask = nil
            let view = pane.view.imageView
            guard let entry, !Task.isCancelled, pane.index == index, !view.isAtFit else { return }
            view.swapInFullResolution(entry.image, prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy,
                                      sourceID: sourceID)
        }
    }

    // MARK: Lock

    private func pane(of view: MetalImageView) -> ComparePane? {
        panes.first { $0.view.imageView === view }
    }

    public func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double) { viewChanged(view) }
    public func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint) { viewChanged(view) }

    private func viewChanged(_ view: MetalImageView) {
        guard let pane = pane(of: view) else { return }
        requestFullResolutionIfNeeded(pane)
        guard isLocked, !isSyncing, !isApplyingImage else { return }
        syncOthers(from: pane)
    }

    /// Every other pane takes `leader`'s zoom and relative position.
    func syncOthers(from leader: ComparePane) {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for pane in panes where pane !== leader && pane.view.imageView.image != nil {
            copyView(from: leader, to: pane)
            requestFullResolutionIfNeeded(pane)
        }
    }

    private func copyView(from leader: ComparePane, to pane: ComparePane) {
        let source = leader.view.imageView
        let target = pane.view.imageView
        if case .bestFit = source.contentMode {
            target.contentMode = .bestFit
            return
        }
        let relative = CompareLock.relativeCentre(imageRect: source.drawnImageRect, viewBounds: source.bounds)
        target.setPixelScale(source.pixelScale, anchor: nil)
        let delta = CompareLock.panDelta(toCentre: relative, imageRect: target.drawnImageRect,
                                         viewBounds: target.bounds)
        let pan = target.pan
        target.pan = CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
    }

    func setLocked(_ locked: Bool) {
        isLocked = locked
        refreshLockItem()
        Culling.announce(locked ? "Sync Zoom and Pan on" : "Sync Zoom and Pan off")
        if locked, let leader = focusedPane { syncOthers(from: leader) }
    }

    /// Zoom In / Out on the focused pane (all panes when locked).
    func stepZoom(in zoomIn: Bool) {
        guard let pane = focusedPane, pane.view.imageView.image != nil else { return }
        pane.view.imageView.stepZoom(in: zoomIn)
        if isLocked { syncOthers(from: pane) }
    }

    /// `0` / the toolbar's Fit All: fit, pan reset (all panes when locked).
    func fitAll() {
        let targets = isLocked ? panes : (focusedPane.map { [$0] } ?? [])
        isSyncing = true
        defer { isSyncing = false }
        for pane in targets {
            pane.view.imageView.pan = .zero
            pane.view.imageView.zoomToFit()
            requestFullResolutionIfNeeded(pane)
        }
    }

    func toggleReference(_ pane: ComparePane) {
        guard panes.contains(where: { $0 === pane }) else { return }
        referenceGeneration &+= 1
        referencePane = referencePane === pane ? nil : pane
        for candidate in panes { updateFooter(candidate) }
        Culling.announce(referencePane == nil ? "Reference released" : "Photo kept as reference")
    }
    @objc func keepFocusedPhoto(_ sender: Any?) { if let pane = focusedPane { toggleReference(pane) } }
    private func stepPane(_ pane: ComparePane?, delta: Int) {
        guard let pane, let index = panes.firstIndex(where: { $0 === pane }) else { return }
        focus(index); step(delta, allPanes: false)
    }

    // MARK: Navigation

    /// ← / → in the focused pane; ⇧← / ⇧→ in every pane.
    func step(_ delta: Int, allPanes: Bool) {
        let targets = allPanes ? panes : (focusedPane.map { [$0] } ?? [])
        var moved = false
        for pane in targets where pane !== referencePane {
            let next = pane.index + delta
            guard list.indices.contains(next) else { continue }
            flushPendingOrientation(pane)
            pane.index = next
            moved = true
            load(pane)
        }
        if !moved { if focusedPane === referencePane { toast(ToastContent("Unpin to change this photo")) } else { NSSound.beep() } }
    }

    /// Wheel or swipe navigation moves that pane (and focuses it). The
    /// panes route the wheel exactly as the viewer does (the same
    /// `MetalImageView`): with the default "Mouse wheel:
    /// Changes image" the wheel at Fit changes the photo; zoomed in it
    /// pans; ⌘ / ⌥ + wheel (or the "Zooms" setting) zooms at the pointer,
    /// and with Lock on the other panes follow.
    public func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool) {
        guard let slot = panes.firstIndex(where: { $0.view.imageView === view }) else { return }
        focus(slot)
        step(forward ? 1 : -1, allPanes: false)
    }

    public func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool {
        guard let pane = pane(of: view) else { return false }
        return pane !== referencePane && list.indices.contains(pane.index + (forward ? 1 : -1))
    }

    // MARK: Keys

    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// ⌘ keys come here before the menu bar: ⌘1–⌘4 focus a pane (the
    /// menu's ⌘1–⌘4 belong to other windows), ⌘L / ⌘R / ⌘⌫ act on it.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, attachedSheet == nil, handleKey(event, commandKeysOnly: true) { return true }
        return super.performKeyEquivalent(with: event)
    }

    public override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    @discardableResult
    func handleKey(_ event: NSEvent, commandKeysOnly: Bool = false) -> Bool {
        var snapshot = KeyEventSnapshot.from(event, isKeyUp: false)
        // Tab reads as a control character that depends on Shift; the key code is exact.
        if event.keyCode == 48 {
            snapshot = KeyEventSnapshot(key: SpecialKey.tab, modifiers: snapshot.flags, keyCode: 48)
        }
        let unshifted = KeyCharacters.unshiftedKey(of: event)
        guard let hit = CompareKeyMap.hit(for: snapshot, unshiftedKey: unshifted,
                                          preset: ShortcutTable.livePreset) else {
            // Mac preset: a plain ⌫ / ⌦ trashes nothing; one hint per run.
            guard !commandKeysOnly else { return false }
            return TrashKeyHint.handle(snapshot, preset: ShortcutTable.livePreset, responder: firstResponder,
                                       toast: { [weak self] in self?.toast($0) })
        }
        if commandKeysOnly {
            // Undo / Redo stay with the Edit menu (it names the action).
            guard snapshot.flags.contains(.command), hit.command != .undo, hit.command != .redo else { return false }
        }
        return perform(hit)
    }

    @discardableResult
    func perform(_ hit: CompareKeyMap.Hit) -> Bool {
        let command = hit.command
        if let slot = ShrikeCommand.compareFocusCommands.firstIndex(of: command) {
            focus(slot)
            return true
        }
        if let stars = command.ratingValue {
            rate(stars, allPanes: hit.allPanes)
            return true
        }
        switch command {
        case .toggleFlag: toggleFlag(allPanes: hit.allPanes)
        case .previousImage: step(-1, allPanes: false)
        case .nextImage: step(1, allPanes: false)
        case .comparePreviousAll: step(-1, allPanes: true)
        case .compareNextAll: step(1, allPanes: true)
        case .zoomIn: stepZoom(in: true)
        case .zoomOut: stepZoom(in: false)
        case .compareFitAll: fitAll()
        case .compareLock: setLocked(!isLocked)
        case .rotateLeft: rotateFocused(.rotate(quarters: -1))
        case .rotateRight: rotateFocused(.rotate(quarters: 1))
        case .moveToTrash: trashFocused()
        case .undo: compareUndoManager.undo()
        case .redo: compareUndoManager.redo()
        case .escape: performClose(nil)
        case .compareFocusNext: stepFocus(1)
        case .compareFocusPrevious: stepFocus(-1)
        default: return false
        }
        return true
    }

    /// A click focuses the pane under the pointer.
    public override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let point = root.convert(event.locationInWindow, from: nil)
            if let slot = panes.firstIndex(where: { $0.view.frame.contains(point) }) { focus(slot) }
        }
        super.sendEvent(event)
    }

    // MARK: Culling (through CullingUndo)

    private func cullingTargets(allPanes: Bool) -> [ComparePane] {
        let targets = allPanes ? panes : (focusedPane.map { [$0] } ?? [])
        return targets.filter { list.indices.contains($0.index) }
    }

    func rate(_ stars: Int, allPanes: Bool) {
        let targets = cullingTargets(allPanes: allPanes)
        guard !targets.isEmpty else { return }
        let urls = Culling.imageURLs(of: targets.map { list[$0.index] })
        CullingUndo.perform(
            .rating, urls: urls, store: services.metadataStore, undoManager: compareUndoManager,
            compute: { Culling.ratingValues(stars, urls: urls, previous: $0) },
            onChange: { [weak self] values in self?.cullingDidChange(values) },
            onFailure: { [weak self] error in self?.toast(ToastContent(CullingUndo.failureMessage(.rating, error: error), kind: .error)) }, suppressing: watcherScope)
    }

    func toggleFlag(allPanes: Bool) {
        let targets = cullingTargets(allPanes: allPanes)
        guard !targets.isEmpty else { return }
        let groups = targets.map { list[$0.index] }
        let urls = Culling.imageURLs(of: groups)
        let leaders = groups.map(\.primary)
        CullingUndo.perform(
            .flag, urls: urls, store: services.metadataStore, undoManager: compareUndoManager,
            compute: { Culling.toggledFlagValues(urls: urls, leaders: leaders, previous: $0) },
            onChange: { [weak self] values in self?.cullingDidChange(values) },
            onFailure: { [weak self] error in self?.toast(ToastContent(CullingUndo.failureMessage(.flag, error: error), kind: .error)) }, suppressing: watcherScope)
    }

    private func cullingDidChange(_ values: [URL: FileRecord]) {
        recordGuard.noteWrite(values.keys)
        for pane in panes where list.indices.contains(pane.index) {
            if let record = values[list[pane.index].primary] {
                pane.record = record
                updateFooter(pane)
            }
        }
        origin?.compareDidChangeCulling(values)
    }

    /// Waits for the culling writes (tests).
    func waitForCullingWrites() async {
        await CullingUndo.waitForPendingWrites()
    }

    // MARK: Toast

    func toast(_ content: ToastContent, action: (@MainActor () -> Void)? = nil) {
        toastsForTesting.append(content.message)
        toastHost.show(content, action: action)
    }

    // MARK: Close

    public override func close() {
        guard !isClosed else { return }
        isClosed = true
        persistenceBanner?.dispose(); persistenceBanner = nil
        chromeObservation = nil
        // Esc, ⌘W or the last pane trashed: the window it came from gets
        // the keys back with its grid, list or canvas focused, so the
        // next ⇧→ acts at once. Not when another
        // window already has the keys.
        let handsBackKeys = isKeyWindow || NSApp.keyWindow == nil
        sizeRefetchTask?.cancel()
        for pane in panes { tearDown(pane) }
        panes = []
        if Self.current === self { Self.current = nil }
        super.close()
        if handsBackKeys { origin?.compareDidClose() }
    }

    var isClosedForTesting: Bool { isClosed }

    // MARK: Toolbar (system NSToolbar, tooltips from the resolver)

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.lockItem, Self.fitAllItem]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        item.target = self
        item.isBordered = true
        switch id {
        case Self.lockItem:
            item.action = #selector(toggleLockFromToolbar(_:))
            item.toolTip = "Zoom and pan in all panes together. " + ShortcutTable.tooltip(for: .compareLock, context: .compare)
            updateLockItem(item)
        case Self.fitAllItem:
            item.label = "Fit All"
            item.action = #selector(fitAllFromToolbar(_:))
            item.toolTip = ShortcutTable.tooltip(for: .compareFitAll, context: .compare)
            item.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Fit All")
        default:
            return nil
        }
        return item
    }

    static func lockImage(locked: Bool) -> NSImage? {
        NSImage(systemSymbolName: locked ? "lock.fill" : "lock.open",
                accessibilityDescription: locked ? "Zoom and pan locked" : "Zoom and pan unlocked")
    }

    var lockToolbarItem: NSToolbarItem? { toolbar?.items.first { $0.itemIdentifier == Self.lockItem } }
    var fitAllToolbarItem: NSToolbarItem? { toolbar?.items.first { $0.itemIdentifier == Self.fitAllItem } }

    private func updateLockItem(_ item: NSToolbarItem) {
        item.label = isLocked ? "Sync Zoom and Pan: On" : "Sync Zoom and Pan: Off"
        item.image = Self.lockImage(locked: isLocked)
    }

    private func refreshLockItem() {
        if let item = lockToolbarItem { updateLockItem(item) }
        fitAllToolbarItem?.label = isLocked ? "Fit All" : "Fit Selected"
        fitAllToolbarItem?.toolTip = isLocked ? "Fit All" : "Fit Selected"
    }

    @objc func toggleLockFromToolbar(_ sender: Any?) { setLocked(!isLocked) }
    @objc func fitAllFromToolbar(_ sender: Any?) { fitAll() }

    // MARK: Edit ▸ Undo / Redo

    @objc func undo(_ sender: Any?) { compareUndoManager.undo() }
    @objc func redo(_ sender: Any?) { compareUndoManager.redo() }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(keepFocusedPhoto(_:)):
            menuItem.state = focusedPane === referencePane ? .on : .off; return focusedPane != nil
        case #selector(toggleLockFromToolbar(_:)):
            menuItem.state = isLocked ? .on : .off; return true
        case #selector(fitAllFromToolbar(_:)): return true
        case NSSelectorFromString("undo:"):
            menuItem.title = compareUndoManager.undoMenuItemTitle
            return compareUndoManager.canUndo
        case NSSelectorFromString("redo:"):
            menuItem.title = compareUndoManager.redoMenuItemTitle
            return compareUndoManager.canRedo
        case ShrikeMainMenu.commandAction:
            guard let command = menuItem.shrikeCommand else { return false }
            return canPerform(command)
        default:
            return super.validateMenuItem(menuItem)
        }
    }
}

// MARK: - Menu commands (the menu bar while Compare is key)

extension CompareWindow: ShrikeMenuActions, ShrikeCommandTarget {

    @objc public func performShrikeCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = item.shrikeCommand else { return }
        perform(command)
    }

    public func canPerform(_ command: ShrikeCommand) -> Bool {
        guard let pane = focusedPane, list.indices.contains(pane.index) else { return false }
        switch command {
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5, .toggleFlag, .moveToTrash, .revealInFinder:
            return true
        case .rotateLeft, .rotateRight, .zoomIn, .zoomOut, .zoomToFit:
            return pane.view.imageView.image != nil
        default:
            return false
        }
    }

    public func perform(_ command: ShrikeCommand) {
        guard canPerform(command) else { return }
        switch command {
        case .revealInFinder:
            if let pane = focusedPane { NSWorkspace.shared.activateFileViewerSelecting([list[pane.index].primary]) }
        case .zoomToFit:
            fitAll()
        default:
            perform(CompareKeyMap.Hit(command: command, allPanes: false))
        }
    }

    public func menuState(for command: ShrikeCommand) -> NSControl.StateValue { .off }

    public var commandFileURLs: [URL] {
        focusedPane.flatMap { list.indices.contains($0.index) ? [list[$0.index].primary] : nil } ?? []
    }
}

// MARK: - Trash (rules per preset, with undo)

/// Where a trashed image was shown, so an undo shows it there again.
@MainActor
struct CompareTrashPlace {
    /// The pane that showed it (it may have closed since).
    weak var pane: ComparePane?
    /// Its slot when it was trashed.
    let slot: Int
    var wasReference = false
    var referenceGeneration: UInt64 = 0
}

extension CompareWindow {

    /// ⌫ / ⌘⌫ / ⌦: the focused image goes to the Trash; the pane shows
    /// the next image no other pane shows, or closes (the layout shrinks).
    func trashFocused() {
        guard let pane = focusedPane, list.indices.contains(pane.index) else { return }
        trash(listIndex: pane.index)
    }

    func trash(listIndex index: Int) {
        guard list.indices.contains(index) else { return }
        let group = list[index]
        let place = panes.firstIndex { $0.index == index }.map { CompareTrashPlace(pane: panes[$0], slot: $0, wasReference: panes[$0] === referencePane, referenceGeneration: referenceGeneration) }
        removeFromList(at: index, shownBy: place?.pane)
        let ops = fileOps
        let previous = trashChain
        let removed = RemovedGroup(index: index, group: group)
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let receipt = try await ops.trash([group])
                guard let self else { return }
                if let failure = receipt.failures.first {
                    await self.trashFailed(removed, place: place, error: failure.error)
                    return
                }
                self.didTrash(receipt, removed: removed, place: place)
            } catch {
                await self?.trashFailed(removed, place: place, error: error)
            }
        }
    }

    func waitForPendingTrash() async {
        while let task = trashChain {
            await task.value
            if trashChain == task { return }
        }
    }

    private func removeFromList(at index: Int, shownBy pane: ComparePane?) {
        if let pane { flushPendingOrientation(pane); if pane === referencePane { referencePane = nil } }
        list.remove(at: index)
        for other in panes where other !== pane && other.index > index { other.index -= 1 }
        for other in panes where other !== pane { other.listTask = queueList(for: other) }
        guard let pane else { return }
        let shown = Set(panes.filter { $0 !== pane }.map(\.index))
        let next = (index..<list.count).first { !shown.contains($0) }
            ?? (0..<min(index, list.count)).reversed().first { !shown.contains($0) }
        if let next {
            pane.index = next
            pane.listTask = queueList(for: pane)
            load(pane)
        } else {
            removePane(pane)
        }
    }

    private func didTrash(_ receipt: TrashReceipt, removed: RemovedGroup, place: CompareTrashPlace?) {
        origin?.compareDidRemove(Set(receipt.trashedGroups.map(\.primary)))
        compareUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undoTrash(receipt, removed: removed, place: place) }
        }
        compareUndoManager.setActionName("Move to Trash")
        toast(ToastContent.trashed(FileActionCopy.movedToTrash(receipt.trashedGroups))) { [weak self] in
            self?.compareUndoManager.undo()
        }
    }

    private func trashFailed(_ removed: RemovedGroup, place: CompareTrashPlace?, error: any Error) async {
        if case .noTrash? = error as? FileOpsError {
            let message = "“\(removed.group.displayName)” can't be moved to the Trash."
            let choice: Int?
            if let responder = alertResponderForTesting {
                choice = responder(message)
            } else {
                choice = await ShrikeAlert.run(
                    message: message,
                    information: "This volume doesn't have a Trash. Delete it now? You can't undo this.",
                    buttons: [ShrikeAlert.Button("Delete", role: .destructive), .cancel()], on: self)
            }
            if choice == 0 {
                do {
                    try await fileOps.deleteImmediately(removed.group)
                    origin?.compareDidRemove([removed.group.primary])
                    return
                } catch {
                    reinsert(removed, place: place)
                    toast(ToastContent(FileActionCopy.deleteFailed(removed.group, error: error), kind: .error))
                    return
                }
            }
            reinsert(removed, place: place)
            return
        }
        reinsert(removed, place: place)
        toast(ToastContent(FileActionCopy.trashFailed(removed.group, error: error), kind: .error))
    }

    /// Puts a group back at its old index and shows it where it was: in
    /// the same pane, or in a new pane at its old slot when that closed.
    private func reinsert(_ removed: RemovedGroup, place: CompareTrashPlace?) {
        guard !isClosedForTesting else { return }
        let index = min(removed.index, list.count)
        list.insert(removed.group, at: index)
        for pane in panes where pane.index >= index { pane.index += 1 }
        var target: ComparePane?
        if let place {
            if let pane = place.pane, panes.contains(where: { $0 === pane }) {
                flushPendingOrientation(pane)
                pane.index = index
                target = pane
            } else if panes.count < CompareSources.maxPanes {
                target = addPane(index: index, at: min(place.slot, panes.count))
                layoutPanes()
                updateSubtitle()
            }
        }
        for pane in panes { pane.listTask = queueList(for: pane) }
        if let target, let slot = panes.firstIndex(where: { $0 === target }) {
            if place?.wasReference == true, place?.referenceGeneration == referenceGeneration, referencePane == nil { referencePane = target }
            focus(slot)
            load(target)
        }
    }

    private func undoTrash(_ receipt: TrashReceipt, removed: RemovedGroup, place: CompareTrashPlace?) {
        compareUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.redoTrash(receipt.trashedGroups) }
        }
        compareUndoManager.setActionName("Move to Trash")
        let ops = fileOps
        let name = removed.group.displayName
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                let result = try await ops.restore(receipt)
                guard let restored = result.groups.first else {
                    self.toast(ToastContent(FileActionCopy.noLongerInTrash(name), kind: .error))
                    return
                }
                self.reinsert(RemovedGroup(index: removed.index, group: restored), place: place)
                self.origin?.compareDidRestore(result.groups)
                self.toast(ToastContent(FileActionCopy.putBack(original: removed.group, restored: restored)))
            } catch {
                self.toast(ToastContent(FileActionCopy.noLongerInTrash(name), kind: .error))
            }
        }
    }

    private func redoTrash(_ groups: [ImageGroup]) {
        guard let group = groups.first,
              let index = list.firstIndex(where: { $0.primary == group.primary }) else { return }
        trash(listIndex: index)
    }
}

// MARK: - Rotate

extension CompareWindow {

    func rotateFocused(_ op: OrientationOp) {
        guard let pane = focusedPane, pane.view.imageView.image != nil,
              list.indices.contains(pane.index) else { return }
        let view = pane.view.imageView
        if case .rotate(let q) = op {
            view.rotateBy(degrees: Double(q) * 90)
            if q % 2 != 0 {
                if let size = drawnSize(of: pane) { view.sourcePixelSize = size }
                updateFooter(pane)
            }
        }
        Culling.announce(RotateCopy.announcement(op))
        let url = list[pane.index].primary
        guard url.isFileURL, services.backupStore != nil, LosslessRotator.isSupported(url) else {
            let copy = RotateCopy.viewOnlyRotate
            if !shownOnceToasts.contains(copy) {
                shownOnceToasts.insert(copy)
                toast(ToastContent(copy))
            }
            return
        }
        if var pending = pane.pendingOrientation, pending.url == url {
            pending.ops.append(op)
            pane.pendingOrientation = pending
        } else {
            flushPendingOrientation(pane)
            pane.pendingOrientation = PendingOrientation(url: url, ops: [op])
        }
        pane.orientationTimer?.cancel()
        pane.orientationTimer = Task { @MainActor [weak self, weak pane] in
            try? await Task.sleep(for: ViewerWindow.orientationWriteDelay)
            guard !Task.isCancelled, let self, let pane else { return }
            self.flushPendingOrientation(pane)
        }
    }

    /// Writes a pane's pending turns now (timer, navigation, close).
    func flushPendingOrientation(_ pane: ComparePane) {
        pane.orientationTimer?.cancel()
        pane.orientationTimer = nil
        guard let pending = pane.pendingOrientation else { return }
        pane.pendingOrientation = nil
        let writes = ViewerWindow.writeOps(for: pending.net)
        guard !writes.isEmpty, let store = services.backupStore else { return }
        let rotator = LosslessRotator(backupStore: store)
        let url = pending.url
        let previous = orientationWriteChain
        orientationWriteChain = Task { @MainActor [weak self] in
            await previous?.value
            self?.watcherScope.ignore(paths: [url], for: .seconds(2))
            var results: [LosslessRotateResult] = []
            do {
                for op in writes { results.append(try await rotator.apply(op, to: url)) }
            } catch {
                if let first = results.first { try? await rotator.undo(first) }
                self?.toast(ToastContent(RotateCopy.failed(url.lastPathComponent), kind: .error))
                self?.fileChanged(url)
                return
            }
            guard let self, let backup = results.first?.backup else { return }
            self.fileChanged(url)
            self.registerRotateUndo(url: url, record: backup)
        }
    }

    func waitForOrientationWrites() async {
        for pane in panes { flushPendingOrientation(pane) }
        await orientationWriteChain?.value
    }

    private func registerRotateUndo(url: URL, record: BackupRecord) {
        guard let store = services.backupStore else { return }
        compareUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let previous = target.orientationWriteChain
                target.orientationWriteChain = Task { @MainActor [weak target] in
                    await previous?.value
                    target?.watcherScope.ignore(paths: [url], for: .seconds(2))
                    let redo = try? await store.restore(record)
                    guard let target else { return }
                    target.fileChanged(url)
                    if let redo { target.registerRotateUndo(url: url, record: redo) }
                }
            }
        }
        compareUndoManager.setActionName("Rotate")
    }

    /// The file's bytes changed: panes showing it decode it again.
    private func fileChanged(_ url: URL) {
        let cache = services.thumbnailCache
        Task { await cache.evict(url: url) }
        for pane in panes where list.indices.contains(pane.index) && list[pane.index].primary == url {
            guard pane.pendingOrientation == nil else { continue }
            let queue = pane.queue
            let previous = pane.listTask
            pane.listTask = Task {
                await previous?.value
                await queue.evict(url: url)
            }
            load(pane)
        }
        origin?.compareDidChangeFiles([url])
    }
}

/// The content view: panes and the toast; lays the panes out itself.
@MainActor
final class CompareRootView: NSView {
    var onLayout: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    /// The gutters show this colour between the panes.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onLayout?()
    }
}

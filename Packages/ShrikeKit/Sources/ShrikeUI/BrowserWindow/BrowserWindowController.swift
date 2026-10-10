//
//  BrowserWindowController.swift
//  ShrikeUI
//
//  Top-level `NSWindowController` for the browser window. Composes:
//    * Left pane: `FolderTreeViewController`        (source list)
//    * Center:    `BrowserContentViewController`    (grid / filmstrip / list)
//    * Right:     `InspectorPaneController`          (SwiftUI via NSHostingView)
//    * Toolbar:   sidebar, back/forward, view mode, sort, filter, search,
//                 inspector
//    * Status:    `BrowserStatusBar`                  (visual effect vibrant)
//
//  All actions route through `ShrikeServices`: thumbnails, metadata, shortcut
//  registry; ⌘B / Return hand off through `WindowCoordinator`.
//

import AppKit
import Foundation
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeIO

@MainActor
public final class BrowserWindowController: NSWindowController {

    // MARK: - Stored state

    public let services: ShrikeServices
    let splitController: NSSplitViewController
    let treeController: FolderTreeViewController
    let contentController: BrowserContentViewController
    private let inspectorController: InspectorPaneController
    private var inspectorInfoTask: Task<Void, Never>?
    private var inspectorTimeoutTask: Task<Void, Never>?
    /// Header reads of recent selections.
    let photoInfoCache = PhotoInfoCache()
    /// The file whose header read is in flight and still inside its short
    /// wait: the inspector and the status bar keep their old values until
    /// it ends, so a click sets each of them once.
    private var awaitingHeaderURL: URL?
    private var selectionGeneration = 0
    /// The header read in flight: a second call for the same file (a
    /// click reports its deselect and its select) awaits it, never a
    /// second read of the file.
    private var headerRead: (url: URL, task: Task<PhotoInfo?, Never>)?
    /// The state waiting for that read.
    private var pendingInspectorState: InspectorState?
    /// Header reads started (tests).
    private(set) var headerReadCount = 0
    /// How long a click waits for a new photo's header read before the
    /// inspector and the status bar show what they have (tests raise it).
    var headerWait: Duration = .milliseconds(80)

    /// Toolbar items the controller keeps in step. Weak:
    /// the toolbar owns them, and Customize Toolbar can remove them.
    weak var historyGroup: NSToolbarItemGroup?
    weak var viewModeGroup: NSToolbarItemGroup?
    weak var sortToolbarItem: NSMenuToolbarItem?
    weak var filterToolbarItem: NSToolbarItem?
    /// Search: a plain toolbar item holding the field, always open
    /// (NSSearchToolbarItem would not open beside the
    /// inspector's tracking separator).
    weak var searchToolbarItem: NSToolbarItem?
    /// The open field's width; follows the room above the content pane.
    lazy var searchFieldWidthConstraint: NSLayoutConstraint =
        searchField.widthAnchor.constraint(equalToConstant: BrowserToolbarRoom.searchFieldWidth)
    /// Shows "Loading…" when a folder takes longer than 150 ms.
    private var subtitleLoadingTask: Task<Void, Never>?
    static let subtitleLoadingDelay: Duration = .milliseconds(150)
    let filterButton = NSButton(
        title: "",
        target: nil,
        action: nil
    )
    let thumbSizeSlider = NSSlider(
        value: Double(Prefs.thumbnailSizePt),
        minValue: 64,
        maxValue: 320,
        target: nil,
        action: nil
    )
    let searchField = NSSearchField()
    /// Status, path and thumbnail size on the window's
    /// bottom border.
    private(set) lazy var bottomBar = BrowserBottomBar(slider: thumbSizeSlider)
    /// While a sort reads values, its progress replaces the status.
    var sortProgressText: String? {
        didSet { if sortProgressText != oldValue { refreshStatusBar() } }
    }

    private var filterPopover: NSPopover?
    var currentFolder: URL?
    var currentFilter: BrowserFilter = .none
    private var searchDebounce: Task<Void, Never>?
    /// Folder navigation history (back stack).
    var backStack: [URL] = [] { didSet { updateHistoryButtons() } }
    var forwardStack: [URL] = [] { didSet { updateHistoryButtons() } }
    /// Active chord prefix, as with the viewer.
    private(set) var chordPrefix: Character?
    private var chordExpiry: Task<Void, Never>?

    /// The viewer this Browser opens into. Weak: the
    /// `WindowCoordinator` owns windows.
    public weak var pairedViewer: ViewerWindow?
    /// Selected once the folder listing lands (return from the viewer, follow).
    var pendingSelection: URL?
    /// The whole selection to put back after a re-list of the same folder
    /// (outside changes, our own tag writes). Wins over `pendingSelection`.
    var pendingReselection: [URL] = []
    /// Re-lists of the same folder that are still on their way. While one
    /// is, the selection is read again when its listing lands, because
    /// the user can change it in between (a rating, then ⇧→): the copy
    /// taken at the start would put the old selection back.
    var relistsInFlight = 0
    /// Images dropped on the content area, selected when
    /// their folder is shown (the first scrolled into view).
    var pendingDropSelection: [URL] = []
    /// The last content drop (tests await it).
    var contentDropTask: Task<Void, Never>?
    /// ⌘F with a hidden toolbar focuses the field a turn later (tests).
    var focusSearchTask: Task<Void, Never>?
    /// Go ▸ Next / Previous Folder in flight (tests await it).
    var adjacentFolderTask: Task<Void, Never>?
    /// Go ▸ Go to Folder… while its sheet is up.
    var goToFolderSheet: GoToFolderSheet?
    var subfolderCheckTask: Task<Void, Never>?
    /// Test seam: called after the empty-folder subfolder check landed.
    var onSubfolderCheckForTesting: (() -> Void)?
    /// The narrowest content pane: room for Back/Forward, View, Sort,
    /// Filter and an open search field.
    static var contentMinimumWidth: CGFloat { BrowserToolbarRoom.contentMinimumWidth }
    /// 22 pt icons + disclosure + "Macintosh HD" need about
    /// 160 pt, plus the floating row cards' margins on macOS 26.
    static let sidebarMinimumWidth: CGFloat = 200
    static let sidebarPreferredWidth: CGFloat = 240
    static let inspectorMinimumWidth: CGFloat = 240
    /// The window's minimum width: both side panes at their minimum
    /// beside the narrowest content pane (plus the dividers and the
    /// floating sidebar's inset), rounded up.
    static var minimumWindowWidth: CGFloat {
        let panes = sidebarMinimumWidth + contentMinimumWidth + inspectorMinimumWidth + 8
        return (panes / 10).rounded(.up) * 10
    }
    /// Shared toast host.
    let toastHost = ToastHostView(placement: .browser)
    lazy var fileOps = FileOps(metadata: services.metadataStore, backups: services.backupStore)
    /// Trashes run one after another.
    var trashChain: Task<Void, Never>?
    /// Rotate / flip presses waiting 500 ms for their write.
    var pendingOrientation: BrowserPendingOrientation?
    var orientationTimer: Task<Void, Never>?
    var orientationWriteChain: Task<Void, Never>?
    /// Copy / Move to folder: slots, panel, conflicts, HUD.
    lazy var transfers: FileTransferCoordinator = makeTransferCoordinator()
    /// Tests answer file alerts here (button index) instead of a sheet.
    var alertResponderForTesting: ((String) -> Int?)?
    /// The latest Open in External Editor launch (tests wait on it).
    var externalEditorLaunch: Task<Void, Never>?
    /// The single selected item's GPS once read (Show in Maps).
    var selectionLocation: KnownLocation?
    /// The running Revert to Original (tests wait on it).
    var revertTask: Task<Void, Never>?
    /// Tests answer the Rename sheet here (new stem; nil = Cancel).
    var renameResponderForTesting: ((RenameSheetModel) -> String?)?
    /// Tests get the Tags session here instead of a popover.
    var tagPopoverPresenterForTesting: ((TagEditSession) -> Void)?
    /// The listed folder's watcher.
    var folderWatcher: FolderWatcher?
    var folderWatchTask: Task<Void, Never>?
    /// File ▸ Export Contact Sheet… while its PDF is made.
    var contactSheetExport: Task<Void, Never>?
    /// Test seam: the saved contact sheet (nil when it failed).
    var contactSheetSavedForTesting: ((URL?) -> Void)?

    public static let windowAutosaveName: NSWindow.FrameAutosaveName = "shrike.browser"

    // MARK: - Init

    public init(services: ShrikeServices, initialFolder: URL? = nil, selecting: URL? = nil) {
        self.services = services
        self.pendingSelection = selecting

        // Controllers — constructed programmatically.
        self.treeController = FolderTreeViewController()
        self.contentController = BrowserContentViewController(services: services)
        self.inspectorController = InspectorPaneController()

        // Split view controller holds all three panes.
        self.splitController = NSSplitViewController()
        super.init(window: Self.makeWindow())

        window?.contentViewController = splitController
        window?.delegate = self
        window?.undoManager?.levelsOfUndo = 50

        configureSplit()
        configureToolbar()
        observeToolbarRoom()
        wireUpDelegates()
        configureStatusBar()
        applySavedFrame()

        // Default to user's Pictures folder if no initial folder supplied.
        let startFolder = initialFolder
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        navigate(to: startFolder, updateHistory: false)

        setupFirstResponder()
        // Settings ▸ RAW+JPEG pairs changed: list the folder again.
        NotificationCenter.default.addObserver(
            self, selector: #selector(groupingDidChange(_:)),
            name: .shrikeGroupingDidChange, object: nil
        )
        // Settings ▸ Thumbnails ▸ Grid size changed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(thumbnailSizeSettingDidChange(_:)),
            name: .shrikeThumbnailSizeChanged, object: nil
        )
    }

    @objc func thumbnailSizeSettingDidChange(_ note: Notification) {
        let size = Prefs.thumbnailSizePt
        thumbSizeSlider.doubleValue = Double(size)
        contentController.thumbnailPixelSize = size
    }

    @objc func groupingDidChange(_ note: Notification) {
        reloadCurrentFolder()
    }

    /// Lists the current folder again, keeping the selection.
    func reloadCurrentFolder() {
        guard let folder = currentFolder else { return }
        // Keep the whole selection, not only its first item: a tag or
        // rating write on several photos makes the watcher re-list the
        // folder, and the selection must survive it.
        let selected = contentController.selectedItems.map(\.url)
        if !selected.isEmpty { pendingReselection = selected }
        relistsInFlight += 1
        navigate(to: folder, updateHistory: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Window

    private static func makeWindow() -> NSWindow {
        let frame = NSRect(origin: .zero, size: defaultContentSize)
        let styleMask: NSWindow.StyleMask = [
            .titled, .closable, .miniaturizable, .resizable,
            .fullSizeContentView,
        ]
        let window = BrowserWindow(
            contentRect: frame,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Shrike"
        // The folder name and the image count show in the
        // title bar, after Back / Forward.
        window.titleVisibility = .visible
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: minimumWindowWidth, height: 560)
        // No window tabs.
        window.tabbingMode = .disallowed
        // The system draws the bottom bar.
        window.setContentBorderThickness(BrowserBottomBar.height, for: .minY)
        window.setAutorecalculatesContentBorderThickness(false, for: .minY)
        return window
    }

    /// Every new Browser starts at the saved Browser frame.
    /// Runs after the content view controller is set (which sizes the
    /// window to the split view's small size) and after the window
    /// controller took the window (which clears the window's autosave
    /// name). Only one window can own the name; a second Browser still
    /// reads the saved frame and the coordinator cascades it. 1280 x 800,
    /// centred, when nothing was saved yet.
    private func applySavedFrame() {
        guard let window else { return }
        windowFrameAutosaveName = Self.windowAutosaveName
        if !window.setFrameUsingName(Self.windowAutosaveName) {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        // A frame saved before the minimum grew.
        if window.frame.width < window.minSize.width {
            var frame = window.frame
            frame.size.width = window.minSize.width
            window.setFrame(frame, display: false)
        }
        updateToolbarRoom()
    }

    static let defaultContentSize = NSSize(width: 1280, height: 800)

    /// Step 24 pt right and down from an open Browser, so the
    /// new one never lands exactly on top of it. Same size as now (the
    /// saved size); kept on the screen.
    public func cascade(from other: NSWindow) {
        guard let window else { return }
        let frame = Self.cascadedFrame(size: window.frame.size, from: other.frame,
                                       visible: other.screen?.visibleFrame)
        window.setFrame(frame, display: false)
    }

    nonisolated static let cascadeOffset: CGFloat = 24

    nonisolated static func cascadedFrame(size: NSSize, from other: NSRect, visible: NSRect?) -> NSRect {
        let step = cascadeOffset
        var frame = NSRect(x: other.minX + step, y: other.maxY - step - size.height,
                           width: size.width, height: size.height)
        guard let visible else { return frame }
        // Off the right or bottom edge: start again at the screen's
        // top-left corner area rather than off screen.
        if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
        if frame.minY < visible.minY { frame.origin.y = min(visible.maxY - frame.height, visible.minY) }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        return frame
    }

    /// Called by `BrowserWindow.keyDown` — forwards through the key map.
    /// Returns true if the event was consumed.
    fileprivate func routeKeyDown(_ event: NSEvent) -> Bool {
        handleKey(event)
    }

    // MARK: - Split configuration

    private func configureSplit() {
        let leftItem = NSSplitViewItem(sidebarWithViewController: treeController)
        leftItem.minimumThickness = Self.sidebarMinimumWidth
        leftItem.maximumThickness = 360
        leftItem.canCollapse = true
        leftItem.preferredThicknessFraction = Self.sidebarPreferredWidth / 1280.0

        let centerItem = NSSplitViewItem(viewController: contentController)
        // The toolbar items between the
        // sidebar and the inspector (Back/Forward, the title, View, Sort,
        // Filter, Search) need this room, with the search field open. At
        // the minimum window the side panes give way (sidebar 160–,
        // inspector 240–) instead of the items falling into the » menu.
        centerItem.minimumThickness = Self.contentMinimumWidth

        // An inspector item, 280 pt (240–360).
        let rightItem = NSSplitViewItem(inspectorWithViewController: inspectorController)
        rightItem.minimumThickness = Self.inspectorMinimumWidth
        rightItem.maximumThickness = 360
        rightItem.canCollapse = true
        // A narrow window shrinks the inspector toward
        // 240 pt; it does not hide it on its own.
        rightItem.canCollapseFromWindowResize = false
        rightItem.preferredThicknessFraction = 280.0 / 1280.0

        splitController.addSplitViewItem(leftItem)
        splitController.addSplitViewItem(centerItem)
        splitController.addSplitViewItem(rightItem)
        // A new name, so a stored 160 pt sidebar does not win.
        splitController.splitView.autosaveName = "shrike.browser.split.v2"
    }

    // MARK: - Toolbar

    private func configureToolbar() {
        // A layout saved by an older version would keep the old items
        // (breadcrumbs, slider): reset it once.
        BrowserToolbarLayout.migrate(ShrikeDefaults.store)
        let toolbar = NSToolbar(identifier: BrowserToolbarLayout.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true

        // Filter button (the Filter item's view, so it can take the tint).
        filterButton.bezelStyle = .texturedRounded
        filterButton.target = self
        filterButton.action = #selector(showFilterPopover(_:))
        filterButton.setAccessibilityLabel("Filter")
        updateFilterButtonBadge()

        // Thumbnail-size slider (lives in the bottom bar).
        thumbSizeSlider.target = self
        thumbSizeSlider.action = #selector(thumbSizeChanged(_:))
        thumbSizeSlider.isContinuous = true
        thumbSizeSlider.setAccessibilityLabel("Thumbnail size")

        // Search field (the Search toolbar item's view).
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        // Esc: clear, and hand the keys back to the grid / list.
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Search")

        window?.toolbarStyle = .unified
        window?.toolbar = toolbar
    }

    // MARK: - Delegate wiring

    private func wireUpDelegates() {
        treeController.delegate = self
        contentController.delegate = self
        contentController.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        contentController.onSortProgress = { [weak self] text in self?.sortProgressText = text }
        contentController.onClearFilter = { [weak self] in self?.clearFilterAndSearch() }
        contentController.onDropFiles = { [weak self] urls in self?.handleContentDrop(urls) }

        inspectorController.onRate = { [weak self] stars in
            guard let self else { return }
            let items = self.contentController.selectedItems
            self.applyRating(stars, to: items)
        }
        inspectorController.onFlag = { [weak self] flag in
            guard let self else { return }
            let items = self.contentController.selectedItems
            self.applyFlag(flag, to: items)
        }
        // The inspector's tag chips are editable.
        inspectorController.onRemoveTag = { [weak self] name in
            self?.removeTagFromSelection(name)
        }
        inspectorController.onAddTag = { [weak self] anchor in
            self?.showTagEditor(anchor: anchor)
        }
        // The preview starts from the grid's thumbnail
        // when it is in memory (no decode), then the sharper read.
        inspectorController.quickThumbnail = { [weak self] in
            guard let self, self.contentController.mode != .list else { return nil }
            let cache = self.services.thumbnailCache
            let size = self.contentController.mode == .filmstrip ? 120 : self.contentController.thumbnailPixelSize
            return { url in cache.cachedThumbnail(for: FileImageSource(url: url), maxPixelSize: size) }
        }
    }

    /// The inspector pane (tests drive its chip callbacks).
    var inspectorForTesting: InspectorPaneController { inspectorController }

    private func configureStatusBar() {
        // The split sits above the bottom bar; a host controller holds
        // both so the split keeps its keyboard loop.
        guard let window else { return }
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let split = splitController.view
        split.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        wrap.addSubview(split)
        wrap.addSubview(bottomBar)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: wrap.topAnchor),
            split.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: wrap.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: BrowserBottomBar.height),
        ])
        bottomBar.onNavigate = { [weak self] url in self?.navigate(to: url) }
        bottomBar.setSliderHidden(contentController.mode != .grid)

        let host = NSViewController()
        host.view = wrap
        host.addChild(splitController)
        window.contentViewController = host
    }

    private func setupFirstResponder() {
        window?.initialFirstResponder = contentController.view
    }

    // MARK: - Toolbar actions

    @objc func showFilterPopover(_ sender: Any?) {
        let popoverController = BrowserFilterPopover(filter: currentFilter)
        popoverController.onChange = { [weak self] newFilter in
            self?.applyFilter(newFilter)
        }
        let popover = NSPopover()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        filterPopover = popover
        // Anchor on the Filter item; when it sits in the overflow menu (or
        // was removed) anchor on the top of the grid instead.
        if let item = filterToolbarItem, let toolbar = window?.toolbar, toolbar.isVisible,
           toolbar.visibleItems?.contains(item) ?? false {
            popover.show(relativeTo: item)
        } else if let view = sender as? NSView, view.window != nil {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        } else if contentController.view.window != nil {
            let host = contentController.view
            let anchor = NSRect(x: host.bounds.maxX - 40, y: host.bounds.maxY - 8, width: 1, height: 1)
            popover.show(relativeTo: anchor, of: host, preferredEdge: .minY)
        }
    }

    @objc func thumbSizeChanged(_ sender: NSSlider) {
        let newSize = Int(sender.doubleValue.rounded())
        Prefs.thumbnailSizePt = newSize
        contentController.thumbnailPixelSize = newSize
    }

    /// Search: applies 150 ms after the last keystroke; an empty
    /// field (Esc or the clear button) applies at once.
    @objc private func searchChanged(_ sender: NSSearchField) {
        searchDebounce?.cancel()
        let term = sender.stringValue
        if term.isEmpty {
            applySearch(term)
            return
        }
        searchDebounce = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDebounceDelay)
            guard !Task.isCancelled else { return }
            self?.applySearch(term)
        }
    }

    static let searchDebounceDelay: Duration = .milliseconds(150)

    private func applySearch(_ term: String) {
        searchDebounce = nil
        guard currentFilter.searchTerm != term else { return }
        currentFilter.searchTerm = term
        contentController.filter = currentFilter
        updateFilterButtonBadge()
        updateSubtitle()
    }

    /// Esc in the search field: clears it, as the field
    /// does by itself, and gives focus back to the grid or list, so the
    /// field loses its focus ring and the arrow keys move the selection.
    func endSearchWithEscape() {
        searchDebounce?.cancel()
        if !searchField.stringValue.isEmpty { searchField.stringValue = "" }
        applySearch("")
        guard let window else { return }
        window.makeFirstResponder(contentController.focusView)
    }

    /// "Clear Filter" in the empty result: drops the filter and the search.
    func clearFilterAndSearch() {
        searchDebounce?.cancel()
        searchField.stringValue = ""
        (filterPopover?.contentViewController as? BrowserFilterPopover)?.filter = .none
        applyFilter(.none)
    }

    /// Test seam: the filter this window applies now.
    var currentFilterForTesting: BrowserFilter { currentFilter }
    /// Test seam: what the inspector shows now.
    var inspectorStateForTesting: InspectorState { inspectorController.stateForTesting }
    var inspectorControllerForTesting: InspectorPaneController? { inspectorController }

    /// A new folder starts without a search (sidebar pick, drop, Go).
    /// The grid's filter drops the term too, so the new listing is not
    /// filtered by a search the field no longer shows.
    func clearSearchForNewFolder() {
        searchDebounce?.cancel()
        searchDebounce = nil
        searchField.stringValue = ""
        guard !currentFilter.searchTerm.isEmpty else { return }
        currentFilter.searchTerm = ""
        contentController.filter = currentFilter
        updateFilterButtonBadge()
    }
    /// Test seam: the open popover's controller.
    var filterPopoverForTesting: BrowserFilterPopover? {
        filterPopover?.contentViewController as? BrowserFilterPopover
    }

    private func applyFilter(_ filter: BrowserFilter) {
        // Preserve the search term from the search field — the popover
        // doesn't own it.
        var next = filter
        next.searchTerm = searchField.stringValue
        currentFilter = next
        contentController.filter = next
        updateFilterButtonBadge()
        updateSubtitle()
    }

    private func updateFilterButtonBadge() {
        let active = !currentFilter.isEmpty
        filterButton.image = NSImage(
            systemSymbolName: active
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle",
            accessibilityDescription: active ? "Filter (active)" : "Filter"
        )
        filterButton.contentTintColor = active ? .controlAccentColor : nil
        filterToolbarItem?.menuFormRepresentation?.image = filterButton.image
    }

    /// Back / Forward follow the history stacks.
    func updateHistoryButtons() {
        guard let group = historyGroup else { return }
        let states = [!backStack.isEmpty, !forwardStack.isEmpty]
        for (index, item) in group.subitems.enumerated() where index < states.count {
            item.isEnabled = states[index]
        }
        if let control = group.view as? NSSegmentedControl {
            for index in 0..<min(states.count, control.segmentCount) {
                control.setEnabled(states[index], forSegment: index)
            }
        }
    }

    /// Clears the subtitle for a new folder; "Loading…" after 150 ms if
    /// the listing hasn't landed.
    func beginSubtitleLoading() {
        window?.subtitle = ""
        subtitleLoadingTask?.cancel()
        subtitleLoadingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.subtitleLoadingDelay)
            guard !Task.isCancelled, let self else { return }
            self.window?.subtitle = "Loading…"
        }
    }

    /// ⌘F: shows a hidden toolbar and puts the caret in Search.
    func focusSearch() {
        guard let window else { return }
        if let toolbar = window.toolbar, !toolbar.isVisible {
            // The field is placed a turn after the toolbar
            // shows; focus it then.
            toolbar.isVisible = true
            window.layoutIfNeeded()
            focusSearchTask = Task { @MainActor [weak self] in
                await Task.yield()
                self?.beginSearchInteraction()
            }
            return
        }
        beginSearchInteraction()
    }

    /// Puts the caret in the field. The keys move only to a field the
    /// user can see: a field in the » menu, or removed
    /// with Customize Toolbar, leaves them in the grid / list.
    private func beginSearchInteraction() {
        guard let window else { return }
        window.layoutIfNeeded()
        guard isSearchFieldOnScreen else {
            NSSound.beep()
            return
        }
        if searchField.currentEditor() == nil {
            window.makeFirstResponder(searchField)
        } else {
            searchField.selectText(nil)
        }
    }

    /// The field is in the window's toolbar, shown and open.
    var isSearchFieldOnScreen: Bool {
        guard let window, searchField.window === window, window.toolbar?.isVisible == true else { return false }
        return !searchField.isHiddenOrHasHiddenAncestor && searchField.frame.width >= 40
    }

    /// The sort key after the current one (the Cycle Sort key).
    func cycleSortKey() {
        let keys = BrowserSortKey.allCases
        var sort = contentController.sort
        let index = keys.firstIndex(of: sort.key) ?? -1
        sort.key = keys[(index + 1) % keys.count]
        applySort(sort)
    }

    // MARK: - Navigation

    /// Switch the browser to a new folder. Enumerates contents, pushes the
    /// old folder onto the back stack, updates breadcrumbs, inspector, and
    /// status bar.
    public func navigate(to url: URL, updateHistory: Bool = true) {
        let std = url.standardizedFileURL
        if std != currentFolder { beginSubtitleLoading() }
        if updateHistory, let current = currentFolder, current != std {
            backStack.append(current)
            forwardStack.removeAll()
        }
        if std != currentFolder { relistsInFlight = 0 }
        currentFolder = std

        // Fire enumerate + metadata hydrate on an isolated Task; we don't
        // want to block the UI for the directory read.
        let store = services.metadataStore
        let backups = services.backupStore
        let hidden = Prefs.showHiddenFiles
        // First paint before hydrate: the grid shows the
        // listing at once; ratings, flags, tags and edit marks are read in
        // the background and land in place.
        let signpost = ShrikeSignposts.browser.begin("folderFirstPaint")
        Task { [weak self] in
            let items = await Self.nameOrdered(Self.enumerate(folder: std, showHidden: hidden))
            await MainActor.run { [weak self] in
                ShrikeSignposts.browser.end("folderFirstPaint", signpost)
                guard let self else { return }
                self.applyFolderContents(items, folder: std)
            }
            let hydrateSignpost = ShrikeSignposts.browser.begin("folderHydrate")
            let hydrated = await Self.hydrate(items, with: store, backups: backups)
            await MainActor.run { [weak self] in
                ShrikeSignposts.browser.end("folderHydrate", hydrateSignpost)
                guard let self, self.currentFolder == std else { return }
                self.contentController.applyHydrated(hydrated)
                // A filter on rating / flag can change the count; leave a
                // pending "Loading…" alone.
                if self.subtitleLoadingTask == nil { self.updateSubtitle() }
                self.refreshSelectionInfo()
                self.onHydratedForTesting?()
            }
            // Persist the most-recent folder outside the MainActor hop.
            try? await store.addRecentFolder(std)
        }
    }

    /// Test seam: called after a listing's saved values landed.
    var onHydratedForTesting: (() -> Void)?
    /// Test seam: called when a listing is first shown.
    var onFolderPaintedForTesting: (() -> Void)?

    private func applyFolderContents(_ items: [BrowserItem], folder: URL) {
        // A re-list of the shown folder: keep the selection as it is NOW.
        var liveSelection: [URL]?
        if relistsInFlight > 0 {
            relistsInFlight -= 1
            if folder == currentFolder { liveSelection = contentController.selectedItems.map(\.url) }
        }
        contentController.emptyFolder = (folder.lastPathComponent, 0, false)
        contentController.setItems(items)
        if items.isEmpty { checkSubfolders(of: folder) }
        if folder == currentFolder {
            subtitleLoadingTask?.cancel()
            subtitleLoadingTask = nil
        }
        window?.title = folder.lastPathComponent.isEmpty ? "Shrike" : folder.lastPathComponent
        window?.representedURL = folder
        updateSubtitle()
        let reselect = liveSelection ?? pendingReselection
        pendingReselection = []
        let dropped = pendingDropSelection
        pendingDropSelection = []
        if let first = dropped.first, folder == currentFolder {
            pendingSelection = nil
            contentController.select(url: first)
            if dropped.count > 1 { contentController.select(urls: dropped) }
        } else if let pending = pendingSelection {
            pendingSelection = nil
            contentController.select(url: pending)
        } else if !reselect.isEmpty,
                  folder == currentFolder {
            contentController.select(urls: reselect)
        }
        treeController.select(folder)
        bottomBar.setFolder(folder)
        startWatching(folder)
        refreshSelectionInfo()
        onFolderPaintedForTesting?()
    }

    /// Enumerates images in `folder` (one level deep). Filters by extension
    /// cheaply before constructing a `BrowserItem` for each; parallelism
    /// isn't worth the overhead at typical folder sizes.
    nonisolated private static func enumerate(folder: URL, showHidden: Bool) async -> [BrowserItem] {
        // The list holds groups; `FolderScanner` decides what
        // an image is (no extension list here) and runs off the main thread.
        let groups = (try? await FolderScanner.imageGroups(in: folder, showHidden: showHidden)) ?? []
        return await Task.detached(priority: .userInitiated) {
            groups.compactMap { group -> BrowserItem? in
                guard var item = try? BrowserItem.make(from: group.primary) else { return nil }
                item.group = group
                return item
            }
        }.value
    }

    /// Fill in rating / flag / tags from MetadataStore. Works off actor
    /// isolation via `await` on each URL — we could batch-fetch later if
    /// the single-statement overhead becomes measurable.
    /// Finder name order, worked out off the main thread so the grid's
    /// sort only compares numbers.
    nonisolated static func nameOrdered(_ items: [BrowserItem]) async -> [BrowserItem] {
        BrowserPipeline.nameOrdered(items)
    }

    nonisolated static func hydrate(
        _ items: [BrowserItem],
        with store: MetadataStore,
        backups: BackupStore?
    ) async -> [BrowserItem] {
        var out = items
        // One batched read for the folder, not one per cell.
        let records = await store.records(for: out.map(\.url))
        for i in out.indices {
            let url = out[i].url
            if let record = records[url] {
                out[i].rating = record.rating
                out[i].isFlagged = record.flagged
            }
            // Finder tags are the source of truth, read off main.
            let tags = FinderTags.readWithColors(url)
            out[i].finderTags = tags
            out[i].tags = tags.map(\.name)
        }
        if let backups {
            let states = await backups.states(for: out.map(\.url))
            for i in out.indices { out[i].edited = states[out[i].url] == .edited }
        }
        return out
    }

    // MARK: - Rating / flag

    /// Every selected item (all image members of each group), one undo
    /// step "Undo Rating", no toast.
    private func applyRating(_ rating: Int, to items: [BrowserItem]) {
        guard !items.isEmpty else { return }
        let urls = Culling.imageURLs(of: items.map(\.group))
        CullingUndo.perform(
            .rating, urls: urls, store: services.metadataStore, undoManager: window?.undoManager,
            compute: { Culling.ratingValues(rating, urls: urls, previous: $0) },
            onChange: { [weak self] values in self?.cullingDidChange(values) }
        )
        Culling.announce(Culling.ratingAnnouncement(rating))
    }

    private func applyFlag(_ flag: Bool, to items: [BrowserItem]) {
        guard !items.isEmpty else { return }
        let urls = Culling.imageURLs(of: items.map(\.group))
        CullingUndo.perform(
            .flag, urls: urls, store: services.metadataStore, undoManager: window?.undoManager,
            compute: { previous in
                var out: [URL: FileRecord] = [:]
                for url in urls {
                    var record = previous[url] ?? FileRecord()
                    record.flagged = flag
                    out[url] = record
                }
                return out
            },
            onChange: { [weak self] values in self?.cullingDidChange(values) }
        )
        Culling.announce(Culling.flagAnnouncement(flag))
    }

    /// Q / \ : if any selected item is unflagged, flag all; else unflag all.
    private func toggleFlagOnSelection() {
        let items = contentController.selectedItems
        guard !items.isEmpty else { return }
        applyFlag(items.contains { !$0.isFlagged }, to: items)
    }

    /// Saved values landed (also after undo / redo). Keeps a paired
    /// viewer's pill in step.
    func cullingDidChange(_ values: [URL: FileRecord]) {
        applyCullingValues(values)
        pairedViewer?.applyCullingValues(values)
    }

    /// Updates cells and the inspector (no forwarding).
    public func applyCullingValues(_ values: [URL: FileRecord]) {
        contentController.applyCulling(values)
        updateInspectorFromSelection()
    }

    // MARK: - Open-in-viewer

    private func openInViewer(items: [BrowserItem], startIndex: Int) {
        let clamped = max(0, min(startIndex, max(0, items.count - 1)))
        WindowCoordinator.shared.openPairedViewer(
            from: self, groups: items.map(\.group), startIndex: clamped
        )
    }

    private func openSelectionInViewer() {
        let items = contentController.visibleItems
        guard let first = contentController.selectedItems.first,
              let index = items.firstIndex(of: first) else { return }
        openInViewer(items: items, startIndex: index)
    }

    // MARK: - File ops

    private func revealInFinder(_ items: [BrowserItem]) {
        let urls = items.map(\.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// The whole selection as one action: one toast, one
    /// undo step; the selection moves to the item after the last removed
    /// one (or before, at the end).
    func trash(_ items: [BrowserItem]) {
        guard !items.isEmpty else { return }
        let groups = items.map(\.group)
        let next = Self.selectionAfterRemoving(items.map(\.url), from: contentController.visibleItems.map(\.url))
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let receipt = try await ops.trash(groups)
                await self?.didTrash(receipt, next: next)
            } catch {
                let failures = groups.map { (group: $0, error: (error as? FileOpsError) ?? FileOpsError.io($0.primary, reason: error.localizedDescription)) }
                await self?.handleTrashFailures(failures, next: next)
            }
        }
    }

    /// Waits for queued trashes (tests).
    func waitForPendingTrash() async { await trashChain?.value }

    /// The URL to select after `removed` leave `visible`: the first kept
    /// item after the last removed one, else the last kept one before.
    nonisolated static func selectionAfterRemoving(_ removed: [URL], from visible: [URL]) -> URL? {
        let gone = Set(removed)
        let indices = visible.indices.filter { gone.contains(visible[$0]) }
        guard let last = indices.max(), let first = indices.min() else { return nil }
        if let after = visible[(last + 1)...].first(where: { !gone.contains($0) }) { return after }
        return visible[..<first].last(where: { !gone.contains($0) })
    }

    /// No Trash on the volume → the permanent-delete alert (Delete removes for good).
    /// Other errors → toast T2.
    private func handleTrashFailures(_ failures: [(group: ImageGroup, error: FileOpsError)], next: URL?) async {
        let noTrash = failures.filter { if case .noTrash = $0.error { return true } else { return false } }
        if let first = noTrash.first {
            let title = noTrash.count == 1
                ? "“\(first.group.displayName)” can't be moved to the Trash."
                : "\(noTrash.count) items can't be moved to the Trash."
            let choice: Int?
            if let responder = alertResponderForTesting {
                choice = responder(title)
            } else {
                choice = await ShrikeAlert.run(
                    message: title,
                    information: "This volume doesn't have a Trash. Delete it now? You can't undo this.",
                    buttons: [ShrikeAlert.Button("Delete", role: .destructive), .cancel()],
                    on: window
                )
            }
            if choice == 0 {
                var deleted: Set<URL> = []
                for failure in noTrash {
                    do {
                        try await fileOps.deleteImmediately(failure.group)
                        deleted.insert(failure.group.primary)
                    } catch {
                        toast(FileActionCopy.deleteFailed(failure.group, error: error), kind: .error)
                    }
                }
                removeFromList(deleted, next: next)
            }
        }
        if let other = failures.first(where: { if case .noTrash = $0.error { return false } else { return true } }) {
            toast(FileActionCopy.trashFailed(other.group, error: other.error), kind: .error)
        }
    }

    func removeFromList(_ primaries: Set<URL>, next: URL?) {
        guard !primaries.isEmpty else { return }
        contentController.setItems(contentController.allItems.filter { !primaries.contains($0.group.primary) })
        if let next { _ = contentController.select(url: next) }
        refreshStatusBar()
        updateSubtitle()
    }

    private func didTrash(_ receipt: TrashReceipt, next: URL?) async {
        if !receipt.failures.isEmpty {
            await handleTrashFailures(receipt.failures.map { (group: $0.group, error: $0.error) }, next: next)
        }
        guard !receipt.items.isEmpty else { return }
        removeFromList(Set(receipt.trashedGroups.map(\.primary)), next: next)
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undoTrash(receipt) }
        }
        undo.setActionName("Move to Trash")
        toast(FileActionCopy.movedToTrash(receipt.trashedGroups), actionTitle: "Undo") { [weak self] in
            self?.window?.undoManager?.undo()
        }
    }

    private func undoTrash(_ receipt: TrashReceipt) {
        let ops = fileOps
        let name = receipt.trashedGroups.first?.displayName ?? ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await ops.restore(receipt)
                guard let first = result.groups.first, let original = receipt.trashedGroups.first else {
                    self.toast(FileActionCopy.noLongerInTrash(name), kind: .error)
                    return
                }
                if let folder = self.currentFolder {
                    self.pendingSelection = first.primary
                    self.navigate(to: folder, updateHistory: false)
                }
                self.toast(FileActionCopy.putBack(original: original, restored: first))
            } catch {
                self.toast(FileActionCopy.noLongerInTrash(name), kind: .error)
            }
        }
    }

    // MARK: - Status bar + inspector

    /// The inspector, then the status bar: a selection change sets each
    /// of them once.
    func refreshSelectionInfo() {
        updateInspectorFromSelection()
        refreshStatusBar()
    }

    /// One selected: "DSC_0042.jpg · 6000 × 4000 · 12.4 MB". A JPEG or PNG
    /// listing has no pixel size; the header read has it
    /// ("dimensions only if known"). While that read is in flight (inside
    /// its short wait) the old text stays: the read sets the text once,
    /// never a short text and then a longer one.
    func refreshStatusBar() {
        if let sortProgressText {
            bottomBar.setStatus(sortProgressText)
            return
        }
        let selected = contentController.selectedItems
        guard selected.count == 1, let item = selected.first,
              item.pixelWidth == nil || item.pixelHeight == nil else {
            bottomBar.setStatus(BrowserBottomBar.statusText(selected))
            return
        }
        if case .hit(let info) = photoInfoCache.lookup(item) {
            bottomBar.setStatus(BrowserBottomBar.statusText([item], headerSize: info?.headerSize))
            return
        }
        if awaitingHeaderURL == item.url { return }
        bottomBar.setStatus(BrowserBottomBar.statusText(selected))
    }

    /// Publishes the inspector once per selection change.
    /// One photo: its Capture rows come from the header cache
    /// when it was read before; a new photo waits for its header read (off
    /// the main thread, up to `headerWait`). A slower read publishes the
    /// Capture section with the rows it showed, values blank, and fills
    /// them in place when the read ends: the section never goes away and
    /// comes back between two photos.
    func updateInspectorFromSelection() {
        let items = contentController.selectedItems
        let state: InspectorState
        if items.isEmpty {
            // The folder, never the first photo.
            if let folder = currentFolder {
                state = .folder(name: folder.lastPathComponent,
                                visible: contentController.visibleItems.count,
                                total: contentController.allItems.count,
                                path: UserFacingPath.string(folder))
            } else {
                state = .empty
            }
        } else {
            state = InspectorState.reduce(items)
        }
        // The same selection again while its read is in flight: that read
        // publishes it.
        if inspectorInfoTask != nil, let pending = pendingInspectorState, pending == state { return }
        inspectorInfoTask?.cancel()
        inspectorTimeoutTask?.cancel()
        inspectorInfoTask = nil
        inspectorTimeoutTask = nil
        pendingInspectorState = nil
        awaitingHeaderURL = nil
        selectionGeneration &+= 1
        guard state.count == 1, let url = state.previewURL, let item = items.first else {
            selectionLocation = nil
            inspectorController.update(state)
            return
        }
        if case .hit(let info) = photoInfoCache.lookup(item) {
            // Show in Maps is enabled only when the item has GPS.
            selectionLocation = KnownLocation(url: url, coordinate: info?.gps)
            inspectorController.update(Self.filled(state, with: info))
            return
        }
        selectionLocation = nil
        let generation = selectionGeneration
        awaitingHeaderURL = url
        pendingInspectorState = state
        let read: Task<PhotoInfo?, Never>
        if let current = headerRead, current.url == url {
            read = current.task
        } else {
            read = Task.detached(priority: .userInitiated) { try? PhotoInfo.readSync(url) }
            headerRead = (url, read)
            headerReadCount += 1
        }
        inspectorTimeoutTask = Task { [weak self] in
            guard let wait = self?.headerWait else { return }
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.selectionGeneration == generation,
                  self.awaitingHeaderURL == url else { return }
            self.awaitingHeaderURL = nil
            self.inspectorController.update(self.inspectorController.keepingCaptureShape(state))
            self.refreshStatusBar()
        }
        inspectorInfoTask = Task { [weak self] in
            let info = await read.value
            guard let self else { return }
            // Kept even when the selection moved on: a later click on this
            // photo fills at once.
            self.photoInfoCache.store(info, for: item)
            if self.headerRead?.url == url { self.headerRead = nil }
            guard !Task.isCancelled, self.selectionGeneration == generation else { return }
            self.inspectorTimeoutTask?.cancel()
            self.inspectorTimeoutTask = nil
            self.pendingInspectorState = nil
            self.awaitingHeaderURL = nil
            self.selectionLocation = KnownLocation(url: url, coordinate: info?.gps)
            self.inspectorController.update(Self.filled(state, with: info))
            self.refreshStatusBar()
        }
    }

    /// `state` with the Capture and Location rows of `info`, and the size
    /// the header gave when the listing has none.
    nonisolated static func filled(_ state: InspectorState, with info: PhotoInfo?) -> InspectorState {
        guard let info else { return state }
        var filled = state
        filled.capture = InspectorRows.capture(info)
        filled.location = InspectorRows.location(info)
        filled.coordinate = info.gps
        if filled.commonWidth == nil || filled.commonHeight == nil, let size = info.headerSize {
            filled.commonWidth = size.width
            filled.commonHeight = size.height
        }
        return filled
    }

    /// Test seam: the bottom bar's status text.
    var statusTextForTesting: String { bottomBar.statusField.stringValue }

    /// Waits for the inspector's header read (tests).
    func waitForInspectorInfo() async { await inspectorInfoTask?.value }

    // MARK: - Toasts

    private func flashToast(_ message: String) { toast(message) }

    /// Shows `message` in the Browser's toast.
    public func toast(
        _ message: String, kind: ToastContent.Kind = .text,
        actionTitle: String? = nil, progress: Double? = nil, action: (@MainActor () -> Void)? = nil
    ) {
        if toastHost.superview == nil { toastHost.install(in: contentController.view) }
        var content = ToastContent(message, kind: kind, actionTitle: actionTitle)
        content.progress = progress
        toastHost.show(content, action: action)
    }

    /// Selects `url` and scrolls it into view (return from the viewer).
    public func select(url: URL) {
        if !contentController.select(url: url) { pendingSelection = url }
    }

    /// The paired viewer moved to `folder`: follow it.
    public func follow(folder: URL, selecting: URL?) {
        pendingSelection = selecting
        navigate(to: folder)
    }

    func updateSubtitle() {
        window?.subtitle = WindowTitles.browserSubtitle(
            visible: contentController.visibleItems.count,
            total: contentController.allItems.count
        )
    }

    // MARK: - Key handling

    public func handleKey(_ event: NSEvent) -> Bool {
        let snap = KeyEventSnapshot.from(event, isKeyUp: false)

        // Special: search field focus goes through the normal responder chain.
        if NSApp.keyWindow?.firstResponder is NSText,
           window?.firstResponder !== contentController.view {
            return false
        }
        return handleKeySnapshot(snap)
    }

    /// The key path without an `NSEvent` (tests drive it directly).
    @discardableResult
    func handleKeySnapshot(_ snap: KeyEventSnapshot) -> Bool {
        // Esc while a copy / move shows its progress: stop the rest.
        if chordPrefix == nil, snap.key == "\u{1b}", transfers.cancelRunning() { return true }
        var resolved = BrowserKeyMap.action(for: snap, preset: ShortcutTable.livePreset, chordPrefix: chordPrefix)
        // A key that doesn't continue the chord cancels it and is handled
        // normally.
        if resolved == nil, chordPrefix != nil {
            clearChord()
            resolved = BrowserKeyMap.action(for: snap, preset: ShortcutTable.livePreset, chordPrefix: nil)
        }
        guard let action = resolved else { return false }
        if chordPrefix != nil { clearChord() }
        dispatch(action)
        return true
    }

    func dispatch(_ action: BrowserAction) {
        switch action {
        case .selectNext:        contentController.moveSelection(1)
        case .selectPrev:        contentController.moveSelection(-1)
        case .selectDown:        contentController.moveSelection(gridStepDown())
        case .selectUp:          contentController.moveSelection(-gridStepDown())
        case .openInViewer:      openSelectionInViewer()
        case .upOneFolder:       goUpOneFolder()
        case .goBack:            goBack()
        case .goForward:         goForward()
        case .copyImage:         copySelectionFiles()
        case .selectAll:         contentController.selectAll()
        case .deselectAll:       contentController.deselectAll()
        case .focusSearch:       focusSearch()
        case .viewModeGrid:      setMode(.grid)
        case .viewModeFilmstrip: setMode(.filmstrip)
        case .viewModeList:      setMode(.list)
        case .cycleSort:         cycleSortKey()
        case .rate(let n):       applyRating(n, to: contentController.selectedItems)
        case .toggleFlag:        toggleFlagOnSelection()
        case .copyPath:          copySelectionPath()
        case .revealInFinder:    revealInFinder(contentController.selectedItems)
        case .deleteToTrash:     trash(contentController.selectedItems)
        case .beginCopyChord:    startChord("c")
        case .beginMoveChord:    startChord("m")
        case .copyToFolder:      startChord("c")
        case .moveToFolder:      startChord("m")
        case .fileToFolder(let verb, let choice): fileToFolder(verb, choice)
        case .cancelChord:       clearChord()
        case .rename:            renameSelection()
        case .editTags:          showTagEditor()
        case .toggleViewer:      openSelectionInViewer()
        case .openExternalEditor(let slot): openSelectionInExternalEditor(slot: slot)
        case .showInMaps:        showSelectionInMaps()
        case .compare:           openCompare()
        case .print:             printSelection()
        }
    }

    /// Open in External Editor N: every selected item, one file each (a
    /// RAW+JPEG pair follows the editor's Send RAW).
    func openSelectionInExternalEditor(slot: Int) {
        let groups = contentController.selectedItems.map(\.group)
        guard !groups.isEmpty else { return }
        externalEditorLaunch = ExternalEditors.open(groups: groups, slot: slot) { [weak self] content, action in
            self?.toast(content.message, kind: content.kind, actionTitle: content.actionTitle, action: action)
        }
    }

    /// The one selected item's GPS, when it has been read and has one.
    var selectedCoordinate: PhotoInfo.Coordinate? {
        let items = contentController.selectedItems
        guard items.count == 1, let known = selectionLocation,
              known.url == items[0].url else { return nil }
        return known.coordinate
    }

    /// Show in Maps for the one selected item, or the "no location" toast
    /// (the key works before the header read has finished).
    func showSelectionInMaps() {
        let items = contentController.selectedItems
        guard items.count == 1 else { return }
        let url = items[0].url
        if let known = selectionLocation, known.url == url {
            openMaps(known.coordinate, file: url)
            return
        }
        Task { [weak self] in
            let coordinate = await ShowInMaps.readLocation(of: url)
            guard let self, self.contentController.selectedItems.map(\.url) == [url] else { return }
            self.selectionLocation = KnownLocation(url: url, coordinate: coordinate)
            self.openMaps(coordinate, file: url)
        }
    }

    private func openMaps(_ coordinate: PhotoInfo.Coordinate?, file: URL) {
        if let coordinate, ShowInMaps.open(coordinate, file: file) { return }
        toast(ShowInMaps.noLocation)
    }

    func setMode(_ mode: BrowserViewMode) {
        contentController.setMode(mode)
        viewModeGroup?.selectedIndex = mode.rawValue
        bottomBar.setSliderHidden(mode != .grid)
    }

    private func gridStepDown() -> Int {
        // A reasonable approximation: in grid mode, one "row" ≈ visible
        // columns. Without full layout introspection, fall back to 4.
        switch contentController.mode {
        case .grid:      return 4
        case .filmstrip: return 1
        case .list:      return 1
        }
    }

    private func goUpOneFolder() {
        guard let current = currentFolder else { return }
        let parent = current.deletingLastPathComponent()
        guard parent.path != current.path else { return }
        navigate(to: parent)
    }

    /// ⌘C: the selected files on the pasteboard (pastes as images in
    /// most apps; Finder pastes the files).
    private func copySelectionFiles() {
        let groups = contentController.selectedItems.map(\.group)
        guard !groups.isEmpty else { return }
        PhotoPasteboard.write(groups, to: .general)
        flashToast(groups.count == 1 ? "Copied" : "Copied \(groups.count) items")
    }

    private func copySelectionPath() {
        let items = contentController.selectedItems
        guard let first = items.first else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(first.url.path, forType: .string)
        flashToast("Copied path")
    }

    // MARK: - Chord handling

    func startChord(_ prefix: Character) {
        chordPrefix = prefix
        chordExpiry?.cancel()
        chordExpiry = nil
        // `C` / `M`: no timeout; the HUD shows after 250 ms.
        if let verb = FileChord.verb(for: prefix) {
            transfers.armHUD(verb)
            return
        }
        chordExpiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            await MainActor.run { self?.clearChord() }
        }
    }

    func clearChord() {
        chordPrefix = nil
        chordExpiry?.cancel()
        chordExpiry = nil
        transfers.dismissHUD()
    }

    // MARK: - History

    public func goBack() {
        guard let prev = backStack.popLast() else { return }
        if let current = currentFolder { forwardStack.append(current) }
        navigate(to: prev, updateHistory: false)
    }

    public func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = currentFolder { backStack.append(current) }
        navigate(to: next, updateHistory: false)
    }
}

// MARK: - NSToolbarDelegate

extension BrowserWindowController: NSToolbarDelegate, NSToolbarItemValidation {

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbarLayout.defaultItems
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        BrowserToolbarLayout.defaultItems + [
            BrowserToolbarID.openInViewer,
            .flexibleSpace,
            .space,
        ]
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .sidebarTrackingSeparator:
            // The window's content controller wraps the split (the bottom
            // bar sits under it), so name the split view here.
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitController.splitView, dividerIndex: 0
            )
        case .inspectorTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier, splitView: splitController.splitView, dividerIndex: 1
            )
        case BrowserToolbarID.backForward:
            return makeHistoryGroup(itemIdentifier)
        case BrowserToolbarID.viewMode:
            return makeViewModeGroup(itemIdentifier)
        case BrowserToolbarID.sort:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")
            item.showsIndicator = true
            item.menu = makeSortMenu()
            // The » row: a glyph and the same rows.
            let menuForm = NSMenuItem(title: "Sort", action: nil, keyEquivalent: "")
            menuForm.image = item.image
            menuForm.submenu = makeSortMenu()
            item.menuFormRepresentation = menuForm
            item.label = "Sort"
            item.visibilityPriority = .high
            item.paletteLabel = "Sort"
            item.toolTip = "Sort By"
            sortToolbarItem = item
            return item
        case BrowserToolbarID.filter:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.view = filterButton
            LiveTooltips.shared.bind(filterButton, command: .filter, context: .browser)
            item.label = "Filter"
            item.visibilityPriority = .high
            item.paletteLabel = "Filter"
            let menuForm = NSMenuItem(title: "Filter…", action: #selector(showFilterPopover(_:)), keyEquivalent: "")
            menuForm.target = self
            menuForm.image = filterButton.image
            item.menuFormRepresentation = menuForm
            filterToolbarItem = item
            return item
        case BrowserToolbarID.search:
            // A plain item with the field always open.
            // NSSearchToolbarItem stayed a button beside the inspector's
            // tracking separator (⌘F, Find… and a click did nothing), and
            // ⌘F then moved the keys to a field that was not on screen.
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            searchField.translatesAutoresizingMaskIntoConstraints = false
            searchFieldWidthConstraint.isActive = true
            item.view = searchField
            item.label = "Search"
            item.paletteLabel = "Search"
            // Search gives way first when the window is narrow;
            // every other item is `.high`.
            item.visibilityPriority = .low
            LiveTooltips.shared.bind(searchField, command: .find, context: .browser)
            searchToolbarItem = item
            return item
        case BrowserToolbarID.inspector:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Inspector")
            item.isBordered = true
            item.target = self
            item.action = #selector(toolbarToggleInspector(_:))
            // The » row: the glyph and a check mark while the inspector
            // shows (`validateMenuItem`).
            let menuForm = NSMenuItem(title: "Inspector", action: #selector(toolbarToggleInspector(_:)), keyEquivalent: "")
            menuForm.target = self
            menuForm.image = item.image
            item.menuFormRepresentation = menuForm
            item.label = "Inspector"
            item.visibilityPriority = .high
            item.paletteLabel = "Inspector"
            LiveTooltips.shared.bind(item, command: .toggleInspector, context: .browser)
            return item
        case BrowserToolbarID.openInViewer:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "photo", accessibilityDescription: "Open in Viewer")
            item.isBordered = true
            item.target = self
            item.action = #selector(toolbarOpenInViewer(_:))
            item.label = "Open"
            item.paletteLabel = "Open in Viewer"
            LiveTooltips.shared.bind(item, command: .openSelection, context: .browser)
            return item
        default:
            return nil
        }
    }

    private func makeHistoryGroup(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let images = ["chevron.left", "chevron.right"].map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier, images: images, selectionMode: .momentary,
            labels: ["Back", "Forward"], target: self, action: #selector(toolbarHistory(_:))
        )
        group.isNavigational = true
        // Validation would enable both halves through the group; the
        // history stacks drive them instead (`updateHistoryButtons`).
        group.autovalidates = false
        for item in group.subitems { item.autovalidates = false }
        group.label = "Back/Forward"
        group.visibilityPriority = .high
        group.paletteLabel = "Back/Forward"
        for (item, command) in zip(group.subitems, [ShrikeCommand.back, .forward]) {
            LiveTooltips.shared.bind(item, command: command, context: .browser)
        }
        group.menuFormRepresentation = overflowSubmenu("Back/Forward", symbol: "chevron.left.chevron.right", rows: [
            (.back, "Back", "chevron.left"), (.forward, "Forward", "chevron.right"),
        ])
        historyGroup = group
        updateHistoryButtons()
        return group
    }

    private func makeViewModeGroup(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        let images = BrowserToolbarLayout.viewModeSymbols.map {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil) ?? NSImage()
        }
        let group = NSToolbarItemGroup(
            itemIdentifier: identifier, images: images, selectionMode: .selectOne,
            labels: ["Grid", "Filmstrip", "List"], target: self, action: #selector(toolbarViewMode(_:))
        )
        group.label = "View"
        group.visibilityPriority = .high
        group.paletteLabel = "View Mode"
        group.selectedIndex = contentController.mode.rawValue
        let commands: [ShrikeCommand] = [.viewAsGrid, .viewAsFilmstrip, .viewAsList]
        for (item, command) in zip(group.subitems, commands) {
            LiveTooltips.shared.bind(item, command: command, context: .browser)
        }
        // The » row: the check mark sits on the current mode
        // (`validateMenuItem` → `menuState`).
        let titles = ["Grid", "Filmstrip", "List"]
        group.menuFormRepresentation = overflowSubmenu(
            "View", symbol: BrowserToolbarLayout.viewModeSymbols[0],
            rows: (0..<3).map { (commands[$0], titles[$0], BrowserToolbarLayout.viewModeSymbols[$0]) })
        viewModeGroup = group
        updateToolbarRoom()
        return group
    }

    /// A » menu row for a toolbar group: a glyph and a submenu of command
    /// rows, each with its own glyph. The rows run through
    /// `performShrikeCommand` and `validateMenuItem`, like the main menu.
    private func overflowSubmenu(_ title: String, symbol: String,
                                 rows: [(ShrikeCommand, String, String)]) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        row.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        let menu = NSMenu(title: title)
        for (command, rowTitle, rowSymbol) in rows {
            let item = NSMenuItem(title: rowTitle, action: ShrikeMainMenu.commandAction, keyEquivalent: "")
            item.representedObject = command.rawValue
            item.target = self
            item.image = NSImage(systemSymbolName: rowSymbol, accessibilityDescription: rowTitle)
            menu.addItem(item)
        }
        row.submenu = menu
        return row
    }

    /// The View ▸ Sort By menu, as the Sort item's menu.
    /// Keys stay in the main menu only (they follow the shortcut preset).
    func makeSortMenu() -> NSMenu {
        let menu = NSMenu(title: "Sort By")
        for command in BrowserToolbarLayout.sortCommands {
            let item = NSMenuItem(title: command.title, action: ShrikeMainMenu.commandAction, keyEquivalent: "")
            item.representedObject = command.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (tag, title) in [(0, "Ascending"), (1, "Descending")] {
            let item = NSMenuItem(title: title, action: #selector(setSortDirection(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// Index of the clicked part of a toolbar group.
    private func clickedIndex(_ sender: Any?, in group: NSToolbarItemGroup?) -> Int {
        if let item = sender as? NSToolbarItem, let group, let index = group.subitems.firstIndex(of: item) {
            return index
        }
        return (sender as? NSToolbarItemGroup)?.selectedIndex ?? group?.selectedIndex ?? -1
    }

    @objc func toolbarHistory(_ sender: Any?) {
        switch clickedIndex(sender, in: historyGroup) {
        case 0: goBack()
        case 1: goForward()
        default: break
        }
    }

    @objc func toolbarViewMode(_ sender: Any?) {
        guard let mode = BrowserViewMode(rawValue: clickedIndex(sender, in: viewModeGroup)) else { return }
        setMode(mode)
    }

    @objc func toolbarToggleInspector(_ sender: Any?) {
        perform(.toggleInspector)
    }

    @objc private func toolbarOpenInViewer(_ sender: Any?) {
        openSelectionInViewer()
    }

    public func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        if let group = historyGroup, let index = group.subitems.firstIndex(of: item) {
            return index == 0 ? !backStack.isEmpty : !forwardStack.isEmpty
        }
        if item.itemIdentifier == BrowserToolbarID.openInViewer {
            return !contentController.selectedItems.isEmpty
        }
        return true
    }
}

// MARK: - FolderTreeDelegate

extension BrowserWindowController: FolderTreeDelegate {

    public func folderTreeDidSelect(_ selection: FolderSelection) {
        // Clear filter + search on folder change. Sort persists.
        clearSearchForNewFolder()
        navigate(to: selection.url)
    }

    public func folderTreeRequestReveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func folderTreeRequestNewFolder(parent: URL) {
        // Simple sheet-less prompt via NSAlert.
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Create a new folder inside \(parent.lastPathComponent):"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        input.placeholderString = "Untitled"
        alert.accessoryView = input
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let name = input.stringValue.isEmpty ? "Untitled" : input.stringValue
        let url = parent.appendingPathComponent(name, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: false
            )
            treeController.reload()
            treeController.select(url)
        } catch {
            flashToast("Couldn't create folder: \(error.localizedDescription)")
        }
    }

    public func folderTreeRequestAddBookmark(_ url: URL) {
        treeController.addFavorite(url)
    }

    public func folderTreeToast(_ message: String) {
        toast(message)
    }

    public func folderTreeRequestTransfer(_ verb: FileVerb, groups: [ImageGroup], to folder: URL) {
        transfer(verb, groups, to: folder)
    }

    /// ⌘D: the current folder goes into Favorites.
    func addCurrentFolderToFavorites() {
        guard let folder = currentFolder else { return }
        treeController.addFavorite(folder)
    }

    /// Test seam: the sidebar.
    var treeControllerForTesting: FolderTreeViewController { treeController }
}

// MARK: - BrowserContentDelegate

extension BrowserWindowController: BrowserContentDelegate {

    /// Runs in the click's main-thread turn, before the selection ring
    /// draws: budget under 16 ms. Everything slow (preview, EXIF, disk
    /// space) is read off the main thread afterwards.
    public func browserContentDidSelect(_ items: [BrowserItem]) {
        let signpost = ShrikeSignposts.browser.begin("browserSelectionChange")
        defer { ShrikeSignposts.browser.end("browserSelectionChange", signpost) }
        refreshSelectionInfo()
    }

    public func browserContentDidOpen(_ items: [BrowserItem], startingAt index: Int) {
        openInViewer(items: items, startIndex: index)
    }

    public func browserContentRequestsRevealInFinder(_ items: [BrowserItem]) {
        revealInFinder(items)
    }

    public func browserContentRequestsTrash(_ items: [BrowserItem]) {
        trash(items)
    }

    public func browserContentRequestsRate(_ items: [BrowserItem], to rating: Int) {
        applyRating(rating, to: items)
    }

    public func browserContentRequestsFlag(_ items: [BrowserItem], flag: Bool) {
        applyFlag(flag, to: items)
    }

    public func browserContentDidChangeMode(_ mode: BrowserViewMode) {
        viewModeGroup?.selectedIndex = mode.rawValue
        bottomBar.setSliderHidden(mode != .grid)
    }
}

// MARK: - NSWindowDelegate

extension BrowserWindowController: NSWindowDelegate {

    public func windowWillClose(_ notification: Notification) {
        stopWatching()
        // Give the autosave name back, so the next new Browser
        // can own it (saves its size) even while this object lives on.
        windowFrameAutosaveName = ""
    }
}

// MARK: - BrowserWindow subclass

/// Custom `NSWindow` that routes `keyDown` through the owning controller so
/// `BrowserKeyMap` shortcuts fire regardless of which pane holds first
/// responder. Follows the same pattern as `ViewerWindow`.
@MainActor
final class BrowserWindow: NSWindow {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Let text fields (search) and editable controls keep their keystrokes.
        if let responder = firstResponder,
           responder is NSText || responder is NSTextField {
            super.keyDown(with: event)
            return
        }
        if let controller = windowController as? BrowserWindowController,
           controller.routeKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }
}

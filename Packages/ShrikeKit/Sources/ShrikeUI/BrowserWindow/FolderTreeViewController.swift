//
//  FolderTreeViewController.swift
//  ShrikeUI
//
//  Left-pane folder tree in the browser window. `NSOutlineView` with the
//  sourceList style. Populated by `FolderTreeDataSource`.
//

import AppKit
import Foundation
import ShrikeCore
import ShrikeIO

@MainActor
public protocol FolderTreeDelegate: AnyObject {
    func folderTreeDidSelect(_ selection: FolderSelection)
    func folderTreeRequestReveal(_ url: URL)
    func folderTreeRequestNewFolder(parent: URL)
    func folderTreeRequestAddBookmark(_ url: URL)
    /// Shows `message` in the window's toast (missing favorite, eject
    /// failure).
    func folderTreeToast(_ message: String)
    /// Images dropped on a folder row are moved or copied
    /// there through `FileOps` (undo, toasts, conflicts).
    func folderTreeRequestTransfer(_ verb: FileVerb, groups: [ImageGroup], to folder: URL)
}

public extension FolderTreeDelegate {
    func folderTreeRequestTransfer(_ verb: FileVerb, groups: [ImageGroup], to folder: URL) {}
}

@MainActor
public final class FolderTreeViewController: NSViewController {

    public let dataSource: FolderTreeDataSource
    public weak var delegate: (any FolderTreeDelegate)?

    private let outlineView: SidebarOutlineView
    private let scrollView: NSScrollView

    /// Sources.
    public let favorites: FavoritesStore
    public let volumes: VolumeSource
    /// The folder the Browser shows; kept selected across a rebuild.
    private var currentURL: URL?
    /// True while the controller itself changes the selection, so the
    /// delegate is not told to navigate to the folder it is already on.
    private var isSelectingProgrammatically = false
    /// The last eject (tests await it).
    private(set) var ejectTask: Task<Void, Never>?

    /// Persisted expand/collapse state (UserDefaults-backed).
    private let expansionKey = "shrike.browser.tree.expanded"

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 600))
        view.addSubview(scrollView)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    public init(favorites: FavoritesStore? = nil, volumes: VolumeSource = .system) {
        self.dataSource = FolderTreeDataSource()
        self.outlineView = SidebarOutlineView()
        self.scrollView = NSScrollView()
        self.favorites = favorites ?? .standard()
        self.volumes = volumes
        super.init(nibName: nil, bundle: nil)

        configureOutlineView()

        dataSource.showHiddenFiles = Prefs.showHiddenFiles
        dataSource.rebuildRoots(favorites: self.favorites.rows(), volumes: volumes.list())
        // Mount / unmount notifications may arrive on any thread: the
        // selector is nonisolated and hops to the main actor.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumesDidChange(_:)),
                           name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumesDidChange(_:)),
                           name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc nonisolated private func volumesDidChange(_ note: Notification) {
        Task { @MainActor [weak self] in self?.refreshVolumes() }
    }

    /// Lists the volumes off the main thread (a slow network disk must not
    /// stall the UI), then rebuilds the sidebar.
    func refreshVolumes() {
        let list = volumes.list
        Task { [weak self] in
            let volumes = await Task.detached(priority: .userInitiated) { list() }.value
            self?.rebuild(volumes: volumes)
        }
    }

    /// Rebuilds Favorites and Locations, keeping the current folder
    /// selected. `volumes` nil lists them again synchronously.
    func rebuild(volumes newVolumes: [SidebarVolume]? = nil) {
        dataSource.rebuildRoots(favorites: favorites.rows(), volumes: newVolumes ?? volumes.list())
        guard isViewLoaded else { return }
        reload()
        if let currentURL { select(currentURL) }
    }

    // MARK: - Favorites editing

    /// Adds `url` to Favorites (⌘D, drag in, context menu).
    public func addFavorite(_ url: URL, at index: Int? = nil) {
        guard favorites.add(url, at: index) else { return }
        rebuild()
    }

    public func removeFavorite(at index: Int) {
        favorites.remove(at: index)
        rebuild()
    }

    public func moveFavorite(from: Int, to: Int) {
        favorites.move(from: from, to: to)
        rebuild()
    }

    /// Index of `node` in the Favorites section.
    private func favoriteIndex(of node: FolderTreeNode) -> Int? {
        guard node.kind == .favorite else { return nil }
        return dataSource.favoritesSection?.children.firstIndex { $0 === node }
    }

    /// ⌫ on a selected favorite removes it. Returns false for other rows.
    @discardableResult
    func deleteSelectedFavorite() -> Bool {
        let row = outlineView.selectedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FolderTreeNode,
              let index = favoriteIndex(of: node) else { return false }
        removeFavorite(at: index)
        return true
    }

    // MARK: - Eject

    /// Ejects `volume` off the main thread; a failure shows a toast.
    func eject(_ volume: SidebarVolume) {
        let eject = volumes.eject
        let url = volume.url
        ejectTask = Task { [weak self] in
            let failed = await Task.detached(priority: .userInitiated) { () -> Bool in
                do { try eject(url); return false } catch { return true }
            }.value
            guard let self else { return }
            if failed {
                self.delegate?.folderTreeToast(SidebarCopy.ejectFailed(volume.name))
            } else {
                self.refreshVolumes()
            }
        }
    }

    /// Test seams.
    var outlineViewForTesting: NSOutlineView { outlineView }
    func cellForTesting(row: Int) -> SidebarRowCell? {
        outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarRowCell
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Configuration

    private func configureOutlineView() {
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FolderTree.Name"))
        column.title = "Name"
        column.width = 200
        // The one column follows the visible width, so a
        // long name truncates with "…" inside the sidebar instead of being
        // clipped by a column wider than the sidebar (the label's tail
        // truncation only applies inside the column).
        column.minWidth = 40
        column.resizingMask = .autoresizingMask
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.rowSizeStyle = .default
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 16
        outlineView.style = .sourceList
        // `selectionHighlightStyle = .sourceList` was deprecated in macOS 12
        // in favour of `.style = .sourceList` above, which already applies
        // the source-list selection chrome.
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.allowsMultipleSelection = false
        // Expanding a deep folder must not widen the column past the
        // sidebar (the names truncate instead).
        outlineView.autoresizesOutlineColumn = false
        outlineView.registerForDraggedTypes([.fileURL, PhotoPasteboard.groupIDsType])
        outlineView.setDraggingSourceOperationMask(.link, forLocal: false)

        outlineView.onDelete = { [weak self] in self?.deleteSelectedFavorite() ?? false }
        outlineView.menu = makeContextMenu()
        outlineView.setAccessibilityLabel("Folder tree")
        outlineView.setAccessibilityIdentifier("BrowserFolderTree")
    }

    /// The sidebar changed width: the name column takes the visible
    /// width again (grows or shrinks, down to its minimum), so a long
    /// name ends in "…" at the sidebar's edge.
    public override func viewDidLayout() {
        super.viewDidLayout()
        guard let column = outlineView.tableColumns.first else { return }
        let clip = scrollView.contentView.bounds.width
        guard clip > 0, abs(outlineView.frame.width - clip) > 0.5 || column.width < column.minWidth else { return }
        outlineView.sizeLastColumnToFit()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    /// Re-read from data source and push to the outline.
    public func reload() {
        outlineView.reloadData()
        // Expand top-level sections automatically — they're the primary
        // groupings and should always be visible. Locations is expanded so
        // Home / Pictures etc. are one click away.
        for root in dataSource.roots {
            outlineView.expandItem(root)
        }
        restoreExpandedState()
    }

    /// Find and select the node corresponding to `url`, if it exists.
    /// Lookup is by path (`FolderTreeDataSource.node(for:)`), listing only
    /// the target's ancestors, off the main thread. The
    /// row is selected when the chain has loaded. When no sidebar root
    /// contains `url`, the selection is cleared so the tree never points
    /// at a stale folder.
    public func select(_ url: URL) {
        currentURL = url
        selectTask?.cancel()
        // A favorite row that already points here stays selected (the
        // user clicked it; don't jump to the same folder in the tree).
        let path = url.standardizedFileURL.path
        if outlineView.selectedRow >= 0,
           let selected = outlineView.item(atRow: outlineView.selectedRow) as? FolderTreeNode,
           selected.url?.standardizedFileURL.path == path {
            selectTask = nil
            return
        }
        selectTask = Task { [weak self] in
            guard let self else { return }
            let node = await self.dataSource.node(for: url)
            guard !Task.isCancelled, self.currentURL == url else { return }
            self.applySelection(node)
        }
    }

    /// The running path lookup (tests await it).
    private(set) var selectTask: Task<Void, Never>?
    /// The keys held during a drop (tests set it; a real drag reads the
    /// keyboard).
    var modifierFlagsProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    /// Expands `node`'s loaded ancestor chain and selects its row.
    private func applySelection(_ node: FolderTreeNode?) {
        isSelectingProgrammatically = true
        defer { isSelectingProgrammatically = false }
        guard let node else {
            outlineView.deselectAll(nil)
            return
        }
        var chain: [FolderTreeNode] = []
        var cursor: FolderTreeNode? = node.parent
        while let c = cursor {
            chain.append(c)
            cursor = c.parent
        }
        for ancestor in chain.reversed() {
            // Loaded while the row was closed: show the new children.
            if !outlineView.isItemExpanded(ancestor) { outlineView.reloadItem(ancestor, reloadChildren: true) }
            outlineView.expandItem(ancestor)
        }
        let row = outlineView.row(forItem: node)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - Expanding (reads off the main thread)

    /// The last child read started by an expand (tests await it).
    private(set) var loadTask: Task<Void, Never>?

    /// Reads `node`'s children off the main thread, then opens the row.
    func loadThenExpand(_ node: FolderTreeNode) {
        guard !dataSource.isLoading(node) else { return }
        loadTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.dataSource.loadChildren(node)
            self.childrenArrived(node)
        }
    }

    /// The children of `node` are in: show them and open the row, keeping
    /// the selected folder selected. Rows above `node` do not move, so the
    /// scroll position holds.
    private func childrenArrived(_ node: FolderTreeNode) {
        guard outlineView.row(forItem: node) >= 0 else { return }
        let selected = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) : nil
        let origin = scrollView.contentView.bounds.origin
        outlineView.reloadItem(node, reloadChildren: true)
        outlineView.expandItem(node)
        if let path = node.url?.standardizedFileURL.path { pendingExpandPaths.remove(path) }
        if let selected {
            let row = outlineView.row(forItem: selected)
            if row >= 0, outlineView.selectedRow != row {
                isSelectingProgrammatically = true
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSelectingProgrammatically = false
            }
        }
        if scrollView.contentView.bounds.origin != origin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        // Folders the user had open last time, one level at a time.
        for child in node.children {
            if let path = child.url?.standardizedFileURL.path, pendingExpandPaths.contains(path) {
                outlineView.expandItem(child)
            }
        }
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reveal in Finder",
                     action: #selector(menuReveal(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "New Folder Inside",
                     action: #selector(menuNewFolder(_:)),
                     keyEquivalent: "n")
        menu.addItem(withTitle: "Add to Favorites",
                     action: #selector(menuAddBookmark(_:)),
                     keyEquivalent: "")
        menu.addItem(withTitle: "Remove from Favorites",
                     action: #selector(menuRemoveFavorite(_:)),
                     keyEquivalent: "")
        for item in menu.items { item.target = self }
        // "Set as Destination ▸ 1 … 9", filled on open with
        // the current slot names.
        menu.addItem(.separator())
        let parent = NSMenuItem(title: "Set as Destination", action: nil, keyEquivalent: "")
        parent.submenu = destinationMenu
        destinationMenu.delegate = self
        menu.addItem(parent)
        return menu
    }

    /// Where the destination slots live (tests use a throwaway suite).
    var destinationSlots: DestinationSlots = .standard

    /// Fills "Set as Destination ▸" for `folder`: one row per slot, the
    /// slot's current folder name (or "Empty"), a check on the slot that
    /// already points here.
    func fillDestinationMenu(for folder: URL?) {
        let menu = destinationMenu
        menu.removeAllItems()
        let slots = destinationSlots.slots()
        let here = folder.map(GroupList.canonical)
        for number in DestinationSlots.numbers {
            let slot = slots.indices.contains(number - 1) ? slots[number - 1] : nil
            let name = slot?.name ?? "Empty"
            let item = NSMenuItem(title: "\(number)  \(name)",
                                  action: #selector(menuSetDestination(_:)), keyEquivalent: "")
            item.target = self
            item.tag = number
            item.representedObject = folder
            item.isEnabled = folder != nil
            if let slot, let here, GroupList.canonical(slot.url) == here { item.state = .on }
            menu.addItem(item)
        }
    }

    let destinationMenu = NSMenu(title: "Set as Destination")

    @objc func menuSetDestination(_ sender: NSMenuItem) {
        guard let folder = sender.representedObject as? URL,
              DestinationSlots.numbers.contains(sender.tag) else { return }
        destinationSlots.set(sender.tag, folder: folder)
    }

    private var menuTargetNode: FolderTreeNode? {
        let row = outlineView.clickedRow
        if row < 0 { return nil }
        return outlineView.item(atRow: row) as? FolderTreeNode
    }

    @objc private func menuReveal(_ sender: Any?) {
        guard let url = menuTargetNode?.url else { return }
        delegate?.folderTreeRequestReveal(url)
    }

    @objc private func menuNewFolder(_ sender: Any?) {
        guard let url = menuTargetNode?.url else { return }
        delegate?.folderTreeRequestNewFolder(parent: url)
    }

    @objc private func menuAddBookmark(_ sender: Any?) {
        guard let url = menuTargetNode?.url else { return }
        addFavorite(url)
    }

    @objc private func menuRemoveFavorite(_ sender: Any?) {
        guard let node = menuTargetNode, let index = favoriteIndex(of: node) else { return }
        removeFavorite(at: index)
    }

    // MARK: - Expansion persistence

    /// Saved open folders whose parent has not loaded yet.
    private var pendingExpandPaths: Set<String> = []

    private func saveExpandedState() {
        var paths: [String] = Array(pendingExpandPaths)
        for i in 0..<outlineView.numberOfRows {
            guard let node = outlineView.item(atRow: i) as? FolderTreeNode,
                  let url = node.url else { continue }
            if outlineView.isItemExpanded(node) {
                paths.append(url.standardizedFileURL.path)
            }
        }
        ShrikeDefaults.store.set(paths, forKey: expansionKey)
    }

    private func restoreExpandedState() {
        guard let paths = ShrikeDefaults.store.array(forKey: expansionKey) as? [String] else {
            return
        }
        pendingExpandPaths = Set(paths)
        // Breadth-first over what is loaded: expand anything whose path
        // matches. An unloaded folder reads its children off the main
        // thread first; its own saved children open when they arrive.
        var queue: [FolderTreeNode] = dataSource.roots
        while !queue.isEmpty {
            let node = queue.removeFirst()
            if let url = node.url, pendingExpandPaths.contains(url.standardizedFileURL.path) {
                outlineView.expandItem(node)
            }
            queue.append(contentsOf: node.children)
        }
    }
}

// MARK: - NSOutlineViewDataSource

// MARK: - Set as Destination ▸

extension FolderTreeViewController: NSMenuItemValidation {
    /// "Add to Favorites" shows for folders not yet in Favorites; "Remove
    /// from Favorites" only on a favorite row. Section headers get nothing.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let node = menuTargetNode
        switch item.action {
        case #selector(menuAddBookmark(_:)):
            let isFavorite = node?.kind == .favorite
            item.isHidden = node == nil || isFavorite
            return node?.url != nil && !isFavorite
        case #selector(menuRemoveFavorite(_:)):
            item.isHidden = node?.kind != .favorite
            return node?.kind == .favorite
        case #selector(menuNewFolder(_:)):
            return node?.url != nil && node?.isMissing == false
        default:
            return node?.url != nil
        }
    }
}

extension FolderTreeViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === destinationMenu else { return }
        fillDestinationMenu(for: menuTargetNode?.url)
    }
}

extension FolderTreeViewController: NSOutlineViewDataSource {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        dataSource.numberOfChildren(of: item as? FolderTreeNode)
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        dataSource.child(index, of: item as? FolderTreeNode) ?? NSNull()
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? FolderTreeNode else { return false }
        return dataSource.isExpandable(node)
    }

    // MARK: Drag and drop
    //
    // Drag a folder in from Finder (or the grid) onto Favorites to add it;
    // drag a favorite within the section to reorder it.

    static let favoriteRowType = NSPasteboard.PasteboardType("app.shrike.favorite-row")

    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? FolderTreeNode, let index = favoriteIndex(of: node) else { return nil }
        let pbItem = NSPasteboardItem()
        pbItem.setString(String(index), forType: Self.favoriteRowType)
        return pbItem
    }

    /// Where a drop lands in Favorites (the insert index), or nil when the
    /// drop is refused. Also used by tests.
    func favoritesDropTarget(item: Any?, childIndex: Int, isReorder: Bool) -> Int? {
        if let node = item as? FolderTreeNode {
            if node.section == .favorites {
                return childIndex < 0 ? node.children.count : childIndex
            }
            if node.kind == .favorite, let index = favoriteIndex(of: node) { return index }
            return nil
        }
        // The section is hidden while empty: a drop anywhere adds the
        // first favorite.
        return dataSource.favoritesSection == nil && !isReorder ? 0 : nil
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let pb = info.draggingPasteboard
        let isReorder = pb.availableType(from: [Self.favoriteRowType]) != nil
            && (info.draggingSource as? NSOutlineView) === outlineView
        // Images on a folder row move or copy into it.
        if !isReorder, let transfer = imageDrop(pb, mask: info.draggingSourceOperationMask,
                                                item: item, childIndex: index) {
            outlineView.setDropItem(transfer.node, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return BrowserDropRules.operation(for: transfer.verb)
        }
        if !isReorder, !BrowserDropRules.droppedGroups(pb).isEmpty,
           Self.droppedFolders(pb).isEmpty {
            return []
        }
        guard let target = favoritesDropTarget(item: item, childIndex: index, isReorder: isReorder) else { return [] }
        if !isReorder, Self.droppedFolders(pb).isEmpty { return [] }
        outlineView.setDropItem(dataSource.favoritesSection, dropChildIndex: target)
        return isReorder ? .move : .link
    }

    public func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        let pb = info.draggingPasteboard
        if (info.draggingSource as? NSOutlineView) === outlineView,
           let raw = pb.string(forType: Self.favoriteRowType), let from = Int(raw) {
            moveFavorite(from: from, to: index < 0 ? Int.max : index)
            return true
        }
        if let transfer = imageDrop(pb, mask: info.draggingSourceOperationMask, item: item, childIndex: index),
           let folder = transfer.node.url {
            delegate?.folderTreeRequestTransfer(transfer.verb, groups: transfer.groups, to: folder)
            return true
        }
        let folders = Self.droppedFolders(pb)
        let start = favoritesDropTarget(item: item, childIndex: index, isReorder: false) ?? 0
        for (offset, url) in folders.enumerated() {
            addFavorite(url, at: start + offset)
        }
        return !folders.isEmpty
    }

    /// A drop of images ON a folder row (not between rows): the row, the
    /// groups and the verb by the Finder rules. Path only:
    /// the volume is found by prefix, nothing is read while dragging.
    func imageDrop(_ pb: NSPasteboard, mask: NSDragOperation, item: Any?, childIndex: Int)
        -> (node: FolderTreeNode, groups: [ImageGroup], verb: FileVerb)? {
        guard childIndex == NSOutlineViewDropOnItemIndex,
              let node = item as? FolderTreeNode, !node.isSection, !node.isMissing,
              let folder = node.url else { return nil }
        let groups = BrowserDropRules.droppedGroups(pb)
        guard let first = groups.first else { return nil }
        let sameVolume = BrowserDropRules.volumeRoot(first.primary) == BrowserDropRules.volumeRoot(folder)
        guard let verb = BrowserDropRules.sidebarVerb(modifiers: modifierFlagsProvider(), mask: mask,
                                                      sameVolume: sameVolume) else { return nil }
        return (node, groups, verb)
    }

    private static func droppedFolders(_ pb: NSPasteboard) -> [URL] {
        let urls = pb.readObjects(forClasses: [NSURL.self],
                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

// MARK: - NSOutlineViewDelegate

extension FolderTreeViewController: NSOutlineViewDelegate {

    public func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FolderTreeNode else { return nil }
        if node.isSection {
            // No custom font or colour; the source list draws
            // the group row title.
            let cell = NSTableCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("FolderTree.Header")
            let label = NSTextField(labelWithString: node.title)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.textField = label
            cell.setAccessibilityLabel(node.title)
            cell.setAccessibilityRole(.group)
            return cell
        }
        let cell = SidebarRowCell(node: node)
        cell.onEject = { [weak self] volume in self?.eject(volume) }
        cell.isRowSelected = outlineView.selectedRowIndexes.contains(outlineView.row(forItem: node))
        return cell
    }

    /// An unloaded folder reads its children off the main
    /// thread and opens when they arrive.
    public func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let node = item as? FolderTreeNode else { return false }
        if node.isSection || node.childrenLoaded { return true }
        loadThenExpand(node)
        return false
    }

    public func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? FolderTreeNode)?.isSection ?? false
    }

    public func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let node = item as? FolderTreeNode else { return false }
        if node.isMissing {
            // A missing favorite says why and stays put.
            if !isSelectingProgrammatically {
                delegate?.folderTreeToast(SidebarCopy.notAvailable(node.title))
            }
            return false
        }
        return !node.isSection
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        // The eject button shows on the selected row as well as on hover.
        for row in 0..<outlineView.numberOfRows {
            guard let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell else { continue }
            cell.isRowSelected = outlineView.selectedRowIndexes.contains(row)
        }
        guard !isSelectingProgrammatically else { return }
        let row = outlineView.selectedRow
        guard row >= 0,
              let node = outlineView.item(atRow: row) as? FolderTreeNode,
              let url = node.url else { return }
        delegate?.folderTreeDidSelect(FolderSelection(url: url))
    }

    public func outlineViewItemDidExpand(_ notification: Notification) {
        saveExpandedState()
    }

    public func outlineViewItemDidCollapse(_ notification: Notification) {
        if let node = notification.userInfo?["NSObject"] as? FolderTreeNode,
           let path = node.url?.standardizedFileURL.path {
            pendingExpandPaths.remove(path)
        }
        saveExpandedState()
    }
}

// MARK: - Outline view (⌫ removes a selected favorite)

@MainActor
final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // 51 = Delete (⌫), 117 = Forward Delete.
        if mods.isEmpty, event.keyCode == 51 || event.keyCode == 117, onDelete?() == true { return }
        super.keyDown(with: event)
    }
}

// MARK: - Row cell

/// A sidebar row: symbol, name, and for ejectable volumes an eject button
/// shown on hover or when the row is selected (always with VoiceOver on).
@MainActor
final class SidebarRowCell: NSTableCellView {

    let node: FolderTreeNode
    var onEject: ((SidebarVolume) -> Void)?
    let ejectButton: NSButton?

    var isRowSelected = false { didSet { updateEject() } }
    private var isHovering = false { didSet { updateEject() } }

    init(node: FolderTreeNode) {
        self.node = node
        if let volume = node.volume, volume.isEjectable {
            let label = SidebarCopy.ejectLabel(volume.name)
            let image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: label) ?? NSImage()
            let button = NSButton(image: image, target: nil, action: nil)
            button.isBordered = false
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.setAccessibilityLabel(label)
            button.toolTip = label
            ejectButton = button
        } else {
            ejectButton = nil
        }
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("FolderTree.Row")

        // No symbol configuration, no tint; the source list
        // sizes and tints the icon.
        let icon = NSImageView(image: NSImage(systemSymbolName: node.symbolName, accessibilityDescription: nil) ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: node.title)
        label.translatesAutoresizingMaskIntoConstraints = false
        // A long name ends in "…" ("Macintosh H…"), never a
        // bare cut. One line; the label gives way before the row does.
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(icon)
        addSubview(label)
        imageView = icon
        textField = label
        var constraints = [
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        if let ejectButton {
            ejectButton.target = self
            ejectButton.action = #selector(ejectTapped(_:))
            ejectButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(ejectButton)
            constraints += [
                ejectButton.widthAnchor.constraint(equalToConstant: 20),
                ejectButton.heightAnchor.constraint(equalToConstant: 20),
                ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)

        if node.isMissing {
            alphaValue = 0.5
            toolTip = SidebarCopy.notAvailableTooltip
            setAccessibilityLabel(node.title + ", " + SidebarCopy.notAvailableTooltip)
        } else {
            setAccessibilityLabel(node.title)
        }
        setAccessibilityRole(.row)
        updateEject()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard ejectButton != nil else { return }
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    private func updateEject() {
        ejectButton?.isHidden = !(isHovering || isRowSelected || NSWorkspace.shared.isVoiceOverEnabled)
    }

    @objc private func ejectTapped(_ sender: Any?) {
        if let volume = node.volume { onEject?(volume) }
    }
}

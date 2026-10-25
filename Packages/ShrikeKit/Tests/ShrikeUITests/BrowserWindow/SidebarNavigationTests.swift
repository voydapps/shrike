//
//  SidebarNavigationTests.swift
//  ShrikeUITests
//
//  Spec 22-sidebar (option B): one Locations tree that always shows the
//  current folder, Favorites as jumps. Temp folders and injected volume
//  lists only: nothing here reads or ejects the user's folders or disks.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class SidebarNavigationTests: XCTestCase {

    private var root: URL!
    private let keys = ["shrike.browser.tree.expanded", "shrike.browser.tree.expanded.sections"]
    private var saved: [String: Any] = [:]

    override func setUp() async throws {
        for key in keys { saved[key] = ShrikeDefaults.store.object(forKey: key); ShrikeDefaults.store.removeObject(forKey: key) }
        root = TestScratch.directory
            .appendingPathComponent("shrike-nav-\(UUID().uuidString)", isDirectory: true).standardizedFileURL
        for name in ["A/inner", "B", "C", "D", "Pics/2025/x", ".hid/under"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { ShrikeDefaults.store.set(value, forKey: key) }
            else { ShrikeDefaults.store.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    private final class Delegate: FolderTreeDelegate {
        var toasts: [String] = []
        var selected: [URL] = []
        func folderTreeDidSelect(_ selection: FolderSelection) { selected.append(selection.url) }
        func folderTreeRequestReveal(_ url: URL) {}
        func folderTreeRequestNewFolder(parent: URL) {}
        func folderTreeRequestAddBookmark(_ url: URL) {}
        func folderTreeToast(_ message: String) { toasts.append(message) }
    }

    /// A sidebar in a window whose only volume is the temp folder.
    private func makeTree(favorites: [URL] = [], volumes: [SidebarVolume]? = nil) -> (FolderTreeViewController, NSWindow, Delegate) {
        let volume = SidebarVolume(url: root, name: "Fixture", kind: .external, isEjectable: false)
        let store = FavoritesStore.inMemory(favorites.map { SidebarFavorite(path: $0.path) })
        let list = volumes ?? [volume]
        let tree = FolderTreeViewController(favorites: store, volumes: VolumeSource(list: { list }, eject: { _ in }))
        let delegate = Delegate()
        tree.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tree
        return (tree, window, delegate)
    }

    private func selectedNode(_ tree: FolderTreeViewController) -> FolderTreeNode? {
        let outline = tree.outlineViewForTesting
        return outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FolderTreeNode : nil
    }

    private func key(_ code: UInt16, _ char: Int, flags: NSEvent.ModifierFlags = [], window: NSWindow) -> NSEvent {
        let text = String(UnicodeScalar(UInt32(char))!)
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                windowNumber: window.windowNumber, context: nil, characters: text,
                                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    // MARK: Sections

    func testFreshPreferencesShowBothSectionsOpenAndHeadersDoNotCollapse() throws {
        let (tree, window, _) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        for section in tree.dataSource.roots {
            XCTAssertTrue(outline.isItemExpanded(section), "\(section.title) is open on a fresh store")
            XCTAssertFalse(tree.outlineView(outline, shouldShowOutlineCellForItem: section), "no collapse arrow on a header")
            XCTAssertFalse(tree.outlineView(outline, shouldCollapseItem: section))
        }
        XCTAssertEqual(tree.dataSource.roots.map(\.title), ["Favorites", "Locations"])
        XCTAssertNil(ShrikeDefaults.store.object(forKey: keys[1]), "the old per-section state is gone")
    }

    func testEmptyFavoritesSectionIsHiddenAndLocationsAlwaysShown() throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        XCTAssertEqual(tree.dataSource.roots.map(\.title), ["Locations"])
        XCTAssertEqual(tree.outlineViewForTesting.numberOfRows, 1 + 2, "header, Home, the volume")
    }

    // MARK: The one selection rule

    func testRevealSelectsTheTreeRowNotTheFavorite() async throws {
        let (tree, window, delegate) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        // The user clicks the Favorite: the Browser is asked to open it.
        let favoriteRow = outline.row(forItem: try XCTUnwrap(tree.dataSource.favoritesSection?.children.first))
        outline.selectRowIndexes(IndexSet(integer: favoriteRow), byExtendingSelection: false)
        XCTAssertEqual(delegate.selected.map(\.path), [url("Pics").path])
        // The Browser has opened the folder: the tree takes over the selection.
        tree.willNavigate(to: url("Pics"))
        XCTAssertEqual(outline.selectedRow, -1, "cleared at once, before the reveal")
        tree.select(url("Pics")); await tree.selectTask?.value
        let node = try XCTUnwrap(selectedNode(tree))
        XCTAssertEqual(node.kind, .folder)
        XCTAssertEqual(node.url?.standardizedFileURL.path, url("Pics").path)
        XCTAssertTrue(node.parent?.parent?.section == .locations, "volume > Pics under Locations")
        // The folder is opened by the reveal (a click, not a key).
        await tree.loadTask?.value
        XCTAssertTrue(outline.isItemExpanded(node))
        XCTAssertEqual(node.children.map(\.title), ["2025"])
        XCTAssertEqual(delegate.selected.count, 1, "the reveal did not ask the Browser to navigate again")
        XCTAssertTrue(tree.openedPaths.isEmpty, "rows opened by the reveal are not saved")
    }

    /// A child's chevron is centred under its parent's icon (±2 pt) at every
    /// sidebar icon size.
    func testChevronIsUnderTheParentIconAtSmallMediumAndLarge() async throws {
        for style in [NSTableView.RowSizeStyle.small, .medium, .large] {
            let (tree, window, _) = makeTree(); defer { window.close() }
            _ = tree.view
            let outline = tree.outlineViewForTesting
            outline.rowSizeStyle = style
            outline.reloadData()
            tree.select(url("Pics/2025"), autoExpand: false); await tree.selectTask?.value
            outline.layoutSubtreeIfNeeded()
            let child = try XCTUnwrap(selectedNode(tree))
            let parent = try XCTUnwrap(child.parent)
            let parentCell = try XCTUnwrap(tree.cellForTesting(row: outline.row(forItem: parent)))
            let icon = parentCell.iconViewForTesting
            let iconMid = outline.convert(icon.bounds, from: icon).midX
            let chevronMid = outline.frameOfOutlineCell(atRow: outline.row(forItem: child)).midX
            XCTAssertEqual(chevronMid, iconMid, accuracy: 2, "style \(style.rawValue), indent \(outline.indentationPerLevel)")
        }
    }

    // MARK: Drag

    /// A drag resting on a closed folder row opens it after the delay; it
    /// is not saved as opened by the user, and moving away or ending the
    /// drag cancels it.
    func testSpringLoadingOpensAClosedRowOnlyWhileTheDragRestsOnIt() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        let a = try XCTUnwrap(selectedNode(tree))
        let volumeRow = try XCTUnwrap(a.parent)
        let pics = try XCTUnwrap(volumeRow.children.first { $0.title == "Pics" })
        XCTAssertFalse(outline.isItemExpanded(pics))
        tree.springLoadDelay = .milliseconds(20)
        tree.isDragInProgress = { true }
        tree.springLoad(pics); await tree.springTask?.value
        XCTAssertTrue(outline.isItemExpanded(pics), "rested on it: opened")
        let saved = ShrikeDefaults.store.object(forKey: "shrike.browser.tree.expanded") as? [String] ?? []
        XCTAssertFalse(saved.contains(url("Pics").path), "not the user's own opening")

        let b = try XCTUnwrap(volumeRow.children.first { $0.title == "A" })
        tree.springLoad(b); tree.springLoad(nil); await tree.springTask?.value
        XCTAssertFalse(outline.isItemExpanded(b), "a drag that moved on opens nothing")

        tree.isDragInProgress = { false }
        outline.collapseItem(pics)
        tree.springLoad(pics); await tree.springTask?.value
        XCTAssertFalse(outline.isItemExpanded(pics), "the drag ended before the delay")
    }

    func testRevealOpensParentsAndIsolatesSiblings() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        var listed: [String] = []
        tree.dataSource.didListFolder = { listed.append($0.standardizedFileURL.path) }
        tree.select(url("Pics/2025")); await tree.selectTask?.value; await tree.loadTask?.value
        XCTAssertEqual(listed, [root.path, url("Pics").path, url("Pics/2025").path],
                       "the chain down to the folder and the folder itself, never A, B, C or D")
        let outline = tree.outlineViewForTesting
        let node = try XCTUnwrap(selectedNode(tree))
        XCTAssertEqual(node.title, "2025")
        XCTAssertTrue(outline.isItemExpanded(try XCTUnwrap(node.parent)))
        XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)))
    }

    func testHiddenAncestorShowsAsAPathRowAtHalfStrength() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        tree.dataSource.showHiddenFiles = false
        tree.select(url(".hid/under"), autoExpand: false); await tree.selectTask?.value
        let node = try XCTUnwrap(selectedNode(tree))
        XCTAssertEqual(node.title, "under")
        let parent = try XCTUnwrap(node.parent)
        XCTAssertTrue(parent.isPathRow); XCTAssertTrue(parent.isDimmed)
        let cell = try XCTUnwrap(tree.cellForTesting(row: tree.outlineViewForTesting.row(forItem: parent)))
        XCTAssertEqual(cell.textField?.alphaValue, 0.5)
        XCTAssertEqual(cell.iconViewForTesting.alphaValue, 0.5)
        XCTAssertEqual(cell.accessibilityLabel(), ".hid", "a path row is not announced as hidden")
    }

    func testFolderOutsideEveryRootIsNotSelected() async throws {
        let (tree, window, _) = makeTree(volumes: []); defer { window.close() }
        _ = tree.view
        XCTAssertNotNil(tree.dataSource.locationsSection?.children.first { $0.isHome })
        tree.select(url("A")); await tree.selectTask?.value
        XCTAssertNil(selectedNode(tree), "no root holds the folder: nothing is selected")
    }

    func testUnmountedVolumeClearsTheSelection() async throws {
        let gone = URL(fileURLWithPath: "/Volumes/SHRIKE-GONE-\(UUID().uuidString)/photos")
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        XCTAssertNotNil(selectedNode(tree))
        tree.select(gone); await tree.selectTask?.value
        XCTAssertNil(selectedNode(tree), "the disk is not in the volume list: the sidebar has nothing to point at")
    }

    // MARK: Keyboard

    func testDownArrowStepsThroughSiblingsAndNeverOpensThem() async throws {
        let (tree, window, delegate) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(outline)
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        let a = try XCTUnwrap(selectedNode(tree))
        XCTAssertFalse(outline.isItemExpanded(a))
        outline.keyDown(with: key(125, NSDownArrowFunctionKey, window: window))
        XCTAssertEqual(delegate.selected.map { $0.lastPathComponent }, ["B"], "↓ moves to the next sibling and opens it")
        // The Browser then reveals B: the keyboard origin means no auto-open.
        tree.select(url("B")); await tree.selectTask?.value
        await tree.loadTask?.value
        let b = try XCTUnwrap(selectedNode(tree))
        XCTAssertEqual(b.title, "B")
        XCTAssertFalse(b.childrenLoaded, "the folder was not even read: a key never opens a row")
        XCTAssertEqual(delegate.selected.count, 1)
    }

    func testRightOpensThenEntersAndLeftClosesThenGoesUp() async throws {
        let (tree, window, delegate) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(outline)
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        let a = try XCTUnwrap(selectedNode(tree))
        outline.keyDown(with: key(124, NSRightArrowFunctionKey, window: window))
        XCTAssertTrue(outline.isItemExpanded(a), "→ opens a closed row")
        XCTAssertEqual(tree.openedPaths, [url("A").path], "a hand-opened row is saved")
        await tree.loadTask?.value
        XCTAssertEqual(delegate.selected.count, 0, "opening does not navigate")
        outline.keyDown(with: key(124, NSRightArrowFunctionKey, window: window))
        XCTAssertEqual(delegate.selected.map { $0.lastPathComponent }, ["inner"], "→ on an open row enters its first child")
        outline.keyDown(with: key(123, NSLeftArrowFunctionKey, window: window))
        XCTAssertEqual(delegate.selected.map { $0.lastPathComponent }, ["inner", "A"], "← on a leaf goes to the parent")
        outline.keyDown(with: key(123, NSLeftArrowFunctionKey, window: window))
        XCTAssertFalse(outline.isItemExpanded(a), "← on an open row closes it")
        XCTAssertTrue(tree.openedPaths.isEmpty, "closing by hand forgets it")
        // ⌥→ is one level, like →.
        outline.keyDown(with: key(124, NSRightArrowFunctionKey, flags: .option, window: window))
        XCTAssertTrue(outline.isItemExpanded(a))
    }

    func testReturnEnterAndCommandDownFocusThePhotosAndSpaceDoesNothing() async throws {
        let (tree, window, delegate) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(outline)
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        var focused = 0
        tree.onFocusPhotos = { focused += 1 }
        outline.keyDown(with: key(36, 13, window: window))
        outline.keyDown(with: key(76, 3, window: window))
        outline.keyDown(with: key(125, NSDownArrowFunctionKey, flags: .command, window: window))
        XCTAssertEqual(focused, 3)
        XCTAssertTrue(delegate.selected.isEmpty, "Return, Enter and ⌘↓ do not navigate")
        outline.keyDown(with: key(49, 32, window: window))
        XCTAssertEqual(focused, 3, "Space does not move focus")
        XCTAssertTrue(delegate.selected.isEmpty)
    }

    // MARK: Persistence

    func testOnlyHandOpenedRowsAreSavedAndTheListIsCapped() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        tree.select(url("Pics/2025")); await tree.selectTask?.value; await tree.loadTask?.value
        XCTAssertTrue(tree.openedPaths.isEmpty)
        XCTAssertNil(ShrikeDefaults.store.stringArray(forKey: keys[0])?.first, "nothing was written for a reveal")
        let pics = try XCTUnwrap(selectedNode(tree)?.parent)
        outline.collapseItem(pics); outline.expandItem(pics)   // the user's own click
        XCTAssertEqual(tree.openedPaths, [url("Pics").path])
        XCTAssertEqual(ShrikeDefaults.store.stringArray(forKey: keys[0]), [url("Pics").path])
        for index in 0..<(FolderTreeViewController.openedPathsLimit + 5) { tree.noteUserOpened("/p/\(index)") }
        XCTAssertEqual(tree.openedPaths.count, FolderTreeViewController.openedPathsLimit)
        XCTAssertEqual(tree.openedPaths.last, "/p/\(FolderTreeViewController.openedPathsLimit + 4)")
        XCTAssertFalse(tree.openedPaths.contains(url("Pics").path), "the oldest were dropped")
    }

    func testSavedOpenRowsComeBackOnAFreshTree() async throws {
        ShrikeDefaults.store.set([url("A").path], forKey: keys[0])
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        // The saved row opens once its parent (the volume row) is loaded.
        let volume = try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        outline.expandItem(volume)
        await tree.loadTask?.value; await tree.loadTask?.value
        let a = try XCTUnwrap(volume.children.first { $0.title == "A" })
        XCTAssertTrue(outline.isItemExpanded(a))
    }

    // MARK: Errors

    func testUnreadableFolderLosesItsChevronGetsATooltipAndOneToast() async throws {
        let (tree, window, delegate) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        let denied = url("A").standardizedFileURL.path
        tree.dataSource.lister = { folder, hidden in
            if folder.standardizedFileURL.path == denied { throw CocoaError(.fileReadNoPermission) }
            return try FolderTreeDataSource.readSubfolders(of: folder, showHidden: hidden)
        }
        let volume = try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        outline.expandItem(volume); await tree.loadTask?.value
        let a = try XCTUnwrap(volume.children.first { $0.title == "A" })
        XCTAssertTrue(tree.dataSource.isExpandable(a))
        outline.expandItem(a); await tree.loadTask?.value
        XCTAssertTrue(a.isUnreadable)
        XCTAssertFalse(tree.dataSource.isExpandable(a), "no chevron")
        XCTAssertEqual(delegate.toasts, ["Shrike can't read “A”."])
        let cell = try XCTUnwrap(tree.cellForTesting(row: outline.row(forItem: a)))
        XCTAssertEqual(cell.toolTip, "Shrike can't read this folder.")
        XCTAssertEqual(cell.accessibilityLabel(), "A, can't read")
        // Read again: still one toast per folder.
        tree.dataSource.invalidate(a)
        _ = await tree.dataSource.loadChildren(a)
        XCTAssertEqual(delegate.toasts.count, 1)
    }

    // MARK: Menu, rows, VoiceOver

    func testContextMenuHasTheNewOrderNoKeysAndEjectForEjectableVolumes() throws {
        let sd = SidebarVolume(url: URL(fileURLWithPath: "/Volumes/SD CARD"), name: "SD CARD", kind: .removable, isEjectable: true)
        let boot = SidebarVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", kind: .internal, isEjectable: false)
        let (tree, window, _) = makeTree(volumes: [sd, boot]); defer { window.close() }
        _ = tree.view
        let menu = try XCTUnwrap(tree.outlineViewForTesting.menu)
        XCTAssertEqual(menu.items.filter { !$0.isSeparatorItem }.map(\.title),
                       ["Open in New Window", "Reveal in Finder", "Copy Path", "New Folder…", "Add to Favorites",
                        "Remove from Favorites", "Set as Destination", "Show Package Contents", "Eject “”"])
        XCTAssertTrue(menu.items.allSatisfy { $0.keyEquivalent.isEmpty }, "no ⌘N on New Folder")
        // Eject: title follows the volume row.
        let locations = try XCTUnwrap(tree.dataSource.locationsSection)
        let sdNode = try XCTUnwrap(locations.children.first { $0.kind == .volume && $0.volume?.name == "SD CARD" })
        let bootNode = try XCTUnwrap(locations.children.first { $0.volume?.name == "Macintosh HD" })
        tree.menuTargetForTesting = sdNode
        let eject = try XCTUnwrap(menu.items.last)
        XCTAssertTrue(tree.validateMenuItem(eject))
        XCTAssertFalse(eject.isHidden)
        XCTAssertEqual(eject.title, "Eject “SD CARD”")
        tree.menuTargetForTesting = bootNode
        XCTAssertFalse(tree.validateMenuItem(eject))
        XCTAssertTrue(eject.isHidden, "the startup disk cannot be ejected")
        tree.menuTargetForTesting = nil
    }

    func testIconBoxesAreSquareAndEqualSoNamesLineUp() throws {
        let (tree, window, _) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        window.contentView?.layoutSubtreeIfNeeded()
        var starts: Set<CGFloat> = []
        for row in 0..<outline.numberOfRows {
            guard let cell = tree.cellForTesting(row: row), let label = cell.textField else { continue }
            // The icon box is pinned square at the row's icon size (width and
            // height constraints), so a name starts at one x in every row.
            let icon = cell.iconViewForTesting
            let side = SidebarRowCell.iconSide(for: outline.effectiveRowSizeStyle)
            let sizes = icon.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height }.map(\.constant)
            XCTAssertGreaterThanOrEqual(sizes.filter { $0 == side }.count, 2, "row \(row): \(sizes)")
            let gap = cell.constraints.first { $0.firstItem === label && $0.firstAttribute == .leading && $0.secondItem === icon }
            starts.insert(gap?.constant ?? -1)
            XCTAssertNotNil(label)
        }
        XCTAssertEqual(starts.count, 1, "label starts 6 pt after the icon box in every row: \(starts)")
        XCTAssertEqual(SidebarRowCell.iconSide(for: .small), 16)
        XCTAssertEqual(SidebarRowCell.iconSide(for: .medium), 20)
        XCTAssertEqual(SidebarRowCell.iconSide(for: .large), 24)
    }

    func testRowsInsideTheTreeUseTheFolderSymbol() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        let volume = try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        let children = await tree.dataSource.loadChildren(volume)
        XCTAssertTrue(children.allSatisfy { $0.symbolName == "folder" })
        XCTAssertEqual(tree.dataSource.locationsSection?.children.first?.symbolName, "house")
    }

    func testVoiceOverNamesAndCurrentFolderValue() async throws {
        let (tree, window, _) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        XCTAssertEqual(outline.accessibilityLabel(), "Sidebar")
        XCTAssertEqual(outline.accessibilityIdentifier(), "BrowserFolderTree")
        tree.select(url("A"), autoExpand: false); await tree.selectTask?.value
        let node = try XCTUnwrap(selectedNode(tree))
        let cell = try XCTUnwrap(tree.cellForTesting(row: outline.selectedRow))
        XCTAssertEqual(cell.accessibilityLabel(), "A, current folder")
        XCTAssertEqual(cell.accessibilityValue() as? String, "current folder")
        XCTAssertNotEqual(cell.accessibilityRole(), .row, "the outline's own row is the row")
        // The Favorite for another folder is not "current".
        let favoriteRow = outline.row(forItem: try XCTUnwrap(tree.dataSource.favoritesSection?.children.first))
        XCTAssertNil(tree.cellForTesting(row: favoriteRow)?.accessibilityValue())
        XCTAssertEqual(node.kind, .folder)
        // A hidden folder is announced as hidden.
        tree.dataSource.showHiddenFiles = true
        let volume = try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        tree.dataSource.invalidate(volume)
        tree.reload()
        outline.collapseItem(volume); outline.expandItem(volume); await tree.loadTask?.value
        let hidden = try XCTUnwrap(volume.children.first { $0.title == ".hid" })
        let hiddenCell = try XCTUnwrap(tree.cellForTesting(row: outline.row(forItem: hidden)))
        XCTAssertEqual(hiddenCell.accessibilityLabel(), ".hid, hidden")
        XCTAssertEqual(hiddenCell.textField?.alphaValue, 0.5)
    }

    func testLongNamesGetExpansionTooltipsAndTailTruncation() throws {
        let (tree, window, _) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let cell = try XCTUnwrap(tree.cellForTesting(row: 1))
        XCTAssertTrue(cell.textField?.allowsExpansionToolTips == true)
        XCTAssertEqual(cell.textField?.lineBreakMode, .byTruncatingTail)
    }

    // MARK: Browser entry points

    func testEveryWayOfChangingFolderEndsWithTheTreeRowSelected() async throws {
        let a = url("A"), pics = url("Pics"), inner = url("A/inner")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: a)
        defer { browser.close() }
        let tree = browser.treeControllerForTesting
        var listed: [String] = []
        tree.dataSource.didListFolder = { listed.append($0.standardizedFileURL.path) }
        func settle(_ folder: URL) async throws {
            let want = folder.standardizedFileURL.path
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                await tree.selectTask?.value
                if let node = selectedNode(tree), node.kind != .favorite,
                   node.url?.standardizedFileURL.path == want, browser.currentFolder?.path == want { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("tree did not select \(want); selected \(String(describing: selectedNode(tree)?.url))")
        }
        try await settle(a)                                   // opened with a folder
        browser.navigate(to: pics); try await settle(pics)    // path bar / Go to Folder / Finder open
        browser.perform(.back); try await settle(a)           // ⌘[
        browser.perform(.forward); try await settle(pics)     // ⌘]
        browser.navigate(to: inner); try await settle(inner)
        browser.perform(.enclosingFolder); try await settle(a) // ⌘↑
        // Only the chains toward the visited folders were read.
        // (/var, /tmp and /etc are read as /private/…: the real folder.)
        let visited = [a, pics, inner].map { FolderTreeDataSource.lookupComponents($0).dropFirst().joined(separator: "/") }
            .map { "/" + $0 }
        for path in listed.map({ FolderTreeDataSource.lookupComponents(URL(fileURLWithPath: $0)).dropFirst().joined(separator: "/") }).map({ "/" + $0 }) {
            XCTAssertTrue(visited.contains { $0 == path || $0.hasPrefix(path + "/") || path == "/" },
                          "\(path) is not on the way to a visited folder")
        }
        XCTAssertFalse(listed.contains(url("B").standardizedFileURL.path))
        XCTAssertFalse(listed.contains(url("C").standardizedFileURL.path))
    }

    // MARK: Row sizes and the spinner

    /// Small, Medium and Large sidebar sizes (System Settings › Appearance):
    /// the icon box follows the row size and the names still line up.
    func testIconBoxFollowsEveryRowSizeAndNamesLineUp() throws {
        let (tree, window, _) = makeTree(favorites: [url("Pics")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        window.makeKeyAndOrderFront(nil)
        for (style, side) in [(NSTableView.RowSizeStyle.small, 16.0), (.medium, 20.0), (.large, 24.0)] as [(NSTableView.RowSizeStyle, CGFloat)] {
            outline.rowSizeStyle = style
            outline.reloadData()
            for root in tree.dataSource.roots { outline.expandItem(root) }
            window.contentView?.layoutSubtreeIfNeeded()
            var starts: Set<CGFloat> = []
            for row in 0..<outline.numberOfRows {
                guard let cell = tree.cellForTesting(row: row), cell.textField != nil else { continue }
                XCTAssertEqual(SidebarRowCell.iconSide(for: outline.effectiveRowSizeStyle), side)
                let sizes = cell.iconViewForTesting.constraints.filter { $0.firstAttribute == .width || $0.firstAttribute == .height }.map(\.constant)
                XCTAssertGreaterThanOrEqual(sizes.filter { $0 == side }.count, 2, "\(style.rawValue): \(sizes)")
                cell.frame.size = NSSize(width: 240, height: outline.rect(ofRow: row).height)
                cell.layoutSubtreeIfNeeded()
                starts.insert((cell.textField!.frame.minX - cell.iconViewForTesting.frame.minX).rounded())
            }
            XCTAssertEqual(starts.count, 1, "\(style.rawValue): names start at one x: \(starts)")
        }
    }

    /// A slow read shows the spinner only after 300 ms (spec 22-sidebar §4.2).
    func testSpinnerShowsOnlyAfter300ms() async throws {
        let (tree, window, _) = makeTree(); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        tree.dataSource.lister = { folder, hidden in
            if folder.lastPathComponent == "A" { Thread.sleep(forTimeInterval: 0.9) }
            return try FolderTreeDataSource.readSubfolders(of: folder, showHidden: hidden)
        }
        let volume = try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
        outline.expandItem(volume); await tree.loadTask?.value
        let a = try XCTUnwrap(volume.children.first { $0.title == "A" })
        outline.expandItem(a)
        let cell = try XCTUnwrap(tree.cellForTesting(row: outline.row(forItem: a)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(cell.isShowingSpinner, "nothing under 300 ms")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(cell.isShowingSpinner, "after 300 ms")
        await tree.loadTask?.value
        XCTAssertFalse(tree.cellForTesting(row: outline.row(forItem: a))?.isShowingSpinner ?? false, "gone when the read ends")
    }
}

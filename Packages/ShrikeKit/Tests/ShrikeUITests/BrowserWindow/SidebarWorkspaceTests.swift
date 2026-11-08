//
//  SidebarWorkspaceTests.swift
//  ShrikeUITests
//
//  Spec 23-workspace: the pinned folder. Temp folders, in-memory stores and
//  an injected volume list only. The one test that reads the real
//  preferences path uses `ShrikeDefaults.store` (a temp suite under XCTest)
//  and puts the key back.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class SidebarWorkspaceTests: XCTestCase {

    private var root: URL!
    private var savedExpansion: Any?
    private var savedWorkspace: Data?

    override func setUp() async throws {
        savedExpansion = ShrikeDefaults.store.object(forKey: "shrike.browser.tree.expanded")
        savedWorkspace = Prefs.browserWorkspaceData
        root = TestScratch.directory
            .appendingPathComponent("shrike-ws-\(UUID().uuidString)", isDirectory: true)
        for path in ["Trips/Italy/Rome", "Trips/Japan/Day1", "Other/Inner"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        if let savedExpansion { ShrikeDefaults.store.set(savedExpansion, forKey: "shrike.browser.tree.expanded") }
        else { ShrikeDefaults.store.removeObject(forKey: "shrike.browser.tree.expanded") }
        Prefs.browserWorkspaceData = savedWorkspace
        try? FileManager.default.removeItem(at: root)
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path, isDirectory: true) }

    private var fixtureVolume: SidebarVolume {
        SidebarVolume(url: root, name: "Fixture", kind: .external, isEjectable: false)
    }

    private final class Delegate: FolderTreeDelegate {
        var toasts: [String] = []
        var selected: [URL] = []
        func folderTreeDidSelect(_ selection: FolderSelection) { selected.append(selection.url) }
        func folderTreeRequestReveal(_ url: URL) {}
        func folderTreeRequestNewFolder(parent: URL) {}
        func folderTreeRequestAddBookmark(_ url: URL) {}
        func folderTreeToast(_ message: String) { toasts.append(message) }
    }

    private func makeTree(workspace: WorkspaceStore, favorites: [URL] = []) -> (FolderTreeViewController, NSWindow, Delegate) {
        let favs = FavoritesStore.inMemory(favorites.map { SidebarFavorite(path: $0.path) })
        let list = [fixtureVolume]
        let tree = FolderTreeViewController(favorites: favs, volumes: VolumeSource(list: { list }, eject: { _ in }),
                                            workspace: workspace)
        let delegate = Delegate()
        tree.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tree
        return (tree, window, delegate)
    }

    private func ancestorSection(_ node: FolderTreeNode?) -> FolderTreeSection? {
        var cursor = node
        while let c = cursor { if let s = c.section { return s }; cursor = c.parent }
        return nil
    }

    // MARK: Store

    func testSetReplaceClearAndPersistThroughShrikeDefaults() {
        Prefs.browserWorkspaceData = nil
        let first = WorkspaceStore.prefsBacked()
        XCTAssertFalse(first.isSet)
        XCTAssertNil(first.row())
        XCTAssertTrue(first.set(url("Trips")))
        XCTAssertEqual(first.row(), SidebarWorkspaceRow(url: url("Trips").standardizedFileURL, isMissing: false))
        XCTAssertNotNil(ShrikeDefaults.store.data(forKey: "shrike.browser.workspace"), "stored through ShrikeDefaults.store")
        XCTAssertFalse(first.saved()?.bookmark.isEmpty ?? true, "a bookmark is kept")

        // A later launch (a new store object) sees it.
        let second = WorkspaceStore.prefsBacked()
        XCTAssertEqual(second.saved()?.path, url("Trips").standardizedFileURL.path)
        // Setting another replaces it.
        XCTAssertTrue(second.set(url("Other")))
        XCTAssertEqual(first.saved()?.path, url("Other").standardizedFileURL.path)
        second.clear()
        XCTAssertFalse(first.isSet)
        XCTAssertNil(ShrikeDefaults.store.data(forKey: "shrike.browser.workspace"))
        XCTAssertNil(Prefs.browserWorkspaceData)
    }

    func testRootFolderIsRefused() {
        let store = WorkspaceStore.inMemory()
        XCTAssertFalse(store.set(URL(fileURLWithPath: "/")))
        XCTAssertFalse(store.isSet)
        let (tree, window, delegate) = makeTree(workspace: store); defer { window.close() }
        XCTAssertFalse(tree.setWorkspace(URL(fileURLWithPath: "/")))
        XCTAssertEqual(delegate.toasts, ["Choose a smaller folder."])
        XCTAssertFalse(store.isSet)
    }

    func testRenamedFolderIsFoundByBookmarkAndMissingOneIsMissing() throws {
        let store = WorkspaceStore.inMemory()
        XCTAssertTrue(store.set(url("Trips")))
        try FileManager.default.moveItem(at: url("Trips"), to: url("Trips 2026"))
        let moved = try XCTUnwrap(store.row())
        XCTAssertFalse(moved.isMissing)
        XCTAssertEqual(moved.url.resolvingSymlinksInPath().lastPathComponent, "Trips 2026")
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(store.saved()).path).lastPathComponent, "Trips 2026",
                       "the new place is saved")
        try FileManager.default.removeItem(at: url("Trips 2026"))
        let gone = try XCTUnwrap(store.row())
        XCTAssertTrue(gone.isMissing)
        XCTAssertTrue(store.isSet, "nothing is cleared by itself")
    }

    func testSetAndClearPostTheChangeNotification() {
        let store = WorkspaceStore.inMemory()
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()
        let token = NotificationCenter.default.addObserver(forName: .shrikeWorkspaceDidChange, object: nil, queue: nil) { _ in counter.value += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.set(url("Trips")); store.clear()
        XCTAssertEqual(counter.value, 2)
    }

    // MARK: Sidebar

    func testSectionOrderFirstRowAndRootLook() throws {
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let (tree, window, _) = makeTree(workspace: store, favorites: [url("Other")]); defer { window.close() }
        _ = tree.view
        XCTAssertEqual(tree.dataSource.roots.compactMap(\.section), [.workspace, .favorites, .locations])
        let outline = tree.outlineViewForTesting
        let header = try XCTUnwrap(outline.item(atRow: 0) as? FolderTreeNode)
        XCTAssertEqual(header.title, "Workspace")
        XCTAssertTrue(header.isSection)
        let rootNode = try XCTUnwrap(outline.item(atRow: 1) as? FolderTreeNode)
        XCTAssertTrue(rootNode.isWorkspaceRoot)
        XCTAssertEqual(rootNode.title, "Trips")
        XCTAssertEqual(rootNode.symbolName, "folder.fill")
        let cell = try XCTUnwrap(tree.cellForTesting(row: 1))
        XCTAssertEqual(cell.accessibilityLabel(), "Trips, Workspace")
        XCTAssertEqual(cell.alphaValue, 1, accuracy: 0.001)
    }

    func testNoWorkspaceNoSection() {
        let (tree, window, _) = makeTree(workspace: .inMemory(), favorites: [url("Other")]); defer { window.close() }
        XCTAssertEqual(tree.dataSource.roots.compactMap(\.section), [.favorites, .locations])
    }

    func testSelectionRuleAndTieWithHome() async throws {
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let (tree, window, _) = makeTree(workspace: store); defer { window.close() }
        let ds = tree.dataSource
        let inside = await ds.node(for: url("Trips/Japan/Day1"))
        XCTAssertEqual(ancestorSection(inside), .workspace, "inside the Workspace: its own tree")
        let atRoot = await ds.node(for: url("Trips"))
        XCTAssertTrue(atRoot?.isWorkspaceRoot == true)
        let outside = await ds.node(for: url("Other/Inner"))
        XCTAssertEqual(ancestorSection(outside), .locations, "outside: Locations as before")

        // The Workspace is Home: Workspace wins the tie (path compare only).
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let tie = FolderTreeDataSource()
        tie.rebuildRoots(favorites: [], volumes: [],
                         workspace: SidebarWorkspaceRow(url: home, isMissing: false))
        let tied = await tie.node(for: home)
        XCTAssertTrue(tied?.isWorkspaceRoot == true)
        XCTAssertEqual(ancestorSection(tied), .workspace)
    }

    func testRevealListsOnlyBelowTheWorkspaceRoot() async throws {
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let (tree, window, _) = makeTree(workspace: store); defer { window.close() }
        var listed: [String] = []
        tree.dataSource.didListFolder = { listed.append($0.standardizedFileURL.path) }
        _ = await tree.dataSource.node(for: url("Trips/Japan/Day1"))
        let top = url("Trips").standardizedFileURL.path
        XCTAssertEqual(listed, [top, top + "/Japan"], "the root and the chain below it, nothing above")
    }

    func testSettingExpandsRootOneLevelAndRebuildsOtherSidebars() async throws {
        let store = WorkspaceStore.inMemory()
        let (tree, window, delegate) = makeTree(workspace: store); defer { window.close() }
        _ = tree.view
        window.makeKeyAndOrderFront(nil)
        XCTAssertNil(tree.dataSource.workspaceSection)
        XCTAssertTrue(tree.setWorkspace(url("Trips")))
        XCTAssertEqual(delegate.toasts, ["Workspace is now “Trips”."])
        XCTAssertEqual(tree.dataSource.roots.first?.section, .workspace)
        let rootNode = try XCTUnwrap(tree.dataSource.workspaceRoot)
        let outline = tree.outlineViewForTesting
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !(outline.isItemExpanded(rootNode) && rootNode.childrenLoaded) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(rootNode.children.map(\.title), ["Italy", "Japan"], "one level read")
        XCTAssertTrue(outline.isItemExpanded(rootNode))
        XCTAssertFalse(outline.isItemExpanded(rootNode.children[1]), "nothing deeper")

        tree.clearWorkspace()
        XCTAssertEqual(delegate.toasts.last, "Workspace cleared.")
        XCTAssertNil(tree.dataSource.workspaceSection)
        XCTAssertFalse(store.isSet)
    }

    /// Setting a Workspace shows the "Workspace" heading: the sidebar goes to
    /// the top even when the revealed folder is far down. An unrelated
    /// rebuild (a Favorite added) leaves the scroll alone.
    func testSettingWorkspaceScrollsSidebarToTopButOtherRebuildsDoNot() async throws {
        for n in 0..<40 {
            try FileManager.default.createDirectory(at: url(String(format: "Tall/f%02d", n)),
                                                    withIntermediateDirectories: true)
        }
        let store = WorkspaceStore.inMemory()
        let (tree, window, _) = makeTree(workspace: store)
        defer { window.close() }
        window.setContentSize(NSSize(width: 300, height: 260))
        _ = tree.view
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let last = url("Tall/f39")
        tree.select(last)
        await tree.selectTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        let scrolled = tree.scrollOffsetForTesting
        XCTAssertGreaterThan(scrolled, 50, "the reveal scrolled down to the folder")

        // Another rebuild keeps the place.
        tree.addFavorite(url("Other"))
        await tree.selectTask?.value
        XCTAssertGreaterThan(tree.scrollOffsetForTesting, 50, "a Favorite added does not scroll to the top")

        XCTAssertTrue(tree.setWorkspace(url("Trips")))
        await tree.selectTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(tree.scrollOffsetForTesting, 0, accuracy: 1, "heading and root row are visible after Set")
        let outline = tree.outlineViewForTesting
        let visible = outline.rows(in: outline.visibleRect)
        XCTAssertEqual((outline.item(atRow: visible.location) as? FolderTreeNode)?.title, "Workspace")
    }

    /// Revealing the Workspace root (Go to Workspace, Command-Up, Back) ends
    /// with the heading visible; revealing any other row does not scroll to
    /// the top.
    func testRevealingTheWorkspaceRootShowsItsHeading() async throws {
        for n in 0..<40 {
            try FileManager.default.createDirectory(at: url(String(format: "Tall/f%02d", n)),
                                                    withIntermediateDirectories: true)
        }
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let (tree, window, _) = makeTree(workspace: store)
        defer { window.close() }
        window.setContentSize(NSSize(width: 300, height: 260))
        _ = tree.view
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()

        tree.select(url("Tall/f39"))
        await tree.selectTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tree.scrollOffsetForTesting, 50, "a non-root reveal scrolls to its row")

        tree.select(url("Trips"))                       // Go to Workspace
        await tree.selectTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(tree.scrollOffsetForTesting, 0, accuracy: 1)
        let outline = tree.outlineViewForTesting
        let first = outline.rows(in: outline.visibleRect)
        XCTAssertEqual((outline.item(atRow: first.location) as? FolderTreeNode)?.title, "Workspace")

        tree.select(url("Tall/f39"))                    // leaving again: normal reveal
        await tree.selectTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tree.scrollOffsetForTesting, 50, "other rows keep their behaviour")
    }

    func testMissingWorkspaceRootLooksAndActsUnavailable() throws {
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Gone").path))
        let (tree, window, delegate) = makeTree(workspace: store); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        let node = try XCTUnwrap(tree.dataSource.workspaceRoot)
        XCTAssertTrue(node.isMissing)
        XCTAssertFalse(tree.dataSource.isExpandable(node), "no chevron")
        let cell = try XCTUnwrap(tree.cellForTesting(row: outline.row(forItem: node)))
        XCTAssertEqual(cell.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(cell.accessibilityLabel(), "Gone, Workspace, Not available")
        XCTAssertFalse(tree.outlineView(outline, shouldSelectItem: node))
        XCTAssertEqual(delegate.toasts, ["“Gone” isn't available."])

        // The context menu offers only Clear Workspace.
        tree.menuTargetForTesting = node
        defer { tree.menuTargetForTesting = nil }
        let menu = try XCTUnwrap(outline.menu)
        for item in menu.items where !item.isSeparatorItem { item.isEnabled = tree.validateMenuItem(item) }
        let visible = menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.isEnabled }.map(\.title)
        XCTAssertEqual(visible, ["Clear Workspace"])
        XCTAssertTrue(store.isSet)
    }

    func testContextMenuItemsPerRow() async throws {
        let store = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let (tree, window, _) = makeTree(workspace: store, favorites: [url("Other")]); defer { window.close() }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        let menu = try XCTUnwrap(outline.menu)
        defer { tree.menuTargetForTesting = nil }
        func titles(for node: FolderTreeNode) -> [String] {
            tree.menuTargetForTesting = node
            for item in menu.items where !item.isSeparatorItem { item.isEnabled = tree.validateMenuItem(item) }
            return menu.items.filter { !$0.isHidden && !$0.isSeparatorItem && $0.isEnabled }.map(\.title)
        }
        let rootNode = try XCTUnwrap(tree.dataSource.workspaceRoot)
        let onRoot = titles(for: rootNode)
        XCTAssertTrue(onRoot.contains("Clear Workspace"))
        XCTAssertFalse(onRoot.contains("Set as Workspace"), "Clear replaces Set on the root row")
        let favorite = try XCTUnwrap(tree.dataSource.favoritesSection?.children.first)
        let onFavorite = titles(for: favorite)
        XCTAssertTrue(onFavorite.contains("Set as Workspace"))
        XCTAssertFalse(onFavorite.contains("Clear Workspace"))
        let slash = FolderTreeNode(url: URL(fileURLWithPath: "/"), title: "Macintosh HD")
        XCTAssertFalse(titles(for: slash).contains("Set as Workspace"), "never offered on /")
        // Set as Workspace sits after Remove from Favorites / Add to Favorites.
        let order = menu.items.map(\.title)
        let add = try XCTUnwrap(order.firstIndex(of: "Add to Favorites"))
        let set = try XCTUnwrap(order.firstIndex(of: "Set as Workspace"))
        let dest = try XCTUnwrap(order.firstIndex(of: "Set as Destination"))
        XCTAssertTrue(add < set && set < dest)
    }

    // MARK: Browser: ⌘↑, ⌃⌘W, ⌘N

    private func makeBrowser(at folder: URL, workspace: URL?) -> BrowserWindowController {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: folder)
        if let workspace { browser.treeControllerForTesting.workspace.set(workspace) }
        return browser
    }

    private func waitFolder(_ browser: BrowserWindowController, _ folder: URL) async throws {
        let want = folder.standardizedFileURL.path
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, browser.currentFolder?.standardizedFileURL.path != want {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(browser.currentFolder?.standardizedFileURL.path, want)
    }

    func testCommandUpStopsAtTheWorkspaceRootAndWorksOutside() async throws {
        let up = KeyEventSnapshot(key: SpecialKey.up, modifiers: .command)
        let browser = makeBrowser(at: url("Trips/Japan/Day1"), workspace: url("Trips")); defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.enclosingFolder))
        browser.handleKeySnapshot(up)                       // Day1 → Japan
        try await waitFolder(browser, url("Trips/Japan"))
        browser.handleKeySnapshot(up)                       // Japan → Trips (the root)
        try await waitFolder(browser, url("Trips"))

        XCTAssertFalse(browser.canPerform(.enclosingFolder), "Go ▸ Enclosing Folder is off at the root")
        browser.handleKeySnapshot(up)
        browser.perform(.enclosingFolder)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(browser.currentFolder?.standardizedFileURL.path, url("Trips").standardizedFileURL.path,
                       "⌘↑ does nothing at the root (key and menu)")

        // Back is not blocked: it leaves the root.
        browser.navigate(to: url("Other/Inner"))
        try await waitFolder(browser, url("Other/Inner"))
        XCTAssertTrue(browser.canPerform(.enclosingFolder), "outside the Workspace ⌘↑ works as today")
        browser.handleKeySnapshot(up)
        try await waitFolder(browser, url("Other"))
        browser.perform(.back)
        try await waitFolder(browser, url("Other/Inner"))
    }

    func testCommandUpWithNoWorkspaceIsUnchanged() async throws {
        let browser = makeBrowser(at: url("Trips"), workspace: nil); defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.enclosingFolder))
        browser.perform(.enclosingFolder)
        try await waitFolder(browser, root)
    }

    func testGoToWorkspace() async throws {
        let browser = makeBrowser(at: url("Other"), workspace: url("Trips")); defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.goToWorkspace))
        browser.perform(.goToWorkspace)
        try await waitFolder(browser, url("Trips"))
        XCTAssertEqual(browser.backStack.last?.standardizedFileURL.path, url("Other").standardizedFileURL.path,
                       "joins Back history")
        let depth = browser.backStack.count
        browser.perform(.goToWorkspace)                       // already there: nothing
        XCTAssertEqual(browser.backStack.count, depth)

        browser.treeControllerForTesting.workspace.clear()
        XCTAssertFalse(browser.canPerform(.goToWorkspace), "disabled when none is set")
    }

    func testShortcutIsCtrlCmdWAndUnique() {
        let binding = ShortcutTable.menuBinding(for: .goToWorkspace)
        XCTAssertEqual(binding?.displayString, "⌃⌘W")
        for preset in ShortcutPreset.allCases {
          for context in [ShortcutContext.browser, .viewer] {
            let rows = ShortcutTable.rows(for: preset).filter { $0.context == context && $0.binding == binding }
            XCTAssertEqual(rows.map(\.command), [.goToWorkspace], "no other command on ⌃⌘W in \(context)")
          }
        }
    }

    func testNewBrowserWindowOpensAtTheWorkspaceRootEachTime() throws {
        let coordinator = WindowCoordinator()
        coordinator.services = ShrikeServices.makeDefault()
        coordinator.workspaceStore = .inMemory(SidebarFavorite(path: url("Trips").path))
        coordinator.newBrowserWindow()
        coordinator.newBrowserWindow()
        defer { coordinator.browsers.forEach { $0.close() } }
        XCTAssertEqual(coordinator.browsers.count, 2, "⌘N always makes a window")
        XCTAssertEqual(coordinator.browsers.map { $0.currentFolder?.standardizedFileURL.path },
                       Array(repeating: url("Trips").standardizedFileURL.path, count: 2))

        let plain = WindowCoordinator()
        plain.services = ShrikeServices.makeDefault()
        plain.newBrowserWindow()
        defer { plain.browsers.forEach { $0.close() } }
        XCTAssertEqual(plain.browsers.count, 1)
        XCTAssertNotEqual(plain.browsers.first?.currentFolder?.standardizedFileURL.path, url("Trips").standardizedFileURL.path,
                          "no Workspace: the usual start folder, as before")
    }

    // MARK: File menu

    private struct FakePanel: OpenPanelRunning {
        var result: [URL]
        var seen: Box
        final class Box: @unchecked Sendable { var request: OpenPanelRequest? }
        func run(_ request: OpenPanelRequest, sheetFor window: NSWindow?,
                 completion: @escaping @MainActor ([URL]) -> Void) {
            seen.request = request
            completion(result)
        }
    }

    func testChooseAndClearWorkspaceFromTheFileMenu() throws {
        let coordinator = WindowCoordinator()
        coordinator.workspaceStore = .inMemory()
        let commands = AppCommands(coordinator: coordinator)
        let clear = NSMenuItem(title: "Clear Workspace", action: #selector(AppCommands.clearWorkspace(_:)), keyEquivalent: "")
        XCTAssertFalse(commands.validateMenuItem(clear), "off while none is set")

        let box = FakePanel.Box()
        commands.panelRunner = FakePanel(result: [url("Trips")], seen: box)
        commands.chooseWorkspace(nil)
        let request = try XCTUnwrap(box.request)
        XCTAssertFalse(request.canChooseFiles, "folders only")
        XCTAssertEqual(request.message, "Choose a folder to keep the sidebar on.")
        XCTAssertEqual(request.prompt, "Choose")
        XCTAssertFalse(request.allowsMultiple)
        XCTAssertEqual(coordinator.workspaceStore.saved()?.path, url("Trips").standardizedFileURL.path)
        XCTAssertTrue(commands.validateMenuItem(clear))

        commands.panelRunner = FakePanel(result: [URL(fileURLWithPath: "/")], seen: box)
        commands.chooseWorkspace(nil)
        XCTAssertEqual(coordinator.workspaceStore.saved()?.path, url("Trips").standardizedFileURL.path, "/ is refused")

        commands.clearWorkspace(nil)
        XCTAssertFalse(coordinator.workspaceStore.isSet)
        XCTAssertFalse(commands.validateMenuItem(clear))
    }

    // MARK: Launch

    func testIdleLaunchRule() {
        let set = WorkspaceStore.inMemory(SidebarFavorite(path: url("Trips").path))
        let none = WorkspaceStore.inMemory()
        let missing = WorkspaceStore.inMemory(SidebarFavorite(path: url("Gone").path))
        typealias C = WindowCoordinator
        // The deferred call, nothing else to open.
        XCTAssertEqual(C.startWindow(workspace: set, idle: true, settled: true), .browser(url("Trips")))
        // The synchronous call: waits (no Welcome flash, no Workspace window).
        XCTAssertEqual(C.startWindow(workspace: set, idle: true, settled: false), .wait)
        // A Finder open event is pending or a window is open: no Workspace window.
        XCTAssertEqual(C.startWindow(workspace: set, idle: false, settled: true), .wait)
        // No Workspace: Welcome as before, at once.
        XCTAssertEqual(C.startWindow(workspace: none, idle: true, settled: false), .welcome(message: nil))
        XCTAssertEqual(C.startWindow(workspace: none, idle: false, settled: true), .wait)
        // A Workspace that is gone: Welcome with the message.
        XCTAssertEqual(C.startWindow(workspace: missing, idle: true, settled: true),
                       .welcome(message: "Workspace “Gone” isn't available."))
    }

    func testPhotoOpenLaunchNeverResolvesTheWorkspace() {
        // The synchronous call and a launch with an open request in flight
        // must not touch the bookmark: a store whose bookmark read would
        // fail the test.
        var reads = 0
        let probe = WorkspaceStore(load: { reads += 1; return try? JSONEncoder().encode(SidebarFavorite(path: "/nonexistent-ws")) },
                                   save: { _ in }, exists: { _ in XCTFail("no disk check on this path"); return true })
        _ = WindowCoordinator.startWindow(workspace: probe, idle: true, settled: false)
        _ = WindowCoordinator.startWindow(workspace: probe, idle: false, settled: true)
        XCTAssertEqual(reads, 1, "only the one cheap 'is it set' read, and only when idle")
    }
}

//
//  FolderTreeAsyncTests.swift
//  ShrikeUITests
//
//  The sidebar never reads the disk on
//  the main thread. Expanding a folder starts the read off main; the row
//  opens when the children arrive, the selection holds, and selecting a
//  folder by path loads only its ancestor chain, off main.
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class FolderTreeAsyncTests: XCTestCase {

    private var tempRoot: URL!

    private let expansionKeys = ["shrike.browser.tree.expanded", "shrike.browser.tree.expanded.sections"]
    private var savedExpansion: [String: Any] = [:]

    override func setUp() async throws {
        try await super.setUp()
        savedExpansion = [:]
        for key in expansionKeys { savedExpansion[key] = ShrikeDefaults.store.object(forKey: key) }
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shrike-tree-async-\(UUID().uuidString)")
        for path in ["A/one", "A/two", "B"] {
            try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        for key in expansionKeys {
            if let value = savedExpansion[key] { ShrikeDefaults.store.set(value, forKey: key) }
            else { ShrikeDefaults.store.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: tempRoot)
        try await super.tearDown()
    }

    /// Records where the lister ran; every read sleeps `delay`.
    private final class SlowLister: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(path: String, onMain: Bool)] = []
        let delay: TimeInterval
        init(delay: TimeInterval) { self.delay = delay }
        var calls: [(path: String, onMain: Bool)] { lock.withLock { _calls } }
        func list(_ url: URL, _ hidden: Bool) -> [URL] {
            lock.withLock { _calls.append((url.standardizedFileURL.path, Thread.isMainThread)) }
            Thread.sleep(forTimeInterval: delay)
            return FolderTreeDataSource.listSubfolders(of: url, showHidden: hidden)
        }
    }

    /// A sidebar whose only root is the temp folder.
    private func makeTree(lister: SlowLister) -> (FolderTreeViewController, FolderTreeNode) {
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: .none)
        tree.dataSource.lister = { lister.list($0, $1) }
        let section = FolderTreeNode(url: nil, title: "Folders", section: .folders)
        section.childrenLoaded = true
        let root = FolderTreeNode(url: tempRoot, title: "root")
        root.parent = section
        section.children = [root]
        tree.dataSource.roots = [section]
        _ = tree.view
        tree.reload()
        tree.outlineViewForTesting.expandItem(section)
        return (tree, root)
    }

    func testSlowExpandDoesNotBlockTheMainThreadAndOpensWhenChildrenArrive() async throws {
        let lister = SlowLister(delay: 0.4)
        let (tree, root) = makeTree(lister: lister)
        let outline = tree.outlineViewForTesting
        // The root row is selected before the expand.
        let rootRow = outline.row(forItem: root)
        XCTAssertGreaterThanOrEqual(rootRow, 0)
        outline.selectRowIndexes(IndexSet(integer: rootRow), byExtendingSelection: false)
        let rowsBefore = outline.numberOfRows

        let start = Date()
        outline.expandItem(root)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "the expand returns at once; the read runs off main")
        XCTAssertTrue(outline.isItemExpanded(root), "actual expansion intent is open while loading, so the user can collapse it")
        XCTAssertEqual(outline.numberOfRows, rowsBefore)

        await tree.loadTask?.value
        XCTAssertTrue(outline.isItemExpanded(root))
        XCTAssertEqual(root.children.map(\.title), ["A", "B"])
        XCTAssertEqual(outline.numberOfRows, rowsBefore + 2)
        XCTAssertEqual(outline.selectedRow, outline.row(forItem: root), "the selection holds")
        XCTAssertEqual(lister.calls.map(\.onMain), [false], "the disk read ran off the main thread")
    }

    func testSelectByPathLoadsOnlyTheChainOffMain() async throws {
        let lister = SlowLister(delay: 0.05)
        let (tree, _) = makeTree(lister: lister)
        let outline = tree.outlineViewForTesting
        let target = tempRoot.appendingPathComponent("A/two")

        let ancestorNode = await tree.dataSource.node(for: target)
        XCTAssertEqual(ancestorNode?.url?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(lister.calls.map(\.path), [tempRoot.standardizedFileURL.path,
                                                  tempRoot.appendingPathComponent("A").standardizedFileURL.path])
        XCTAssertTrue(lister.calls.allSatisfy { !$0.onMain })
        let readsBeforeSelection = lister.calls.count
        let start = Date()
        tree.select(target)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.03)
        await tree.selectTask?.value

        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
        XCTAssertEqual(selected.url?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(lister.calls.map(\.path), [tempRoot.standardizedFileURL.path,
                                                  tempRoot.appendingPathComponent("A").standardizedFileURL.path])
        XCTAssertTrue(lister.calls.allSatisfy { !$0.onMain })
        XCTAssertEqual(lister.calls.count, readsBeforeSelection, "known Current Folder selection does not traverse ancestors again")
        XCTAssertEqual(tree.dataSource.currentFolder, target.standardizedFileURL)
    }

    /// The outline's data source calls never read the disk.
    func testDataSourceCallsNeverList() {
        let lister = SlowLister(delay: 0)
        let (tree, root) = makeTree(lister: lister)
        XCTAssertEqual(tree.dataSource.numberOfChildren(of: root), 0)
        XCTAssertNil(tree.dataSource.child(0, of: root))
        XCTAssertTrue(tree.dataSource.isExpandable(root))
        XCTAssertTrue(lister.calls.isEmpty)
    }
    private final class PolicyLister: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Int: DispatchSemaphore] = [:]
        private var released = false
        private var recorded: [(URL, Bool)] = []
        private var expired = 0
        var calls: [(URL, Bool)] { lock.withLock { recorded } }
        var timeouts: Int { lock.withLock { expired } }
        func list(_ folder: URL, _ hidden: Bool) -> [URL] {
            let wait = lock.withLock { () -> DispatchSemaphore? in
                let index = recorded.count
                recorded.append((folder.standardizedFileURL, hidden))
                guard !released else { return nil }
                let wait = DispatchSemaphore(value: 0); waits[index] = wait
                return wait
            }
            if let wait, wait.wait(timeout: .now() + 5) != .success {
                lock.withLock { expired += 1 }
            }
            return FolderTreeDataSource.listSubfolders(of: folder, showHidden: hidden)
        }
        func open(_ index: Int) { lock.withLock { waits[index] }?.signal() }
        func openAll() {
            let pending = lock.withLock { () -> [DispatchSemaphore] in
                released = true
                return Array(waits.values)
            }
            for wait in pending { wait.signal() }
        }
    }

    private func waitForPolicy(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard ready() else {
            XCTFail("Owned policy/expansion request did not reach its controlled boundary")
            throw NSError(domain: "FolderTreeAsyncTests.policyBoundary", code: 1)
        }
    }

    func testOverlappingOldOnReadsCannotExpandOrClearNewOnLoadAfterOffOnAndFolderChange() async throws {
        let ownedRoot = URL(fileURLWithPath: tempRoot.path, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: ownedRoot.appendingPathComponent(".Hidden"), withIntermediateDirectories: true)
        // Do not restore any unrelated saved expansions in this owned component.
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let gate = PolicyLister()
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: .none)
        let root = FolderTreeNode(url: ownedRoot, title: "Owned root")
        let other = FolderTreeNode(url: ownedRoot.appendingPathComponent("B", isDirectory: true), title: "Owned B")
        let section = FolderTreeNode(url: nil, title: "Locations", section: .locations)
        section.childrenLoaded = true; section.children = [root, other]
        root.parent = section; other.parent = section
        tree.dataSource.roots = [section]
        tree.dataSource.showHiddenFiles = true
        tree.dataSource.lister = { gate.list($0, $1) }
        _ = tree.view
        let outline = tree.outlineViewForTesting
        outline.expandItem(section)
        tree.select(ownedRoot.appendingPathComponent("A", isDirectory: true)); await tree.selectTask?.value
        XCTAssertTrue(gate.calls.isEmpty, "Current Folder selection does not walk ancestors")
        var tasks: [Task<Void, Never>] = []
        do {
            outline.expandItem(root)
            let oldRoot = try XCTUnwrap(tree.loadTask); tasks.append(oldRoot)
            try await waitForPolicy { gate.calls.count == 1 }
            outline.expandItem(other)
            let oldOther = try XCTUnwrap(tree.loadTask); tasks.append(oldOther)
            try await waitForPolicy { gate.calls.count == 2 }
            XCTAssertTrue(outline.isItemExpanded(root), "the first actual pending expansion is open")
            XCTAssertTrue(outline.isItemExpanded(other), "the second actual pending expansion is open")
            let b = ownedRoot.appendingPathComponent("B", isDirectory: true)
            // Browser intent is already B while the sidebar still selected A.
            tree.refreshHiddenFilesPolicy(false, currentFolder: b)
            tree.refreshHiddenFilesPolicy(true, currentFolder: b)
            await tree.selectTask?.value
            XCTAssertEqual(root.loadGeneration, 2); XCTAssertEqual(other.loadGeneration, 2)
            outline.expandItem(root)
            let current = try XCTUnwrap(tree.loadTask); tasks.append(current)
            try await waitForPolicy { gate.calls.count == 3 }
            gate.open(0); gate.open(1)
            await oldRoot.value; await oldOther.value
            XCTAssertTrue(tree.dataSource.isLoading(root), "old completion must not clear the newer inFlight entry")
            XCTAssertFalse(root.childrenLoaded)
            XCTAssertTrue(outline.isItemExpanded(root), "fresh ON intent stays open while its own read is pending; old completion cannot replace it")
            XCTAssertFalse(outline.isItemExpanded(other), "the older overlapping task is not the last loadTask")
            XCTAssertFalse(other.childrenLoaded)
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url, b)
            gate.open(2); await current.value
            XCTAssertTrue(outline.isItemExpanded(root))
            XCTAssertEqual(Set(root.children.map(\.title)), [".Hidden", "A", "B"])
            XCTAssertFalse(tree.dataSource.isLoading(root))
            XCTAssertFalse(outline.isItemExpanded(other))
            XCTAssertEqual(tree.dataSource.currentFolder, b)
            let stillSelected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(stillSelected.url, b)
            XCTAssertEqual(gate.calls.map { $0.0 }, [ownedRoot.standardizedFileURL, b.standardizedFileURL, ownedRoot.standardizedFileURL])
            XCTAssertEqual(gate.calls.map { $0.1 }, [true, true, true])
            XCTAssertEqual(gate.timeouts, 0)
        } catch {
            gate.openAll()
            for task in tasks { await task.value }
            throw error
        }
        gate.openAll()
        for task in tasks { await task.value }
    }

    func testHiddenPolicyInvalidatesRetainedBaseCacheBeforeItReappears() async throws {
        let ownedRoot = URL(fileURLWithPath: tempRoot.path, isDirectory: true).standardizedFileURL
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let fixture = ownedRoot.appendingPathComponent("RetainedCacheFixture", isDirectory: true)
        for name in ["Visible", ".Hidden"] {
            try FileManager.default.createDirectory(at: fixture.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: .none)
        let source = tree.dataSource
        let folders = try XCTUnwrap(source.roots.first { $0.section == .folders })
        let base = try XCTUnwrap(folders.children.first), baseURL = try XCTUnwrap(base.url)
        let untouched = try XCTUnwrap(folders.children.dropFirst().first)
        // The standard base URL is an identity-only cache key. This injected
        // lister reads ONLY the owned fixture, never Home/Pictures or ancestors.
        source.lister = { _, hidden in FolderTreeDataSource.listSubfolders(of: fixture, showHidden: hidden) }
        var reads: [URL] = []
        source.didListFolder = { reads.append($0) }
        source.showHiddenFiles = true
        await source.loadChildren(base)
        XCTAssertEqual(Set(base.children.map(\.title)), [".Hidden", "Visible"])
        source.setCurrentFolder(baseURL)
        XCTAssertFalse(folders.children.contains { $0 === base }, "the cached base node is privately retained, not in roots")
        _ = tree.view
        let generation = base.loadGeneration, untouchedGeneration = untouched.loadGeneration
        tree.refreshHiddenFilesPolicy(false, currentFolder: baseURL)
        await tree.selectTask?.value
        XCTAssertEqual(base.loadGeneration, generation + 1)
        XCTAssertEqual(untouched.loadGeneration, untouchedGeneration + 1)
        XCTAssertFalse(base.childrenLoaded); XCTAssertTrue(base.children.isEmpty)
        XCTAssertEqual(reads, [baseURL], "invalidating excluded and collapsed base nodes must not list them")
        tree.select(ownedRoot)
        await tree.selectTask?.value
        XCTAssertTrue(folders.children.contains { $0 === base }, "the same retained base object reappears")
        await source.loadChildren(base)
        XCTAssertEqual(base.children.map(\.title), ["Visible"], "the old hidden child cache cannot return")
        XCTAssertEqual(reads, [baseURL, baseURL])
        tree.refreshHiddenFilesPolicy(false, currentFolder: ownedRoot)
        XCTAssertEqual(base.loadGeneration, generation + 1)
        XCTAssertEqual(untouched.loadGeneration, untouchedGeneration + 1)
        XCTAssertTrue(base.childrenLoaded)
        XCTAssertEqual(reads.count, 2, "unchanged policy, including pair-only notifications, keeps caches intact")
        tree.refreshHiddenFilesPolicy(true, currentFolder: ownedRoot)
        await tree.selectTask?.value
        XCTAssertEqual(base.loadGeneration, generation + 2)
        XCTAssertEqual(untouched.loadGeneration, untouchedGeneration + 2)
        XCTAssertFalse(base.childrenLoaded)
        XCTAssertEqual(reads.count, 2)
    }

    func testExpansionCapabilityQueryDoesNotReadOrOpenCollapsedFolder() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let lister = SlowLister(delay: 0)
        let (tree, root) = makeTree(lister: lister)
        let outline = tree.outlineViewForTesting
        let row = outline.row(forItem: root)
        XCTAssertGreaterThanOrEqual(row, 0)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let savedPaths = ShrikeDefaults.store.stringArray(forKey: expansionKeys[0])
        let savedSections = ShrikeDefaults.store.stringArray(forKey: expansionKeys[1])
        for _ in 0..<5 {
            _ = tree.outlineView(outline, shouldExpandItem: root)
            XCTAssertTrue(outline.isExpandable(root))
        }
        // Drain any task incorrectly started by the original capability callback.
        // This is a callback regression, not native OS accessibility automation.
        await tree.loadTask?.value
        XCTAssertNil(tree.loadTask)
        XCTAssertTrue(lister.calls.isEmpty)
        XCTAssertFalse(root.childrenLoaded)
        XCTAssertTrue(root.children.isEmpty)
        XCTAssertFalse(outline.isItemExpanded(root))
        XCTAssertEqual(outline.selectedRow, row)
        XCTAssertEqual(ShrikeDefaults.store.stringArray(forKey: expansionKeys[0]), savedPaths)
        XCTAssertEqual(ShrikeDefaults.store.stringArray(forKey: expansionKeys[1]), savedSections)
    }

    private func hostOutline(_ tree: FolderTreeViewController) throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tree.view
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(tree.outlineViewForTesting))
        return window
    }

    private func expandByKeyboard(_ outline: NSOutlineView, window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
            charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        outline.keyDown(with: event)
    }

    func testActualKeyboardExpansionLoadsZeroCachedChildrenAndDiscoversEmptyLeaf() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let lister = SlowLister(delay: 0)
        let (tree, root) = makeTree(lister: lister)
        let window = try hostOutline(tree); defer { window.close() }
        let outline = tree.outlineViewForTesting
        let row = outline.row(forItem: root)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertTrue(root.children.isEmpty); XCTAssertFalse(root.childrenLoaded)
        try expandByKeyboard(outline, window: window)
        let initial = try XCTUnwrap(tree.loadTask, "actual AppKit WillExpand must start an unloaded row's read")
        XCTAssertTrue(outline.isItemExpanded(root), "real expansion intent is visible while loading")
        await initial.value
        XCTAssertTrue(root.childrenLoaded)
        XCTAssertEqual(root.children.map(\.title), ["A", "B"])
        XCTAssertTrue(outline.isItemExpanded(root))
        XCTAssertEqual(outline.selectedRow, outline.row(forItem: root))
        let empty = try XCTUnwrap(root.children.first { $0.title == "B" })
        let emptyRow = outline.row(forItem: empty)
        XCTAssertGreaterThanOrEqual(emptyRow, 0)
        outline.selectRowIndexes(IndexSet(integer: emptyRow), byExtendingSelection: false)
        try expandByKeyboard(outline, window: window)
        let emptyRead = try XCTUnwrap(tree.loadTask)
        XCTAssertNotEqual(initial, emptyRead, "a real empty-folder expansion gets its own lifecycle callback")
        await emptyRead.value
        XCTAssertTrue(empty.childrenLoaded); XCTAssertTrue(empty.children.isEmpty)
        XCTAssertFalse(tree.dataSource.isExpandable(empty))
        XCTAssertFalse(outline.isItemExpanded(empty), "a loaded empty directory is a leaf")
        XCTAssertFalse(tree.outlineView(outline, shouldExpandItem: empty))
        XCTAssertEqual(tree.loadTask, emptyRead)
        XCTAssertEqual(lister.calls.map(\.path), [tempRoot.standardizedFileURL.path,
                                                 tempRoot.appendingPathComponent("B").standardizedFileURL.path])
        XCTAssertTrue(lister.calls.allSatisfy { !$0.onMain })
    }

    func testCollapseRevokesPendingExpansionAndFreshCachedReopenStillWorks() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let (tree, root) = makeTree(lister: SlowLister(delay: 0))
        let gate = PolicyLister(); tree.dataSource.lister = { gate.list($0, $1) }
        let outline = tree.outlineViewForTesting
        outline.expandItem(root)
        let pending = try XCTUnwrap(tree.loadTask)
        do {
            try await waitForPolicy { gate.calls.count == 1 }
            XCTAssertTrue(outline.isItemExpanded(root))
            outline.collapseItem(root)
            XCTAssertFalse(outline.isItemExpanded(root))
            gate.open(0); await pending.value
            XCTAssertTrue(root.childrenLoaded, "cache completion remains useful after visual intent is revoked")
            XCTAssertFalse(outline.isItemExpanded(root), "completed IO must not reopen a collapsed row")
            outline.expandItem(root)
            XCTAssertTrue(outline.isItemExpanded(root))
            XCTAssertEqual(root.children.map(\.title), ["A", "B"])
            for child in root.children { XCTAssertGreaterThanOrEqual(outline.row(forItem: child), 0) }
            XCTAssertEqual(gate.calls.count, 1, "fresh explicit expansion can reuse the completed cache")
            XCTAssertEqual(gate.timeouts, 0)
        } catch {
            gate.openAll(); await pending.value
            throw error
        }
        gate.openAll()
    }

    func testQuickReopenJoinsPendingReadAndOldCompletionCannotEraseNewIntent() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let (tree, root) = makeTree(lister: SlowLister(delay: 0))
        let gate = PolicyLister(); tree.dataSource.lister = { gate.list($0, $1) }
        let outline = tree.outlineViewForTesting
        let row = outline.row(forItem: root)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.expandItem(root)
        let old = try XCTUnwrap(tree.loadTask)
        var fresh: Task<Void, Never>?
        do {
            try await waitForPolicy { gate.calls.count == 1 }
            outline.collapseItem(root)
            XCTAssertFalse(outline.isItemExpanded(root))
            outline.expandItem(root)
            fresh = try XCTUnwrap(tree.loadTask, "a new intent must join rather than drop the pending read")
            XCTAssertNotEqual(fresh, old)
            XCTAssertTrue(outline.isItemExpanded(root))
            XCTAssertTrue(tree.dataSource.isLoading(root))
            gate.open(0); await old.value; await fresh?.value
            XCTAssertTrue(outline.isItemExpanded(root))
            XCTAssertTrue(root.childrenLoaded)
            XCTAssertEqual(root.children.map(\.title), ["A", "B"])
            for child in root.children { XCTAssertGreaterThanOrEqual(outline.row(forItem: child), 0) }
            XCTAssertEqual(outline.selectedRow, outline.row(forItem: root))
            XCTAssertEqual(gate.calls.count, 1, "both real intents share one underlying enumeration")
            XCTAssertFalse(tree.dataSource.isLoading(root))
            XCTAssertEqual(gate.timeouts, 0)
        } catch {
            gate.openAll(); await old.value; await fresh?.value
            throw error
        }
        gate.openAll()
    }

    func testQueuedExpandThenCollapseStartsNoReadAndCannotEraseFreshQueuedIntent() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let lister = SlowLister(delay: 0)
        let (tree, root) = makeTree(lister: lister)
        let outline = tree.outlineViewForTesting
        outline.expandItem(root)
        let revoked = try XCTUnwrap(tree.loadTask)
        XCTAssertTrue(outline.isItemExpanded(root))
        outline.collapseItem(root)
        // No actor yield occurs between the actual expansion and collapse.
        await revoked.value
        XCTAssertTrue(lister.calls.isEmpty, "revoked queued intent must not start filesystem work")
        XCTAssertFalse(root.childrenLoaded); XCTAssertTrue(root.children.isEmpty)
        XCTAssertFalse(tree.dataSource.isLoading(root))
        XCTAssertFalse(outline.isItemExpanded(root))

        outline.expandItem(root)
        let old = try XCTUnwrap(tree.loadTask)
        outline.collapseItem(root)
        outline.expandItem(root)
        let fresh = try XCTUnwrap(tree.loadTask)
        XCTAssertNotEqual(old, fresh)
        // The stale task's early-exit defer must not remove this newer intent.
        await old.value; await fresh.value
        XCTAssertEqual(lister.calls.count, 1)
        XCTAssertTrue(outline.isItemExpanded(root))
        XCTAssertEqual(root.children.map(\.title), ["A", "B"])
        for child in root.children { XCTAssertGreaterThanOrEqual(outline.row(forItem: child), 0) }
        XCTAssertTrue(lister.calls.allSatisfy { !$0.onMain })
    }

    func testQueuedExpansionInvalidatedByPolicyStartsNoRead() async throws {
        for key in expansionKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        let lister = SlowLister(delay: 0)
        let (tree, root) = makeTree(lister: lister)
        let outline = tree.outlineViewForTesting
        let section = try XCTUnwrap(root.parent)
        let other = FolderTreeNode(url: tempRoot.appendingPathComponent("B", isDirectory: true).standardizedFileURL,
                                   title: "Second owned queued folder")
        other.parent = section; section.children.append(other)
        tree.reload(); outline.expandItem(section)
        XCTAssertGreaterThanOrEqual(outline.row(forItem: other), 0)
        let initialPolicy = tree.dataSource.showHiddenFiles, generation = root.loadGeneration
        let otherGeneration = other.loadGeneration
        outline.expandItem(root)
        let first = try XCTUnwrap(tree.loadTask)
        outline.expandItem(other)
        let last = try XCTUnwrap(tree.loadTask)
        XCTAssertNotEqual(first, last)
        XCTAssertTrue(outline.isItemExpanded(root)); XCTAssertTrue(outline.isItemExpanded(other))
        // Both real row expansions queue before any actor yield. Cancelling only
        // the last loadTask must not let the earlier queued intent start IO.
        tree.refreshHiddenFilesPolicy(!initialPolicy, currentFolder: nil)
        XCTAssertFalse(first.isCancelled)
        XCTAssertTrue(last.isCancelled)
        await first.value; await last.value
        XCTAssertEqual(tree.dataSource.showHiddenFiles, !initialPolicy)
        XCTAssertEqual(root.loadGeneration, generation + 1)
        XCTAssertEqual(other.loadGeneration, otherGeneration + 1)
        XCTAssertTrue(lister.calls.isEmpty, "obsolete policy must not initiate either old-policy read")
        for node in [root, other] {
            XCTAssertFalse(node.childrenLoaded); XCTAssertTrue(node.children.isEmpty)
            XCTAssertFalse(tree.dataSource.isLoading(node))
            XCTAssertFalse(outline.isItemExpanded(node), "unfinished expansion is cancelled by the policy change")
        }
    }

}

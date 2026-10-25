import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

/// Loaded-row viewport geometry, not a claim of physical native scroll input.
@MainActor
final class FolderTreeViewportTests: XCTestCase {
    private var ownedRoot: URL!
    private var saved: [String: Any] = [:]
    private let keys = ["shrike.browser.tree.expanded", "shrike.browser.tree.expanded.sections"]

    override func setUp() async throws {
        for key in keys { saved[key] = ShrikeDefaults.store.object(forKey: key); ShrikeDefaults.store.removeObject(forKey: key) }
        ownedRoot = TestScratch.directory.appendingPathComponent("shrike-viewport-\(UUID())", isDirectory: true).standardizedFileURL
        for name in [".HiddenOne", ".HiddenTwo", "AOpen", "Closed/DoNotRead", "B"]
            + (0..<60).map({ String(format: "Row%02d", $0) })
            + (0..<20).map({ String(format: "AOpen/Child%02d", $0) }) {
            try FileManager.default.createDirectory(at: ownedRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        for key in keys {
            if let value = saved[key] { ShrikeDefaults.store.set(value, forKey: key) }
            else { ShrikeDefaults.store.removeObject(forKey: key) }
        }
        try? FileManager.default.removeItem(at: ownedRoot)
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        _ = try XCTUnwrap(condition() ? true : nil, "Owned sidebar callback reaches its controlled boundary")
    }

    private func drain(_ tree: FolderTreeViewController) async {
        while let task = tree.loadTask {
            await task.value
            if tree.loadTask == task { return }
        }
    }

    private func root(_ tree: FolderTreeViewController) throws -> FolderTreeNode {
        try XCTUnwrap(tree.dataSource.locationsSection?.children.first { $0.kind == .volume })
    }

    private func node(_ title: String, tree: FolderTreeViewController) throws -> FolderTreeNode {
        try XCTUnwrap(try root(tree).children.first { $0.title == title })
    }

    private func fixture(duplicateFavorite: Bool = false) async throws -> (FolderTreeViewController, NSWindow) {
        // The owned folder is the one Locations root (an injected volume), so
        // the reveal lists only the fixture, never Home or "/".
        let volume = SidebarVolume(url: ownedRoot, name: "Fixture", kind: .external, isEjectable: false)
        let favorites: FavoritesStore = duplicateFavorite
            ? .inMemory([SidebarFavorite(path: ownedRoot.appendingPathComponent("Row25").path)])
            : .inMemory()
        let tree = FolderTreeViewController(favorites: favorites, volumes: VolumeSource(list: { [volume] }, eject: { _ in }))
        tree.dataSource.showHiddenFiles = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let outer = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        window.contentView = outer
        let view = tree.view
        view.translatesAutoresizingMaskIntoConstraints = false; outer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: outer.leadingAnchor), view.topAnchor.constraint(equalTo: outer.topAnchor),
            view.widthAnchor.constraint(equalToConstant: 300), view.heightAnchor.constraint(equalToConstant: 240),
        ])
        tree.select(ownedRoot); await tree.selectTask?.value
        tree.outlineViewForTesting.expandItem(try root(tree)); await drain(tree)
        tree.outlineViewForTesting.expandItem(try node("AOpen", tree: tree)); await drain(tree)
        outer.layoutSubtreeIfNeeded()
        return (tree, window)
    }

    private func position(_ title: String, tree: FolderTreeViewController, offset: CGFloat = 5) throws {
        let outline = tree.outlineViewForTesting
        let row = outline.row(forItem: try node(title, tree: tree))
        XCTAssertGreaterThanOrEqual(row, 0)
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: outline.rect(ofRow: row).minY + offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func top(_ tree: FolderTreeViewController) throws -> (FolderTreeNode, CGFloat) {
        let outline = tree.outlineViewForTesting
        let row = outline.rows(in: outline.visibleRect).location
        let node = try XCTUnwrap(outline.item(atRow: row) as? FolderTreeNode)
        return (node, outline.rect(ofRow: row).minY - outline.visibleRect.minY)
    }

    private func assertTop(_ title: String, offset: CGFloat, tree: FolderTreeViewController,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let visible = try top(tree)
        XCTAssertEqual(visible.0.title, title, file: file, line: line)
        XCTAssertEqual(visible.1, offset, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(visible.0.parent?.url?.standardizedFileURL, ownedRoot, file: file, line: line)
    }

    func testHiddenRowsAboveViewportPreserveLoadedIdentityOffsetAndDuplicateSection() async throws {
        let (tree, window) = try await fixture(duplicateFavorite: true); defer { window.close() }
        let outline = tree.outlineViewForTesting
        var reads: [URL] = []
        tree.dataSource.didListFolder = { reads.append($0.standardizedFileURL) }
        try position("Row25", tree: tree)
        let initial = try top(tree)
        XCTAssertEqual(initial.0.title, "Row25")
        let oldY = outline.visibleRect.minY
        for hidden in [true, false] {
            tree.refreshHiddenFilesPolicy(hidden, currentFolder: ownedRoot)
            await tree.selectTask?.value; await drain(tree)
            try assertTop("Row25", offset: initial.1, tree: tree)
            XCTAssertEqual(try root(tree).children.contains { $0.title == ".HiddenOne" }, hidden)
            XCTAssertTrue(outline.isItemExpanded(try root(tree)))
            XCTAssertTrue(outline.isItemExpanded(try node("AOpen", tree: tree)))
            let closed = try node("Closed", tree: tree)
            XCTAssertFalse(outline.isItemExpanded(closed)); XCTAssertFalse(closed.childrenLoaded)
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url?.standardizedFileURL, ownedRoot)
            if hidden { XCTAssertGreaterThan(outline.visibleRect.minY, oldY, "Two inserted rows must change y while preserving visible identity") }
            // Real same-folder first paint: the reveal runs again on the same row.
            tree.select(ownedRoot, preservingViewportOnReload: true)
            await tree.selectTask?.value; await drain(tree)
            try assertTop("Row25", offset: initial.1, tree: tree)
        }
        XCTAssertTrue(Set(reads).isSubset(of: [ownedRoot, ownedRoot.appendingPathComponent("AOpen")]))
    }

    func testRemovedHiddenAnchorUsesAdjacentLoadedSiblingAndClampsShortTree() async throws {
        let (tree, window) = try await fixture(); defer { window.close() }
        tree.refreshHiddenFilesPolicy(true, currentFolder: ownedRoot)
        await tree.selectTask?.value; await drain(tree)
        try position(".HiddenOne", tree: tree)
        let offset = try top(tree).1
        tree.refreshHiddenFilesPolicy(false, currentFolder: ownedRoot)
        await tree.selectTask?.value; await drain(tree)
        try assertTop("AOpen", offset: offset, tree: tree)
        // If all former neighbors disappear, use the loaded ancestor and clamp.
        tree.dataSource.lister = { _, _ in [] }
        tree.refreshHiddenFilesPolicy(true, currentFolder: ownedRoot)
        await tree.selectTask?.value; await drain(tree)
        let outline = tree.outlineViewForTesting
        XCTAssertEqual(outline.visibleRect.minY, 0, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(outline.row(forItem: try root(tree)), 0)
    }

    private final class ChildGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var open = false
        private var entered = false
        private var timedOut = false
        var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return entered }
        var didTimeOut: Bool { condition.lock(); defer { condition.unlock() }; return timedOut }
        func hold() {
            condition.lock(); defer { condition.unlock() }
            entered = true
            let deadline = Date().addingTimeInterval(5)
            while !open { if !condition.wait(until: deadline) { timedOut = true; break } }
        }
        func release() { condition.lock(); open = true; condition.broadcast(); condition.unlock() }
    }

    func testLateChildrenPreserveNewerScrollInsteadOfReplayingPolicyAnchor() async throws {
        try await lateChildren(navigate: false)
    }

    func testLateChildrenCannotMoveNewFolderAfterNavigation() async throws {
        try await lateChildren(navigate: true)
    }

    private func lateChildren(navigate: Bool) async throws {
        let (tree, window) = try await fixture(); defer { window.close() }
        let gate = ChildGate(); defer { gate.release() }
        let branch = ownedRoot.appendingPathComponent("AOpen")
        tree.dataSource.lister = { folder, hidden in
            if folder.standardizedFileURL == branch, hidden { gate.hold() }
            return FolderTreeDataSource.listSubfolders(of: folder, showHidden: hidden)
        }
        try position("Row25", tree: tree)
        tree.refreshHiddenFilesPolicy(true, currentFolder: ownedRoot)
        await tree.selectTask?.value
        try await wait { gate.isWaiting }
        let pending = try XCTUnwrap(tree.loadTask)
        if navigate {
            let other = ownedRoot.appendingPathComponent("B")
            tree.select(other); await tree.selectTask?.value
            let outline = tree.outlineViewForTesting
            // Where the new folder's row sits in the visible area.
            func rowOffset() -> CGFloat { outline.rect(ofRow: outline.selectedRow).minY - outline.visibleRect.minY }
            let before = rowOffset()
            gate.release(); await pending.value
            XCTAssertEqual(tree.dataSource.currentFolder, other)
            XCTAssertEqual(rowOffset(), before, accuracy: 0.5, "late rows above must not move the new folder away")
            XCTAssertTrue(outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)))
            let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
            XCTAssertEqual(selected.url?.standardizedFileURL, other.standardizedFileURL)
        } else {
            try position("Row40", tree: tree, offset: 7)
            let latest = try top(tree)
            gate.release(); await pending.value
            try assertTop("Row40", offset: latest.1, tree: tree)
            XCTAssertNotEqual(latest.0.title, "Row25")
        }
        XCTAssertFalse(gate.didTimeOut)
    }
}

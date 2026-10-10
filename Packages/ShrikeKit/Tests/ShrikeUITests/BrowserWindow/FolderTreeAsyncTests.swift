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

@MainActor
final class FolderTreeAsyncTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("shrike-tree-async-\(UUID().uuidString)")
        for path in ["A/one", "A/two", "B"] {
            try FileManager.default.createDirectory(at: tempRoot.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
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
        XCTAssertFalse(outline.isItemExpanded(root), "the row opens only when the children arrive")
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

        let start = Date()
        tree.select(target)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.03)
        await tree.selectTask?.value

        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderTreeNode)
        XCTAssertEqual(selected.url?.standardizedFileURL, target.standardizedFileURL)
        XCTAssertEqual(lister.calls.map(\.path), [tempRoot.standardizedFileURL.path,
                                                  tempRoot.appendingPathComponent("A").standardizedFileURL.path])
        XCTAssertTrue(lister.calls.allSatisfy { !$0.onMain })
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
}

//
//  SidebarDeepFolders028Tests.swift
//  ShrikeUITests
//
//  Spec 28 §1 (L-1): the sidebar indent shrinks with depth so a deep
//  folder's name keeps room; tooltips and the path for VoiceOver.
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class SidebarDeepFolders028Tests: XCTestCase {

    // MARK: Pure indent rule

    func testIndentTableOfTheSpecAt200() {
        // Spec 28 §1's rule with the measured fixed width (65 pt, not the
        // guessed 52): at 200 pt depth ≤ 2 gives 16, 3 gives 15, 5 gives 9,
        // 7 gives 6, 10 gives 4, 19 gives 2 (the floor; spec said 6).
        XCTAssertEqual(SidebarIndent.fixed, 65)
        XCTAssertEqual(SidebarIndent.minimumIndent, 2)
        let expected: [Int: CGFloat] = [0: 16, 1: 16, 2: 16, 3: 15, 5: 9, 7: 6, 10: 4, 19: 2, 40: 2]
        for (depth, indent) in expected {
            XCTAssertEqual(SidebarIndent.indent(width: 200, depth: depth, shallow: 16), indent, "depth \(depth)")
        }
        // At 360 pt the shallow indent holds to depth 6 and beyond.
        XCTAssertEqual(SidebarIndent.indent(width: 360, depth: 6, shallow: 16), 16)
        // The shallow value is the icon-size one (17 at Medium), never more.
        XCTAssertEqual(SidebarIndent.indent(width: 400, depth: 2, shallow: 17), 17)
    }

    func testToolTipText() {
        XCTAssertNil(SidebarRowCell.toolTip(name: "Bravo", path: "~/Bravo", isCut: false, isSelected: false))
        XCTAssertEqual(SidebarRowCell.toolTip(name: "Bravo", path: "~/Bravo", isCut: true, isSelected: false), "Bravo")
        XCTAssertEqual(SidebarRowCell.toolTip(name: "Bravo", path: "~/Bravo", isCut: false, isSelected: true),
                       "Bravo\n~/Bravo")
    }

    // MARK: In a window

    private var root: URL!
    private let names = ["Alpha-level-one", "Bravo-level-two", "Charlie-level-three", "Delta-level-four",
                         "Echo-level-five", "Foxtrot-level-six", "Golf-level-seven", "Hotel-level-eight",
                         "India-level-nine", "Juliet-level-ten"]

    override func setUp() async throws {
        try await super.setUp()
        root = TestScratch.directory.appendingPathComponent("deep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private var deepest: URL {
        names.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    private final class Delegate: FolderTreeDelegate {
        func folderTreeDidSelect(_ selection: FolderSelection) {}
        func folderTreeRequestReveal(_ url: URL) {}
        func folderTreeRequestNewFolder(parent: URL) {}
        func folderTreeRequestAddBookmark(_ url: URL) {}
        func folderTreeToast(_ message: String) {}
    }

    private func makeTree(width: CGFloat) -> (FolderTreeViewController, NSWindow, Delegate) {
        let volume = SidebarVolume(url: root, name: "Fixture", kind: .external, isEjectable: false)
        let store = FavoritesStore.inMemory([])
        let tree = FolderTreeViewController(favorites: store, volumes: VolumeSource(list: { [volume] }, eject: { _ in }))
        let delegate = Delegate()
        tree.delegate = delegate
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = tree
        window.setContentSize(NSSize(width: width, height: 700))
        return (tree, window, delegate)
    }

    /// Per folder row: name, level, the room its name has (label start to
    /// the visible cell end) and the `fixed` that room implies.
    private func rooms(_ tree: FolderTreeViewController) -> [(name: String, level: Int, room: CGFloat, fixed: CGFloat)] {
        let outline = tree.outlineViewForTesting
        var out: [(String, Int, CGFloat, CGFloat)] = []
        for row in 0..<outline.numberOfRows {
            guard let cell = tree.cellForTesting(row: row), let label = cell.textField,
                  names.contains(cell.node.title) else { continue }
            let labelX = outline.convert(label.bounds, from: label).minX
            let cellEnd = min(outline.convert(cell.bounds, from: cell).maxX, outline.visibleRect.maxX)
            let room = cellEnd - labelX
            let depth = CGFloat(outline.level(forRow: row) - 1)
            let fixed = outline.visibleRect.width - room - depth * outline.indentationPerLevel
            out.append((cell.node.title, outline.level(forRow: row), room, fixed))
        }
        return out
    }

    func testTenLevelsAt200KeepEveryNameReadable() async throws {
        let (tree, window, _) = makeTree(width: 200); defer { window.close() }
        _ = tree.view
        tree.outlineViewForTesting.rowSizeStyle = .medium
        tree.outlineViewForTesting.reloadData()
        tree.select(deepest); await tree.selectTask?.value
        await tree.loadTask?.value
        window.layoutIfNeeded()
        tree.view.layoutSubtreeIfNeeded()
        let outline = tree.outlineViewForTesting
        XCTAssertEqual(tree.visibleDepth, 10, "the volume row is depth 0")
        let measured = rooms(tree)
        XCTAssertEqual(measured.count, names.count)
        for row in measured {
            print("L-1 style \(outline.effectiveRowSizeStyle.rawValue) indent \(outline.indentationPerLevel) level \(row.level) \(row.name) room \(row.room) fixed \(row.fixed)")
            // At least 8 characters of a 13 pt name.
            XCTAssertGreaterThanOrEqual(row.room, 52, "\(row.name) at level \(row.level)")
        }
        let selected = try XCTUnwrap(tree.cellForTesting(row: outline.selectedRow))
        XCTAssertEqual(selected.node.title, names.last)
        XCTAssertEqual(selected.toolTip, names.last! + "\n" + UserFacingPath.string(deepest))
        XCTAssertEqual(selected.accessibilityHelp(), UserFacingPath.string(deepest))
    }

    /// A folder ~19 levels below the disk (as a real temp folder is): the
    /// selected deepest row still shows most of its name at 200 pt.
    func testNineteenLevelsAt200ShowTheSelectedName() async throws {
        var deep = deepest
        for i in 11...19 { deep = deep.appendingPathComponent("Level-\(i)-name", isDirectory: true) }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let (tree, window, _) = makeTree(width: 200); defer { window.close() }
        _ = tree.view
        tree.outlineViewForTesting.rowSizeStyle = .medium
        tree.outlineViewForTesting.reloadData()
        tree.select(deep); await tree.selectTask?.value
        await tree.loadTask?.value
        tree.view.layoutSubtreeIfNeeded()
        let outline = tree.outlineViewForTesting
        XCTAssertEqual(tree.visibleDepth, 19)
        let cell = try XCTUnwrap(tree.cellForTesting(row: outline.selectedRow))
        let label = try XCTUnwrap(cell.textField)
        let labelX = outline.convert(label.bounds, from: label).minX
        let room = min(outline.convert(cell.bounds, from: cell).maxX, outline.visibleRect.maxX) - labelX
        XCTAssertGreaterThanOrEqual(room, 60, "the selected deepest row is never an empty bar")
    }

    func testCollapsingBringsTheShallowIndentBack() async throws {
        let (tree, window, _) = makeTree(width: 200); defer { window.close() }
        _ = tree.view
        tree.select(deepest); await tree.selectTask?.value
        await tree.loadTask?.value
        tree.view.layoutSubtreeIfNeeded()
        let outline = tree.outlineViewForTesting
        XCTAssertLessThan(outline.indentationPerLevel, 10)
        let alpha = try XCTUnwrap((0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? FolderTreeNode }
            .first { $0.title == names[1] })
        outline.collapseItem(alpha)
        print("L-1 collapse: depth \(tree.visibleDepth) width \(outline.visibleRect.width) rows \(outline.numberOfRows) expanded \(outline.isItemExpanded(alpha))")
        // The test window may show a legacy scroller (clip 183 pt, not 200):
        // the indent follows the rule for the clip width and depth 2.
        let shallow = FolderTreeViewController.indentation(forIconSide: SidebarRowCell.iconSide(for: outline.effectiveRowSizeStyle))
        XCTAssertEqual(tree.visibleDepth, 2)
        XCTAssertEqual(outline.indentationPerLevel,
                       SidebarIndent.indent(width: outline.visibleRect.width, depth: 2, shallow: shallow))
        XCTAssertGreaterThanOrEqual(outline.indentationPerLevel, 14)
        // Wider sidebar, deep tree open again: the shallow indent at 360 pt.
        outline.expandItem(alpha, expandChildren: true)
        window.setContentSize(NSSize(width: 360, height: 700))
        tree.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(tree.visibleDepth, 10)
        XCTAssertEqual(outline.indentationPerLevel,
                       SidebarIndent.indent(width: outline.visibleRect.width, depth: 10, shallow: shallow))
        XCTAssertGreaterThanOrEqual(outline.indentationPerLevel, 13, "360 pt: room for a wide indent again")
    }
}

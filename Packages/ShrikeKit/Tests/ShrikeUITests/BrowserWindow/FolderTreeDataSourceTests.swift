//
//  FolderTreeDataSourceTests.swift
//  ShrikeUITests
//
//  Covers the lazy-enumeration data source that backs the folder tree. We
//  build a synthetic directory hierarchy in a temp folder and exercise
//  `loadChildren`, `numberOfChildren`, `isExpandable`, and the hidden-files
//  toggle.
//

import XCTest
import Foundation
@testable import ShrikeUI

@MainActor
final class FolderTreeDataSourceTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        let fm = FileManager.default
        let base = TestScratch.directory
            .appendingPathComponent("shrike-tree-test-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base

        // Visible folder A
        try fm.createDirectory(
            at: base.appendingPathComponent("AlphaFolder"),
            withIntermediateDirectories: true
        )
        // Visible folder B (nested)
        try fm.createDirectory(
            at: base.appendingPathComponent("BetaFolder/inner"),
            withIntermediateDirectories: true
        )
        // Hidden folder
        try fm.createDirectory(
            at: base.appendingPathComponent(".hidden"),
            withIntermediateDirectories: true
        )
        // Regular file (should be ignored — we only list folders)
        let filePath = base.appendingPathComponent("note.txt")
        try Data().write(to: filePath)
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Roots

    // Favorites (while there is one), then Locations: Home first, then
    // the volumes.
    func testRoots_SectionOrderAndEmptySectionsHidden() {
        let ds = FolderTreeDataSource()
        XCTAssertEqual(ds.roots.map(\.section), [.locations], "no Favorites section while empty")
        XCTAssertEqual(ds.roots.first?.children.first?.title, "Home")
        let fav = SidebarFavoriteRow(url: tempRoot, isMissing: false)
        let sd = SidebarVolume(url: URL(fileURLWithPath: "/Volumes/SD"), name: "SD", kind: .removable, isEjectable: true)
        ds.rebuildRoots(favorites: [fav], volumes: [sd])
        XCTAssertEqual(ds.roots.map(\.section), [.favorites, .locations])
        XCTAssertEqual(ds.roots.map(\.title), ["Favorites", "Locations"])
        XCTAssertEqual(ds.locationsSection?.children.map(\.title), ["Home", "SD"])
    }

    // Desktop, Documents, Pictures and Downloads are inside Home, not roots.
    func testLocations_HomeIsTheOnlyFolderRootBesidesVolumes() {
        let ds = FolderTreeDataSource()
        let locations = ds.locationsSection!
        XCTAssertEqual(locations.children.map(\.title), ["Home"])
        XCTAssertEqual(locations.children.first?.symbolName, "house")
        XCTAssertTrue(locations.children.first?.isHome == true)
    }

    // A rebuild (⌘D, a disk mounted) keeps the nodes of roots that stay.
    func testRebuild_KeepsLocationRootNodes() {
        let ds = FolderTreeDataSource()
        let sd = SidebarVolume(url: URL(fileURLWithPath: "/Volumes/SD"), name: "SD", kind: .removable, isEjectable: true)
        ds.rebuildRoots(favorites: [], volumes: [sd])
        let before = ds.locationsSection!.children
        ds.rebuildRoots(favorites: [.init(url: tempRoot, isMissing: false)], volumes: [sd])
        XCTAssertTrue(zip(before, ds.locationsSection!.children).allSatisfy { $0 === $1 })
    }

    // MARK: - Lazy load

    func testLoadChildren_OnlyFolders() async {
        let ds = FolderTreeDataSource()
        let node = FolderTreeNode(url: tempRoot, title: "root")
        let kids = await ds.loadChildren(node)
        let titles = Set(kids.map(\.title))
        XCTAssertTrue(titles.contains("AlphaFolder"))
        XCTAssertTrue(titles.contains("BetaFolder"))
        // File must be filtered out.
        XCTAssertFalse(titles.contains("note.txt"))
    }

    func testLoadChildren_HidesDotFilesByDefault() async {
        let ds = FolderTreeDataSource()
        ds.showHiddenFiles = false
        let node = FolderTreeNode(url: tempRoot, title: "root")
        let kids = await ds.loadChildren(node)
        XCTAssertFalse(kids.contains { $0.title == ".hidden" })
    }

    func testLoadChildren_ShowsDotFilesWhenEnabled() async {
        let ds = FolderTreeDataSource()
        ds.showHiddenFiles = true
        let node = FolderTreeNode(url: tempRoot, title: "root")
        let kids = await ds.loadChildren(node)
        XCTAssertTrue(kids.contains { $0.title == ".hidden" })
    }

    func testLoadChildren_IsCached() async {
        let ds = FolderTreeDataSource()
        let node = FolderTreeNode(url: tempRoot, title: "root")
        XCTAssertFalse(node.childrenLoaded)
        _ = await ds.loadChildren(node)
        XCTAssertTrue(node.childrenLoaded)
        // A second call returns the cached array without re-reading.
        let first = await ds.loadChildren(node)
        let second = await ds.loadChildren(node)
        XCTAssertEqual(first.map(\.title), second.map(\.title))
    }

    func testInvalidate_ResetsLoadedFlag() async {
        let ds = FolderTreeDataSource()
        let node = FolderTreeNode(url: tempRoot, title: "root")
        _ = await ds.loadChildren(node)
        XCTAssertTrue(node.childrenLoaded)
        ds.invalidate(node)
        XCTAssertFalse(node.childrenLoaded)
        XCTAssertTrue(node.children.isEmpty)
    }

    // MARK: - isExpandable

    func testIsExpandable_UnloadedFolder_TreatedAsExpandable() {
        let ds = FolderTreeDataSource()
        let node = FolderTreeNode(url: tempRoot, title: "root")
        XCTAssertTrue(ds.isExpandable(node))
    }

    func testIsExpandable_FalseForFiles() {
        let ds = FolderTreeDataSource()
        let fileNode = FolderTreeNode(
            url: tempRoot.appendingPathComponent("note.txt"),
            title: "note.txt",
            isFolder: false
        )
        XCTAssertFalse(ds.isExpandable(fileNode))
    }
}

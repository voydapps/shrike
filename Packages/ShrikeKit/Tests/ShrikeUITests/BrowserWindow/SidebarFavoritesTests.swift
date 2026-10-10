//
//  SidebarFavoritesTests.swift
//  ShrikeUITests
//
//  Favorites and
//  Locations in the Browser sidebar. Temp folders and an injected volume
//  list only: nothing here reads the user's folders or ejects a disk.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class SidebarFavoritesTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-fav-\(UUID().uuidString)", isDirectory: true)
        for name in ["Client", "Italy", "Seed1", "Seed2"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
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

    private final class Record: @unchecked Sendable {
        let lock = NSLock()
        var ejected: [URL] = []
        var onMain: [Bool] = []
    }

    // First launch seeds only the seed folders that exist, by path (no
    // bookmark, no read); later loads keep the saved list.
    func testSeedAddRemoveMoveAndPersist() {
        let backing = FavoritesStore.inMemory(nil, seed: [url("Seed1"), url("Gone"), url("Seed2")])
        XCTAssertEqual(backing.favorites().map(\.url.lastPathComponent), ["Seed1", "Seed2"])
        XCTAssertTrue(backing.favorites().allSatisfy { $0.bookmark.isEmpty })

        XCTAssertTrue(backing.add(url("Client")))
        XCTAssertFalse(backing.add(url("Client")), "no duplicates")
        backing.move(from: 2, to: 0)
        XCTAssertEqual(backing.favorites().map(\.url.lastPathComponent), ["Client", "Seed1", "Seed2"])
        backing.remove(at: 1)
        XCTAssertEqual(backing.favorites().map(\.url.lastPathComponent), ["Client", "Seed2"])

        // The list survives a relaunch (same stored data).
        var stored: Data?
        let first = FavoritesStore(load: { stored }, save: { stored = $0 }, seed: { [] })
        first.add(url("Italy"))
        let relaunched = FavoritesStore(load: { stored }, save: { stored = $0 }, seed: { [self.url("Seed1")] })
        XCTAssertEqual(relaunched.favorites().map(\.url.lastPathComponent), ["Italy"])
        XCTAssertFalse(relaunched.favorites()[0].bookmark.isEmpty, "an added folder keeps a bookmark")
    }

    func testMissingFavoriteIsDimmedAndToastsInsteadOfNavigating() throws {
        let store = FavoritesStore.inMemory([SidebarFavorite(path: url("Client").path)])
        try FileManager.default.removeItem(at: url("Client"))
        XCTAssertEqual(store.rows().map(\.isMissing), [true])

        let tree = FolderTreeViewController(favorites: store, volumes: .none)
        let delegate = Delegate()
        tree.delegate = delegate
        _ = tree.view
        let outline = tree.outlineViewForTesting
        let node = try XCTUnwrap(tree.dataSource.favoritesSection?.children.first)
        XCTAssertTrue(node.isMissing)
        let row = outline.row(forItem: node)
        let cell = try XCTUnwrap(tree.cellForTesting(row: row))
        XCTAssertEqual(cell.alphaValue, 0.5, accuracy: 0.001)
        XCTAssertEqual(cell.toolTip, "Not available")
        XCTAssertFalse(tree.outlineView(outline, shouldSelectItem: node))
        XCTAssertEqual(delegate.toasts, ["“Client” is not available. The disk may be disconnected."])
        XCTAssertTrue(delegate.selected.isEmpty)
    }

    func testDeleteKeyAndDropsEditFavorites() throws {
        let store = FavoritesStore.inMemory([SidebarFavorite(path: url("Client").path),
                                             SidebarFavorite(path: url("Italy").path)])
        let tree = FolderTreeViewController(favorites: store, volumes: .none)
        _ = tree.view
        let outline = tree.outlineViewForTesting
        let section = try XCTUnwrap(tree.dataSource.favoritesSection)
        XCTAssertFalse(tree.dataSource.isExpandable(section.children[0]), "favorites are leaves")

        // A drop onto a favorite row lands before it; onto the header with
        // no index lands at the end; outside Favorites is refused.
        XCTAssertEqual(tree.favoritesDropTarget(item: section.children[1], childIndex: -1, isReorder: false), 1)
        XCTAssertEqual(tree.favoritesDropTarget(item: section, childIndex: -1, isReorder: true), 2)
        let folders = try XCTUnwrap(tree.dataSource.roots.last)
        XCTAssertNil(tree.favoritesDropTarget(item: folders.children.first, childIndex: -1, isReorder: false))

        tree.addFavorite(url("Seed1"), at: 1)
        XCTAssertEqual(store.favorites().map(\.url.lastPathComponent), ["Client", "Seed1", "Italy"])
        tree.moveFavorite(from: 0, to: 3)
        XCTAssertEqual(store.favorites().map(\.url.lastPathComponent), ["Seed1", "Italy", "Client"])

        // ⌫ on a selected favorite removes it; on a folder row it does not.
        let italy = try XCTUnwrap(tree.dataSource.favoritesSection?.children[1])
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: italy)), byExtendingSelection: false)
        XCTAssertTrue(tree.deleteSelectedFavorite())
        XCTAssertEqual(store.favorites().map(\.url.lastPathComponent), ["Seed1", "Client"])
        let home = try XCTUnwrap(tree.dataSource.roots.last?.children.first)
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: home)), byExtendingSelection: false)
        XCTAssertFalse(tree.deleteSelectedFavorite())
    }

    // (headless): volumes list removable first with the
    // symbols; eject runs off the main thread; a failure toasts.
    func testLocationsOrderSymbolsAndEject() async throws {
        let record = Record()
        let volumes = VolumeSource(
            list: {
                SidebarVolume.ordered([
                    SidebarVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", kind: .internal, isEjectable: false),
                    SidebarVolume(url: URL(fileURLWithPath: "/Volumes/Backup"), name: "Backup", kind: .external, isEjectable: true),
                    SidebarVolume(url: URL(fileURLWithPath: "/Volumes/SD CARD"), name: "SD CARD", kind: .removable, isEjectable: true),
                ])
            },
            eject: { url in
                let main = Thread.isMainThread
                record.lock.withLock {
                    record.ejected.append(url)
                    record.onMain.append(main)
                }
                if url.lastPathComponent == "SD CARD" { throw CocoaError(.fileWriteNoPermission) }
            }
        )
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: volumes)
        let delegate = Delegate()
        tree.delegate = delegate
        _ = tree.view
        let locations = try XCTUnwrap(tree.dataSource.roots.first { $0.section == .locations })
        XCTAssertEqual(locations.children.map(\.title), ["SD CARD", "Macintosh HD", "Backup"])
        XCTAssertEqual(locations.children.map(\.symbolName), ["sdcard", "internaldrive", "externaldrive"])

        let outline = tree.outlineViewForTesting
        let sdRow = outline.row(forItem: locations.children[0])
        let sdCell = try XCTUnwrap(tree.cellForTesting(row: sdRow))
        let eject = try XCTUnwrap(sdCell.ejectButton)
        XCTAssertEqual(eject.accessibilityLabel(), "Eject SD CARD")
        XCTAssertTrue(eject.isHidden, "hidden until hover or selection")
        sdCell.isRowSelected = true
        XCTAssertFalse(eject.isHidden)
        XCTAssertNil(tree.cellForTesting(row: outline.row(forItem: locations.children[1]))?.ejectButton,
                     "the boot disk has no eject button")

        eject.performClick(nil)
        await tree.ejectTask?.value
        XCTAssertEqual(delegate.toasts, ["Couldn't eject “SD CARD”. A file on it may be in use."])
        let (ejected, onMain) = record.lock.withLock { (record.ejected, record.onMain) }
        XCTAssertEqual(ejected.map(\.lastPathComponent), ["SD CARD"])
        XCTAssertEqual(onMain, [false])
    }

    // The boot volume is not a lookup root: selecting a temp folder does
    // not walk from "/" (it matches no sidebar root).
    func testBootVolumeIsNotALookupRoot() async {
        let ds = FolderTreeDataSource()
        ds.rebuildRoots(favorites: [], volumes: [
            SidebarVolume(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", kind: .internal, isEjectable: false),
        ])
        var listed: [URL] = []
        ds.didListFolder = { listed.append($0) }
        let awaited1 = await ds.node(for: url("Italy"))
        XCTAssertNil(awaited1)
        XCTAssertTrue(listed.isEmpty)
    }

    // ⌘D adds the Browser's current folder.
    func testCommandDAddsTheCurrentFolder() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: url("Italy"))
        defer { browser.close() }
        XCTAssertTrue(browser.canPerform(.addToFavorites))
        browser.perform(.addToFavorites)
        let favorites = browser.treeControllerForTesting.favorites.favorites()
        XCTAssertEqual(favorites.map(\.path), [url("Italy").standardizedFileURL.path])
        XCTAssertNotNil(browser.treeControllerForTesting.dataSource.favoritesSection)
    }

    /// A long name in a narrow
    /// sidebar ends in "…". The outline column follows the visible width,
    /// so the label is cut by its truncation, not clipped by the column.
    func testLongNameInANarrowSidebarTruncatesInsideTheVisibleWidth() throws {
        let long = "Macintosh HD Photo Archive 2026 Italy and Spain"
        try FileManager.default.createDirectory(at: url(long), withIntermediateDirectories: true)
        let store = FavoritesStore.inMemory([SidebarFavorite(path: url(long).path)])
        let tree = FolderTreeViewController(favorites: store, volumes: .none)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 400),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = tree
        let outline = tree.outlineViewForTesting
        let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
        for width in [220.0, 160.0, 300.0, 170.0] {
            window.setContentSize(NSSize(width: width, height: 400))
            window.contentView?.layoutSubtreeIfNeeded()
            outline.layoutSubtreeIfNeeded()
            let node = try XCTUnwrap(tree.dataSource.favoritesSection?.children.first)
            let row = outline.row(forItem: node)
            XCTAssertGreaterThanOrEqual(row, 0)
            let cell = try XCTUnwrap(tree.cellForTesting(row: row))
            cell.layoutSubtreeIfNeeded()
            let label = try XCTUnwrap(cell.textField)
            XCTAssertEqual(label.stringValue, long)
            XCTAssertEqual(label.lineBreakMode, .byTruncatingTail)
            let column = try XCTUnwrap(outline.tableColumns.first)
            XCTAssertLessThanOrEqual(outline.frame.width, clip.bounds.width + 0.5, "width \(width): no hidden overflow")
            XCTAssertLessThanOrEqual(column.width, clip.bounds.width + 0.5, "width \(width): the column fits")
            let inClip = label.convert(label.bounds, to: clip)
            XCTAssertLessThanOrEqual(inClip.maxX, clip.bounds.maxX + 0.5, "width \(width): the label ends inside")
            XCTAssertLessThan(label.frame.width, label.intrinsicContentSize.width,
                              "width \(width): the name is cut by the label (it truncates)")
        }
    }
}

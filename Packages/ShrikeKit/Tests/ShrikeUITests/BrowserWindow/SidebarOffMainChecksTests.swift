//
//  SidebarOffMainChecksTests.swift
//  ShrikeUITests
//
//  Audit E-3: the sidebar's first paint reads stored data only; the
//  existence checks, bookmark lookups and the volume list run off the main
//  thread, and only rows that differ are corrected afterwards.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class SidebarOffMainChecksTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-e3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Here"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var _main = 0, _off = 0
        func note() {
            lock.lock(); defer { lock.unlock() }
            if Thread.isMainThread { _main += 1 } else { _off += 1 }
        }
        var main: Int { lock.lock(); defer { lock.unlock() }; return _main }
        var off: Int { lock.lock(); defer { lock.unlock() }; return _off }
    }

    func testFirstPaintTouchesNoDiskAndTheChecksRunOffTheMainThread() async throws {
        let calls = Calls()
        let exists: @Sendable (URL) -> Bool = { calls.note(); return FileManager.default.fileExists(atPath: $0.path) }
        var favData: Data? = try JSONEncoder().encode([SidebarFavorite(path: root.appendingPathComponent("Gone").path),
                                                      SidebarFavorite(path: root.appendingPathComponent("Here").path)])
        var wsData: Data? = try JSONEncoder().encode(SidebarFavorite(path: root.appendingPathComponent("Gone2").path))
        let favs = FavoritesStore(load: { favData }, save: { favData = $0 }, seed: { [] }, exists: exists)
        let ws = WorkspaceStore(load: { wsData }, save: { wsData = $0 }, exists: exists)
        let listed = Calls()
        let volumes = VolumeSource(list: { listed.note(); return [] }, eject: { _ in }, initial: { [] })

        let tree = FolderTreeViewController(favorites: favs, volumes: volumes, workspace: ws)
        _ = tree.view
        XCTAssertEqual(calls.main + calls.off, 0, "first paint: no disk check yet")
        let shown = try XCTUnwrap(tree.dataSource.favoritesSection?.children)
        XCTAssertEqual(shown.map(\.isMissing), [false, false], "shown as present until proven missing")
        XCTAssertFalse(try XCTUnwrap(tree.dataSource.workspaceRoot).isMissing)

        await tree.sidebarChecksFinished()
        XCTAssertGreaterThan(calls.off, 0)
        XCTAssertEqual(calls.main, 0, "every existence check ran off the main thread")
        XCTAssertEqual(listed.main, 0, "the volume list ran off the main thread")
        XCTAssertGreaterThan(listed.off, 0)
        XCTAssertEqual(tree.dataSource.favoritesSection?.children.map(\.isMissing), [true, false])
        XCTAssertTrue(try XCTUnwrap(tree.dataSource.workspaceRoot).isMissing)
    }

    func testRebuildKeepsTheMissingLookWithoutAFlash() async throws {
        let store = FavoritesStore.inMemory([SidebarFavorite(path: root.appendingPathComponent("Gone").path)])
        let tree = FolderTreeViewController(favorites: store, volumes: .none)
        _ = tree.view
        await tree.sidebarChecksFinished()
        XCTAssertEqual(tree.dataSource.favoritesSection?.children.map(\.isMissing), [true])
        tree.rebuild()
        XCTAssertEqual(tree.dataSource.favoritesSection?.children.map(\.isMissing), [true], "no flash back to present")
        await tree.sidebarChecksFinished()
        XCTAssertEqual(tree.dataSource.favoritesSection?.children.map(\.isMissing), [true])
    }

    func testCheckDoesNotOverwriteAFavoriteAddedWhileItRan() async throws {
        let store = FavoritesStore.inMemory([SidebarFavorite(path: root.appendingPathComponent("Here").path)])
        let checked = await store.checkedRows()
        XCTAssertTrue(store.add(root, at: nil))
        XCTAssertFalse(store.commit(checked), "the saved list changed: the result is dropped, the caller checks again")
        XCTAssertEqual(store.favorites().count, 2)
    }

    /// A plain rebuild (a workspace post, the add-favorite key) while the first
    /// volume list is still being read must not lose that list.
    func testRebuildWhileTheFirstVolumeListIsPendingKeepsTheList() async throws {
        let gate = DispatchSemaphore(value: 0)
        let volume = SidebarVolume(url: root, name: "Fixture", kind: .external, isEjectable: false)
        let volumes = VolumeSource(list: { gate.wait(); return [volume] }, eject: { _ in }, initial: { [] })
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: volumes)
        _ = tree.view
        tree.rebuild()                       // cancels the running check, asks for the list again
        gate.signal(); gate.signal()         // the cancelled read and the new one
        await tree.sidebarChecksFinished()
        XCTAssertTrue(tree.volumesKnownForTesting)
        XCTAssertTrue(tree.dataSource.locationsSection?.children.contains { $0.url?.path == root.standardizedFileURL.path } == true)
    }

    /// The first list must leave the current folder revealed AND opened, as a
    /// list that was there from the start does (control: synchronous list).
    func testFirstVolumeListStillOpensTheCurrentFolderLikeASynchronousList() async throws {
        let sub = root.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub.appendingPathComponent("Child"), withIntermediateDirectories: true)
        let volume = SidebarVolume(url: root, name: "Fixture", kind: .external, isEjectable: false)
        func run(gated: Bool) async throws -> (selected: String?, expanded: Bool) {
            let gate = DispatchSemaphore(value: 0)
            let list: @Sendable () -> [SidebarVolume] = { if gated { gate.wait() }; return [volume] }
            let source = gated ? VolumeSource(list: list, eject: { _ in }, initial: { [] })
                               : VolumeSource(list: list, eject: { _ in })
            let tree = FolderTreeViewController(favorites: .inMemory(), volumes: source)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = tree
            defer { window.close() }
            _ = tree.view
            ShrikeDefaults.store.removeObject(forKey: "shrike.browser.tree.expanded")
            tree.select(sub)
            if gated { gate.signal() }
            await tree.sidebarChecksFinished()
            await tree.selectTask?.value
            let outline = tree.outlineViewForTesting
            let node = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? FolderTreeNode : nil
            let selected = node?.url?.resolvingSymlinksInPath().path
            return (selected, node.map { outline.isItemExpanded($0) } ?? false)
        }
        let control = try await run(gated: false)
        let late = try await run(gated: true)
        XCTAssertEqual(control.selected, sub.resolvingSymlinksInPath().path, "control: the folder is selected")
        XCTAssertEqual(late.selected, control.selected)
        XCTAssertEqual(late.expanded, control.expanded, "the late list opens the folder exactly as the control does")
    }

    func testRevealUnderVolumesWaitsForTheFirstVolumeListInsteadOfBeingClearedAsEjected() async throws {
        let gate = DispatchSemaphore(value: 0)
        let fake = URL(fileURLWithPath: "/Volumes/ShrikeE3Fake", isDirectory: true)
        let volume = SidebarVolume(url: fake, name: "Fake", kind: .external, isEjectable: false)
        let volumes = VolumeSource(list: { gate.wait(); return [volume] }, eject: { _ in }, initial: { [] })
        let tree = FolderTreeViewController(favorites: .inMemory(), volumes: volumes)
        _ = tree.view
        XCTAssertFalse(tree.volumesKnownForTesting)
        tree.select(fake.appendingPathComponent("Photos"))
        XCTAssertTrue(tree.hasDeferredRevealForTesting, "the reveal waits for the list")
        gate.signal()
        await tree.sidebarChecksFinished()
        XCTAssertTrue(tree.volumesKnownForTesting)
        XCTAssertFalse(tree.hasDeferredRevealForTesting, "the reveal ran once the volume was listed")
        XCTAssertTrue(tree.dataSource.locationsSection?.children.contains { $0.url?.path == fake.path } == true)
    }
}

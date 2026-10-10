//
//  BrowserWatchTests.swift
//  ShrikeUITests
//
//  (Browser side): the listed folder is watched; a batch of
//  outside changes lists it again; the folder going away stops the
//  watcher. Temp folders only.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class BrowserWatchTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent("a.jpg"))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testListedFolderIsWatchedAndFolderGoneStopsTheWatcher() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let watching = await waitUntil { browser.folderWatcher != nil }
        XCTAssertTrue(watching)
        XCTAssertEqual(GroupList.canonical(browser.folderWatcher!.folder), GroupList.canonical(dir))
        XCTAssertTrue(FolderWatcherRegistry.shared.registered.contains { $0 === browser.folderWatcher })

        // An unrelated folder's change is ignored.
        browser.handleFolderChange(FolderChange(folderEvent: .deleted), in: dir.deletingLastPathComponent())
        XCTAssertNotNil(browser.folderWatcher)

        browser.handleFolderChange(FolderChange(folderEvent: .deleted), in: dir)
        XCTAssertNil(browser.folderWatcher)
        XCTAssertFalse(FolderWatcherRegistry.shared.registered.contains { GroupList.canonical($0.folder) == GroupList.canonical(self.dir) })
    }

    // (the list side): an added file appears after a change batch.
    func testAddedFileIsListedAfterAChangeBatch() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 1 }
        XCTAssertTrue(loaded)
        let b = dir.appendingPathComponent("b.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: b)
        browser.handleFolderChange(FolderChange(added: [b]), in: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(listed)
    }

    // A re-list (outside change, or the watcher seeing our own tag write)
    // keeps the WHOLE selection, not only its first item. Before the fix
    // only `selectedItems.first` survived, which made
    // TagEditorTests.testBrowserInspectorChipsRemoveAndAdd flaky.
    func testReListKeepsAMultiSelection() async throws {
        let b = dir.appendingPathComponent("b.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: b)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(loaded)
        browser.contentController.selectAll()
        XCTAssertEqual(browser.contentController.selectedItems.count, 2)
        let c = dir.appendingPathComponent("c.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: c)
        browser.handleFolderChange(FolderChange(added: [c], modified: [b]), in: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == 3 }
        XCTAssertTrue(listed)
        XCTAssertEqual(Set(browser.contentController.selectedItems.map(\.url.lastPathComponent)),
                       ["a.jpg", "b.jpg"])
    }
}

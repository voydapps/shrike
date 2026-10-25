//
//  ViewerWatchTests.swift
//  ShrikeUITests
//
//  File watching (viewer side) and Browser "Folder gone": outside
//  changes reach the viewer's list without moving the displayed item;
//  a removed displayed file shows the next one with a toast; the folder
//  going away shows the empty state. Temp folders only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class ViewerWatchTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        let root = TestScratch.directory
            .appendingPathComponent("shrike-vwatch-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func makeFiles(_ names: [String]) throws -> [URL] {
        let urls = names.map { dir.appendingPathComponent($0) }
        for url in urls { try Data([0xFF, 0xD8, 0xFF]).write(to: url) }
        return urls
    }

    private func viewer(_ urls: [URL], start: Int) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: start,
                                  services: services)
        viewer.markDisplayedForTesting(start)
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testViewerWatchesTheDisplayedFolder() throws {
        let urls = try makeFiles(["a.jpg", "b.jpg"])
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        XCTAssertNotNil(viewer.folderWatcher)
        XCTAssertEqual(GroupList.canonical(viewer.folderWatcher!.folder), GroupList.canonical(dir))
        XCTAssertTrue(FolderWatcherRegistry.shared.registered.contains { $0 === viewer.folderWatcher })
        viewer.close()
        XCTAssertNil(viewer.folderWatcher)
    }

    // Removed displayed file: the next one shows, with the toast; no undo.
    func testRemovedDisplayedFileShowsNextWithToast() throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        try FileManager.default.removeItem(at: urls[1])
        viewer.handleFolderChange(FolderChange(removed: [urls[1]]), in: dir)
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "c.jpg"])
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message,
                       "“b.jpg” was moved or deleted.")
        XCTAssertNil(viewer.contentRootForTesting.toastHost.content?.actionTitle)
        XCTAssertFalse(viewer.undoManagerForTesting.canUndo)
    }

    // Removed other file: the displayed item stays; no toast.
    func testRemovedOtherFileKeepsDisplayedItem() throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 2)
        defer { viewer.close() }
        viewer.handleFolderChange(FolderChange(removed: [urls[0]]), in: dir)
        XCTAssertEqual(viewer.groups.count, 2)
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[2])
        XCTAssertEqual(viewer.displayedItem?.listIndex, 1)
        XCTAssertNil(viewer.contentRootForTesting.toastHost.content)
    }

    // Renamed: keeps its place; the title follows.
    func testRenamedDisplayedFileKeepsItsPlace() throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        let renamed = dir.appendingPathComponent("zz.jpg")
        try FileManager.default.moveItem(at: urls[1], to: renamed)
        viewer.handleFolderChange(FolderChange(renamed: [.init(from: urls[1], to: renamed)]), in: dir)
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "zz.jpg", "c.jpg"])
        XCTAssertEqual(viewer.displayedItem?.group.primary, renamed)
        XCTAssertEqual(viewer.title, "zz.jpg")
    }

    // (viewer): an added file is listed; the displayed item stays.
    func testAddedFileIsInsertedInNameOrder() async throws {
        let urls = try makeFiles(["a.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        let b = try makeFiles(["b.jpg"])[0]
        viewer.handleFolderChange(FolderChange(added: [b]), in: dir)
        let listed = await waitUntil { viewer.groups.count == 3 }
        XCTAssertTrue(listed)
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertEqual(viewer.displayedItem?.group.primary, urls[1])
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2)
    }

    func testFolderGoneShowsEmptyState() throws {
        let urls = try makeFiles(["a.jpg"])
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        viewer.handleFolderChange(FolderChange(folderEvent: .deleted), in: dir)
        XCTAssertTrue(viewer.isShowingEmptyState)
        XCTAssertEqual(viewer.emptyStateView?.title, "“Italy 2026” is no longer available.")
        XCTAssertNil(viewer.displayedItem)
        XCTAssertNil(viewer.folderWatcher)
        // No pill, filmstrip, histogram or badge over the empty state.
        let chrome = viewer.contentRootForTesting.emptyStateChromeHiddenForTesting
        XCTAssertTrue(chrome.pill && chrome.filmstrip && chrome.histogram && chrome.badge)
    }

    // The Browser shows the Folder-gone state with its button.
    func testBrowserFolderGoneStateGoesToEnclosingFolder() async throws {
        _ = try makeFiles(["a.jpg"])
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 1 }
        XCTAssertTrue(loaded)
        browser.handleFolderChange(FolderChange(folderEvent: .deleted), in: dir)
        let state = browser.contentController.emptyStateForTesting
        XCTAssertEqual(state?.titleText, "“Italy 2026” is no longer available.")
        XCTAssertEqual(state?.buttonTitle, "Go to Enclosing Folder")
        XCTAssertEqual(browser.contentController.visibleItems.count, 0)
        // The status bar and the subtitle stop counting the gone folder.
        XCTAssertEqual(browser.statusTextForTesting, "", "nothing selected: an empty status")
        XCTAssertEqual(browser.window?.subtitle, "0 photos")
        let gone = dir.appendingPathComponent("x/y", isDirectory: true)
        XCTAssertEqual(BrowserWindowController.nearestExistingAncestor(of: gone).standardizedFileURL.path,
                       dir.standardizedFileURL.path)
    }
}

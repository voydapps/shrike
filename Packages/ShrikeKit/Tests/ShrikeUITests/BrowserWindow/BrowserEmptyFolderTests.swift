//
//  BrowserEmptyFolderTests.swift
//  ShrikeUITests
//
//  The copy for a folder with no images.
//  Icon photo.on.rectangle, "No images in “<folder>”.", "Subfolders are
//  in the sidebar." only when the folder has subfolders, no button, and
//  no drop hint. Temp folders, offscreen windows.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class BrowserEmptyFolderTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testEmptyFolderWithoutSubfoldersShowsTitleOnly() async throws {
        let folder = try makeFolder("Scans")
        try Data("notes".utf8).write(to: folder.appendingPathComponent("readme.txt"))
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: folder)
        defer { browser.close() }
        var checked = false
        browser.onSubfolderCheckForTesting = { checked = true }
        let shown = await waitUntil {
            browser.contentController.emptyStateForTesting?.titleText == "No images in “Scans”."
        }
        XCTAssertTrue(shown, "title \(String(describing: browser.contentController.emptyStateForTesting?.titleText))")
        _ = await waitUntil { checked }
        let state = try XCTUnwrap(browser.contentController.emptyStateForTesting)
        XCTAssertEqual(state.titleText, "No images in “Scans”.")
        XCTAssertNil(state.subtitleText, "no subfolders: no message")
        XCTAssertNil(state.buttonTitle, "no button")
        XCTAssertTrue(state.symbolShown, "photo.on.rectangle icon")
    }

    /// A temp folder is on no sidebar row, so the copy only
    /// counts the subfolders; it makes no sidebar claim.
    func testEmptyFolderOutsideTheSidebarCountsItsSubfolders() async throws {
        let folder = try makeFolder("Trips")
        _ = try makeFolder("Trips/2025")
        _ = try makeFolder("Trips/2026")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: folder)
        defer { browser.close() }
        let shown = await waitUntil {
            browser.contentController.emptyStateForTesting?.subtitleText == "This folder has 2 subfolders."
        }
        XCTAssertTrue(shown, "message \(String(describing: browser.contentController.emptyStateForTesting?.subtitleText))")
        let inSidebar = await browser.sidebarShowsSubfolders(of: folder)
        XCTAssertFalse(inSidebar)
    }

    func testEmptyFolderSubtitleCopy() {
        typealias C = BrowserContentViewController
        XCTAssertEqual(C.emptyFolderSubtitle(subfolders: 0, inSidebar: true), "")
        XCTAssertEqual(C.emptyFolderSubtitle(subfolders: 3, inSidebar: true), "Subfolders are in the sidebar.")
        XCTAssertEqual(C.emptyFolderSubtitle(subfolders: 1, inSidebar: false), "This folder has 1 subfolder.")
        XCTAssertEqual(C.emptyFolderSubtitle(subfolders: 12, inSidebar: false), "This folder has 12 subfolders.")
        XCTAssertEqual(BrowserWindowController.subfolderCount(root, showHidden: false), 0)
    }

    /// The folder is a row of the sidebar tree (its parent is a sidebar
    /// root here): its subfolders are in the sidebar, and the copy says so.
    /// With the sidebar closed it only counts them.
    func testEmptyFolderWithSubfoldersPointsToTheSidebar() async throws {
        let folder = try makeFolder("Trips")
        _ = try makeFolder("Trips/2025")
        let start = try makeFolder("Start")
        try Data("x".utf8).write(to: start.appendingPathComponent("a.txt"))
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: start)
        defer { browser.close() }
        let tree = browser.treeController
        tree.dataSource.roots.append(FolderTreeNode(url: root, title: "Test Root"))
        tree.reload()
        let inSidebar = await browser.sidebarShowsSubfolders(of: folder)
        XCTAssertTrue(inSidebar)
        browser.splitController.splitViewItems[0].isCollapsed = true
        let closed = await browser.sidebarShowsSubfolders(of: folder)
        XCTAssertFalse(closed, "a closed sidebar shows nothing")
        browser.splitController.splitViewItems[0].isCollapsed = false
        browser.go(to: .folder(folder))
        let shown = await waitUntil {
            browser.contentController.emptyStateForTesting?.subtitleText == "Subfolders are in the sidebar."
        }
        XCTAssertTrue(shown, "message \(String(describing: browser.contentController.emptyStateForTesting?.subtitleText))")
        let state = try XCTUnwrap(browser.contentController.emptyStateForTesting)
        XCTAssertEqual(state.titleText, "No images in “Trips”.")
        XCTAssertNil(state.buttonTitle)
        XCTAssertFalse(state.titleText.contains("Drop"), "no false drop hint")
    }

    func testHasSubfoldersSkipsPackagesAndHiddenFolders() throws {
        let folder = try makeFolder("Mixed")
        XCTAssertFalse(BrowserWindowController.hasSubfolders(folder, showHidden: false))
        _ = try makeFolder("Mixed/.cache")
        XCTAssertFalse(BrowserWindowController.hasSubfolders(folder, showHidden: false), "hidden is skipped")
        XCTAssertTrue(BrowserWindowController.hasSubfolders(folder, showHidden: true), "unless hidden files show")
        _ = try makeFolder("Mixed/Album.app")
        XCTAssertFalse(BrowserWindowController.hasSubfolders(folder, showHidden: false), "a package is a file")
        _ = try makeFolder("Mixed/Raw")
        XCTAssertTrue(BrowserWindowController.hasSubfolders(folder, showHidden: false))
        XCTAssertFalse(BrowserWindowController.hasSubfolders(root.appendingPathComponent("gone"), showHidden: false))
    }
}

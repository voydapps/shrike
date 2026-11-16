//
//  FolderGoneRealPathsTests.swift
//  ShrikeUITests
//
//  Pass 2p task 1: Go to Enclosing Folder through the real user paths
//  after audit E-3 (the ancestor is found off the main thread and kept only
//  while the window still shows the folder it was asked for). Each path is
//  run with several spellings of the same folder (through the `/var` →
//  `/private/var` link, a trailing slash, a link of our own), so a caller
//  that hands the guard another spelling than `currentFolder` would fail
//  here instead of leaving a button that does nothing.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class FolderGoneRealPathsTests: XCTestCase {

    private var root: URL!

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-2p1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    /// The spellings one folder can arrive with.
    private func spellings(of url: URL) -> [URL] {
        let path = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().path
        let privatePath = path.hasPrefix("/private/") ? path : "/private" + path
        var out = [URL(fileURLWithPath: path, isDirectory: true),
                   URL(fileURLWithPath: path + "/"),
                   URL(fileURLWithPath: path, isDirectory: false)]
        if FileManager.default.fileExists(atPath: privatePath) {
            out.append(URL(fileURLWithPath: privatePath, isDirectory: true))
        }
        if resolved != path { out.append(URL(fileURLWithPath: resolved, isDirectory: true)) }
        return out
    }

    /// Presses Go to Enclosing Folder and waits for the window to show `expected`.
    private func pressGoToEnclosing(_ browser: BrowserWindowController, expect expected: URL,
                                    _ label: String) async throws {
        let state = try XCTUnwrap(browser.contentController.emptyStateForTesting, label)
        XCTAssertEqual(state.buttonTitle, "Go to Enclosing Folder", label)
        state.perform(NSSelectorFromString("buttonPressed:"), with: nil)
        let want = CanonicalPath.of(expected)
        let moved = await waitUntil { browser.currentFolder.map(CanonicalPath.of) == want }
        XCTAssertTrue(moved, "\(label): the button moved to \(browser.currentFolder?.path ?? "nil"), not \(want)")
    }

    // (a) The shown folder is deleted while open.
    func testDeletedWhileOpenGoesToTheNearestParent() async throws {
        let parent = root.appendingPathComponent("Trips", isDirectory: true)
        for (index, spelling) in spellings(of: parent).enumerated() {
            let shoot = parent.appendingPathComponent("Shoot\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
            let opened = spelling.appendingPathComponent("Shoot\(index)", isDirectory: true)
            let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: opened)
            defer { browser.close() }
            await browser.listingTask?.value
            let watching = await waitUntil { browser.folderWatcher != nil }
            XCTAssertTrue(watching, "\(opened.path): watched")
            try FileManager.default.removeItem(at: shoot)
            let gone = await waitUntil { browser.contentController.isShowingFolderGone }
            XCTAssertTrue(gone, "\(opened.path): the gone card appears")
            try await pressGoToEnclosing(browser, expect: parent, opened.path)
        }
    }

    // (b) Opening a folder that is already missing (Recent Folders, Go to Folder).
    func testOpeningAMissingFolderGoesToTheNearestParent() async throws {
        let parent = root.appendingPathComponent("Albums", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let start = root.appendingPathComponent("Start", isDirectory: true)
        try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: start)
        defer { browser.close() }
        await browser.listingTask?.value
        for spelling in spellings(of: parent) {
            // Two missing levels: the nearest existing parent is `Albums`.
            let missing = spelling.appendingPathComponent("Gone/Deeper", isDirectory: true)
            browser.navigate(to: missing)
            await browser.listingTask?.value
            let gone = await waitUntil { browser.contentController.isShowingFolderGone }
            XCTAssertTrue(gone, "\(missing.path): the gone card appears")
            try await pressGoToEnclosing(browser, expect: parent, missing.path)
            await browser.listingTask?.value
        }
    }

    // (c) A folder reached through a link of our own (`Link` → `Real`).
    func testAFolderUnderALinkGoesToTheNearestParent() async throws {
        let real = root.appendingPathComponent("Real", isDirectory: true)
        let link = root.appendingPathComponent("Link", isDirectory: true)
        let shoot = real.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let opened = link.appendingPathComponent("Shoot", isDirectory: true)

        // Deleted while open.
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: opened)
        defer { browser.close() }
        await browser.listingTask?.value
        let watching = await waitUntil { browser.folderWatcher != nil }
        XCTAssertTrue(watching)
        try FileManager.default.removeItem(at: shoot)
        let gone = await waitUntil { browser.contentController.isShowingFolderGone }
        XCTAssertTrue(gone, "a folder opened through a link shows the gone card")
        try await pressGoToEnclosing(browser, expect: link, "deleted under a link")

        // Opened while already missing, through the link.
        browser.navigate(to: link.appendingPathComponent("Missing", isDirectory: true))
        await browser.listingTask?.value
        let goneAgain = await waitUntil { browser.contentController.isShowingFolderGone }
        XCTAssertTrue(goneAgain)
        try await pressGoToEnclosing(browser, expect: link, "missing under a link")
    }

    // The disk check after a disk goes (the caller with `disk:`): the stored
    // name reaches the card's subtitle for the folder still shown.
    func testEjectedDiskNameReachesTheSubtitle() async throws {
        let start = root.appendingPathComponent("Start", isDirectory: true)
        try FileManager.default.createDirectory(at: start, withIntermediateDirectories: true)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: start)
        defer { browser.close() }
        await browser.listingTask?.value
        let disk = "Shrike-Gone-\(UUID().uuidString)"
        let gone = URL(fileURLWithPath: "/Volumes/\(disk)/DCIM", isDirectory: true).standardizedFileURL
        browser.currentFolder = gone
        XCTAssertFalse(browser.contentController.isShowingFolderGone)
        browser.folderTreeVolumesDidChange()
        let named = await waitUntil {
            browser.contentController.emptyStateForTesting?.subtitleText == "“\(disk)” was disconnected."
        }
        XCTAssertTrue(named, "the disk name found off the main thread reaches the subtitle")
        XCTAssertEqual(browser.contentController.emptyStateForTesting?.buttonTitle, "Go to Enclosing Folder")
    }
}

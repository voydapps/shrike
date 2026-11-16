//
//  FolderGoneOffMainTests.swift
//  ShrikeUITests
//
//  Audit E-3 follow-ups: the "folder gone" state, the disk check after a
//  disk comes or goes and Go to Enclosing Folder read the disk off the main
//  thread; a late answer for a folder no longer shown is dropped. A sidebar
//  drag checks its folders once per drag, not once per pointer move.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class FolderGoneOffMainTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var other: URL!

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-e3b-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Shoot", isDirectory: true)
        other = root.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    func testSubtitleFromAKnownDiskName() {
        XCTAssertEqual(BrowserContentViewController.folderGoneSubtitle(disk: "CARD"), "“CARD” was disconnected.")
        XCTAssertEqual(BrowserContentViewController.folderGoneSubtitle(disk: nil),
                       "It may have been moved, or its disk was disconnected.")
    }

    func testGoneDiskNameArrivesLaterAndAStaleNameIsDropped() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let gone = URL(fileURLWithPath: "/Volumes/Shrike-Gone-\(UUID().uuidString)/DCIM", isDirectory: true)
        content.showFolderGone(gone) {}
        XCTAssertEqual(content.emptyStateForTesting?.subtitleText,
                       "It may have been moved, or its disk was disconnected.", "no disk read while drawing")
        content.setFolderGoneDisk("Elsewhere", for: dir)
        XCTAssertEqual(content.emptyStateForTesting?.subtitleText,
                       "It may have been moved, or its disk was disconnected.", "a name for another folder is dropped")
        content.setFolderGoneDisk("CARD", for: gone)
        XCTAssertEqual(content.emptyStateForTesting?.subtitleText, "“CARD” was disconnected.")

        // The window resolves the name itself, off the main thread.
        browser.currentFolder = gone
        browser.showFolderGone(gone)
        let disk = gone.pathComponents[2]
        let named = await waitUntil { content.emptyStateForTesting?.subtitleText == "“\(disk)” was disconnected." }
        XCTAssertTrue(named)
    }

    func testGoToEnclosingFolderNavigatesAndALateAnswerIsDropped() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        await browser.listingTask?.value
        browser.handleFolderChange(FolderChange(folderEvent: .deleted), in: dir)
        let state = try XCTUnwrap(browser.contentController.emptyStateForTesting)
        XCTAssertEqual(state.buttonTitle, "Go to Enclosing Folder")

        // The user goes somewhere else before the answer comes back.
        state.perform(NSSelectorFromString("buttonPressed:"), with: nil)
        browser.navigate(to: other)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(browser.currentFolder, other, "the late answer does not move the window")

        browser.handleFolderChange(FolderChange(folderEvent: .deleted), in: other)
        try XCTUnwrap(browser.contentController.emptyStateForTesting)
            .perform(NSSelectorFromString("buttonPressed:"), with: nil)
        let moved = await waitUntil { browser.currentFolder?.standardizedFileURL.path == root.standardizedFileURL.path }
        XCTAssertTrue(moved)
    }

    func testDroppedFoldersAreCheckedOncePerDrag() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("shrike-e3-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([other as NSURL])
        XCTAssertEqual(FolderTreeViewController.droppedFolders(pb).map(\.lastPathComponent), ["Other"])
        try FileManager.default.removeItem(at: other)
        XCTAssertEqual(FolderTreeViewController.droppedFolders(pb).map(\.lastPathComponent), ["Other"],
                       "the same drag reuses its answer")
        pb.clearContents()
        pb.writeObjects([other as NSURL])
        XCTAssertEqual(FolderTreeViewController.droppedFolders(pb), [], "a new drag checks again")
    }
}

//
//  ScopedWatcherIgnoreTests.swift
//  ShrikeUITests
//
//  A window ignores its own file writes in its own watcher (and its paired
//  window's), never in every watcher of the app. A second window on the
//  same folder (the `probe` below) must still hear about the change, so
//  it can refresh its thumbnail, size and badges. Temp folders and a temp
//  `BackupStore` only.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO

/// A second window's watcher on the folder: collects what it reports.
private final class Probe: Sendable {
    private struct Seen: Sendable {
        var modified: Set<String> = []
        var renamed: Set<String> = []
    }
    let watcher: FolderWatcher
    private let seen = OSAllocatedUnfairLock<Seen>(initialState: Seen())
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(folder: URL) throws {
        watcher = try FolderWatcher(folder: folder)
        let stream = watcher.changes
        let seen = self.seen
        let t = Task {
            for await change in stream {
                seen.withLock {
                    $0.modified.formUnion(change.modified.map(\.lastPathComponent))
                    $0.renamed.formUnion(change.renamed.map { "\($0.from.lastPathComponent)>\($0.to.lastPathComponent)" })
                }
            }
        }
        task.withLock { $0 = t }
    }

    func stop() { watcher.stop(); task.withLock { $0?.cancel() } }

    var modified: Set<String> { seen.withLock { $0.modified } }
    var renamed: Set<String> { seen.withLock { $0.renamed } }

    func waitForModified(_ name: String, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if modified.contains(name) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return modified.contains(name)
    }

    func waitForRename(_ pair: String, timeout: TimeInterval = 8) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if renamed.contains(pair) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return renamed.contains(pair)
    }
}

/// Remembers what it was told to ignore.
private final class RecordingSuppressor: FolderChangeSuppressing, @unchecked Sendable {
    private let recorded = OSAllocatedUnfairLock<[URL]>(initialState: [])
    func ignore(paths: [URL], for duration: Duration) { recorded.withLock { $0 += paths } }
    var paths: [URL] { recorded.withLock { $0 } }
}

@MainActor
final class ScopedWatcherIgnoreTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        ViewerWindow.orientationWriteDelay = .milliseconds(100)
        root = TestScratch.directory
            .appendingPathComponent("shrike-scoped-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
    }

    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: root)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func services() -> ShrikeServices {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        return services
    }

    private func viewer(_ url: URL) async -> ViewerWindow {
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services())
        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready)
        return viewer
    }

    private func browser(count: Int = 1) async -> BrowserWindowController {
        let browser = BrowserWindowController(services: services(), initialFolder: dir)
        let loaded = await waitUntil { browser.contentController.visibleItems.count == count }
        XCTAssertTrue(loaded)
        return browser
    }

    // MARK: WindowWatcherScope

    func testScopeIgnoresOwnAndPartnerWatchersButNotOthers() async throws {
        let a = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        let mine = try FolderWatcher(folder: dir), partner = try FolderWatcher(folder: dir)
        let other = try Probe(folder: dir)
        defer { mine.stop(); partner.stop(); other.stop() }
        let scope = WindowWatcherScope(), partnerScope = WindowWatcherScope()
        scope.setWatcher(mine); partnerScope.setWatcher(partner); scope.setPartner(partnerScope)
        XCTAssertEqual(scope.watchers.count, 2)
        var mineHeard = Set<String>(), partnerHeard = Set<String>()
        let t1 = Task { for await c in mine.changes { mineHeard.formUnion(c.modified.map(\.lastPathComponent)) } }
        let t2 = Task { for await c in partner.changes { partnerHeard.formUnion(c.modified.map(\.lastPathComponent)) } }
        defer { t1.cancel(); t2.cancel() }
        scope.ignore(paths: [a], for: .seconds(2))
        try Data([1, 2, 3]).write(to: a, options: .atomic)
        let heard = await other.waitForModified("a.jpg")
        XCTAssertTrue(heard, "a watcher outside the scope still reports the write")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(mineHeard.isEmpty, "the window's own watcher ignores it")
        XCTAssertTrue(partnerHeard.isEmpty, "the paired window's watcher ignores it")
    }

    func testPairingLinksTheScopes() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = await viewer(url)
        let browser = await browser()
        defer { viewer.close(); browser.close() }
        viewer.pairedBrowser = browser; browser.pairedViewer = viewer
        let viewerSide = Set(viewer.watcherScope.watchers.map { ObjectIdentifier($0) })
        if let w = browser.folderWatcher { XCTAssertTrue(viewerSide.contains(ObjectIdentifier(w))) } else { XCTFail("no browser watcher") }
        viewer.pairedBrowser = nil
        XCTAssertFalse(viewer.watcherScope.watchers.contains { $0 === browser.folderWatcher })
    }

    // MARK: Viewer

    func testViewerSaveInPlaceIsSeenByAnotherWatcher() async throws {
        let url = dir.appendingPathComponent("s.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = await viewer(url)
        defer { viewer.close() }
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        let ready = await waitUntil { viewer.navCoalescer.isIdle }
        XCTAssertTrue(ready)
        viewer.contentRootForTesting.enterEditMode(image: SaveFlowTests.image(), url: url, landOn: .rotate)
        viewer.contentRootForTesting.editModeController.appendSnapped90(quarters: 1)
        let recipe = try XCTUnwrap(viewer.contentRootForTesting.editModeController.recipe)
        let deadline = Date().addingTimeInterval(2)
        while await recipe.operations.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let seen = await probe.waitForModified("s.jpg")
        XCTAssertTrue(seen, "a Browser on the folder must hear the save, to refresh the thumbnail")
    }

    func testViewerRotateIsSeenByAnotherWatcher() async throws {
        let url = dir.appendingPathComponent("r.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = SaveFlowTests.image()
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        viewer.dispatch(.rotateRight)
        await viewer.waitForOrientationWrites()
        let seen = await probe.waitForModified("r.jpg")
        XCTAssertTrue(seen)
    }

    func testViewerRevertAndUndoAreSeenByAnotherWatcher() async throws {
        let url = dir.appendingPathComponent("v.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        _ = try await store.backup(url, reason: .save)
        try SaveFlowTests.writeImage(url, type: .png) // different bytes, kept as v.jpg
        let viewer = await viewer(url)
        defer { viewer.close() }
        viewer.alertResponderForTesting = { _ in 1 }
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        _ = await waitUntil { viewer.isDisplayedEdited }
        viewer.revertDisplayedToOriginal()
        let reverted = await probe.waitForModified("v.jpg")
        XCTAssertTrue(reverted, "Revert is seen by another watcher")
        let afterRevert = await waitUntil { !viewer.isDisplayedEdited }
        XCTAssertTrue(afterRevert)
        try await Task.sleep(for: .milliseconds(1500))
        let probe2 = try Probe(folder: dir)
        defer { probe2.stop() }
        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        let undone = await probe2.waitForModified("v.jpg")
        XCTAssertTrue(undone, "Undo of the revert is seen by another watcher")
    }

    // MARK: Browser

    func testBrowserRotateAndUndoAreSeenByAnotherWatcher() async throws {
        let url = dir.appendingPathComponent("b.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let browser = await browser()
        defer { browser.close() }
        browser.contentController.selectAll()
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        browser.perform(.rotateRight)
        await browser.waitForOrientationWrites()
        let seen = await probe.waitForModified("b.jpg")
        XCTAssertTrue(seen, "a second Browser must hear the rotate")
        try await Task.sleep(for: .milliseconds(1500))
        let probe2 = try Probe(folder: dir)
        defer { probe2.stop() }
        let undo = try XCTUnwrap(browser.window?.undoManager)
        undo.undo()
        await browser.waitForOrientationWrites()
        let undone = await probe2.waitForModified("b.jpg")
        XCTAssertTrue(undone, "a second Browser must hear the undo")
    }

    func testBrowserRevertIsSeenByAnotherWatcher() async throws {
        let a = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        _ = try await store.backup(a, reason: .save)
        try SaveFlowTests.writeImage(a, type: .png)
        let browser = await browser()
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.contains { $0.edited } }
        browser.alertResponderForTesting = { _ in 1 }
        XCTAssertTrue(browser.contentController.select(urls: [a]))
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        browser.perform(.revertToOriginal)
        await browser.revertTask?.value
        let seen = await probe.waitForModified("a.jpg")
        XCTAssertTrue(seen)
    }

    // MARK: FileOps (trash / move / rename / copy)

    func testBrowserRenameIsSeenByAnotherWatcher() async throws {
        let a = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        let browser = await browser()
        defer { browser.close() }
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        _ = try await browser.fileOps.rename(ImageGroup(primary: a), toStem: "renamed")
        let seen = await probe.waitForRename("a.jpg>renamed.jpg")
        XCTAssertTrue(seen, "a second window on the folder must hear the rename")
    }

    func testViewerRenameIsSeenByAnotherWatcher() async throws {
        let a = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        let viewer = await viewer(a)
        defer { viewer.close() }
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        _ = try await viewer.fileOps.rename(ImageGroup(primary: a), toStem: "renamed")
        let seen = await probe.waitForRename("a.jpg>renamed.jpg")
        XCTAssertTrue(seen)
    }

    // MARK: Compare

    func testCompareRotateIsSeenByAnotherWatcher() async throws {
        let urls = try ["c1.jpg", "c2.jpg"].map { name -> URL in
            let u = dir.appendingPathComponent(name)
            try SaveFlowTests.writeImage(u, type: .jpeg)
            return u
        }
        CompareWindow.presentsWindows = false
        defer { CompareWindow.current?.close(); CompareWindow.presentsWindows = true }
        let window = CompareWindow.open(
            CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: services(), origin: nil, frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        let loaded = await waitUntil { window.panes.allSatisfy { $0.view.imageView.image != nil } }
        XCTAssertTrue(loaded)
        let probe = try Probe(folder: dir)
        defer { probe.stop() }
        window.rotateFocused(.rotate(quarters: 1))
        await window.waitForOrientationWrites()
        let seen = await probe.waitForModified("c1.jpg")
        XCTAssertTrue(seen, "the Browser must hear a rotate done in Compare")
    }

    // Compare tells its origin directly, so the origin's watcher ignores
    // Compare's writes; another window's watcher does not.
    func testCompareIgnoresItsOriginsWatcherOnly() async throws {
        let urls = try ["o1.jpg", "o2.jpg"].map { name -> URL in
            let u = dir.appendingPathComponent(name)
            try SaveFlowTests.writeImage(u, type: .jpeg)
            return u
        }
        let browser = await browser(count: 2)
        defer { browser.close() }
        CompareWindow.presentsWindows = false
        defer { CompareWindow.current?.close(); CompareWindow.presentsWindows = true }
        let window = CompareWindow.open(
            CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: services(), origin: browser, frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        let watcher = try XCTUnwrap(browser.folderWatcher)
        XCTAssertTrue(window.watcherScope.watchers.contains { $0 === watcher })
        window.origin = nil
        XCTAssertTrue(window.watcherScope.watchers.isEmpty)
    }

    // MARK: Tags and ratings

    func testTagWriteIsSeenByAnotherWatcherButNotByTheWindowsOwn() async throws {
        let a = dir.appendingPathComponent("t.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        let own = try FolderWatcher(folder: dir)
        let probe = try Probe(folder: dir)
        defer { own.stop(); probe.stop() }
        var ownHeard = Set<String>()
        let t = Task { for await c in own.changes { ownHeard.formUnion(c.modified.map(\.lastPathComponent)) } }
        defer { t.cancel() }
        let scope = WindowWatcherScope()
        scope.setWatcher(own)
        let done = expectation(description: "tag landed")
        TagEditSession.enqueue([FinderTagEdit(url: a, change: .set(["Venice"]))], suppressing: scope,
                               onError: { _ in }, landed: { done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        let seen = await probe.waitForModified("t.jpg")
        XCTAssertTrue(seen, "another window sees the xattr change")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(ownHeard.isEmpty)
    }

    func testRatingWriteIgnoresOnlyTheGivenSuppressor() async throws {
        let a = dir.appendingPathComponent("q.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        let scoped = RecordingSuppressor()
        let wrote = expectation(description: "rating written")
        CullingUndo.perform(
            .rating, urls: [a], store: ShrikeServices.makeDefault().metadataStore, undoManager: nil,
            compute: { Culling.ratingValues(3, urls: [a], previous: $0) },
            onChange: { _ in wrote.fulfill() }, suppressing: scoped)
        await fulfillment(of: [wrote], timeout: 5)
        XCTAssertEqual(scoped.paths, [a])
    }
}

//
//  TrashPathsTests.swift
//  ShrikeUITests
//
//  Spec 25 §5.1 and §12.3: every way to trash shows the Undo toast, and a
//  right-click on a strip cell trashes that cell's photo. A fake Trash (a
//  temp folder) stands in for the user's Trash; no real file goes there.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class TrashPathsTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var fakeTrash: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-trashpaths-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Folder", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func makeFiles(_ count: Int, real: Bool = false) throws -> [URL] {
        try (1...count).map { i in
            let url = dir.appendingPathComponent(String(format: "img%02d.jpg", i))
            if real {
                _ = try SaveFlowTests.writeImage(url, type: .jpeg)
            } else {
                try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            }
            return url
        }
    }

    private func fakeOps() -> FileOps {
        let trash = fakeTrash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
    }

    private func services() -> ShrikeServices {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        return services
    }

    private func viewer(_ urls: [URL], start: Int = 0) -> ViewerWindow {
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: start,
                                  services: services())
        viewer.fileOps = fakeOps()
        viewer.markDisplayedForTesting(start)
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The Trash ran for `url` and the toast offers Undo.
    private func assertTrashedWithUndo(_ url: URL, host: ToastHostView, _ path: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(path): file trashed",
                       file: file, line: line)
        XCTAssertEqual(host.actionTitleForTesting, "Undo", "\(path): Undo toast", file: file, line: line)
        XCTAssertEqual(host.content?.message, "Moved “\(url.lastPathComponent)” to the Trash.", path,
                       file: file, line: line)
    }

    private func send(_ item: NSMenuItem, to target: AnyObject) {
        _ = NSApp.sendAction(item.action!, to: target, from: item)
    }

    // MARK: Viewer

    func testViewerFileMenuTrashShowsTheUndoToast() async throws {
        let urls = try makeFiles(3)
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let item = try XCTUnwrap(bar.items(for: .moveToTrash).first)
        XCTAssertTrue(viewer.validateMenuItem(item))
        viewer.performShrikeCommand(item)
        await viewer.waitForPendingTrash()
        assertTrashedWithUndo(urls[1], host: viewer.contentRootForTesting.toastHost, "File menu")
    }

    func testViewerContextMenuTrashShowsTheUndoToast() async throws {
        let urls = try makeFiles(3)
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let item = try XCTUnwrap(viewer.contextMenu.menu.items.first { $0.title == "Move to Trash" })
        viewer.performShrikeCommand(item)
        await viewer.waitForPendingTrash()
        assertTrashedWithUndo(urls[1], host: viewer.contentRootForTesting.toastHost, "context menu")
    }

    func testViewerToolbarTrashButtonShowsTheUndoToast() async throws {
        let urls = try makeFiles(3)
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        let bar = try XCTUnwrap(viewer.toolbarController)
        bar.toolbar.autosavesConfiguration = false
        let item = try XCTUnwrap(bar.toolbar.items.first { $0.itemIdentifier == ViewerWindowToolbar.ID.trash }
            ?? bar.item(ViewerWindowToolbar.ID.trash)
            ?? bar.toolbar(bar.toolbar, itemForItemIdentifier: ViewerWindowToolbar.ID.trash,
                           willBeInsertedIntoToolbar: true))
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), "the Trash button runs")
        await viewer.waitForPendingTrash()
        assertTrashedWithUndo(urls[1], host: viewer.contentRootForTesting.toastHost, "toolbar button")
    }

    func testFullScreenCapsuleTrashShowsTheUndoToast() async throws {
        let urls = try makeFiles(3)
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(content.toolbarForTesting.buttonWithIdentifierForTesting("toolbar.deleteToTrash"))
        button.performClick(nil)
        await viewer.waitForPendingTrash()
        assertTrashedWithUndo(urls[1], host: content.toastHost, "full-screen capsule")
    }

    // MARK: Strip right-click (§12.2, §12.3 vector 3)

    func testRightClickOnAStripCellMakesItTheDisplayedPhotoAndTrashesIt() async throws {
        let urls = try makeFiles(6, real: true)
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        await viewer.updateFilmstrip(centeredOn: 0)
        let strip = viewer.contentRootForTesting.filmstripForTesting
        let menu = try XCTUnwrap(strip.rightClickMenuForTesting(4), "the strip shows photo 5")
        // The right-click took the viewer to photo 5 (it paints after the decode).
        let shown = await waitUntil { viewer.displayedItem?.group.primary == urls[4] }
        XCTAssertTrue(shown, "photo 5 is shown: \(String(describing: viewer.displayedItem?.group.primary))")
        // The menu is the viewer's own, and its Trash row acts on the displayed photo.
        menu.delegate?.menuNeedsUpdate?(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Move to Trash" })
        viewer.performShrikeCommand(item)
        await viewer.waitForPendingTrash()
        assertTrashedWithUndo(urls[4], host: viewer.contentRootForTesting.toastHost, "strip right-click")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), "photo 1 stays")
    }

    // MARK: Browser

    func testBrowserFileMenuAndContextMenuTrashShowTheUndoToast() async throws {
        let urls = try makeFiles(4)
        let browser = BrowserWindowController(services: services(), initialFolder: dir)
        defer { browser.close() }
        browser.fileOps = fakeOps()
        let content = browser.contentController
        let listed = await waitUntil { content.visibleItems.count == 4 }
        XCTAssertTrue(listed)

        // File menu.
        XCTAssertTrue(content.select(url: urls[0]))
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let fileItem = try XCTUnwrap(bar.items(for: .moveToTrash).first)
        XCTAssertTrue(browser.validateMenuItem(fileItem))
        browser.performShrikeCommand(fileItem)
        await browser.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path), "File menu")
        XCTAssertEqual(browser.toastHost.actionTitleForTesting, "Undo", "File menu: Undo toast")

        // Context menu.
        browser.toastHost.dismiss(animated: false)
        XCTAssertTrue(content.select(url: urls[1]))
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        let item = try XCTUnwrap(menu.items.first { $0.title == "Move to Trash" })
        send(item, to: try XCTUnwrap(item.target))
        await browser.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path), "context menu")
        XCTAssertEqual(browser.toastHost.actionTitleForTesting, "Undo", "context menu: Undo toast")
    }
}

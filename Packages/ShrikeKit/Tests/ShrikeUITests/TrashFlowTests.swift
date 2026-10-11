//
//  TrashFlowTests.swift
//  ShrikeUITests
//
//  Delete to Trash in the viewer and
//  the Browser. A fake Trash (a temp folder) stands in for the user's
//  Trash through `FileOps`'s `trashItem:` test seam — no real file ever
//  goes to the user's Trash.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class TrashFlowTests: XCTestCase {

    private var dir: URL!
    private var fakeTrash: URL!

    override func setUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-trash-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func makeFiles(_ names: [String]) throws -> [URL] {
        let urls = names.map { dir.appendingPathComponent($0) }
        for url in urls { try Data([0xFF, 0xD8, 0xFF]).write(to: url) }
        return urls
    }

    private func fakeOps(noTrash: Bool = false) -> FileOps {
        let trash = fakeTrash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            if noTrash { throw FileOpsError.noTrash(volumeName: "NAS", url: url) }
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

    private func viewer(_ urls: [URL], start: Int, ops: FileOps) -> ViewerWindow {
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: start,
                                  services: services())
        viewer.fileOps = ops
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

    // Image 5 of 10, ⌫ → image 6 at once, "5 / 9"; ⌘Z → back at 5.
    func testTrashRemovesInTheSameTurnAndUndoPutsItBack() async throws {
        let urls = try makeFiles((1...10).map { String(format: "img%02d.jpg", $0) })
        let viewer = viewer(urls, start: 4, ops: fakeOps())
        defer { viewer.close() }
        viewer.dispatch(.deleteToTrash)
        // Same main-actor turn: the list already moved on.
        XCTAssertEqual(viewer.groups.count, 9)
        XCTAssertEqual(viewer.groups[4].primary.lastPathComponent, "img06.jpg")
        XCTAssertNil(viewer.displayedItem, "nothing stale is labelled as shown")
        await viewer.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[4].path))
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Move to Trash")

        viewer.performUndo()
        let back = await waitUntil { viewer.groups.count == 10 }
        XCTAssertTrue(back)
        XCTAssertEqual(viewer.groups[4].primary.lastPathComponent, "img05.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[4].path))
    }

    // MARK: - Filmstrip follows deletes

    private func stripNames(_ viewer: ViewerWindow) -> [String] {
        let map = viewer.contentRootForTesting.filmstripForTesting.cellFileNamesForTesting
        return map.keys.sorted().map { map[$0]! }
    }

    private func pillText(_ viewer: ViewerWindow) -> String {
        viewer.contentRootForTesting.navigationPositionOverlayForTesting
            .labelTextForTesting.string
    }

    private func names(_ viewer: ViewerWindow) -> [String] {
        viewer.groups.map(\.primary.lastPathComponent)
    }

    // Delete drops the cell at once, the pill count follows, undo re-adds it.
    func testFilmstripDropsDeletedCellAndPillCountFollows_undoBringsItBack() async throws {
        let urls = try makeFiles((1...10).map { String(format: "img%02d.jpg", $0) })
        let viewer = viewer(urls, start: 4, ops: fakeOps())
        defer { viewer.close() }
        await viewer.updateFilmstrip(centeredOn: 4)
        XCTAssertEqual(stripNames(viewer), names(viewer))

        viewer.dispatch(.deleteToTrash)
        let dropped = await waitUntil { self.stripNames(viewer) == self.names(viewer) && viewer.groups.count == 9 }
        XCTAssertTrue(dropped, "strip: \(stripNames(viewer))")
        XCTAssertFalse(stripNames(viewer).contains("img05.jpg"))
        let pill = await waitUntil { self.pillText(viewer).hasPrefix("5 / 9") }
        XCTAssertTrue(pill, pillText(viewer))

        await viewer.waitForPendingTrash()
        viewer.performUndo()
        let back = await waitUntil { viewer.groups.count == 10 && self.stripNames(viewer) == self.names(viewer) }
        XCTAssertTrue(back, "strip: \(stripNames(viewer))")
        XCTAssertTrue(stripNames(viewer).contains("img05.jpg"))
        let pill10 = await waitUntil { self.pillText(viewer).hasPrefix("5 / 10") }
        XCTAssertTrue(pill10, pillText(viewer))
    }

    // Several deletes in a row, the last photo, and a RAW+JPEG group.
    func testFilmstripAfterSeveralDeletesAndAPairedGroup() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg", "p.cr2", "p.jpg"])
        let groups = [urls[0], urls[1], urls[2], urls[3], urls[4]].map { ImageGroup(primary: $0) }
            + [ImageGroup(primary: urls[6], companions: [.init(url: urls[5], kind: .raw)])]
        let viewer = ViewerWindow(groups: groups, startIndex: 1, services: services())
        viewer.fileOps = fakeOps()
        defer { viewer.close() }
        viewer.markDisplayedForTesting(1)
        await viewer.updateFilmstrip(centeredOn: 1)

        viewer.dispatch(.deleteToTrash)            // b
        viewer.markDisplayedForTesting(1)
        viewer.dispatch(.deleteToTrash)            // c
        let two = await waitUntil { self.stripNames(viewer) == ["a.jpg", "d.jpg", "e.jpg", "p.jpg"] }
        XCTAssertTrue(two, "strip: \(stripNames(viewer))")
        XCTAssertTrue(self.pillText(viewer).isEmpty == false)

        viewer.markDisplayedForTesting(3)
        viewer.dispatch(.deleteToTrash)            // the RAW+JPEG group, last
        let three = await waitUntil { self.stripNames(viewer) == ["a.jpg", "d.jpg", "e.jpg"] }
        XCTAssertTrue(three, "strip: \(stripNames(viewer))")
        await viewer.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[5].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[6].path))
        let pill = await waitUntil { self.pillText(viewer).hasPrefix("3 / 3") }
        XCTAssertTrue(pill, pillText(viewer))
    }

    // Browser: grid, filmstrip and list all drop the trashed items, and
    // undo brings them back.
    func testBrowserViewsDropTrashedItemsInEveryMode() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.jpg"])
        let browser = BrowserWindowController(services: services(), initialFolder: dir)
        defer { browser.close() }
        browser.fileOps = fakeOps()
        let content = browser.contentController
        let listed = await waitUntil { content.visibleItems.count == 5 }
        XCTAssertTrue(listed)

        for mode in [BrowserViewMode.grid, .filmstrip, .list] {
            content.setMode(mode)
            let toTrash = content.visibleItems.filter { $0.url == urls[1] || $0.url == urls[2] }
            XCTAssertEqual(toTrash.count, 2, "\(mode)")
            browser.trash(toTrash)
            await browser.waitForPendingTrash()
            XCTAssertEqual(content.visibleItems.map(\.url.lastPathComponent), ["a.jpg", "d.jpg", "e.jpg"], "\(mode)")
            switch mode {
            case .grid, .filmstrip:
                XCTAssertEqual(content.collectionViewForTesting.numberOfItems(inSection: 0), 3, "\(mode)")
            case .list:
                XCTAssertEqual(content.tableViewForTesting.numberOfRows, 3)
            }
            // Put them back for the next mode.
            browser.window?.undoManager?.undo()
            let back = await waitUntil { content.visibleItems.count == 5 }
            XCTAssertTrue(back, "undo in \(mode)")
        }
    }

    // Presses queue in order; each targets the item shown at press time.
    func testQueuedPressesEachTargetTheItemShownThen() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        let viewer = viewer(urls, start: 1, ops: fakeOps())
        defer { viewer.close() }
        viewer.dispatch(.deleteToTrash)          // b
        viewer.markDisplayedForTesting(1)        // c is painted
        viewer.dispatch(.deleteToTrash)          // c
        await viewer.waitForPendingTrash()
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "d.jpg"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[2].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[3].path))
    }

    // Last of 3, ⌫ three times → empty state; ⌘Z brings one back.
    func testEmptyStateAndUndoFromIt() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 2, ops: fakeOps())
        defer { viewer.close() }
        let before = viewer.contentRootForTesting.emptyStateChromeHiddenForTesting
        for _ in 0..<3 {
            viewer.markDisplayedForTesting(viewer.groups.count - 1)
            viewer.dispatch(.deleteToTrash)
        }
        await viewer.waitForPendingTrash()
        XCTAssertTrue(viewer.groups.isEmpty)
        XCTAssertTrue(viewer.isShowingEmptyState)
        XCTAssertEqual(viewer.emptyStateView?.title, "No more images in “Italy 2026”.")
        // The empty state hides the pill, filmstrip, histogram, badge.
        let empty = viewer.contentRootForTesting.emptyStateChromeHiddenForTesting
        XCTAssertTrue(empty.pill && empty.filmstrip && empty.histogram && empty.badge)

        viewer.performUndo()
        let back = await waitUntil { viewer.groups.count == 1 }
        XCTAssertTrue(back)
        XCTAssertEqual(viewer.groups.first?.primary.lastPathComponent, "a.jpg")
        XCTAssertFalse(viewer.isShowingEmptyState)
        let after = viewer.contentRootForTesting.emptyStateChromeHiddenForTesting
        XCTAssertEqual(after.filmstrip, before.filmstrip, "the filmstrip comes back as it was")
        XCTAssertEqual(after.histogram, before.histogram)
    }

    // No Trash on the volume → the permanent-delete alert; Cancel puts it back.
    func testNoTrashAlertCancelPutsTheItemBack() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg"])
        let viewer = viewer(urls, start: 0, ops: fakeOps(noTrash: true))
        defer { viewer.close() }
        var asked: String?
        viewer.alertResponderForTesting = { message in asked = message; return 1 }  // Cancel
        viewer.dispatch(.deleteToTrash)
        XCTAssertEqual(viewer.groups.count, 1)
        await viewer.waitForPendingTrash()
        XCTAssertEqual(asked, "“a.jpg” can't be moved to the Trash.")
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path))
    }

    // (copy): a pair names its RAW file.
    func testPairToastCopy() {
        let pair = ImageGroup(primary: URL(fileURLWithPath: "/x/P1.JPG"),
                              companions: [.init(url: URL(fileURLWithPath: "/x/P1.ORF"), kind: .raw)])
        XCTAssertEqual(FileActionCopy.movedToTrash([pair]), "Moved “P1.JPG” and its RAW file to the Trash.")
        XCTAssertEqual(FileActionCopy.movedToTrash([pair, pair]), "Moved 2 items to the Trash.")
        XCTAssertEqual(FileActionCopy.putBack(original: pair, restored: ImageGroup(primary: URL(fileURLWithPath: "/x/P1 2.JPG"))),
                       "Put back as “P1 2.JPG”.")
    }

    // (files): both members of a pair go to the Trash.
    func testTrashingAPairMovesBothFiles() async throws {
        let urls = try makeFiles(["P1.JPG", "P1.ORF", "P2.JPG"])
        let groups = [ImageGroup(primary: urls[0], companions: [.init(url: urls[1], kind: .raw)]),
                      ImageGroup(primary: urls[2])]
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services())
        defer { viewer.close() }
        viewer.fileOps = fakeOps()
        viewer.markDisplayedForTesting(0)
        viewer.dispatch(.deleteToTrash)
        await viewer.waitForPendingTrash()
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: urls[1].path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fakeTrash.path).count, 2)
    }

    // FastStone viewer — ⌫ is Previous, ⌦ trashes. Mac: ⌫ trashes.
    func testTrashKeysPerPreset() {
        let back = KeyEventSnapshot(key: SpecialKey.backspace)
        let forward = KeyEventSnapshot(key: SpecialKey.forwardDelete)
        XCTAssertEqual(ViewerKeyMap.action(for: back, context: .viewer, preset: .fastStoneCompat, chordPrefix: nil), .prevImage)
        XCTAssertEqual(ViewerKeyMap.action(for: forward, context: .viewer, preset: .fastStoneCompat, chordPrefix: nil), .deleteToTrash)
        XCTAssertEqual(ViewerKeyMap.action(for: back, context: .viewer, preset: .macNative, chordPrefix: nil), .deleteToTrash)
    }

    // Browser: the selection moves to the item after the last removed one.
    func testBrowserSelectionAfterRemoval() {
        let u = ["a", "b", "c", "d", "e"].map { URL(fileURLWithPath: "/x/\($0).jpg") }
        XCTAssertEqual(BrowserWindowController.selectionAfterRemoving([u[1], u[2]], from: u), u[3])
        XCTAssertEqual(BrowserWindowController.selectionAfterRemoving([u[3], u[4]], from: u), u[2])
        XCTAssertEqual(BrowserWindowController.selectionAfterRemoving([u[1], u[3]], from: u), u[4])
        XCTAssertNil(BrowserWindowController.selectionAfterRemoving(u, from: u))
    }
}

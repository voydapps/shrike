//
//  TransferFlowTests.swift
//  ShrikeUITests
//
//  The `C` / `M` chord, its HUD,
//  destination slots, name clashes, and Copy / Move with one undo step.
//  Temp folders only; slots live in a throwaway defaults suite; a fake
//  Trash folder stands in for the user's Trash.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class TransferFlowTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var selects: URL!
    private var fakeTrash: URL!
    private var slots: DestinationSlots!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-transfer-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        selects = root.appendingPathComponent("Selects", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        for folder in [dir!, selects!, fakeTrash!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        slots = DestinationSlots(defaults: makeTestDefaults())
        FileTransferCoordinator.hudDelay = .milliseconds(250)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFiles(_ names: [String], in folder: URL? = nil) throws -> [URL] {
        let urls = names.map { (folder ?? dir).appendingPathComponent($0) }
        for url in urls { try Data([0xFF, 0xD8, 0xFF]).write(to: url) }
        return urls
    }

    private func fakeOps() -> FileOps {
        let trash = fakeTrash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
    }

    private func viewer(_ urls: [URL], start: Int) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: start,
                                  services: services)
        viewer.fileOps = fakeOps()
        viewer.transfers.slots = slots
        viewer.markDisplayedForTesting(start)
        return viewer
    }

    private func key(_ k: String, _ mods: NSEvent.ModifierFlags = []) -> ShrikeUI.KeyEventSnapshot {
        ShrikeUI.KeyEventSnapshot(key: k, modifiers: mods)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Chord resolver

    func testChordFollowups() {
        func resolve(_ k: String, _ mods: NSEvent.ModifierFlags = [], chord: Character) -> ViewerAction? {
            ViewerKeyMap.action(for: key(k, mods), context: .viewer, preset: .macNative, chordPrefix: chord)
        }
        XCTAssertEqual(resolve("1", chord: "m"), .fileToFolder(.move, .slot(1)))
        XCTAssertEqual(resolve("m", chord: "m"), .fileToFolder(.move, .last))
        XCTAssertEqual(resolve("c", chord: "c"), .fileToFolder(.copy, .last))
        XCTAssertEqual(resolve("0", chord: "c"), .fileToFolder(.copy, .choose))
        XCTAssertEqual(resolve("4", .option, chord: "c"), .fileToFolder(.copy, .rechoose(4)))
        XCTAssertEqual(resolve("\u{1b}", chord: "m"), .cancelChord)
        XCTAssertNil(resolve("c", chord: "m"), "another letter passes through")
        XCTAssertNil(resolve("\u{F703}", chord: "m"))
        XCTAssertEqual(BrowserKeyMap.action(for: key("2"), chordPrefix: "m"), .fileToFolder(.move, .slot(2)))
    }

    // MARK: HUD after 250 ms; `M 1` fast draws none.

    func testHUDAppearsAfterDelayButNotForAFastChord() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        slots.set(1, folder: selects)
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }

        viewer.handleKeySnapshot(key("m"))
        XCTAssertFalse(viewer.transfers.isHUDVisible)
        let shown = await waitUntil(1) { viewer.transfers.isHUDVisible }
        XCTAssertTrue(shown)
        XCTAssertEqual(viewer.transfers.hud?.rowTitles.first, "Selects, " + (selects.path as NSString).abbreviatingWithTildeInPath)
        viewer.handleKeySnapshot(key("\u{1b}"))
        XCTAssertFalse(viewer.transfers.isHUDVisible)
        XCTAssertNil(viewer.chordPrefix)
        XCTAssertEqual(viewer.groups.count, 3, "Esc only cancels")

        let before = viewer.transfers.hudShownCount
        viewer.handleKeySnapshot(key("m"))
        viewer.handleKeySnapshot(key("1"))
        XCTAssertEqual(viewer.groups.count, 2, "the move leaves the list in the same turn")
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(viewer.transfers.hudShownCount, before, "no HUD for a fast chord")
        await viewer.waitForPendingFileWork()
        XCTAssertTrue(exists(selects.appendingPathComponent("a.jpg")))
        XCTAssertFalse(exists(urls[0]))
    }

    // MARK: `M` then `→`: the HUD closes, the next image shows.

    func testOtherKeyCancelsChordAndIsHandled() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        viewer.handleKeySnapshot(key("m"))
        _ = await waitUntil(1) { viewer.transfers.isHUDVisible }
        XCTAssertTrue(viewer.handleKeySnapshot(key("\u{F703}")))
        XCTAssertNil(viewer.chordPrefix)
        XCTAssertFalse(viewer.transfers.isHUDVisible)
        let advanced = await waitUntil(2) { viewer.intent.currentIndex == 1 }
        XCTAssertTrue(advanced, "→ still navigates after cancelling the chord")
        XCTAssertEqual(viewer.groups.count, 3)
    }

    // MARK: Move / copy with undo

    func testMoveLeavesListAndUndoPutsItBack() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg", "c.jpg"])
        slots.set(2, folder: selects)
        let viewer = viewer(urls, start: 1)
        defer { viewer.close() }
        viewer.dispatch(.fileToFolder(.move, .slot(2)))
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["a.jpg", "c.jpg"])
        await viewer.waitForPendingFileWork()
        XCTAssertTrue(exists(selects.appendingPathComponent("b.jpg")))
        XCTAssertEqual(viewer.contentRoot.toastHost.content?.message, "Moved “b.jpg” to “Selects”.")
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Move")
        XCTAssertEqual(slots.last(.move)?.lastPathComponent, "Selects")

        viewer.performUndo()
        let back = await waitUntil { viewer.groups.count == 3 }
        XCTAssertTrue(back)
        XCTAssertEqual(viewer.groups[1].primary.lastPathComponent, "b.jpg")
        XCTAssertTrue(exists(urls[1]))
        XCTAssertFalse(exists(selects.appendingPathComponent("b.jpg")))
    }

    func testCopyKeepsItemAndUndoTrashesTheCopy() async throws {
        let urls = try makeFiles(["a.jpg", "b.jpg"])
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        var asked: String?
        viewer.transfers.panelResponder = { title in asked = title; return self.selects }
        viewer.dispatch(.fileToFolder(.copy, .slot(3)))   // empty slot → panel
        await viewer.waitForPendingFileWork()
        _ = await waitUntil { self.exists(self.selects.appendingPathComponent("a.jpg")) }
        await viewer.waitForPendingFileWork()
        XCTAssertEqual(asked, "Choose a folder for slot 3")
        XCTAssertEqual(slots.slot(3)?.name, "Selects", "the chosen folder is saved in the slot")
        XCTAssertEqual(viewer.groups.count, 2, "a copied item stays")
        XCTAssertTrue(exists(urls[0]))
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Copy")

        viewer.performUndo()
        let gone = await waitUntil { !self.exists(self.selects.appendingPathComponent("a.jpg")) }
        XCTAssertTrue(gone)
        XCTAssertTrue(exists(urls[0]))
    }

    func testDestinationIsCurrentFolder() async throws {
        let urls = try makeFiles(["a.jpg"])
        slots.set(1, folder: dir)
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        viewer.dispatch(.fileToFolder(.move, .slot(1)))
        XCTAssertEqual(viewer.contentRoot.toastHost.content?.message, "“a.jpg” is already in “Italy 2026”.")
        XCTAssertEqual(viewer.groups.count, 1)
        XCTAssertFalse(viewer.undoManagerForTesting.canUndo)
    }

    // Alert A2: the slot's folder is gone; Clear Slot empties it.
    func testUnavailableSlotAlert() async throws {
        let urls = try makeFiles(["a.jpg"])
        let client = root.appendingPathComponent("Client", isDirectory: true)
        try FileManager.default.createDirectory(at: client, withIntermediateDirectories: true)
        slots.set(4, folder: client)
        try FileManager.default.removeItem(at: client)
        let viewer = viewer(urls, start: 0)
        defer { viewer.close() }
        var asked: String?
        viewer.alertResponderForTesting = { message in asked = message; return 1 }  // Clear Slot
        viewer.dispatch(.fileToFolder(.copy, .slot(4)))
        let answered = await waitUntil { asked != nil && self.slots.slot(4) == nil }
        XCTAssertTrue(answered)
        XCTAssertEqual(asked, "“Client” is not available.")
        XCTAssertTrue(exists(urls[0]))
    }

    // MARK: "Do this for the remaining 2 conflicts" + Keep Both.

    func testConflictKeepBothForAllRenamesPairsTogether() async throws {
        let names = ["x.jpg", "x.ORF", "y.jpg", "z.jpg"]
        let sources = try makeFiles(names)
        _ = try makeFiles(names, in: selects)
        let groups = [
            ImageGroup(primary: sources[0], companions: [.init(url: sources[1], kind: .raw)]),
            ImageGroup(primary: sources[2]),
            ImageGroup(primary: sources[3]),
        ]
        let coordinator = FileTransferCoordinator(window: nil)
        var remaining: [Int] = []
        coordinator.conflictResponder = { conflict in
            remaining.append(conflict.remainingConflicts)
            return ConflictAnswer(.keepBoth, applyToRemaining: true)
        }
        let outcome = await coordinator.run(.copy, groups, to: selects, ops: fakeOps())
        XCTAssertEqual(remaining, [2], "asked once, with 2 more pending")
        XCTAssertEqual(outcome.items.count, 3)
        for name in ["x 2.jpg", "x 2.ORF", "y 2.jpg", "z 2.jpg"] {
            XCTAssertTrue(exists(selects.appendingPathComponent(name)), name)
        }
        XCTAssertEqual(FileTransferCopy.applyToRemaining(2), "Do this for the remaining 2 conflicts")
    }

    func testCopyLines() {
        let one = [ImageGroup(primary: URL(fileURLWithPath: "/p/DSC_0042.jpg"))]
        let three = (1...3).map { ImageGroup(primary: URL(fileURLWithPath: "/p/\($0).jpg")) }
        XCTAssertEqual(FileTransferCopy.done(.move, one, folder: selects), "Moved “DSC_0042.jpg” to “Selects”.")
        XCTAssertEqual(FileTransferCopy.done(.copy, three, folder: selects), "Copied 3 items to “Selects”.")
        XCTAssertEqual(FileTransferCopy.progress(.copy, completed: 2, total: 12), "Copying 3 of 12…")
        XCTAssertEqual(FileTransferCopy.cancelled(.copy, done: 3, total: 12),
                       "Copied 3 of 12 items. The rest were cancelled.")
        XCTAssertEqual(FileTransferCopy.conflictTitle("DSC_0042.jpg", folder: selects),
                       "“DSC_0042.jpg” already exists in “Selects”.")
    }

    // MARK: "Show both files"

    private func names(_ folder: URL) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .map { $0.components(separatedBy: "-").last ?? $0 })
    }

    /// Trash, Copy and Move act on the item's own files (the image and its
    /// attached companions), never on the pair's other image.
    func testShowBothFilesActsOnTheItemsOwnFilesOnly() async throws {
        _ = try makeFiles(["P1.JPG", "P1.ORF", "P1.xmp", "P1.MOV", "P2.JPG"])
        let groups = try await FolderScanner.imageGroups(in: dir, grouping: .showBothFiles)
        XCTAssertEqual(groups.map(\.primary.lastPathComponent), ["P1.JPG", "P1.ORF", "P2.JPG"])
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.fileOps = fakeOps()
        viewer.transfers.slots = slots
        slots.set(2, folder: selects)
        viewer.markDisplayedForTesting(0)

        // Copy the JPEG item: the JPEG and its Live Photo movie, not the RAW.
        viewer.dispatch(.fileToFolder(.copy, .slot(2)))
        await viewer.waitForPendingFileWork()
        _ = await waitUntil { self.names(self.selects).count == 2 }
        XCTAssertEqual(names(selects), ["P1.JPG", "P1.MOV"])
        for name in ["P1.JPG", "P1.MOV"] {
            try FileManager.default.removeItem(at: selects.appendingPathComponent(name))
        }

        // Trash the JPEG item: the RAW and its XMP stay, and stay listed.
        viewer.dispatch(.deleteToTrash)
        await viewer.waitForPendingTrash()
        XCTAssertEqual(names(fakeTrash), ["P1.JPG", "P1.MOV"])
        XCTAssertTrue(exists(dir.appendingPathComponent("P1.ORF")))
        XCTAssertTrue(exists(dir.appendingPathComponent("P1.xmp")))
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["P1.ORF", "P2.JPG"])
        XCTAssertEqual(viewer.contentRoot.toastHost.content?.message, "Moved “P1.JPG” to the Trash.")
        viewer.markDisplayedForTesting(0)   // P1.ORF is painted

        // Move the RAW item: the RAW and its XMP; P2 is untouched.
        viewer.dispatch(.fileToFolder(.move, .slot(2)))
        await viewer.waitForPendingFileWork()
        _ = await waitUntil { self.names(self.selects).count == 2 }
        XCTAssertEqual(names(selects), ["P1.ORF", "P1.xmp"])
        XCTAssertTrue(exists(dir.appendingPathComponent("P2.JPG")))
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["P2.JPG"])
    }

    /// The Browser in "Show both files": trashing the RAW item leaves the
    /// JPEG and its movie in place.
    func testBrowserShowBothFilesTrashesPerFile() async throws {
        let before = ImageGroupingPreference.isEnabled
        ImageGroupingPreference.isEnabled = false
        defer { ImageGroupingPreference.isEnabled = before }
        _ = try makeFiles(["P1.JPG", "P1.ORF", "P1.xmp", "P1.MOV"])
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        defer { browser.close() }
        browser.fileOps = fakeOps()
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(loaded)
        let raw = try XCTUnwrap(browser.contentController.visibleItems.first { $0.url.pathExtension == "ORF" })
        XCTAssertEqual(raw.group.allURLs.map(\.lastPathComponent), ["P1.ORF", "P1.xmp"])
        browser.trash([raw])
        await browser.waitForPendingTrash()
        XCTAssertEqual(names(fakeTrash), ["P1.ORF", "P1.xmp"])
        XCTAssertTrue(exists(dir.appendingPathComponent("P1.JPG")))
        XCTAssertTrue(exists(dir.appendingPathComponent("P1.MOV")))
    }
}

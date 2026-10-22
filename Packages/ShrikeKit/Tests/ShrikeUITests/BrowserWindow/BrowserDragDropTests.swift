//
//  BrowserDragDropTests.swift
//  ShrikeUITests
//
//  Drag out of the grid, the list
//  and the viewer filmstrip carries the primary's file URL plus the
//  private group type; a drop on the Browser content navigates and
//  selects, with the accent border; a drop on a sidebar folder row moves
//  or copies through FileOps with the Finder modifiers and one undo step.
//  Offscreen views, temp folders and a private pasteboard only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

/// A drag in progress, as AppKit hands it to a destination.
@MainActor
final class FakeDraggingInfo: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingSourceOperationMask: NSDragOperation
    var draggingSource: Any?

    init(pasteboard: NSPasteboard, mask: NSDragOperation, source: Any? = nil) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = mask
        draggingSource = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

@MainActor
final class BrowserDragDropTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var selects: URL!
    private var other: URL!
    private var fakeTrash: URL!
    private var pasteboards: [NSPasteboard] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-dragdrop-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        selects = root.appendingPathComponent("Selects", isDirectory: true)
        other = root.appendingPathComponent("Other", isDirectory: true)
        fakeTrash = root.appendingPathComponent("FakeTrash", isDirectory: true)
        for folder in [dir!, selects!, other!, fakeTrash!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
    }

    override func tearDown() async throws {
        for pb in pasteboards { pb.releaseGlobally() }
        pasteboards = []
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func pasteboard(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("shrike-test-\(UUID().uuidString)"))
        pasteboards.append(pb)
        pb.clearContents()
        pb.writeObjects(items)
        return pb
    }

    private func pasteboard(urls: [URL]) -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("shrike-test-\(UUID().uuidString)"))
        pasteboards.append(pb)
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        return pb
    }

    private func makeFiles(_ names: [String], in folder: URL) throws -> [URL] {
        let urls = names.map { folder.appendingPathComponent($0) }
        for url in urls { try Data([0xFF, 0xD8, 0xFF]).write(to: url) }
        return urls
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func pairGroup() -> ImageGroup {
        ImageGroup(primary: dir.appendingPathComponent("P1.JPG"),
                   companions: [.init(url: dir.appendingPathComponent("P1.ORF"), kind: .raw),
                                .init(url: dir.appendingPathComponent("P1.xmp"), kind: .sidecar)])
    }

    private func item(for group: ImageGroup) -> BrowserItem {
        var item = BrowserItem(url: group.primary, displayName: group.primary.lastPathComponent, fileSize: 1,
                               modificationDate: Date(), creationDate: nil, captureDate: nil, utType: .jpeg,
                               pixelWidth: nil, pixelHeight: nil, rating: 0)
        item.group = group
        return item
    }

    private func browser(_ folder: URL) -> BrowserWindowController {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: folder)
        let trash = fakeTrash!
        browser.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { url in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        browser.transfers.slots = DestinationSlots(defaults: makeTestDefaults())
        return browser
    }

    // MARK: Drag out

    func testGridDragCarriesThePrimaryURLAndTheWholeGroup() throws {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let group = pairGroup()
        content.setItems([item(for: group)])
        let writer = try XCTUnwrap(content.collectionView(NSCollectionView(),
                                                          pasteboardWriterForItemAt: IndexPath(item: 0, section: 0)))
        let pb = pasteboard([try XCTUnwrap(writer as? NSPasteboardItem)])
        XCTAssertEqual(PhotoPasteboard.fileURLs(on: pb).map(\.standardizedFileURL),
                       [group.primary.standardizedFileURL], "outside Shrike only the primary travels")
        XCTAssertEqual(PhotoPasteboard.draggedGroups(on: pb),
                       [.init(source: content.dragSourceID, group: group)], "in-app: the whole group")
        XCTAssertNil(content.collectionView(NSCollectionView(),
                                            pasteboardWriterForItemAt: IndexPath(item: 5, section: 0)))
    }

    func testListDragCarriesTheSameItem() throws {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let group = pairGroup()
        content.setItems([item(for: group)])
        let writer = try XCTUnwrap(content.tableView(NSTableView(), pasteboardWriterForRow: 0))
        let pb = pasteboard([try XCTUnwrap(writer as? NSPasteboardItem)])
        XCTAssertEqual(PhotoPasteboard.fileURLs(on: pb).map(\.lastPathComponent), ["P1.JPG"])
        XCTAssertEqual(PhotoPasteboard.draggedGroups(on: pb).first?.group.allURLs.map(\.lastPathComponent),
                       ["P1.JPG", "P1.ORF", "P1.xmp"])
    }

    func testFilmstripDragCarriesTheGroupOfThatCell() throws {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let single = ImageGroup(primary: dir.appendingPathComponent("A.JPG"))
        let viewer = ViewerWindow(groups: [single, pairGroup()], startIndex: 0, services: services)
        defer { viewer.close() }
        let item = try XCTUnwrap(viewer.contentRoot.filmstripDragItemForTesting(1))
        let pb = pasteboard([item])
        XCTAssertEqual(PhotoPasteboard.fileURLs(on: pb).map(\.lastPathComponent), ["P1.JPG"])
        let dragged = try XCTUnwrap(PhotoPasteboard.draggedGroups(on: pb).first)
        XCTAssertEqual(dragged.group, pairGroup())
        XCTAssertEqual(dragged.source, viewer.contentRoot.filmstripDragSourceForTesting)
        XCTAssertNil(viewer.contentRoot.filmstripDragItemForTesting(7))
    }

    func testSourceMaskCopiesOutsideAndMovesInside() {
        XCTAssertEqual(BrowserDropRules.sourceMask(for: .outsideApplication), .copy)
        XCTAssertEqual(BrowserDropRules.sourceMask(for: .withinApplication), [.copy, .move, .generic])
    }

    // MARK: Rules

    func testSidebarVerbFollowsFinderRules() {
        let all: NSDragOperation = [.copy, .move, .generic, .link]
        typealias R = BrowserDropRules
        XCTAssertEqual(R.sidebarVerb(modifiers: [], mask: all, sameVolume: true), .move)
        XCTAssertEqual(R.sidebarVerb(modifiers: [], mask: all, sameVolume: false), .copy)
        XCTAssertEqual(R.sidebarVerb(modifiers: .option, mask: all, sameVolume: true), .copy)
        XCTAssertEqual(R.sidebarVerb(modifiers: .command, mask: all, sameVolume: false), .move)
        // ⌘ narrows the source mask to .generic: still a move.
        XCTAssertEqual(R.sidebarVerb(modifiers: .command, mask: .generic, sameVolume: false), .move)
        // A copy-only source never moves.
        XCTAssertEqual(R.sidebarVerb(modifiers: .command, mask: .copy, sameVolume: true), .copy)
        XCTAssertNil(R.sidebarVerb(modifiers: [], mask: .link, sameVolume: true))
        XCTAssertEqual(R.operation(for: .copy), .copy)
        XCTAssertEqual(R.operation(for: .move), .move)
    }

    func testVolumeRootIsByPathPrefix() {
        XCTAssertEqual(BrowserDropRules.volumeRoot(URL(fileURLWithPath: "/Volumes/SD/DCIM/a.jpg")), "/Volumes/SD")
        XCTAssertEqual(BrowserDropRules.volumeRoot(URL(fileURLWithPath: "/Users/me/Pictures")), "/")
        XCTAssertEqual(BrowserDropRules.volumeRoot(URL(fileURLWithPath: "/Volumes")), "/")
    }

    func testContentAcceptsFoldersAndImagesButNotItsOwnGrid() throws {
        let group = pairGroup()
        XCTAssertTrue(BrowserDropRules.acceptsContentDrop(pasteboard(urls: [other]), ownSource: "me"))
        XCTAssertTrue(BrowserDropRules.acceptsContentDrop(
            pasteboard(urls: [dir.appendingPathComponent("x.heic")]), ownSource: "me"))
        XCTAssertFalse(BrowserDropRules.acceptsContentDrop(
            pasteboard(urls: [dir.appendingPathComponent("notes.txt")]), ownSource: "me"))
        let own = pasteboard([PhotoPasteboard.dragItem(for: group, source: "me")])
        XCTAssertFalse(BrowserDropRules.acceptsContentDrop(own, ownSource: "me"), "no reordering")
        let fromViewer = pasteboard([PhotoPasteboard.dragItem(for: group, source: "viewer")])
        XCTAssertTrue(BrowserDropRules.acceptsContentDrop(fromViewer, ownSource: "me"))
    }

    func testResolveContentDrop() throws {
        let files = try makeFiles(["x.jpg", "y.jpg"], in: other)
        let stray = try makeFiles(["z.jpg"], in: selects)
        let text = other.appendingPathComponent("notes.txt")
        try Data("n".utf8).write(to: text)
        // A folder URL without the trailing slash is still a folder.
        let plainFolder = URL(fileURLWithPath: selects.path)
        XCTAssertEqual(BrowserDropRules.resolveContentDrop([plainFolder, files[0]]),
                       .folder(selects.standardizedFileURL))
        XCTAssertEqual(BrowserDropRules.resolveContentDrop(files + stray),
                       .images(folder: other.standardizedFileURL, files: files.map(\.standardizedFileURL)),
                       "images open the first one's folder; others there are selected")
        XCTAssertEqual(BrowserDropRules.resolveContentDrop([text, plainFolder]), .folder(selects.standardizedFileURL))
        XCTAssertNil(BrowserDropRules.resolveContentDrop([text]))
        XCTAssertNil(BrowserDropRules.resolveContentDrop([]))
    }

    func testFinderFilesOnTheSidebarAreGroupedAmongThemselves() throws {
        let files = try makeFiles(["P1.JPG", "P1.ORF", "Q.jpg"], in: dir)
        let groups = BrowserDropRules.droppedGroups(pasteboard(urls: files + [other]))
        XCTAssertEqual(groups.count, 2, "the pair is one shot; the folder is left out")
        XCTAssertEqual(groups.flatMap(\.allURLs).count, 3)
    }

    // MARK: Content drop

    func testContentBorderShowsWhileAnAcceptedDragIsOver() throws {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let target = content.dropViewForTesting
        XCTAssertTrue(target.dropHighlight.isHidden)
        XCTAssertTrue(target.registeredDraggedTypes.contains(.fileURL))
        XCTAssertNil(target.dropHighlight.hitTest(NSPoint(x: 5, y: 5)), "the border never takes clicks")

        let finder = FakeDraggingInfo(pasteboard: pasteboard(urls: [other]), mask: [.copy, .link, .generic])
        XCTAssertEqual(target.draggingEntered(finder), .generic, "navigating copies nothing")
        XCTAssertFalse(target.dropHighlight.isHidden)
        XCTAssertTrue(target.dropHighlight.superview === target)
        target.draggingExited(finder)
        XCTAssertTrue(target.dropHighlight.isHidden)

        let own = FakeDraggingInfo(pasteboard: pasteboard([PhotoPasteboard.dragItem(for: pairGroup(),
                                                                                     source: content.dragSourceID)]),
                                   mask: [.copy, .move, .generic])
        XCTAssertEqual(target.draggingEntered(own), [])
        XCTAssertTrue(target.dropHighlight.isHidden, "no border over its own grid")
        XCTAssertFalse(target.performDragOperation(own))
    }

    func testDroppingImagesNavigatesToTheirFolderAndSelectsThem() async throws {
        _ = try makeFiles(["a.jpg"], in: dir)
        let files = try makeFiles(["x.jpg", "y.jpg", "z.jpg"], in: other)
        let browser = browser(dir)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 1 }
        XCTAssertTrue(loaded)

        let target = browser.contentController.dropViewForTesting
        let info = FakeDraggingInfo(pasteboard: pasteboard(urls: [files[1], files[2]]), mask: [.copy, .generic])
        XCTAssertFalse(target.draggingEntered(info).isEmpty)
        XCTAssertTrue(target.performDragOperation(info))
        XCTAssertTrue(target.dropHighlight.isHidden)
        await browser.contentDropTask?.value
        let selected = await waitUntil {
            browser.contentController.selectedItems.map(\.displayName) == ["y.jpg", "z.jpg"]
        }
        XCTAssertTrue(selected)
        XCTAssertEqual(browser.currentFolder, other.standardizedFileURL)
        XCTAssertEqual(names(other), ["x.jpg", "y.jpg", "z.jpg"], "nothing is copied")
        XCTAssertEqual(names(dir), ["a.jpg"])
    }

    func testDroppingAFolderNavigatesToIt() async throws {
        _ = try makeFiles(["a.jpg"], in: dir)
        _ = try makeFiles(["s.jpg"], in: selects)
        let browser = browser(dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 1 }
        let target = browser.contentController.dropViewForTesting
        XCTAssertTrue(target.performDragOperation(FakeDraggingInfo(pasteboard: pasteboard(urls: [selects]),
                                                                   mask: .copy)))
        await browser.contentDropTask?.value
        let shown = await waitUntil {
            browser.contentController.visibleItems.map(\.displayName) == ["s.jpg"]
        }
        XCTAssertTrue(shown)
        XCTAssertEqual(browser.currentFolder, selects.standardizedFileURL)
    }

    // MARK: Sidebar folder row

    func testSidebarDropMovesTheWholeGroupWithOneUndo() async throws {
        let before = ImageGroupingPreference.isEnabled
        ImageGroupingPreference.isEnabled = true
        defer { ImageGroupingPreference.isEnabled = before }
        _ = try makeFiles(["P1.JPG", "P1.ORF", "P1.xmp", "Q.jpg"], in: dir)
        let browser = browser(dir)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(loaded)
        let pair = try XCTUnwrap(browser.contentController.visibleItems.first { $0.displayName == "P1.JPG" })
        XCTAssertEqual(pair.group.allURLs.count, 3)

        let tree = browser.treeControllerForTesting
        let outline = tree.outlineViewForTesting
        let row = FolderTreeNode(url: selects, title: "Selects")
        let pb = pasteboard([PhotoPasteboard.dragItem(for: pair.group, source: browser.contentController.dragSourceID)])
        let info = FakeDraggingInfo(pasteboard: pb, mask: [.copy, .move, .generic])

        tree.modifierFlagsProvider = { [] }
        XCTAssertEqual(tree.outlineView(outline, validateDrop: info, proposedItem: row,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex), .move,
                       "same volume moves")
        tree.modifierFlagsProvider = { .option }
        XCTAssertEqual(tree.outlineView(outline, validateDrop: info, proposedItem: row,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex), .copy, "⌥ copies")
        XCTAssertEqual(tree.outlineView(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 0), [],
                       "images between rows are refused")
        let missing = FolderTreeNode(url: other, title: "Gone")
        missing.isMissing = true
        XCTAssertEqual(tree.outlineView(outline, validateDrop: info, proposedItem: missing,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex), [])

        tree.modifierFlagsProvider = { [] }
        XCTAssertTrue(tree.outlineView(outline, acceptDrop: info, item: row, childIndex: NSOutlineViewDropOnItemIndex))
        await browser.waitForPendingFileWork()
        let moved = await waitUntil { self.names(self.selects) == ["P1.JPG", "P1.ORF", "P1.xmp"] }
        XCTAssertTrue(moved, "every file of the shot moves")
        XCTAssertEqual(names(dir), ["Q.jpg"])
        let left = await waitUntil { browser.contentController.visibleItems.map(\.displayName) == ["Q.jpg"] }
        XCTAssertTrue(left, "the moved item leaves the list")
        XCTAssertEqual(browser.transferNotice.message, "Moved “P1.JPG” to “Selects”.")
        XCTAssertEqual(browser.transferNotice.buttonTitles, ["Undo"])
        XCTAssertNil(browser.toastHost.content, "the result takes its own band, not a toast over the photos")
        XCTAssertTrue(browser.noticeStackForTesting?.arrangedSubviews.contains(browser.transferNotice) ?? false)

        browser.window?.undoManager?.undo()
        await browser.waitForPendingFileWork()
        let back = await waitUntil { self.names(self.dir) == ["P1.JPG", "P1.ORF", "P1.xmp", "Q.jpg"] }
        XCTAssertTrue(back, "one undo puts the whole shot back")
        XCTAssertEqual(names(selects), [])
    }

    func testSidebarDropWithOptionCopies() async throws {
        let files = try makeFiles(["a.jpg"], in: dir)
        let browser = browser(dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 1 }
        let tree = browser.treeControllerForTesting
        tree.modifierFlagsProvider = { .option }
        let info = FakeDraggingInfo(pasteboard: pasteboard(urls: files), mask: [.copy, .move, .generic, .link])
        XCTAssertTrue(tree.outlineView(tree.outlineViewForTesting, acceptDrop: info,
                                       item: FolderTreeNode(url: selects, title: "Selects"),
                                       childIndex: NSOutlineViewDropOnItemIndex))
        await browser.waitForPendingFileWork()
        let copied = await waitUntil { self.names(self.selects) == ["a.jpg"] }
        XCTAssertTrue(copied)
        XCTAssertEqual(names(dir), ["a.jpg"], "a copy leaves the original")
        XCTAssertEqual(browser.transferNotice.message, "Copied “a.jpg” to “Selects”.")
    }
}

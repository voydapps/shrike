//
//  TagEditorTests.swift
//  ShrikeUITests
//
//  The Tags popover session writes Finder
//  tags at once to the primary and its RAW (not sidecars), shows shared
//  tags and half-set colours for a multi-selection, and is ONE undo step.
//  Temp files only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class TagEditorTests: XCTestCase {

    private var dir: URL!
    private let red = FinderTag(name: "Red", color: .red)
    private let blue = FinderTag(name: "Blue", color: .blue)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url
    }

    private func session(_ groups: [ImageGroup], undo: UndoManager? = nil,
                         changed: ((([URL]) -> Void))? = nil) -> TagEditSession {
        TagEditSession(groups: groups, colorTags: [red, blue], undoManager: undo,
                       onChange: { changed?($0) }, onError: { XCTFail($0) })
    }

    // The popover is positioned on a view that outlives a tag change
    // (the window's content view), at the anchor's place.
    func testPopoverAnchorSurvivesTheCellReload() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let holder = NSView(frame: NSRect(x: 50, y: 40, width: 200, height: 200))
        let cell = NSView(frame: NSRect(x: 10, y: 20, width: 80, height: 60))
        holder.addSubview(cell)
        content.addSubview(holder)
        let anchor = TagsPopoverController.stableAnchor(cell.bounds, of: cell)
        XCTAssertTrue(anchor.view === content)
        XCTAssertEqual(anchor.rect, NSRect(x: 60, y: 60, width: 80, height: 60))
        cell.removeFromSuperview()   // the reload replaces the cell
        XCTAssertNotNil(anchor.view.window, "the positioning view is still in the window")
        // A view outside any window keeps itself.
        let loose = NSView(frame: .zero)
        XCTAssertTrue(TagsPopoverController.stableAnchor(.zero, of: loose).view === loose)
    }

    // T, click Red → the file carries the Red tag.
    func testColourToggleWritesPrimaryAndRAWButNotSidecar() async throws {
        let jpg = try file("P1.JPG"), orf = try file("P1.ORF"), xmp = try file("P1.xmp")
        let group = ImageGroup(primary: jpg, companions: [
            .init(url: orf, kind: .raw), .init(url: xmp, kind: .sidecar),
        ])
        var changed: [URL] = []
        let s = session([group], changed: { changed = $0 })
        XCTAssertEqual(s.state(of: red), .off)
        s.toggle(red)
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(jpg), ["Red"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(orf), ["Red"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(xmp), [], "sidecars are never tagged")
        XCTAssertEqual(s.state(of: red), .on)
        XCTAssertEqual(changed, [jpg])
        s.toggle(red)
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(jpg), [])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(orf), [])
    }

    func testMultiSelectionSharedTokensAndHalfSetColour() async throws {
        let a = try file("a.jpg"), b = try file("b.jpg")
        try FinderTags.write(a, tags: ["Client", "Red"])
        try FinderTags.write(b, tags: ["Client", "Venice"])
        let s = session([ImageGroup(primary: a), ImageGroup(primary: b)])
        XCTAssertEqual(s.commonTags, ["Client"])
        XCTAssertEqual(s.state(of: red), .mixed)
        s.toggle(red) // a click sets that colour on all
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(b), ["Client", "Venice", "Red"])
        XCTAssertEqual(s.state(of: red), .on)
        s.remove(["client"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Red"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(b), ["Venice", "Red"])
        s.add(["Venice"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Red", "Venice"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(b), ["Venice", "Red"], "no duplicate")
    }

    func testOneUndoStepPerSessionWithRedo() async throws {
        let a = try file("a.jpg")
        try FinderTags.write(a, tags: ["Client"])
        let undo = UndoManager()
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        let s = session([ImageGroup(primary: a)], undo: undo)
        s.toggle(red)
        s.add(["Venice"])
        s.toggle(blue)
        undo.endUndoGrouping()
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Client", "Red", "Venice", "Blue"])
        XCTAssertEqual(undo.undoActionName, "Tags")
        undo.undo()
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Client"])
        XCTAssertFalse(undo.canUndo, "the whole session was one step")
        undo.redo()
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Client", "Red", "Venice", "Blue"])
    }

    func testCompletionsSkipTagsAlreadyShared() throws {
        let a = try file("a.jpg")
        try FinderTags.write(a, tags: ["Venice"])
        TagEditSession.recentTags = ["Venice", "Verona"]
        defer { TagEditSession.recentTags = [] }
        let s = session([ImageGroup(primary: a)])
        let offered = s.completions(for: "ve")
        XCTAssertTrue(offered.contains("Verona"))
        XCTAssertFalse(offered.contains("Venice"))
    }

    func testViewerTKeyOpensSessionOnDisplayedItemAndRefreshesPill() async throws {
        let a = try file("a.jpg"), b = try file("b.jpg")
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: a), ImageGroup(primary: b)],
                                  startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        var opened: TagEditSession?
        viewer.tagPopoverPresenterForTesting = { opened = $0 }
        XCTAssertTrue(viewer.canPerform(.tags))
        viewer.handleKeySnapshot(ShrikeUI.KeyEventSnapshot(key: "t", modifiers: []))
        let session = try XCTUnwrap(opened)
        XCTAssertEqual(session.groups.map(\.primary), [a])
        session.add(["Client"])
        await FinderTagWriter.shared.flush()
        let deadline = Date().addingTimeInterval(2)
        while viewer.fileBadges[a]?.tags.isEmpty ?? true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewer.fileBadges[a]?.tags.map(\.name), ["Client"])
        XCTAssertEqual(viewer.positionMarks(for: 0).tags.map(\.name), ["Client"])
        viewer.windowUndoManager.undo()
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), [])
        let cleared = Date().addingTimeInterval(2)
        while !(viewer.fileBadges[a]?.tags.isEmpty ?? true), Date() < cleared {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewer.fileBadges[a]?.tags.map(\.name), [])
    }

    // The Browser inspector's chip ⓧ removes the tag from the
    // selection (one undo step); "+" opens the popover on the Tags row.
    func testBrowserInspectorChipsRemoveAndAdd() async throws {
        let a = try file("a.jpg"), b = try file("b.jpg")
        try FinderTags.write(a, tags: ["Client", "Venice"])
        try FinderTags.write(b, tags: ["Client"])
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let deadline = Date().addingTimeInterval(3)
        while browser.contentController.visibleItems.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(browser.contentController.visibleItems.count, 2)
        browser.contentController.selectAll()
        let inspector = browser.inspectorForTesting
        _ = inspector.view

        inspector.onRemoveTag?("Client")
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Venice"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(b), [])
        let undo = try XCTUnwrap(browser.window?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Tags")
        undo.undo()
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(a), ["Client", "Venice"])
        await FinderTagWriter.shared.flush(); XCTAssertEqual(FinderTags.read(b), ["Client"])

        var opened: TagEditSession?
        browser.tagPopoverPresenterForTesting = { opened = $0 }
        inspector.addTagTapped()
        let session = try XCTUnwrap(opened, "the + chip opens the Tags popover")
        XCTAssertEqual(Set(session.groups.map(\.primary.lastPathComponent)), ["a.jpg", "b.jpg"])
        XCTAssertEqual(session.commonTags, ["Client"])
    }
}

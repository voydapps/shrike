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
        await browser.listingTask?.value
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

    /// Direct delegate/component coverage, separate from the real field-editor
    /// input cases below. With no editor these supplied objects are committed;
    /// pending plaintext is covered by the real editor boundary below.
    /// AppKit owns where accepted objects are inserted.
    func testTokenAdditionNormalizesBatchAgainstActualRepresentedObjects() async throws {
        let recent = TagEditSession.recentTags
        defer { TagEditSession.recentTags = recent }
        let cases: [(stored: [String], shown: [String], input: [Any], index: Int,
                     accepted: [String], model: [String])] = [
            ([], [], [" Workflow ", "workflow", "\n", 42, "Client", "CLIENT"], 0,
             ["Workflow", "Client"], ["Workflow", "Client"]),
            (["Client", "Venice"], ["Client", "Venice"], ["client", "VENICE", " New ", "new"], 0,
             ["New"], ["Client", "Venice", "New"]),
            (["Client", "Venice"], ["Client", "Venice"], ["Venice"], 1,
             [], ["Client", "Venice"]),
            // The edited token is absent from the actual represented objects.
            (["Client", "Venice"], ["Venice"], ["Client"], 0,
             ["Client"], ["Client", "Venice"]),
            (["Client", "Venice"], ["Venice"], [" Project ", "project"], 0,
             ["Project"], ["Client", "Venice", "Project"]),
            (["Client"], [], ["Client"], 0, ["Client"], ["Client"]),
            (["Café"], ["Café"], [" CAFÉ "], 1, [], ["Café"]),
            ([], [], ["", " \n ", 42], 0, [], []),
        ]
        for (index, example) in cases.enumerated() {
            let url = try file("table-\(index).jpg")
            try FinderTags.write(url, tags: example.stored)
            let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
            let state = session([ImageGroup(primary: url)], undo: undo)
            XCTAssertFalse(state.didRegisterUndo, "case \(index), before view load")
            let controller = TagsPopoverController(session: state); _ = controller.view
            XCTAssertFalse(state.didRegisterUndo, "case \(index), after view load")
            controller.tokenField.objectValue = example.shown
            XCTAssertFalse(state.didRegisterUndo, "case \(index), after represented-object setup")
            let accepted = controller.tokenField(controller.tokenField, shouldAdd: example.input, at: example.index)
            XCTAssertEqual(accepted as? [String], example.accepted, "case \(index)")
            XCTAssertEqual(controller.tokenField.objectValue as? [String], example.shown,
                           "the callback returns insertions; it must not replace the field contents")
            XCTAssertEqual(state.commonTags, example.model, "case \(index)")
            undo.endUndoGrouping()
            XCTAssertEqual(state.didRegisterUndo, example.model != example.stored,
                           "case \(index), tag session owns registration only after a real change")
            await FinderTagWriter.shared.flush()
            XCTAssertEqual(FinderTags.read(url), example.model, "case \(index)")
        }
    }

    private func tokenWindow(_ controller: TagsPopoverController) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0; window.ignoresMouseEvents = true; window.animationBehavior = .none
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    private func tokenEditor(_ field: NSTokenField, in window: NSWindow) throws -> NSTextView {
        if field.currentEditor() == nil { XCTAssertTrue(window.makeFirstResponder(field)) }
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.delegate === field); XCTAssertTrue(editor.window === window)
        return editor
    }

    private func tokenKey(_ text: String, code: UInt16, in window: NSWindow) throws {
        window.sendEvent(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)))
    }

    private func tokenRanges(_ editor: NSTextView) -> [NSRange] {
        guard let storage = editor.textStorage else { return [] }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is NSTextAttachment { ranges.append(range) }
        }
        return ranges
    }

    private func untilTokenState(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), description)
    }

    private func assertTagAgreement(_ expected: [String], session: TagEditSession, url: URL,
                                    store: MetadataStore) async throws {
        // The writer fence covers only already-enqueued writes. Let normal
        // deferred token removal update the model and enqueue its final write.
        try await untilTokenState("Deferred token changes reach the expected session before the writer fence") {
            session.current[url]?.sorted() == expected.sorted() && session.commonTags.sorted() == expected.sorted()
        }
        await FinderTagWriter.shared.flush()
        XCTAssertEqual(session.current[url]?.sorted(), expected.sorted())
        XCTAssertEqual(session.commonTags.sorted(), expected.sorted())
        XCTAssertEqual(FinderTags.read(url).sorted(), expected.sorted())
        let entries = try XCTUnwrap(FinderTags.readXattrEntries(url))
        XCTAssertEqual(entries.map { FinderTags.parseEntry($0).name }.sorted(), expected.sorted())
        let stored = try await store.tags(for: url)
        XCTAssertEqual(stored, expected.sorted())
    }

    /// Audit on-screen M1: a colour click followed by a typed tag keeps both.
    func testTypedTagAfterAColourClickKeepsTheColour() async throws {
        let recent = TagEditSession.recentTags
        defer { TagEditSession.recentTags = recent }
        let url = try file("colour-then-typed.jpg")
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("colour.sqlite"))
        let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        let state = session([ImageGroup(primary: url)], undo: undo)
        let controller = TagsPopoverController(session: state)
        let window = tokenWindow(controller); defer { window.close() }
        let editor = try tokenEditor(controller.tokenField, in: window)
        let red = try XCTUnwrap(controller.toggles.first)
        controller.toggleColor(red)
        XCTAssertEqual(editor.selectedRange().length, 0, "nothing is selected after the click")
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count, "caret after the last token")
        editor.insertText("keeper", replacementRange: editor.selectedRange())
        try tokenKey("\r", code: 36, in: window)
        try await untilTokenState("both tags are on the file") {
            Set(state.commonTags.map { $0.lowercased() }).isSuperset(of: [red.tag0.name.lowercased(), "keeper"])
        }
        await FinderTagWriter.shared.flush()
        let onDisk = FinderTags.read(url).map { $0.lowercased() }
        XCTAssertTrue(onDisk.contains(red.tag0.name.lowercased()), "\(onDisk)")
        XCTAssertTrue(onDisk.contains("keeper"), "\(onDisk)")
    }

    /// Real NSTokenField field-editor input and Return tokenization, not a
    /// direct shouldAdd invocation or a claim about the production popover.
    func testFieldEditorCommitRejectsDuplicateTokensAndPreservesPendingText() async throws {
        let recent = TagEditSession.recentTags
        defer { TagEditSession.recentTags = recent }
        let url = try file("native-add.jpg")
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("add.sqlite"))
        let undo = UndoManager(); undo.groupsByEvent = false; undo.beginUndoGrouping()
        let state = session([ImageGroup(primary: url)], undo: undo)
        let controller = TagsPopoverController(session: state)
        let window = tokenWindow(controller); defer { window.close() }
        let editor = try tokenEditor(controller.tokenField, in: window)
        editor.insertText("workflow", replacementRange: editor.selectedRange())
        XCTAssertTrue(tokenRanges(editor).isEmpty, "plain proposal is not a committed token")
        XCTAssertEqual(controller.tokenField.objectValue as? [String], ["workflow"],
                       "AppKit exposes pending plaintext in objectValue before tokenization")
        XCTAssertTrue(state.commonTags.isEmpty)
        try tokenKey("\r", code: 36, in: window)
        try await untilTokenState("First Return creates one actual token") {
            tokenRanges(editor).count == 1 && controller.tokenField.objectValue as? [String] == ["workflow"]
        }
        try await assertTagAgreement(["workflow"], session: state, url: url, store: store)
        XCTAssertTrue(try tokenEditor(controller.tokenField, in: window) === editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" WORKFLOW ", replacementRange: editor.selectedRange())
        try tokenKey("\r", code: 36, in: window)
        try await untilTokenState("Duplicate Return leaves exactly one actual token") {
            tokenRanges(editor).count == 1 && controller.tokenField.objectValue as? [String] == ["workflow"]
        }
        try await assertTagAgreement(["workflow"], session: state, url: url, store: store)
        XCTAssertTrue(window.firstResponder === editor)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("unsubmitted", replacementRange: editor.selectedRange())
        await FinderTagWriter.shared.flush(); await Task.yield()
        XCTAssertTrue(editor.string.hasSuffix("unsubmitted"), "async landed/removal callbacks preserve pending text")
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(controller.tokenField.currentEditor() === editor)
        XCTAssertEqual(state.commonTags, ["workflow"])
        XCTAssertEqual(FinderTags.read(url), ["workflow"])
        // Clear only unsubmitted text; this is not a simulated popover Cancel.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count - "unsubmitted".utf16.count,
                                        length: "unsubmitted".utf16.count))
        editor.deleteBackward(nil)
        // NSTextInputClient composition remains owned by the same editor;
        // this is component input, not a claim about a particular IME app.
        editor.setMarkedText("未確定", selectedRange: NSRange(location: 3, length: 0),
                             replacementRange: editor.selectedRange())
        let marked = editor.markedRange()
        XCTAssertTrue(editor.hasMarkedText())
        await Task.yield()
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(state.commonTags, ["workflow"])
        editor.unmarkText(); editor.setSelectedRange(marked); editor.deleteBackward(nil)
        undo.endUndoGrouping()
        XCTAssertEqual(undo.undoActionName, "Tags")
        undo.undo()
        try await assertTagAgreement([], session: state, url: url, store: store)
        XCTAssertFalse(undo.canUndo, "one tag session has one Undo step despite duplicate input")
        undo.redo()
        try await assertTagAgreement(["workflow"], session: state, url: url, store: store)
    }

    func testFieldEditorReplacesAndRemovesExistingToken() async throws {
        let recent = TagEditSession.recentTags
        defer { TagEditSession.recentTags = recent }
        let url = try file("native-edit.jpg")
        try FinderTags.write(url, tags: ["Client", "Venice"])
        let store = try MetadataStore(databaseURL: dir.appendingPathComponent("edit.sqlite"))
        let state = session([ImageGroup(primary: url)])
        let controller = TagsPopoverController(session: state)
        let window = tokenWindow(controller); defer { window.close() }
        let editor = try tokenEditor(controller.tokenField, in: window)
        let original = try XCTUnwrap(tokenRanges(editor).first)
        XCTAssertEqual(tokenRanges(editor).count, 2)
        editor.insertText("Client", replacementRange: original)
        try tokenKey("\r", code: 36, in: window)
        try await untilTokenState("Editing a token to itself keeps it and its neighbor") {
            controller.tokenField.objectValue as? [String] == ["Client", "Venice"] && tokenRanges(editor).count == 2
        }
        try await assertTagAgreement(["Client", "Venice"], session: state, url: url, store: store)
        XCTAssertFalse(state.didRegisterUndo, "recommitting an unchanged tag is not a session change")
        editor.insertText("Project", replacementRange: try XCTUnwrap(tokenRanges(editor).first))
        try tokenKey("\r", code: 36, in: window)
        try await untilTokenState("Editing a represented token inserts its replacement at the original index") {
            controller.tokenField.objectValue as? [String] == ["Project", "Venice"] && tokenRanges(editor).count == 2
        }
        try await assertTagAgreement(["Project", "Venice"], session: state, url: url, store: store)
        editor.setSelectedRange(try XCTUnwrap(tokenRanges(editor).first))
        editor.deleteBackward(nil)
        try await untilTokenState("Native token removal updates the session") {
            controller.tokenField.objectValue as? [String] == ["Venice"] && state.commonTags == ["Venice"]
        }
        try await assertTagAgreement(["Venice"], session: state, url: url, store: store)
    }

}

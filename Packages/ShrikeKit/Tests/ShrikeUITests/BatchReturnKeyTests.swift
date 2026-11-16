//
//  BatchReturnKeyTests.swift
//  ShrikeUITests
//
//  Return and Esc in a Batch text field (spec 28 §14 / B-8): the first
//  Return only commits the field, a second Return runs; Esc cancels the
//  edit and keeps the window; ⌘Return runs from anywhere. Keys are posted
//  and dequeued, so `NSApp.currentEvent` is the key as on screen, then
//  delivered through the field editor (`keyDown` → `insertNewline:` → end
//  of editing → AppKit presses the default button) or the window's key
//  equivalent pass. Windows are built offscreen and never shown.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class BatchReturnKeyTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-return-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BatchWindowController.presentsWindows = false
    }

    override func tearDown() async throws {
        // Leave a harmless event as NSApp.currentEvent for the next test.
        if let app = NSApp, let filler = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                                            timestamp: 0, windowNumber: 0, context: nil,
                                                            subtype: 0, data1: 0, data2: 0) {
            app.postEvent(filler, atStart: true)
            _ = app.nextEvent(matching: .applicationDefined, until: Date(timeIntervalSinceNow: 1),
                              inMode: .default, dequeue: true)
        }
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        if let current = BatchWindowController.current {
            await current.model.waitForRun()
            current.close()
        }
        BatchWindowController.presentsWindows = true
        await BatchUndo.lastTask?.value
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    private func jpeg(_ name: String) throws -> URL {
        let folder = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A Batch window with three photos, Rename on with a valid template and an
    /// output folder: Run is enabled.
    private func openRename(_ tag: String) async throws -> (BatchWindowController, NSWindow) {
        let sources = try (0..<3).map { try jpeg("\(tag)\($0).jpg") }
        let batch = BatchWindowController.open(groups: sources.map { ImageGroup(primary: $0) },
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        batch.model.form.renameOn = true
        batch.model.form.template = "{name}-r"
        batch.model.form.outputFolder = dir.appendingPathComponent("out-\(tag)", isDirectory: true)
        let ready = await waitUntil { batch.model.canRun }
        XCTAssertTrue(ready, "Run is enabled before the key")
        let window = try XCTUnwrap(batch.window)
        window.contentView?.layoutSubtreeIfNeeded()
        return (batch, window)
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { allViews($0) } }

    private func templateField(_ window: NSWindow) throws -> NSTextField {
        try XCTUnwrap(allViews(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Name template" }, "the template field")
    }

    /// An editable SwiftUI number field (not the AppKit template field).
    private func numberField(_ window: NSWindow) throws -> NSTextField {
        try XCTUnwrap(allViews(window.contentView!).compactMap { $0 as? NSTextField }
            .first { $0.isEditable && $0.isEnabled && $0.accessibilityLabel() != "Name template" }, "a number field")
    }

    /// Starts editing the field and types through the field editor.
    @discardableResult
    private func edit(_ field: NSTextField, _ window: NSWindow, type text: String = "x") throws -> NSTextView {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.moveToEndOfDocument(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        return editor
    }

    /// A key event that AppKit itself made current: posted, then dequeued.
    private func currentKey(_ window: NSWindow, _ chars: String, _ code: UInt16,
                            _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let made = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        let app = try XCTUnwrap(NSApp)
        app.postEvent(made, atStart: true)
        let got = try XCTUnwrap(app.nextEvent(matching: .keyDown, until: Date(timeIntervalSinceNow: 1),
                                              inMode: .default, dequeue: true))
        XCTAssertEqual(got.keyCode, code)
        XCTAssertTrue(app.currentEvent === got, "AppKit made the key current, as for a real key press")
        return got
    }

    private func isEditing(_ window: NSWindow) -> Bool { (window.firstResponder as? NSText)?.isFieldEditor == true }

    /// Lets queued main-queue work (the deferred end of editing) run.
    private func settle() async { try? await Task.sleep(for: .milliseconds(50)) }

    private func runStarted(_ batch: BatchWindowController) async -> Bool {
        await waitUntil(1) { batch.model.phase != .form }
    }

    // MARK: Return in a field: the field editor path

    /// The on-screen regression (28a round 6): Return typed in the name
    /// template field ends the editing, AppKit then presses the default
    /// button itself, and the batch started at once.
    func testFirstReturnInTheTemplateFieldOnlyCommitsThenSecondReturnRuns() async throws {
        let (batch, window) = try await openRename("T")
        defer { batch.close() }
        let editor = try edit(try templateField(window), window)
        let settled = await waitUntil { batch.model.canRun }
        XCTAssertTrue(settled)
        editor.keyDown(with: try currentKey(window, "\r", 36))
        await settle()
        XCTAssertEqual(batch.model.phase, .form, "the first Return only commits the field")
        XCTAssertEqual(batch.model.form.template, "{name}-rx", "the typed value is kept")
        XCTAssertFalse(isEditing(window), "the field is committed and no longer edited")
        let again = await waitUntil { batch.model.canRun }
        XCTAssertTrue(again)
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36))
        let started = await runStarted(batch)
        XCTAssertTrue(started, "the second Return runs")
        await batch.model.waitForRun()
    }

    /// The same through the editor's command (`insertNewline:`) and keypad Enter.
    func testInsertNewlineAndEnterInTheTemplateFieldOnlyCommit() async throws {
        for (tag, code, chars) in [("N", UInt16(36), "\r"), ("K", UInt16(76), "\u{3}")] {
            let (batch, window) = try await openRename(tag)
            let editor = try edit(try templateField(window), window)
            let settled = await waitUntil { batch.model.canRun }
            XCTAssertTrue(settled)
            let event = try currentKey(window, chars, code)
            if code == 36 { editor.doCommand(by: #selector(NSResponder.insertNewline(_:))) } else { editor.keyDown(with: event) }
            await settle()
            XCTAssertEqual(batch.model.phase, .form, "key \(code) only commits the field")
            XCTAssertFalse(isEditing(window))
            batch.close()
        }
    }

    /// The SwiftUI number field (Resize size) behaves the same.
    func testFirstReturnInTheSizeFieldOnlyCommitsThenSecondReturnRuns() async throws {
        let (batch, window) = try await openRename("Z")
        defer { batch.close() }
        batch.model.form.resizeOn = true
        let settled = await waitUntil { batch.model.canRun }
        XCTAssertTrue(settled)
        window.contentView?.layoutSubtreeIfNeeded()
        let editor = try edit(try numberField(window), window, type: "1")
        editor.keyDown(with: try currentKey(window, "\r", 36))
        await settle()
        XCTAssertEqual(batch.model.phase, .form, "the first Return only commits the size")
        XCTAssertFalse(isEditing(window))
        let again = await waitUntil { batch.model.canRun }
        XCTAssertTrue(again)
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36))
        let started = await runStarted(batch)
        XCTAssertTrue(started, "the second Return runs")
        await batch.model.waitForRun()
    }

    // MARK: Return in a field: the key-equivalent pass

    /// A shown window asks its buttons for key equivalents before the field
    /// editor sees the key: the default button must not run then either.
    func testReturnReachingTheDefaultButtonWhileAFieldIsEditedOnlyCommits() async throws {
        let (batch, window) = try await openRename("Q")
        defer { batch.close() }
        try edit(try templateField(window), window)
        let settled = await waitUntil { batch.model.canRun }
        XCTAssertTrue(settled)
        XCTAssertTrue(window.performKeyEquivalent(with: try currentKey(window, "\r", 36)), "the key is used")
        await settle()
        XCTAssertEqual(batch.model.phase, .form, "Return while the field is edited only commits it")
        XCTAssertEqual(batch.model.form.template, "{name}-rx")
        XCTAssertFalse(isEditing(window))
        let again = await waitUntil { batch.model.canRun }
        XCTAssertTrue(again)
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36))
        let started = await runStarted(batch)
        XCTAssertTrue(started, "the second Return runs")
        await batch.model.waitForRun()
    }

    // MARK: Other keys

    func testCommandReturnRunsWhileAFieldIsEdited() async throws {
        let (batch, window) = try await openRename("C")
        defer { batch.close() }
        try edit(try templateField(window), window)
        let settled = await waitUntil { batch.model.canRun }
        XCTAssertTrue(settled)
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36, .command))
        let started = await runStarted(batch)
        XCTAssertTrue(started, "⌘Return runs from anywhere")
        await batch.model.waitForRun()
    }

    /// Pass 2n task 4: ⌘Return right after typing a size commits it (Run goes
    /// off while the new preview is made), then runs once, with the typed size.
    func testCommandReturnRightAfterTypingASizeRunsWithTheTypedSize() async throws {
        let (batch, window) = try await openRename("Q")
        defer { batch.close() }
        batch.model.form.resizeOn = true
        let settled = await waitUntil { batch.model.canRun }
        XCTAssertTrue(settled)
        window.contentView?.layoutSubtreeIfNeeded()
        let typed = batch.model.form.resizeValue * 10 + 1
        try edit(try numberField(window), window, type: "1")
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36, .command))
        XCTAssertEqual(batch.model.form.resizeValue, typed, "the key committed the typed size first")
        let started = await waitUntil(3) { batch.model.phase != .form }
        XCTAssertTrue(started, "the run starts once the preview is current")
        await batch.model.waitForRun()
    }

    /// A queued run is dropped when the form changes again before the preview lands.
    func testQueuedRunIsCancelledByALaterFormChange() async throws {
        let (batch, _) = try await openRename("K")
        defer { batch.close() }
        batch.model.form.counterStart = 5
        XCTAssertFalse(batch.model.canRun)
        batch.model.requestRunWhenCurrent()
        batch.model.form.counterStart = 6
        await batch.model.waitForPreview()
        await settle()
        XCTAssertTrue(batch.model.canRun)
        XCTAssertEqual(batch.model.phase, .form, "no run after a later change")
    }

    func testEscInAFieldCancelsTheEditAndKeepsTheWindow() async throws {
        let (batch, window) = try await openRename("E")
        defer { batch.close() }
        let field = try templateField(window)
        try edit(field, window)
        XCTAssertEqual(batch.model.form.template, "{name}-rx", "typing reaches the form live")
        XCTAssertTrue(window.performKeyEquivalent(with: try currentKey(window, "\u{1b}", 53)))
        await settle()
        XCTAssertTrue(BatchWindowController.current === batch, "Esc in a field does not close the window")
        XCTAssertFalse(isEditing(window), "the edit is cancelled")
        XCTAssertEqual(batch.model.form.template, "{name}-r", "the value from before the edit is back")
        XCTAssertEqual(field.stringValue, "{name}-r")
        // With no field edited, Esc closes the window as before.
        _ = window.performKeyEquivalent(with: try currentKey(window, "\u{1b}", 53))
        XCTAssertNil(BatchWindowController.current, "Esc outside a field closes the window")
    }

    /// Esc in the SwiftUI number field and through the field editor's own
    /// keyDown (both field kinds) keeps the window too.
    func testEscInANumberFieldAndThroughTheFieldEditorKeepsTheWindow() async throws {
        for (tag, number, keyPass) in [("EN", true, true), ("EK", true, false), ("ET", false, false)] {
            let (batch, window) = try await openRename(tag)
            batch.model.form.resizeOn = true
            let settled = await waitUntil { batch.model.canRun }
            XCTAssertTrue(settled)
            window.contentView?.layoutSubtreeIfNeeded()
            let field = number ? try numberField(window) : try templateField(window)
            let editor = try edit(field, window, type: "1")
            let esc = try currentKey(window, "\u{1b}", 53)
            if keyPass { _ = window.performKeyEquivalent(with: esc) } else { editor.keyDown(with: esc) }
            await settle()
            XCTAssertTrue(BatchWindowController.current === batch, "\(tag): Esc in a field does not close the window")
            XCTAssertFalse(isEditing(window), "\(tag): the edit is cancelled")
            batch.close()
        }
    }

    func testReturnWithFocusOnACheckboxRuns() async throws {
        let (batch, window) = try await openRename("B")
        defer { batch.close() }
        let box = try XCTUnwrap(allViews(window.contentView!).compactMap { $0 as? NSButton }
            .first { $0.title == "Resize" }, "the Resize checkbox")
        window.makeFirstResponder(box)
        XCTAssertFalse(isEditing(window))
        _ = window.performKeyEquivalent(with: try currentKey(window, "\r", 36))
        let started = await runStarted(batch)
        XCTAssertTrue(started, "Return with no field edited runs")
        await batch.model.waitForRun()
    }

    // MARK: Cmd-Z in a field (pass 2zd)

    /// Edit > Undo goes to nil: the first object up the chain from the
    /// first responder that answers `undo:` validates and performs it.
    private func undoTarget(_ window: NSWindow) -> NSResponder? {
        let undo = NSSelectorFromString("undo:")
        var responder = window.firstResponder
        while let r = responder, !r.responds(to: undo) { responder = r.nextResponder }
        return responder
    }

    private func editUndo(_ window: NSWindow, _ context: String) -> Bool {
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        guard let target = undoTarget(window) else { XCTFail("nothing answers undo: \(context)"); return false }
        let enabled = (target as? any NSMenuItemValidation)?.validateMenuItem(item)
            ?? (target as? any NSUserInterfaceValidations)?.validateUserInterfaceItem(item) ?? true
        XCTAssertTrue(enabled, "Edit > Undo is enabled after typing (\(context)), target \(type(of: target))")
        guard enabled else { return false }
        XCTAssertTrue(item.title.hasPrefix("Undo"), item.title)
        return NSApp?.sendAction(item.action!, to: target, from: item) ?? false
    }

    /// Typing in the template field and in a number field can be undone with
    /// Cmd-Z / Edit > Undo (0.2.32 could; the Batch window's own undo: since
    /// then asked the window's undo manager, not the field editor's).
    func testTypingInTheFormFieldsCanBeUndone() async throws {
        let (batch, window) = try await openRename("u")
        let template = try templateField(window)
        let before = template.stringValue
        let editor = try edit(template, window, type: "z")
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertEqual(editor.string, before + "z")
        XCTAssertTrue(editUndo(window, "template"))
        XCTAssertEqual(editor.string, before, "Cmd-Z takes the typing back")
        await settle()
        // After SwiftUI's next update: the form has the undone text, so nothing writes the typing back.
        XCTAssertEqual(batch.model.form.template, before, "the form follows the undo")
        XCTAssertEqual(template.stringValue, before)
        // Typing, a pause (the next event, as on screen), then Cmd-Z.
        _ = try edit(template, window, type: "q")
        await settle()
        XCTAssertEqual(batch.model.form.template, before + "q")
        XCTAssertTrue(editUndo(window, "template after a pause"))
        await settle()
        XCTAssertEqual(batch.model.form.template, before)
        XCTAssertEqual(template.stringValue, before)
        window.makeFirstResponder(nil)

        let number = try numberField(window)
        let was = number.stringValue
        let numberEditor = try edit(number, window, type: "7")
        XCTAssertEqual(numberEditor.string, was + "7")
        XCTAssertTrue(editUndo(window, "number"))
        XCTAssertEqual(numberEditor.string, was, "Cmd-Z takes the typing back in a number field too")
        window.makeFirstResponder(nil)
        await settle()
        XCTAssertEqual(number.stringValue, was)
    }
}

//
//  BatchAccessibilityTests.swift
//  ShrikeUITests
//
//  Every Batch checkbox has an accessibility title (its
//  label), read through the AX API on an offscreen Batch window.
//

import AppKit
import XCTest
@testable import ShrikeUI
import ShrikeCore
import SwiftUI

@MainActor
final class BatchAccessibilityTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-ax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        BatchWindowController.presentsWindows = false
    }

    override func tearDown() async throws {
        BatchWindowController.current?.close()
        BatchWindowController.presentsWindows = true
        try? FileManager.default.removeItem(at: dir)
    }

    private func openBatch() async throws -> BatchWindowController {
        let url = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        let batch = BatchWindowController.open(groups: [ImageGroup(primary: url)],
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        batch.announce = { _ in }
        let view = try XCTUnwrap(batch.window?.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return batch
    }

    /// The window's checkboxes as the AX API sees them: the button cell
    /// is the accessibility element of an NSButton.
    private func checkboxes(in view: NSView) -> [(button: NSButton, title: String?)] {
        func buttons(_ v: NSView) -> [NSButton] {
            ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons)
        }
        return buttons(view).compactMap { button in
            guard let cell = button.cell,
                  cell.accessibilityRole() == .checkBox else { return nil }
            return (button, cell.accessibilityTitle())
        }
    }

    func testEveryCheckboxHasItsLabelAsTheAccessibilityTitle() async throws {
        let batch = try await openBatch()
        defer { batch.close() }
        let found = checkboxes(in: try XCTUnwrap(batch.window?.contentView))
        XCTAssertEqual(found.map { $0.title ?? "" }.sorted(),
                       ["Convert", "Don't enlarge", "Keep metadata", "Remove location",
                        "Rename", "Resize", "Rotate"])
        XCTAssertTrue(found.allSatisfy { !($0.title ?? "").isEmpty }, "no untitled checkbox")
    }

    func testCheckboxesFollowAndChangeTheForm() async throws {
        let batch = try await openBatch()
        defer { batch.close() }
        let view = try XCTUnwrap(batch.window?.contentView)
        let model = batch.model
        func box(_ title: String) throws -> NSButton {
            try XCTUnwrap(checkboxes(in: view).first { $0.title == title }?.button, title)
        }
        // A click changes the form.
        let rename = try box("Rename")
        let before = model.form.renameOn
        XCTAssertEqual(rename.state == .on, before)
        rename.performClick(nil)
        XCTAssertEqual(model.form.renameOn, !before)
        // The form changes the box; a row that is off greys its boxes out.
        model.form.convertOn = false
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try box("Convert").state, .off)
        XCTAssertFalse(try box("Keep metadata").isEnabled)
        XCTAssertTrue(try box("Convert").isEnabled)
        model.form.convertOn = true
        try await Task.sleep(for: .milliseconds(50))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try box("Convert").state, .on)
        XCTAssertTrue(try box("Keep metadata").isEnabled)
    }

    /// 28a B.8: the queue's + and − buttons name themselves (title and label);
    /// the old SwiftUI image buttons were NSButtons with an empty title.
    func testQueueButtonsHaveNames() async throws {
        let batch = try await openBatch()
        defer { batch.close() }
        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        let all = buttons(try XCTUnwrap(batch.window?.contentView)).filter { !$0.isHiddenOrHasHiddenAncestor }
        let unnamed = all.filter { b in
            b.cell?.accessibilityRole() == .button && (b.accessibilityTitle() ?? "").isEmpty && (b.accessibilityLabel() ?? "").isEmpty
        }
        XCTAssertTrue(unnamed.isEmpty, "unnamed AppKit buttons: \(unnamed.map { type(of: $0) })")
        let names = all.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(names.contains("Add Photos"))
        XCTAssertTrue(names.contains("Remove from Queue"))
        let add = try XCTUnwrap(all.first { $0.accessibilityLabel() == "Add Photos" })
        XCTAssertEqual(add.accessibilityTitle(), "Add Photos")
        XCTAssertEqual(add.cell?.accessibilityTitle(), "Add Photos", "the cell is what the AX API reads")
        let size = add.frame.size
        XCTAssertTrue(size.width >= 10 && size.width <= 30 && size.height >= 10 && size.height <= 30, "\(size)")
        XCTAssertTrue(add.isEnabled)
        let remove = try XCTUnwrap(all.first { $0.accessibilityLabel() == "Remove from Queue" })
        XCTAssertFalse(remove.isEnabled, "nothing selected")
    }

    /// The AX elements of every visible AppKit button: (cell title, cell label).
    /// SwiftUI's own buttons expose nothing here (an NSHostingView answers no
    /// accessibility children in-process), which is why they are AppKit now.
    private func namedButtons(in view: NSView) -> [(button: NSButton, title: String, label: String)] {
        func buttons(_ v: NSView) -> [NSButton] { ((v as? NSButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        return buttons(view).filter { !$0.isHiddenOrHasHiddenAncestor && $0.cell?.accessibilityRole() != .checkBox }
            .map { ($0, $0.cell?.accessibilityTitle() ?? "", $0.cell?.accessibilityLabel() ?? "") }
    }

    private func host<V: View>(_ root: V) -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: root)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return (window, view)
    }

    /// 28a review rounds 2 and 4: the footer, running and result buttons carry
    /// their visible title as accessibility title and label (button and cell),
    /// with no invisible characters; keys and enabled states are kept.
    func testFooterRunningAndResultButtonsAreNamed() async throws {
        let batch = try await openBatch()
        defer { batch.close() }
        let form = namedButtons(in: try XCTUnwrap(batch.window?.contentView))
        func find(_ list: [(button: NSButton, title: String, label: String)], _ name: String) throws -> NSButton {
            let hit = try XCTUnwrap(list.first { $0.title == name }, "\(name) in \(list.map(\.title))")
            XCTAssertEqual(hit.label, name)
            XCTAssertEqual(hit.button.accessibilityTitle(), name)
            XCTAssertEqual(hit.button.title, name, "visible title, no invisible characters")
            return hit.button
        }
        // Pop-up pickers name themselves by value; their SwiftUI label is not checked here.
        XCTAssertTrue(form.filter { !($0.button is NSPopUpButton) }.allSatisfy { !$0.title.isEmpty && !$0.title.contains("\u{2063}") },
                      "unnamed: \(form.filter { $0.title.isEmpty }.map { "\($0.button.title)|\($0.button.frame.size)|\($0.button is NSPopUpButton)" })")
        let cancel = try find(form, "Cancel")
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
        let m = batch.model; let runTitle = BatchModel.Copy.footerRunTitle(reviewingRemaining: m.reviewingRemaining, queueCount: m.queue.count, processable: m.processableCount, changesOriginals: m.changesOriginals)
        let run = try find(form, runTitle)
        XCTAssertEqual(run.keyEquivalent, "\r", "Return is the default button")
        XCTAssertEqual(run.isEnabled, batch.model.canRun)

        let (runningWindow, running) = host(BatchRunningView(model: batch.model))
        defer { runningWindow.close() }
        let stop = try find(namedButtons(in: running), "Stop Batch")
        XCTAssertEqual(stop.keyEquivalent, ".")
        XCTAssertEqual(stop.keyEquivalentModifierMask, .command)

        var done = false
        let (doneWindow, result) = host(BatchDoneView(model: batch.model, actions: BatchViewActions(done: { done = true })))
        defer { doneWindow.close() }
        let list = namedButtons(in: result)
        let doneButton = try find(list, "Done")
        XCTAssertEqual(doneButton.keyEquivalent, "\r")
        doneButton.performClick(nil)
        XCTAssertTrue(done)
        let actions = try XCTUnwrap(list.first { $0.title == "Actions" }?.button as? NSPopUpButton)
        XCTAssertEqual(actions.itemTitles, ["Actions", "Copy Log", "Show Completed Files", "Open Completed in Shrike",
                                            "Undo Batch", "Run Another Batch"])
        XCTAssertFalse(actions.item(withTitle: "Undo Batch")?.isEnabled ?? true, "nothing to undo")
    }
}

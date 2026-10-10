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

@MainActor
final class BatchAccessibilityTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
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
}

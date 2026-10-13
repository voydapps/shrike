//
//  ShortcutsWindowSearch0210Tests.swift
//  ShrikeUITests
//
//  0.2.10, audit 2026-10-13 items 1 and 2: the Shortcuts window keeps the
//  Command symbol while filtered, and its search field takes typing on open.
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ShortcutsWindowSearch0210Tests: XCTestCase {

    /// Item 1: "Zoom In" lives in Viewer, Edit Mode and Compare. Rows keyed by
    /// the action alone were mixed up when the filter changed.
    func testRowIdsAreUniqueAcrossTheWholeWindow() {
        let model = ShortcutsWindowModel()
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            model.preset = preset
            model.query = ""
            let ids = model.listSections.flatMap { $0.rows.map(\.id) }
            XCTAssertEqual(ids.count, Set(ids).count, "every row id is unique (\(preset))")
        }
    }

    func testFilteredRowsKeepTheirKeysIncludingTheCommandSymbol() {
        let model = ShortcutsWindowModel()
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            model.preset = preset
            model.query = ""
            let all = model.listSections
            var checked = 0
            for section in all {
                for row in section.rows {
                    model.query = row.action
                    let hit = model.listSections.first { $0.title == section.title }?
                        .rows.first { $0.action == row.action }
                    XCTAssertEqual(hit?.keys, row.keys, "\(section.title)/\(row.action) filtered by its title")
                    XCTAssertEqual(hit?.id, row.id)
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 50)
            model.query = "zoom"
            let zoomIn = model.listSections.first { $0.title == "Viewer" }?.rows.first { $0.action == "Zoom In" }
            let zoomOut = model.listSections.first { $0.title == "Viewer" }?.rows.first { $0.action == "Zoom Out" }
            if preset == .macNative {
                XCTAssertEqual(zoomIn?.keys, "⌘+, ⌘=, ⇧⌘+")
                XCTAssertEqual(zoomOut?.keys, "⌘-")
                // Edit Mode keeps its own keys, Compare has bare ones, side by side.
                let edit = model.listSections.first { $0.title == "Edit Mode" }?.rows.first { $0.action == "Zoom In" }
                let compare = model.listSections.first { $0.title == "Compare" }?.rows.first { $0.action == "Zoom In" }
                XCTAssertEqual(edit?.keys, "⌘+, ⌘=")
                XCTAssertEqual(compare?.keys, "+, =, ⇧+")
            }
            model.query = ""
        }
    }

    /// Item 9: Esc also closes a viewer that has no Browser, and the list says so.
    func testEscapeLabelCoversClosingALoneViewer() {
        let viewer = ShortcutsTab.sections(for: .macNative).first { $0.title == "Viewer" }
        let esc = viewer?.rows.first { $0.keys == "Esc" }
        XCTAssertEqual(esc?.action, "Exit Full Screen, Return to Browser, or Close")
    }

    /// Item 2: the search field is the first responder when the window opens,
    /// typing lands, and the same holds on a re-open.
    func testSearchFieldTakesTypingOnOpenAndReopen() throws {
        let controller = ShortcutsWindowController.shared
        for round in 1...2 {
            controller.modelForTesting.query = ""
            controller.show()
            let window = try XCTUnwrap(controller.window)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "round \(round): a field editor is first responder")
            let field = try XCTUnwrap(editor.delegate as? NSTextField, "round \(round): it belongs to the search field")
            XCTAssertTrue(field.isEditable)
            editor.insertText("zoom", replacementRange: NSRange(location: NSNotFound, length: 0))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(controller.modelForTesting.query, "zoom", "round \(round): typing reached the model")
            window.close()
        }
    }
}

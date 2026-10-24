//
//  ShortcutTableTests.swift
//  ShrikeUITests
//
//  One shortcut table feeds the keymaps, the menu bar, the
//  tooltips and Settings ▸ Shortcuts.
//

import XCTest
import AppKit
@testable import ShrikeUI
import enum ShrikeCore.ShortcutPreset

@MainActor
final class ShortcutTableTests: XCTestCase {

    private let presets: [ShortcutPreset] = [.macNative, .fastStoneCompat]
    private let contexts: [ShrikeUI.ShortcutContext] = [.viewer, .browser, .editMode]

    private func snap(_ key: String, _ mods: NSEvent.ModifierFlags = []) -> ShrikeUI.KeyEventSnapshot {
        KeyEventSnapshot(key: key, modifiers: mods)
    }

    /// Fails when one key means two things (or is listed twice) in a context.
    func testNoDuplicateKeysWithinAContext() {
        for preset in presets {
            for context in contexts {
                var seen: [KeyBinding: ShrikeCommand] = [:]
                for row in ShortcutTable.rows(for: preset) where row.context == context {
                    if let other = seen[row.binding] {
                        XCTFail("\(preset) \(context): \(row.binding.displayString) is bound to both \(other) and \(row.command)")
                    }
                    seen[row.binding] = row.command
                }
                XCTAssertFalse(seen.isEmpty)
            }
        }
    }

    /// Special keys use the Cocoa function-key code points.
    func testSpecialKeysUseCocoaCodePoints() {
        XCTAssertEqual(SpecialKey.home.unicodeScalars.first?.value, UInt32(NSHomeFunctionKey))
        XCTAssertEqual(SpecialKey.home, "\u{F729}")
        XCTAssertEqual(SpecialKey.end, "\u{F72B}")
        XCTAssertEqual(SpecialKey.pageUp, "\u{F72C}")
        XCTAssertEqual(SpecialKey.pageDown, "\u{F72D}")
        XCTAssertEqual(SpecialKey.forwardDelete, "\u{F728}")
        XCTAssertEqual(SpecialKey.f2, "\u{F705}")
        XCTAssertEqual(SpecialKey.f5, "\u{F708}")
        for preset in presets {
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F729}"), context: .viewer, preset: preset), .firstImage)
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F72B}"), context: .viewer, preset: preset), .lastImage)
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F72C}"), context: .viewer, preset: preset), .prevImage)
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F72D}"), context: .viewer, preset: preset), .nextImage)
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F705}"), context: .viewer, preset: preset), .rename)
            XCTAssertEqual(ViewerKeyMap.action(for: snap("\u{F708}"), context: .viewer, preset: preset), .slideshow)
        }
    }

    /// The Levels rows are live now: the menu and
    /// the viewer keys both reach them.
    func testLevelsRowsAreLive() {
        let mac = ShortcutTable.rows(for: .macNative)
        func has(_ c: ShrikeCommand, _ b: KeyBinding) -> Bool {
            mac.contains { $0.command == c && $0.context == .viewer && $0.binding == b }
        }
        XCTAssertTrue(has(.levels, KeyBinding("l", [.command, .shift])))
        XCTAssertTrue(has(.autoContrast, KeyBinding("l", [.command, .shift, .option])))
        XCTAssertTrue(has(.autoColor, KeyBinding("b", [.command, .shift])))
        for c in [ShrikeCommand.levels, .autoContrast, .autoColor] {
            XCTAssertNotNil(ShortcutTable.menuBinding(for: c))
        }
        XCTAssertEqual(ViewerKeyMap.action(for: .levels, context: .viewer), .selectEditTool(.levels))
        XCTAssertEqual(ViewerKeyMap.action(for: .autoContrast, context: .viewer), .autoLevels(.contrast))
        XCTAssertEqual(ViewerKeyMap.action(for: .autoColor, context: .viewer), .autoLevels(.color))
    }

    /// Menu keys are the same in both presets (the menu is built once).
    func testMenuKeysExistInBothPresets() {
        for command in ShrikeCommand.allCases {
            guard let binding = ShortcutTable.menuBinding(for: command) else { continue }
            let contextsWithCommand = contexts.filter {
                !ShortcutTable.bindings(for: command, context: $0, preset: .macNative).isEmpty
            }
            for context in contextsWithCommand where context != .editMode {
                let mac = ShortcutTable.bindings(for: command, context: context, preset: .macNative)
                guard mac.contains(binding) else { continue }
                XCTAssertTrue(
                    ShortcutTable.bindings(for: command, context: context, preset: .fastStoneCompat).contains(binding),
                    "\(command) \(binding.displayString) missing from FastStone \(context)"
                )
            }
        }
    }

    func testPresetDifferences() {
        let backspace = snap(SpecialKey.backspace)
        XCTAssertNil(ViewerKeyMap.action(for: backspace, context: .viewer, preset: .macNative), "plain ⌫ no longer trashes (spec 25 §5.2)")
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.backspace, .command), context: .viewer, preset: .macNative), .deleteToTrash)
        XCTAssertEqual(ViewerKeyMap.action(for: backspace, context: .viewer, preset: .fastStoneCompat), .prevImage)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("1"), context: .viewer, preset: .macNative), .rate(1))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("1"), context: .viewer, preset: .fastStoneCompat), .zoomActualSize)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("1", .control), context: .viewer, preset: .fastStoneCompat), .rate(1))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("f"), context: .viewer, preset: .fastStoneCompat), .toggleFullscreen)
        XCTAssertNil(ViewerKeyMap.action(for: snap("f"), context: .viewer, preset: .macNative))
    }

    /// Viewer keys.
    func testViewerSurfaceKeys() {
        XCTAssertEqual(ViewerKeyMap.action(for: snap("b", .command), context: .viewer), .showInBrowser)
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.up, .command), context: .viewer), .showInBrowser)
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.escape), context: .viewer), .exitFullscreen)
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.right, [.command, .option]), context: .viewer), .nextFolder)
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.left, [.command, .option]), context: .viewer), .prevFolder)
    }

    /// Keys whose meaning changed when the shortcut table became the one
    /// source (they replace the old ViewerKeyMap / EditKeyboard tests
    /// for the same keys).
    func testShortcutTableKeyChanges() {
        let fs = ShortcutPreset.fastStoneCompat
        XCTAssertEqual(ViewerKeyMap.action(for: snap("r", [.command, .shift]), context: .viewer), .rotateLossless(quarters: 2))
        // Edit mode turns the recipe.
        XCTAssertEqual(ViewerKeyMap.action(for: snap("r", [.command, .shift]), context: .editMode), .editRotate90(quarters: 2))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("l", .command), context: .viewer), .rotateLossless(quarters: -1))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("r", [.command, .option]), context: .viewer), .revealInFinder)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("c", .command), context: .viewer), .copyBitmap)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("c", [.command, .option]), context: .viewer), .copyPath)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("l"), context: .viewer, preset: fs), .rotateLossless(quarters: -1))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("r"), context: .viewer, preset: fs), .rotateLossless(quarters: 1))
        XCTAssertEqual(ViewerKeyMap.action(for: snap("w"), context: .viewer, preset: fs), .revealInFinder)
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.returnKey), context: .viewer, preset: fs), .toggleFullscreen)
        XCTAssertEqual(ViewerKeyMap.action(for: snap("c"), context: .editMode), .selectEditTool(.crop))
        // Nav keys work in edit mode and ask first.
        XCTAssertEqual(ViewerKeyMap.action(for: snap(SpecialKey.right), context: .editMode), .nextImage)
    }

    /// Arrows belong to the collection view; ⌫ trashes; ⌘↑ goes up.
    func testBrowserKeys() {
        for arrow in [SpecialKey.left, SpecialKey.right, SpecialKey.up, SpecialKey.down] {
            XCTAssertNil(BrowserKeyMap.action(for: snap(arrow)))
        }
        XCTAssertNil(BrowserKeyMap.action(for: snap(SpecialKey.backspace)))
        XCTAssertEqual(BrowserKeyMap.action(for: snap(SpecialKey.backspace, .command)), .deleteToTrash)
        XCTAssertNil(BrowserKeyMap.action(for: snap(SpecialKey.forwardDelete)))
        XCTAssertEqual(BrowserKeyMap.action(for: snap(SpecialKey.up, .command)), .upOneFolder)
        XCTAssertEqual(BrowserKeyMap.action(for: snap(SpecialKey.down, .command)), .openInViewer)
        XCTAssertEqual(BrowserKeyMap.action(for: snap(SpecialKey.returnKey)), .openInViewer)
        XCTAssertEqual(BrowserKeyMap.action(for: snap(SpecialKey.space)), .openInViewer)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("b", .command)), .toggleViewer)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("[", .command)), .goBack)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("]", .command)), .goForward)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("a", .command)), .selectAll)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("3")), .rate(3))
        XCTAssertEqual(BrowserKeyMap.action(for: snap("\\")), .toggleFlag)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("c")), .beginCopyChord)
        XCTAssertEqual(BrowserKeyMap.action(for: snap("2"), chordPrefix: "c"), .fileToFolder(.copy, .slot(2)))
    }

    func testDisplayStringsAndTooltips() {
        XCTAssertEqual(KeyBinding("r", [.command, .option]).displayString, "⌥⌘R")
        XCTAssertEqual(KeyBinding(SpecialKey.backspace, .command).displayString, "⌘⌫")
        XCTAssertEqual(KeyBinding(SpecialKey.backspace, .command).menuKeyEquivalent, "\u{8}")
        XCTAssertNil(KeyBinding("q").menuKeyEquivalent, "bare letters never go on menu items")
        XCTAssertEqual(KeyBinding(SpecialKey.f2).menuKeyEquivalent, SpecialKey.f2)
        XCTAssertEqual(ShortcutTable.displayString(for: .moveToTrash, context: .browser, preset: .macNative), "⌘⌫")
        XCTAssertTrue(ShortcutTable.tooltip(for: .previousImage, context: .viewer).hasPrefix("Previous Photo  ·  "))
        XCTAssertEqual(ShortcutTable.tooltip(for: .settings, context: .viewer), "Settings…")
    }

    func testShortcutsTabListsEveryRowWithKeys() {
        for preset in presets {
            let sections = ShortcutsTab.sections(for: preset)
            XCTAssertEqual(sections.map(\.title), ["Viewer", "Browser", "Edit Mode", "Compare"])
            for section in sections {
                XCTAssertFalse(section.rows.isEmpty)
                XCTAssertFalse(section.rows.contains { $0.keys.isEmpty })
                XCTAssertFalse(section.rows.contains { $0.action.contains("coming soon") })
            }
        }
    }
}

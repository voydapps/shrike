//
//  BrowserKeyRoutingTests.swift
//  ShrikeUITests
//
//  Key routing: grid / list ask the Browser key map first,
//  Welcome: Return on a Recent row, live tooltips.
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class BrowserKeyRoutingTests: XCTestCase {

    static func key(_ chars: String, _ flags: NSEvent.ModifierFlags = [], keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    func testGridAsksKeyMapFirstAndSkipsSuperWhenConsumed() {
        let grid = BrowserCollectionView()
        var seen: [String] = []
        grid.keyHandler = { event in
            seen.append(event.charactersIgnoringModifiers ?? "")
            return true
        }
        grid.keyDown(with: Self.key("q", keyCode: 12))
        XCTAssertEqual(seen, ["q"])
    }

    func testListAsksKeyMapFirst() {
        let list = BrowserTableView()
        var consumed = 0
        list.keyHandler = { _ in consumed += 1; return true }
        list.keyDown(with: Self.key("3", keyCode: 20))
        XCTAssertEqual(consumed, 1)
    }

    /// The Browser keys must resolve in the browser context (Mac preset);
    /// plain arrows must not (the grid moves by its real column count).
    func testBrowserKeyMapCoversSpecKeysAndLeavesArrowsAlone() {
        let mapped: [(String, NSEvent.ModifierFlags)] = [
            (SpecialKey.returnKey, []), (SpecialKey.down, .command),
            (SpecialKey.backspace, .command),
            ("0", []), ("5", []), ("q", []), ("\\", []), ("t", []), ("c", []), ("m", []),
            (SpecialKey.f2, []), ("b", .command), (SpecialKey.up, .command),
            ("[", .command), ("]", .command), ("a", .command),
        ]
        for (key, flags) in mapped {
            let command = ShortcutTable.command(
                for: ShrikeUI.KeyEventSnapshot(key: key, modifiers: flags), context: .browser, preset: .macNative
            )
            XCTAssertNotNil(command, "\(key) \(flags) must be mapped in the browser")
        }
        for arrow in [SpecialKey.up, SpecialKey.down, SpecialKey.left, SpecialKey.right] {
            let snap = ShrikeUI.KeyEventSnapshot(key: arrow)
            XCTAssertNil(BrowserKeyMap.action(for: snap, preset: .macNative))
            XCTAssertNil(BrowserKeyMap.action(for: snap, preset: .fastStoneCompat))
        }
    }

    func testWelcomeReturnOnFocusedRecentRowOpensIt() {
        let first = FileManager.default.temporaryDirectory
        let second = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-none")
        let controller = WelcomeWindowController(recentURLs: { [first, second] })
        defer { controller.close() }
        var opened: [URL] = []
        controller.onOpenURLs = { opened += $0 }
        controller.reloadRecents()
        guard let window = controller.window as? WelcomeWindow else {
            return XCTFail("Welcome uses WelcomeWindow")
        }
        XCTAssertTrue(window.makeFirstResponder(controller.recentRows[1]))
        XCTAssertTrue(window.performKeyEquivalent(with: Self.key(SpecialKey.returnKey, keyCode: 36)))
        XCTAssertEqual(opened, [second])
        // ↑ moves to the row above.
        controller.recentRows[1].keyDown(with: Self.key(SpecialKey.up, keyCode: 126))
        XCTAssertTrue(window.firstResponder === controller.recentRows[0])
        // Tab order: Open…, Open Folder…, list, back to Open….
        XCTAssertTrue(controller.openFolderButton.nextKeyView === controller.recentRows[0])
        XCTAssertTrue(controller.recentRows[0].nextKeyView === controller.openButton)
    }

    func testTooltipFormatUsesPresetKey() {
        XCTAssertEqual(LiveTooltips.text(.previousImage, context: .viewer, preset: .macNative),
                       "Previous Image  ·  ←")
        XCTAssertEqual(LiveTooltips.text(.resetEdits, context: .editMode, preset: .macNative),
                       "Reset Edits")
        // ⌫ trashes in the Mac preset; FastStone's first trash key is ⌦.
        XCTAssertNotEqual(LiveTooltips.text(.moveToTrash, context: .viewer, preset: .macNative),
                          LiveTooltips.text(.moveToTrash, context: .viewer, preset: .fastStoneCompat))
    }
}

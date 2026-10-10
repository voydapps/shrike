//
//  EditKeyboardTests.swift
//  ShrikeUITests
//
//  Keymap tests covering the edit-mode overrides. The
//  plain viewer-mode shortcuts are covered in `ViewerKeyMapTests`; this
//  file only exercises the edit-mode branch and the `⌘K <letter>` chord
//  that hops between tools.
//
//  Covers:
//    - Bare `E` → enterEditMode (viewer context)
//    - `⌘K C/R/S/J` resolves to selectEditTool(.crop/.rotate/.resize/.color)
//    - In edit mode: Esc → exitEditMode, ⌘S/⌘⇧S → save / save-as,
//      ⌘Z/⌘⇧Z → undoEdit/redoEdit, [/] → editRotate90(-1/+1)
//    - In edit mode: nav keys (space, ⇧space, arrows, home/end, pgup/pgdn)
//      resolve to navigation; the window asks through the exit alert
//    - In edit mode: ⌘R / ⌘⇧R / ⌘⌥R → rotateLossless with correct quarters
//    - `⌘K` inside edit mode still returns toggleFilmstrip (the chord
//      timer is re-armed at the window layer)
//

import XCTest
import AppKit
@testable import ShrikeUI

final class EditKeyboardTests: XCTestCase {

    // MARK: - Helpers

    private func snap(
        _ key: String,
        mods: NSEvent.ModifierFlags = []
    ) -> KeyEventSnapshot {
        KeyEventSnapshot(key: key, modifiers: mods)
    }

    private func resolve(
        _ key: String,
        mods: NSEvent.ModifierFlags = [],
        context: ShortcutContext = .editMode,
        chord: Character? = nil
    ) -> ViewerAction? {
        ViewerKeyMap.action(
            for: snap(key, mods: mods),
            context: context,
            preset: false ? .fastStoneCompat : .macNative,
            chordPrefix: chord
        )
    }

    // MARK: - Entry: bare `E`

    func testBareE_EntersEditMode_InViewer() {
        XCTAssertEqual(
            resolve("e", context: .viewer),
            .enterEditMode
        )
    }

    func testShiftE_OpensExternalEditor_NotEnterEdit() {
        // ⇧E kept for the external-editor path note.
        XCTAssertNotEqual(
            resolve("e", mods: [.shift], context: .viewer),
            .enterEditMode
        )
    }

    // MARK: - ⌘K chord removed

    func testCmdK_ChordNoLongerSelectsTools() {
        XCTAssertNil(resolve("c", context: .viewer, chord: "k"))
        XCTAssertNil(resolve("r", context: .editMode, chord: "k"))
    }

    func testEditMode_Return_IsDone() {
        XCTAssertEqual(resolve("\r"), .applyCurrentEditTool)
    }

    // MARK: - Edit-mode: Esc / Cmd-S / Cmd-Z

    func testEditMode_Escape_ExitsEditMode() {
        XCTAssertEqual(resolve("\u{1B}"), .exitEditMode)
    }

    func testEditMode_CmdZ_IsUndoEdit() {
        XCTAssertEqual(resolve("z", mods: [.command]), .undoEdit)
    }

    func testEditMode_CmdShiftZ_IsRedoEdit() {
        XCTAssertEqual(
            resolve("z", mods: [.command, .shift]),
            .redoEdit
        )
    }

    func testEditMode_CmdS_IsSaveEditedFile() {
        XCTAssertEqual(resolve("s", mods: [.command]), .saveEditedFile)
    }

    func testEditMode_CmdShiftS_IsSaveEditedFileAs() {
        XCTAssertEqual(
            resolve("s", mods: [.command, .shift]),
            .saveEditedFileAs
        )
    }

    // MARK: - Edit-mode: bracket keys

    func testEditMode_LeftBracket_RotatesCCW() {
        XCTAssertEqual(resolve("["), .editRotate90(quarters: -1))
    }

    func testEditMode_RightBracket_RotatesCW() {
        XCTAssertEqual(resolve("]"), .editRotate90(quarters: 1))
    }

    // MARK: - Edit-mode: ⌘R family

    // In edit mode ⌘R turns the recipe, not the file.
    func testEditMode_CmdR_RotatesTheRecipeCW() {
        XCTAssertEqual(
            resolve("r", mods: [.command]),
            .editRotate90(quarters: 1)
        )
    }

    // MARK: - Edit-mode: navigation keys

    /// The navigation keys resolve in edit mode too; `dispatch` then asks
    /// through the exit alert when there are changes.
    func testEditMode_NavigationKeysResolve() {
        XCTAssertEqual(resolve(" "), .nextImage)
        XCTAssertEqual(resolve(" ", mods: .shift), .prevImage)
        XCTAssertEqual(resolve("\u{F703}"), .nextImage)
        XCTAssertEqual(resolve("\u{F702}"), .prevImage)
        XCTAssertEqual(resolve("\u{F729}"), .firstImage)
        XCTAssertEqual(resolve("\u{F72B}"), .lastImage)
        XCTAssertEqual(resolve("\u{F72C}"), .prevImage)
        XCTAssertEqual(resolve("\u{F72D}"), .nextImage)
        XCTAssertEqual(resolve("\u{F703}", mods: [.command, .option]), .nextFolder)
        XCTAssertEqual(resolve("\u{F702}", mods: [.command, .option]), .prevFolder)
    }

    /// ⇧Space goes back in the viewer as well.
    func testViewer_ShiftSpace_IsPrevious() {
        XCTAssertEqual(resolve(" ", mods: .shift, context: .viewer), .prevImage)
        XCTAssertEqual(resolve(" ", context: .viewer), .nextImage)
    }

    // MARK: - Edit-mode: ⌘K preserved as toggleFilmstrip

    func testEditMode_CmdK_IsToggleFilmstrip() {
        // ⌘K is only Show Filmstrip, no tool chord.
        XCTAssertEqual(
            resolve("k", mods: [.command]),
            .toggleFilmstrip
        )
    }

    // MARK: - Edit-mode: other command keys ignored

    func testEditMode_CmdE_IsIgnored() {
        // ⌘E opens an external editor in viewer; inside edit mode we
        // don't want that surface — the user is already editing.
        XCTAssertNil(resolve("e", mods: [.command]))
    }

    func testEditMode_BareLetters_Ignored() {
        // Edit mode intentionally ignores bare letter shortcuts so
        // typing into a text field (W/H) doesn't trigger viewer-style
        // actions. Sampling one letter is enough — the resolver falls
        // through to nil by default.
        XCTAssertNil(resolve("l"))
        XCTAssertNil(resolve("h"))
        XCTAssertNil(resolve("f"))
    }
}

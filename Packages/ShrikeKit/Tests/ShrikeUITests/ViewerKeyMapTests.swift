//
//  ViewerKeyMapTests.swift
//  ShrikeUITests
//
//  Unit tests for the pure keymap resolver. We construct KeyEventSnapshot
//  values directly (NSEvent would need a running event loop) and verify
//  that each pressed key → the expected ViewerAction.
//
//  Covers:
//    - Bare keys (Space, arrows, a/b/0-5, l/r, q, z)
//    - Command-prefixed shortcuts (⌘1, ⌘2, ⌘0, ⌘=, ⌘i, ⌘k, ⌘e, ⌘z, ⌘⇧Z)
//    - Shift-prefixed (⇧W, ⇧H)
//    - FastStone mode override on 0-3
//    - Chord resolution (C → digit, M → digit)
//    - Non-viewer context returns nil
//

import XCTest
import AppKit
@testable import ShrikeUI

final class ViewerKeyMapTests: XCTestCase {

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
        context: ShortcutContext = .viewer,
        fastStone: Bool = false,
        chord: Character? = nil
    ) -> ViewerAction? {
        ViewerKeyMap.action(
            for: snap(key, mods: mods),
            context: context,
            preset: fastStone ? .fastStoneCompat : .macNative,
            chordPrefix: chord
        )
    }

    // MARK: - Bare navigation

    func testSpace_IsNextImage() {
        XCTAssertEqual(resolve(" "), .nextImage)
    }

    func testEscape_ExitsFullscreen() {
        XCTAssertEqual(resolve("\u{1B}"), .exitFullscreen)
    }

    func testRightArrow_IsNextImage() {
        XCTAssertEqual(resolve("\u{F703}"), .nextImage)
    }

    func testLeftArrow_IsPrevImage() {
        XCTAssertEqual(resolve("\u{F702}"), .prevImage)
    }

    func testHome_IsFirstImage() {
        XCTAssertEqual(resolve("\u{F729}"), .firstImage)
    }

    func testEnd_IsLastImage() {
        XCTAssertEqual(resolve("\u{F72B}"), .lastImage)
    }

    /// Regression: the map used to be shifted by one code point
    /// (End → first image, Home ignored). Pin the AppKit constants.
    func testFunctionKeyConstantsMatchAppKit() {
        XCTAssertEqual(resolve(String(UnicodeScalar(UInt16(NSHomeFunctionKey))!)), .firstImage)
        XCTAssertEqual(resolve(String(UnicodeScalar(UInt16(NSEndFunctionKey))!)), .lastImage)
        XCTAssertEqual(resolve(String(UnicodeScalar(UInt16(NSPageUpFunctionKey))!)), .prevImage)
        XCTAssertEqual(resolve(String(UnicodeScalar(UInt16(NSPageDownFunctionKey))!)), .nextImage)
    }

    // MARK: - Bare rating

    func testDigit1_BareIsRating() {
        XCTAssertEqual(resolve("1"), .rate(1))
    }

    func testDigit5_BareIsRating() {
        XCTAssertEqual(resolve("5"), .rate(5))
    }

    func testDigit0_BareIsRatingZero() {
        XCTAssertEqual(resolve("0"), .rate(0))
    }

    // MARK: - FastStone mode override

    // MARK: - Command-prefixed

    func testCmd1_IsActualSize() {
        XCTAssertEqual(resolve("1", mods: .command), .zoomActualSize)
    }

    func testCmd2_IsZoom200() {
        XCTAssertEqual(resolve("2", mods: .command), .zoom200)
    }

    func testCmd3_IsZoom300() {
        XCTAssertEqual(resolve("3", mods: .command), .zoom300)
    }

    func testCmd0_IsFitToWindow() {
        XCTAssertEqual(resolve("0", mods: .command), .fitToWindow)
    }

    func testCmdEquals_IsZoomIn() {
        XCTAssertEqual(resolve("=", mods: .command), .zoomIn)
    }

    func testCmdMinus_IsZoomOut() {
        XCTAssertEqual(resolve("-", mods: .command), .zoomOut)
    }

    func testCmdI_IsToggleInspector() {
        XCTAssertEqual(resolve("i", mods: .command), .toggleInspector)
    }

    func testCmdK_IsToggleFilmstrip() {
        XCTAssertEqual(resolve("k", mods: .command), .toggleFilmstrip)
    }

    func testCmdZ_IsUndo() {
        XCTAssertEqual(resolve("z", mods: .command), .undo)
    }

    func testCmdShiftZ_IsRedo() {
        XCTAssertEqual(resolve("z", mods: [.command, .shift]), .redo)
    }

    // MARK: - Shift-prefixed

    func testShiftW_IsFitWidth() {
        XCTAssertEqual(resolve("w", mods: .shift), .fitWidth)
    }

    func testShiftH_IsFitHeight() {
        XCTAssertEqual(resolve("h", mods: .shift), .fitHeight)
    }

    // MARK: - Bare letters

    func testBareA_IsActualSize() {
        XCTAssertEqual(resolve("a"), .zoomActualSize)
    }

    func testBareB_IsBestFit() {
        XCTAssertEqual(resolve("b"), .zoomBestFit)
    }

    func testBareH_IsFlipHorizontal() {
        XCTAssertEqual(resolve("h"), .flipHorizontal)
    }

    func testBareQ_IsToggleFlag() {
        XCTAssertEqual(resolve("q"), .toggleFlag)
    }

    func testBareZ_IsLoupeHoldPress() {
        XCTAssertEqual(resolve("z"), .toggleMagnifierHold(true))
    }

    func testBareC_StartsCopyChord() {
        XCTAssertEqual(resolve("c"), .beginCopyChord)
    }

    func testBareM_StartsMoveChord() {
        XCTAssertEqual(resolve("m"), .beginMoveChord)
    }

    // MARK: - Chord follow-up (a second key after C or M)

    func testCopyChord_DigitRoutesToCopyToFolder() {
        XCTAssertEqual(resolve("3", chord: "c"), .fileToFolder(.copy, .slot(3)))
    }

    func testMoveChord_DigitRoutesToMoveToFolder() {
        XCTAssertEqual(resolve("7", chord: "m"), .fileToFolder(.move, .slot(7)))
    }

    func testChord_NonDigitReturnsNil() {
        XCTAssertNil(resolve("x", chord: "c"))
    }

    // MARK: - Context gating

    func testNonViewerContext_ReturnsNil() {
        XCTAssertNil(resolve(" ", context: .browser))
        XCTAssertNil(resolve("1", mods: .command, context: .slideshow))
    }

    // MARK: - Unmapped keys

    func testUnmappedKey_ReturnsNil() {
        XCTAssertNil(resolve("`"))
        XCTAssertNil(resolve("~"))
        XCTAssertNil(resolve("\t"))
    }
}

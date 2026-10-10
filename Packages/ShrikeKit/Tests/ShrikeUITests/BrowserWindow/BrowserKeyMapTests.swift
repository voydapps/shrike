//
//  BrowserKeyMapTests.swift
//  ShrikeUITests
//
//  Covers `BrowserKeyMap.action(for:chordPrefix:)`. Pure resolver, tested
//  by constructing `KeyEventSnapshot` directly like ViewerKeyMapTests.
//

import XCTest
import AppKit
@testable import ShrikeUI

final class BrowserKeyMapTests: XCTestCase {

    // MARK: - Helpers

    private func snap(_ key: String, mods: NSEvent.ModifierFlags = []) -> KeyEventSnapshot {
        KeyEventSnapshot(key: key, modifiers: mods)
    }

    private func resolve(
        _ key: String,
        mods: NSEvent.ModifierFlags = [],
        chord: Character? = nil
    ) -> BrowserAction? {
        BrowserKeyMap.action(for: snap(key, mods: mods), chordPrefix: chord)
    }

    // MARK: - Ratings 0-5

    func testBareDigit_SetsRating() {
        XCTAssertEqual(resolve("0"), .rate(0))
        XCTAssertEqual(resolve("1"), .rate(1))
        XCTAssertEqual(resolve("2"), .rate(2))
        XCTAssertEqual(resolve("3"), .rate(3))
        XCTAssertEqual(resolve("4"), .rate(4))
        XCTAssertEqual(resolve("5"), .rate(5))
    }

    func testDigitWithCommand_IsViewMode() {
        XCTAssertEqual(resolve("1", mods: .command), .viewModeGrid)
        XCTAssertEqual(resolve("2", mods: .command), .viewModeFilmstrip)
        XCTAssertEqual(resolve("3", mods: .command), .viewModeList)
    }

    // MARK: - Flag

    func testQ_TogglesFlag() {
        XCTAssertEqual(resolve("q"), .toggleFlag)
    }

    func testBackslash_TogglesFlag() {
        XCTAssertEqual(resolve("\\"), .toggleFlag)
    }

    // MARK: - Selection

    func testReturn_IsOpenInViewer() {
        XCTAssertEqual(resolve("\u{0D}"), .openInViewer)
    }

    // MARK: - Command combinations

    func testCmdA_SelectAll() {
        XCTAssertEqual(resolve("a", mods: .command), .selectAll)
    }

    func testCmdShiftA_DeselectAll() {
        XCTAssertEqual(resolve("a", mods: [.command, .shift]), .deselectAll)
    }

    func testCmdF_FocusSearch() {
        XCTAssertEqual(resolve("f", mods: .command), .focusSearch)
    }

    func testBareC_BeginsCopyChord() {
        XCTAssertEqual(resolve("c"), .beginCopyChord)
    }

    func testBareM_BeginsMoveChord() {
        XCTAssertEqual(resolve("m"), .beginMoveChord)
    }

    func testCmdB_TogglesViewer() {
        XCTAssertEqual(resolve("b", mods: .command), .toggleViewer)
    }

    // MARK: - Chord follow-ups (a second key after C or M)

    func testChordC_DigitRoutesToCopyToFolder() {
        XCTAssertEqual(resolve("1", chord: "c"), .fileToFolder(.copy, .slot(1)))
        XCTAssertEqual(resolve("9", chord: "c"), .fileToFolder(.copy, .slot(9)))
    }

    func testChordM_DigitRoutesToMoveToFolder() {
        XCTAssertEqual(resolve("3", chord: "m"), .fileToFolder(.move, .slot(3)))
    }

    func testChord_NonDigit_ReturnsNil() {
        XCTAssertNil(resolve("a", chord: "c"))
        XCTAssertNil(resolve("\u{F703}", chord: "c"))
    }

    // MARK: - Unmapped

    func testUnmappedKey_ReturnsNil() {
        XCTAssertEqual(resolve("t"), .editTags, "T opens Tags")
        XCTAssertNil(resolve("u"))
        XCTAssertNil(resolve("z", mods: [.command, .control, .option]))
    }
}

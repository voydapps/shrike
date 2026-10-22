//
//  KeyCharactersTests.swift
//  ShrikeUITests
//
//  Plain letter shortcuts work on a non-Latin layout
//  (RussianWin: Q types "й"). The ASCII layout is a fixed map here, so
//  the test machine's layout never decides the result.
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class KeyCharactersTests: XCTestCase {

    /// US key codes → (plain, shifted).
    final class FixedASCIILayout: ASCIIKeyLayout {
        static let us: [UInt16: (String, String)] = [
            12: ("q", "Q"), 1: ("s", "S"), 13: ("w", "W"), 4: ("h", "H"),
            8: ("c", "C"), 46: ("m", "M"), 40: ("k", "K"), 6: ("z", "Z"),
            24: ("=", "+"), 18: ("1", "!"), 20: ("3", "#"), 15: ("r", "R"),
        ]
        var calls = 0
        func character(keyCode: UInt16, shift: Bool) -> String? {
            calls += 1
            guard let pair = Self.us[keyCode] else { return nil }
            return shift ? pair.1 : pair.0
        }
    }

    private var layout = FixedASCIILayout()

    override func setUp() async throws {
        try await super.setUp()
        layout = FixedASCIILayout()
        KeyCharacters.asciiLayout = layout
    }

    override func tearDown() async throws {
        KeyCharacters.asciiLayout = SystemASCIIKeyLayout.shared
        try await super.tearDown()
    }

    static func key(_ chars: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [],
                    unshifted: String? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode
        )!
    }

    // MARK: Snapshot

    func testCyrillicLetterFallsBackToASCIIKey() {
        XCTAssertEqual(KeyEventSnapshot.from(Self.key("й", keyCode: 12), isKeyUp: false).key, "q")
        XCTAssertEqual(KeyEventSnapshot.from(Self.key("Й", keyCode: 12, .shift), isKeyUp: false).key, "q")
        XCTAssertEqual(KeyEventSnapshot.from(Self.key("ы", keyCode: 1), isKeyUp: true).key, "s")
    }

    /// AZERTY types "a" on key code 12: ASCII, so it is never remapped.
    func testASCIICharacterIsNotRemapped() {
        XCTAssertEqual(KeyEventSnapshot.from(Self.key("a", keyCode: 12), isKeyUp: false).key, "a")
        XCTAssertEqual(KeyCharacters.key(of: Self.key("A", keyCode: 12, .shift)), "A")
        XCTAssertEqual(layout.calls, 0, "an ASCII key never asks the layout")
    }

    func testFunctionKeysAreNotRemapped() {
        let right = SpecialKey.right
        XCTAssertEqual(KeyCharacters.key(of: Self.key(right, keyCode: 124)), right)
        XCTAssertEqual(KeyCharacters.key(of: Self.key(SpecialKey.f2, keyCode: 120)), SpecialKey.f2)
        XCTAssertEqual(layout.calls, 0)
    }

    /// A non-Latin key with no ASCII twin keeps what it typed.
    func testUnknownKeyKeepsTypedCharacter() {
        XCTAssertEqual(KeyCharacters.key(of: Self.key("ё", keyCode: 50)), "ё")
    }

    // MARK: Every resolver

    func testViewerFlagOnRussianLayout() {
        let snap = KeyEventSnapshot.from(Self.key("й", keyCode: 12), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: snap, context: .viewer, preset: .macNative), .toggleFlag)
        let fitWidth = KeyEventSnapshot.from(Self.key("Ц", keyCode: 13, .shift), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: fitWidth, context: .viewer, preset: .macNative), .fitWidth)
        let fitHeight = KeyEventSnapshot.from(Self.key("Р", keyCode: 4, .shift), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: fitHeight, context: .viewer, preset: .macNative), .fitHeight)
    }

    /// `C` then `C` = copy to the last folder, on the Russian "с".
    func testViewerCopyChordOnRussianLayout() {
        let first = KeyEventSnapshot.from(Self.key("с", keyCode: 8), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: first, context: .viewer, preset: .macNative), .beginCopyChord)
        let second = KeyEventSnapshot.from(Self.key("с", keyCode: 8), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: second, context: .viewer, preset: .macNative, chordPrefix: "c"),
                       .fileToFolder(.copy, .last))
        let move = KeyEventSnapshot.from(Self.key("ь", keyCode: 46), isKeyUp: false)
        XCTAssertEqual(ViewerKeyMap.action(for: move, context: .viewer, preset: .macNative), .beginMoveChord)
    }

    func testBrowserFlagAndChordOnRussianLayout() {
        let snap = KeyEventSnapshot.from(Self.key("й", keyCode: 12), isKeyUp: false)
        XCTAssertEqual(BrowserKeyMap.action(for: snap, preset: .macNative), .toggleFlag)
        let chord = KeyEventSnapshot.from(Self.key("с", keyCode: 8), isKeyUp: false)
        XCTAssertEqual(BrowserKeyMap.action(for: chord, preset: .macNative), .beginCopyChord)
    }

    func testCompareLockAndFlagOnRussianLayout() {
        let lockEvent = Self.key("ы", keyCode: 1)
        let lock = CompareKeyMap.hit(for: KeyEventSnapshot.from(lockEvent, isKeyUp: false),
                                     unshiftedKey: KeyCharacters.unshiftedKey(of: lockEvent), preset: .macNative)
        XCTAssertEqual(lock?.command, .compareLock)
        let flagEvent = Self.key("й", keyCode: 12)
        let flag = CompareKeyMap.hit(for: KeyEventSnapshot.from(flagEvent, isKeyUp: false),
                                     unshiftedKey: KeyCharacters.unshiftedKey(of: flagEvent), preset: .macNative)
        XCTAssertEqual(flag?.command, .toggleFlag)
        XCTAssertEqual(flag?.allPanes, false)
    }

    func testSlideshowFlagOnRussianLayout() {
        XCTAssertEqual(SlideshowKeyAction.action(for: Self.key("й", keyCode: 12), fastStone: false), .toggleFlag)
        XCTAssertEqual(SlideshowKeyAction.action(for: Self.key("к", keyCode: 15), fastStone: false), .toggleRandom)
        // Latin layouts: unchanged.
        XCTAssertEqual(SlideshowKeyAction.action(for: Self.key("q", keyCode: 12), fastStone: false), .toggleFlag)
    }

    // MARK: Real layout + speed

    /// The system layout gives some ASCII character for the Q key on any
    /// ASCII-capable layout (q, a…), and a key press costs microseconds.
    func testSystemLayoutTranslationIsFast() {
        KeyCharacters.asciiLayout = SystemASCIIKeyLayout.shared
        let event = Self.key("й", keyCode: 12)
        let first = KeyCharacters.key(of: event)
        XCTAssertTrue(first.unicodeScalars.allSatisfy(\.isASCII), "got \(first)")
        let n = 10_000
        let start = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for _ in 0..<n { total &+= KeyEventSnapshot.from(event, isKeyUp: false).key.utf8.count }
        let perKey = Double(DispatchTime.now().uptimeNanoseconds - start) / Double(n) / 1000
        print("key translation: \(String(format: "%.2f", perKey)) µs per key (\(n) keys)")
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThan(perKey, 50, "a key press must cost microseconds")
    }
}

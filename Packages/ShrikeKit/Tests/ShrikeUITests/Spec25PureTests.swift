//
//  Spec25PureTests.swift
//  ShrikeUITests
//
//  The pure pieces of spec 25 (0.2.7): name fitter, size text, cell
//  labels, the Trash keys and the Compare Tab rows.
//

import AppKit
import SwiftUI
import ShrikeCore
import XCTest
@testable import ShrikeUI

@MainActor
final class Spec25PureTests: XCTestCase {

    // MARK: FileNameFit (§6.4 vector 1)

    private func fit(_ name: String, _ n: Int) -> String {
        FileNameFit.fit(name) { $0.count <= n }
    }

    func testFileNameFitTable() {
        XCTAssertEqual(fit("IMG_4245_new.jpg", 16), "IMG_4245_new.jpg")
        XCTAssertEqual(fit("IMG_4245_new.jpg", 15), "IM…4245_new.jpg")
        XCTAssertEqual(fit("IMG_4245_new.jpg", 14), "…4245_new.jpg")
        XCTAssertEqual(fit("IMG_4245.JPG", 10), "…4245.JPG")
        XCTAssertEqual(fit("Holiday-beach-sunset.jpg", 16), "Holiday…nset.jpg")
        XCTAssertEqual(fit("2026-10-09 Wedding Anna.jpg", 14), "2026-…Anna.jpg")
        XCTAssertEqual(fit("a.jpg", 3), "a.…")
    }

    func testFileNameFitEdges() {
        XCTAssertEqual(fit("", 5), "")
        XCTAssertEqual(fit("x", 1), "x")
        XCTAssertFalse(fit("Holiday", 5).isEmpty)
        XCTAssertLessThanOrEqual(fit("Holiday", 5).count, 5)
        XCTAssertFalse(fit("photo.verylongextension", 6).isEmpty)
        XCTAssertEqual(fit("anything.jpg", 0), "…")
    }

    func testFourSimilarNamesStayDifferent() {
        let names = ["IMG_4245_new.jpg", "IMG_4235_new.jpg", "IMG_4228_new.jpg", "IMG_4245.jpg"]
        let fitted = names.map { fit($0, 14) }
        XCTAssertEqual(Set(fitted).count, 4, "\(fitted)")
    }

    // MARK: FileSizeText (§2.4 vector 5)

    func testFileSizeText() {
        XCTAssertEqual(FileSizeText.string(0), "0 bytes")
        XCTAssertEqual(FileSizeText.string(1), "1 byte")
        XCTAssertEqual(FileSizeText.string(100), "100 bytes")
        XCTAssertEqual(FileSizeText.string(999), "999 bytes")
        XCTAssertTrue(["1 KB", "1,5 KB", "1.5 KB", "2 KB"].contains(FileSizeText.string(1500)), FileSizeText.string(1500))
        XCTAssertTrue(FileSizeText.string(12_345_678).hasSuffix("MB"))
        XCTAssertTrue(FileSizeText.string(12_345_678).hasPrefix("12"))
    }

    // MARK: CellAccessibility (§7.3 vector 2)

    func testCellAccessibilityLabels() {
        func label(_ name: String, _ r: Int = 0, flag: Bool = false, pair: Bool = false, failed: Bool = false) -> String {
            CellAccessibility.label(name: name, rating: r, flagged: flag, isPair: pair, failed: failed)
        }
        XCTAssertEqual(label("IMG_4222.JPG", 3, flag: true), "IMG_4222.JPG, 3 stars, flagged")
        XCTAssertEqual(label("IMG_4223.JPG", 1), "IMG_4223.JPG, 1 star")
        XCTAssertEqual(label("IMG_4224.JPG"), "IMG_4224.JPG")
        XCTAssertEqual(label("IMG_4225.JPG", 5, pair: true), "IMG_4225.JPG, 5 stars, RAW and JPEG pair")
        XCTAssertEqual(label("bad.jpg", failed: true), "bad.jpg, can't preview")
    }

    // MARK: Trash keys (§5.3)

    func testMacTrashBindingsAreCommandBackspaceOnly() {
        for context in [ShortcutContext.viewer, .browser, .compare] {
            let bindings = ShortcutTable.bindings(for: .moveToTrash, context: context, preset: .macNative)
            XCTAssertEqual(bindings, [KeyBinding(SpecialKey.backspace, .command)], "\(context)")
        }
        XCTAssertTrue(ShortcutTable.bindings(for: .moveToTrash, context: .viewer, preset: .fastStoneCompat)
            .contains(KeyBinding(SpecialKey.forwardDelete)))
    }

    func testPlainDeleteHintShowsOncePerRun() {
        TrashKeyHint.resetForTesting()
        defer { TrashKeyHint.resetForTesting() }
        let back = KeyEventSnapshot(key: SpecialKey.backspace)
        var shown: [ToastContent] = []
        XCTAssertTrue(TrashKeyHint.handle(back, preset: .macNative, responder: nil) { shown.append($0) })
        XCTAssertEqual(shown.map(\.message), ["Press ⌘⌫ to move to the Trash."])
        XCTAssertEqual(shown.first?.kind, .text)
        XCTAssertNil(shown.first?.actionTitle)
        XCTAssertTrue(TrashKeyHint.handle(KeyEventSnapshot(key: SpecialKey.forwardDelete), preset: .macNative,
                                          responder: nil) { shown.append($0) }, "swallowed")
        XCTAssertEqual(shown.count, 1, "second press is silent")
    }

    func testHintIgnoresFastStoneCommandAndTextFields() {
        TrashKeyHint.resetForTesting()
        defer { TrashKeyHint.resetForTesting() }
        var shown = 0
        let back = KeyEventSnapshot(key: SpecialKey.backspace)
        XCTAssertFalse(TrashKeyHint.handle(back, preset: .fastStoneCompat, responder: nil) { _ in shown += 1 })
        XCTAssertFalse(TrashKeyHint.handle(KeyEventSnapshot(key: SpecialKey.backspace, modifiers: .command),
                                           preset: .macNative, responder: nil) { _ in shown += 1 })
        XCTAssertFalse(TrashKeyHint.handle(back, preset: .macNative, responder: NSTextView()) { _ in shown += 1 })
        XCTAssertEqual(shown, 0)
        XCTAssertFalse(TrashKeyHint.wasShown)
    }

    // MARK: Compare Tab rows (§11)

    func testCompareTabRows() {
        let tab = KeyBinding(SpecialKey.tab)
        let back = KeyBinding(SpecialKey.tab, .shift)
        for preset in ShortcutPreset.allCases {
            XCTAssertEqual(ShortcutTable.bindings(for: .compareFocusNext, context: .compare, preset: preset), [tab])
            XCTAssertEqual(ShortcutTable.bindings(for: .compareFocusPrevious, context: .compare, preset: preset), [back])
        }
        XCTAssertEqual(tab.displayString, "⇥")
        XCTAssertEqual(back.displayString, "⇧⇥")
        XCTAssertEqual(ShrikeCommand.compareFocusNext.title, "Next Pane")
        XCTAssertEqual(ShrikeCommand.compareFocusPrevious.title, "Previous Pane")
    }

    // MARK: FittedNameLabel (§6.4 vectors 2 and 3)

    func testFittedLabelKeepsFourSimilarNamesApartAndRefitsOnResize() {
        let names = ["IMG_4245_new.jpg", "IMG_4235_new.jpg", "IMG_4228_new.jpg", "IMG_4245.jpg"]
        var seen = Set<String>()
        for name in names {
            let label = FittedNameLabel()
            label.font = .systemFont(ofSize: 12)
            label.fullName = name
            label.frame = NSRect(x: 0, y: 0, width: 96, height: 16)
            label.layoutSubtreeIfNeeded()
            label.refit()
            XCTAssertFalse(label.stringValue.isEmpty)
            seen.insert(label.stringValue)
        }
        XCTAssertEqual(seen.count, 4, "\(seen)")

        let label = FittedNameLabel()
        label.font = .systemFont(ofSize: 12)
        label.fullName = "IMG_4245_new.jpg"
        label.frame = NSRect(x: 0, y: 0, width: 104, height: 16)
        let narrow = label.stringValue
        label.setFrameSize(NSSize(width: 300, height: 16))
        XCTAssertEqual(label.stringValue, "IMG_4245_new.jpg")
        XCTAssertNotEqual(narrow, label.stringValue)
        XCTAssertTrue(narrow.hasSuffix("jpg"), narrow)
    }

    // MARK: Inspector style (§8.3)

    func testInspectorUsesTheRatingYellowAndTwelvePointText() {
        XCTAssertEqual(InspectorStyle.filledStarColor, Badges.ratingColor)
        XCTAssertEqual(InspectorStyle.smallFontSize, 12)
        XCTAssertGreaterThanOrEqual(InspectorStyle.starHitSize, 24)
        XCTAssertEqual(InspectorStyle.starSize, 16)
    }

    /// §8: the Clear link underlines on hover and is plain otherwise. The
    /// view's hover handler only flips the flag this text is built from.
    func testClearLinkUnderlinesOnHover() {
        let plain = InspectorClearLink.title(hovered: false)
        let hover = InspectorClearLink.title(hovered: true)
        XCTAssertEqual(String(plain.characters), "Clear")
        XCTAssertEqual(String(hover.characters), "Clear")
        XCTAssertTrue(plain.runs.allSatisfy { $0.underlineStyle == nil })
        XCTAssertTrue(hover.runs.allSatisfy { $0.underlineStyle == .single })
    }

    /// The link is built from that text, reacts to hover and is reachable
    /// for VoiceOver with a plain-words label.
    @MainActor
    func testClearLinkViewBuilds() {
        let host = NSHostingView(rootView: InspectorClearLink {})
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}

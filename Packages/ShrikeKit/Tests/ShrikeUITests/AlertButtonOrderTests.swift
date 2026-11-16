//
//  AlertButtonOrderTests.swift
//  ShrikeUITests
//
//  Pass 2c task 1. Reads the built NSAlert's real buttons: left-to-right
//  order, key equivalents, destructive flag (spec 28 §17.1, §19.2).
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class AlertButtonOrderTests: XCTestCase {

    /// The alert's visible buttons (not the Esc twin), left to right, after layout.
    static func visibleButtons(_ alert: NSAlert) -> [NSButton] {
        alert.layout()
        var found: [NSButton] = []
        func walk(_ view: NSView) {
            if let b = view as? NSButton, !b.isHidden, !b.title.isEmpty,
               b.identifier?.rawValue != "safeCancelEscTwin" { found.append(b) }
            view.subviews.forEach(walk)
        }
        if let content = alert.window.contentView { walk(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    static func escTwin(_ alert: NSAlert) -> SafeCancelEscTwin? {
        var twin: SafeCancelEscTwin?
        func walk(_ v: NSView) {
            if let b = v as? SafeCancelEscTwin, b.identifier?.rawValue == "safeCancelEscTwin" { twin = b }
            v.subviews.forEach(walk)
        }
        if let c = alert.window.contentView { walk(c) }
        return twin
    }

    /// Destructive on the left, safe Cancel on the right (default, Return and Esc).
    static func assertDestructiveLeftSafeCancelRight(
        _ alert: NSAlert, titles: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        let visible = visibleButtons(alert)
        XCTAssertEqual(visible.map { $0.title.replacingOccurrences(of: "\u{2063}", with: "") }, titles,
                       "left-to-right order", file: file, line: line)
        XCTAssertEqual(visible.map { $0.accessibilityLabel() ?? "" }, titles, file: file, line: line)
        guard visible.count == 2 else { return }
        let f0 = visible[0].convert(visible[0].bounds, to: nil)
        let f1 = visible[1].convert(visible[1].bounds, to: nil)
        XCTAssertEqual(f0.midY, f1.midY, accuracy: 1, "same row", file: file, line: line)
        XCTAssertTrue(visible[0].hasDestructiveAction, file: file, line: line)
        XCTAssertEqual(visible[0].keyEquivalent, "", file: file, line: line)
        XCTAssertFalse(visible[1].hasDestructiveAction, file: file, line: line)
        XCTAssertEqual(visible[1].keyEquivalent, "\r", "Return on the safe Cancel", file: file, line: line)
        let twin = escTwin(alert)
        XCTAssertEqual(twin?.keyEquivalent, "\u{1b}", "Esc answers it too", file: file, line: line)
        XCTAssertTrue(twin?.target === visible[1], "the Esc twin clicks the Cancel", file: file, line: line)
        XCTAssertTrue(alert.window.defaultButtonCell === visible[1].cell, file: file, line: line)
    }

    func testQuitAlertOrder() {
        let alert = ShrikeAlert.make(message: QuitQuestion.title, information: "x",
                                     buttons: QuitQuestion.quitButtons)
        Self.assertDestructiveLeftSafeCancelRight(alert, titles: ["Quit Anyway", "Cancel"])
    }

    func testTimeoutAlertsOrder() {
        let alert = ShrikeAlert.make(message: QuitQuestion.writeTimeoutTitle,
                                     information: QuitQuestion.writeTimeoutInformation,
                                     buttons: QuitQuestion.timeoutButtons)
        Self.assertDestructiveLeftSafeCancelRight(alert, titles: ["Quit Anyway", "Keep Waiting"])
    }

    /// Recovery sheet: Not Now answers Esc, Show in Finder answers Return.
    /// Offscreen, AppKit stacks these two long buttons; only the keys are pinned.
    func testRecoverySheetButtons() {
        let alert = RenameRecoveryPresenter.makeSheetAlert(title: "t", information: "i")
        let visible = Self.visibleButtons(alert)
        XCTAssertEqual(Set(visible.map { $0.title }), [RenameRecoveryNotice.notNow, RenameRecoveryNotice.showInFinder])
        XCTAssertEqual(visible.first { $0.title == RenameRecoveryNotice.notNow }?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(visible.first { $0.title == RenameRecoveryNotice.showInFinder }?.keyEquivalent, "\r")
    }

    /// Print loading sheet: one Cancel that answers Esc; plain "Cancel" for VoiceOver.
    func testSingleCancelAnswersEsc() {
        let alert = ShrikeAlert.make(message: "m", style: .informational, buttons: [.cancel()])
        let visible = Self.visibleButtons(alert)
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(visible.first?.accessibilityLabel(), "Cancel")
    }

    /// Cancel / default pair keeps Cancel left, default right (HIG), keys intact.
    func testCancelThenDefaultKeepsOrderAndKeys() {
        let alert = ShrikeAlert.make(message: "m", buttons: [.cancel(), ShrikeAlert.Button("Move", role: .default)])
        let visible = Self.visibleButtons(alert)
        XCTAssertEqual(visible.map { $0.accessibilityLabel() ?? "" }, ["Cancel", "Move"])
        XCTAssertEqual(visible.first?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(visible.last?.keyEquivalent, "\r")
    }

    func testAnswerIndexMapping() {
        // The right button answers first; the builder's array is left to right.
        XCTAssertEqual(ShrikeAlert.index(of: .alertFirstButtonReturn, buttonCount: 2), 1)
        XCTAssertEqual(ShrikeAlert.index(of: .alertSecondButtonReturn, buttonCount: 2), 0)
    }

    /// 28a round 2 finding 4 / round 3 B.7: every button an assistive app can
    /// reach has a name equal to its visible title (no U+2063), the Esc twin is
    /// no button and no accessibility element, and Esc still answers Cancel.
    func testAlertButtonsAreNamedAndTheEscTwinIsHidden() throws {
        let alert = ShrikeAlert.make(message: "Change 3 original photos?", information: "x",
                                     buttons: [ShrikeAlert.Button("Change Originals", role: .destructive), .safeCancel()])
        alert.layout()
        var buttons: [NSButton] = []
        func walk(_ v: NSView) {
            if let b = v as? NSButton { buttons.append(b) }
            v.subviews.forEach(walk)
        }
        walk(try XCTUnwrap(alert.window.contentView))
        XCTAssertEqual(buttons.count, 2, "no extra (unnamed) button")
        for b in buttons {
            let shown = b.title.replacingOccurrences(of: "\u{2063}", with: "")
            XCTAssertEqual(b.accessibilityTitle(), shown)
            XCTAssertEqual(b.accessibilityLabel(), shown)
            XCTAssertFalse(b.accessibilityTitle()?.contains("\u{2063}") ?? true)
        }
        let twin = try XCTUnwrap(Self.escTwin(alert))
        XCTAssertFalse(twin.isAccessibilityElement())
        let cancel = try XCTUnwrap(buttons.first { $0.accessibilityTitle() == "Cancel" })
        let probe = EscProbe()
        cancel.target = probe; cancel.action = #selector(EscProbe.hit(_:))
        let esc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: alert.window.windowNumber, context: nil,
                                                 characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                 isARepeat: false, keyCode: 53))
        XCTAssertTrue(alert.window.performKeyEquivalent(with: esc))
        XCTAssertEqual(probe.hits, 1, "Esc answers the safe Cancel")
        let capsEsc = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .capsLock, timestamp: 0,
                                                     windowNumber: alert.window.windowNumber, context: nil,
                                                     characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                                     isARepeat: false, keyCode: 53))
        XCTAssertTrue(alert.window.performKeyEquivalent(with: capsEsc))
        XCTAssertEqual(probe.hits, 2, "Esc with Caps Lock on answers too")
    }
}

@MainActor
private final class EscProbe: NSObject {
    var hits = 0
    @objc func hit(_ sender: Any?) { hits += 1 }
}

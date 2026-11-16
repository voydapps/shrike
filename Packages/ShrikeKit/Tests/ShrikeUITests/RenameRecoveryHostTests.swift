//
//  RenameRecoveryHostTests.swift
//  ShrikeUITests
//
//  Spec 28 §18.1: which window hosts the recovery notice. Window-free.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class RenameRecoveryHostTests: XCTestCase {
    private typealias C = RenameRecoveryHost.Candidate

    func testOnlyBrowserViewerOrWelcomeHost() {
        XCTAssertEqual(RenameRecoveryHost.choose([C(kind: .browser, isOnScreen: true, hasSheet: false)]), .use(0))
        XCTAssertEqual(RenameRecoveryHost.choose([C(kind: .viewer, isOnScreen: true, hasSheet: false)]), .use(0))
        XCTAssertEqual(RenameRecoveryHost.choose([C(kind: .welcome, isOnScreen: true, hasSheet: false)]), .use(0))
        // Settings, Batch, Compare, Slideshow, panels: never.
        XCTAssertEqual(RenameRecoveryHost.choose([C(kind: .other, isOnScreen: true, hasSheet: false)]), .wait)
    }

    func testSkipsOtherWindowsAndOffScreenOnes() {
        let list = [C(kind: .other, isOnScreen: true, hasSheet: false),     // key: Settings
                    C(kind: .viewer, isOnScreen: false, hasSheet: false),   // minimized viewer
                    C(kind: .browser, isOnScreen: true, hasSheet: false)]
        XCTAssertEqual(RenameRecoveryHost.choose(list), .use(2))
    }

    func testFirstAllowedWindowWithASheetWaits() {
        let list = [C(kind: .browser, isOnScreen: true, hasSheet: true),
                    C(kind: .viewer, isOnScreen: true, hasSheet: false)]
        XCTAssertEqual(RenameRecoveryHost.choose(list), .wait, "queue the notice until that sheet ends")
    }

    func testNoWindowWaits() {
        XCTAssertEqual(RenameRecoveryHost.choose([]), .wait)
    }

    func testCountsToastStaysEightSeconds() {
        XCTAssertEqual(RenameRecoveryPresenter.toastDuration, 8.0)
    }

    /// The bug of 2026-11-13: with the §18.1 sheet up, ⌘Q and Quit Shrike did
    /// nothing (an NSAlert window prevents termination while modal, and a sheet
    /// counts). The informational sheet must let the app quit.
    func testRecoverySheetDoesNotBlockQuit() {
        let alert = RenameRecoveryPresenter.makeSheetAlert(title: "A photo has a temporary name", information: "x")
        XCTAssertFalse(alert.window.preventsApplicationTerminationWhenModal)
        XCTAssertTrue(ShrikeAlert.make(message: "m", buttons: [.cancel()]).window.preventsApplicationTerminationWhenModal,
                      "other alerts keep the AppKit default")
    }

    /// Esc = Not Now (left), Return = Show in Finder (right, default); the
    /// caution icon (`.critical`); the ended-at-quit code maps to Not Now.
    func testRecoverySheetKeysAndQuitCode() {
        let alert = RenameRecoveryPresenter.makeSheetAlert(title: "t", information: "a\n    b")
        XCTAssertEqual(alert.alertStyle, .critical)
        XCTAssertEqual(alert.buttons.map(\.title), ["Show in Finder", "Not Now"])   // right to left
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(ShrikeAlert.index(of: .alertSecondButtonReturn, buttonCount: 2), 0, "quit ends it as Not Now: no Finder")
    }

    /// Entry lines: the temporary name line is indented, the rest is not.
    func testRecoverySheetIndentsTemporaryNameLines() {
        let body = RenameRecoveryPresenter.bodyText("lead\n“a.jpg” is now\n    “.tmp-a.jpg” in “~/X”")
        let ns = body.string as NSString
        XCTAssertFalse(body.string.contains("    "), "the spaces become a paragraph indent")
        let lead = body.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tmp = body.attribute(.paragraphStyle, at: ns.range(of: "“.tmp").location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(lead?.headIndent, 0)
        XCTAssertEqual(tmp?.headIndent, RenameRecoveryPresenter.entryIndent)
        XCTAssertEqual(tmp?.firstLineHeadIndent, RenameRecoveryPresenter.entryIndent)
    }
}

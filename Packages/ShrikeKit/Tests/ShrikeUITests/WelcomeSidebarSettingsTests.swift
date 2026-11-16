//
//  WelcomeSidebarSettingsTests.swift
//  ShrikeUITests
//
//  Welcome is a solid window with push buttons, the Browser sidebar
//  width, the folder header state, Settings has no initial focus, and the
//  default buttons take the system accent.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class WelcomeSidebarSettingsTests: XCTestCase {

    func testWelcomeWindowIsSolidWithPushButtons() throws {
        let welcome = WelcomeWindowController(recentURLs: { [] })
        defer { welcome.close() }
        let content = try XCTUnwrap(welcome.window?.contentView)
        XCTAssertFalse(content is NSVisualEffectView, "no material behind the window (V9)")
        // Spec 28 §8 (amends spec 27 P3-11): Open Photo… is the system default
        // button (rounded, Return); the system draws its label. No custom colour.
        XCTAssertEqual(welcome.openButton.bezelStyle, .rounded)
        XCTAssertNil(welcome.openButton.bezelColor)
        XCTAssertEqual(welcome.openButton.keyEquivalent, "\r")
    }

    func testBrowserSidebarWidths() {
        XCTAssertEqual(BrowserWindowController.sidebarMinimumWidth, 200)
        XCTAssertEqual(BrowserWindowController.sidebarPreferredWidth, 240)
    }

    func testFolderOnlyInspectorStateCarriesThePath() {
        let state = InspectorState.folder(name: "jpg", visible: 200, total: 200, path: "~/Pictures/jpg")
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.folderPath, "~/Pictures/jpg")
        XCTAssertNotNil(state.folderSummary)
    }

    /// The Editing tab has no text field to take the first
    /// focus (its number was shown selected).
    func testSettingsEditingTabHasNoTextField() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI/Preferences/EditingTab.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("TextField("), "a TextField takes the first focus")
    }

    /// The window keeps no first responder after it is built (offscreen:
    /// the window is never ordered front).
    func testSettingsWindowStartsWithTheWindowAsFirstResponder() {
        let controller = PreferencesWindowController()
        defer { controller.close() }
        let window = controller.window
        XCTAssertNotNil(window)
        XCTAssertFalse(window?.firstResponder is NSTextField)
    }
}

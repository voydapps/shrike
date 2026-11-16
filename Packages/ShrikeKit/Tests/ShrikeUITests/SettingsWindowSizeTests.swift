//
//  SettingsWindowSizeTests.swift
//  ShrikeUITests
//
//  Spec 28 §14 (pass 2l): the Settings window's height follows the tab's
//  content, top edge fixed. The window is never shown.
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class SettingsWindowSizeTests: XCTestCase {
    private var savedTab: PreferencesTab!

    override func setUp() async throws {
        savedTab = PreferencesTab.loadSelected()
        PreferencesWindowController.reduceMotion = { true }
    }

    override func tearDown() async throws {
        PreferencesTab.saveSelected(savedTab)
        PreferencesWindowController.reduceMotion = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    }

    func testTabSwitchKeepsTheTopEdgeAndTheHeightInBounds() async throws {
        PreferencesTab.saveSelected(.general)
        let controller = PreferencesWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // AppKit snaps the window frame to the pixel grid, so a capped height
        // (80 % of a 674 pt visible screen = 539.2 pt) can come out a fraction
        // of a point taller: 540 pt on a CI runner's small screen. Allow 1 pt.
        let snap: CGFloat = 1
        func check(_ label: String) {
            let content = window.contentRect(forFrameRect: window.frame)
            XCTAssertEqual(content.width, SettingsWindowSize.width, accuracy: 0.5, label)
            XCTAssertGreaterThanOrEqual(window.frame.height, SettingsWindowSize.minimumHeight - 0.5,
                                        "\(label): measured \(controller.measuredContentHeight)")
            if controller.measuredContentHeight <= max(visible * 0.8, 320) {
                XCTAssertGreaterThanOrEqual(content.height, controller.measuredContentHeight - 0.5,
                                            "\(label): nothing clipped")
            }
            XCTAssertLessThanOrEqual(content.height, max(visible * 0.8, 320) + snap,
                                     "\(label): measured \(controller.measuredContentHeight)")
        }
        check("General")
        let generalHeight = window.frame.height
        XCTAssertGreaterThan(controller.measuredContentHeight, 460,
                             "the General tab's content is taller than the old fitting size")
        for tab in [PreferencesTab.advanced, .externalEditors, .general] {
            let top = window.frame.maxY
            controller.selectTabForTesting(tab)
            for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "\(tab): the top edge stays")
            check("\(tab)")
        }
        XCTAssertEqual(window.frame.height, generalHeight, accuracy: 1, "back on General: the same height")
    }

    /// Pass 2p: Shortcuts and External Editors are short; the window is 320
    /// pt high (not 320 pt of content under the title bar and toolbar).
    func testShortTabsGiveA320PointWindowWithNoEmptyBand() async throws {
        PreferencesTab.saveSelected(.general)
        let controller = PreferencesWindowController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }
        for tab in [PreferencesTab.shortcuts, .externalEditors] {
            controller.selectTabForTesting(tab)
            for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(20)) }
            let content = window.contentRect(forFrameRect: window.frame).height
            if controller.measuredContentHeight <= content {
                XCTAssertEqual(window.frame.height, SettingsWindowSize.minimumHeight, accuracy: 0.5,
                               "\(tab): measured \(controller.measuredContentHeight)")
            } else {
                XCTFail("\(tab): the content (\(controller.measuredContentHeight)) does not fit \(content)")
            }
        }
    }
}

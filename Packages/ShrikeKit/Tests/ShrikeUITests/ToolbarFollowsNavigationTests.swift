//
//  ToolbarFollowsNavigationTests.swift
//  ShrikeUITests
//
//  Audit on-screen M2: the viewer toolbar is re-validated whenever the displayed
//  photo changes, not only on mouse events.
//

import XCTest
import AppKit
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ToolbarFollowsNavigationTests: XCTestCase {

    private final class CountingToolbar: NSToolbar {
        var validations = 0
        override func validateVisibleItems() { validations += 1; super.validateVisibleItems() }
    }

    func testMarkDisplayedValidatesTheToolbar() throws {
        let dir = TestScratch.directory
            .appendingPathComponent("ToolbarNav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var groups: [ImageGroup] = []
        for name in ["a.jpg", "b.jpg"] {
            let url = dir.appendingPathComponent(name)
            try SaveFlowTests.writeImage(url, type: .jpeg)
            groups.append(ImageGroup(primary: url))
        }
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: .makeDefault())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        let counting = CountingToolbar(identifier: "test.counting")
        viewer.toolbar = counting
        viewer.markDisplayedForTesting(1)
        XCTAssertGreaterThanOrEqual(counting.validations, 1, "a keyboard step re-validates the toolbar")
        let before = counting.validations
        viewer.markDisplayedForTesting(0)
        XCTAssertGreaterThan(counting.validations, before)
    }
}

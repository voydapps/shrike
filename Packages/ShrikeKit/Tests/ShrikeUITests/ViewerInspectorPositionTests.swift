//
//  ViewerInspectorPositionTests.swift
//  ShrikeUITests
//
//  The side panel's "n of N" follows the window title when the list changes
//  without a new photo (Save Copy added a file: title "1 of 11", panel "1 of 10").
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class ViewerInspectorPositionTests: XCTestCase {

    func testInspectorCountFollowsTheTitleWhenTheListGrows() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-inspos-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (1...3).map { i -> URL in
            let url = root.appendingPathComponent("p\(i).jpg")
            try Data([0xFF]).write(to: url)
            return url
        }
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        viewer.contentRoot.setImage(SaveFlowTests.image(), index: 0, total: 3)
        XCTAssertEqual(viewer.contentRoot.inspectorForTesting.indexSummaryForTesting, "1 of 3")

        // What Save Copy does: a new file joins the list after the shown one.
        let copy = root.appendingPathComponent("p1 copy.jpg")
        try Data([0xFF]).write(to: copy)
        viewer.list.insert([RemovedGroup(index: 1, group: ImageGroup(primary: copy))])
        viewer.syncListKeepingDisplayed()

        XCTAssertTrue(viewer.subtitle.hasPrefix("1 of 4"), viewer.subtitle)
        XCTAssertEqual(viewer.contentRoot.inspectorForTesting.indexSummaryForTesting, "1 of 4")
    }
}

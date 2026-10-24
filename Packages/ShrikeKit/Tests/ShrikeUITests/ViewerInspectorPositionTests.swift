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

/// COR-4: a folder change while a navigation is still in flight must not lose that navigation.
@MainActor
final class ListSyncDuringNavigationTests: XCTestCase {

    func testFolderChangeDuringASlowNavigationStillArrives() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ListSyncNav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var groups: [ImageGroup] = []
        for name in ["p0.jpg", "p1.jpg", "p2.jpg"] {
            let url = root.appendingPathComponent(name)
            try SaveFlowTests.writeImage(url, type: .jpeg)
            groups.append(ImageGroup(primary: url))
        }
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: .makeDefault())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        for _ in 0..<200 where !viewer.navCoalescer.isIdle { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(viewer.displayedItem?.group.primary, groups[0].primary)

        // The user asked for p2: the intent cursor moved, the decode is slow (still in flight).
        _ = viewer.intent.jumpIntent(to: 2)
        viewer.coalesceNav { try? await Task.sleep(for: .seconds(30)) }
        XCTAssertFalse(viewer.navCoalescer.isIdle)

        // Meanwhile a file joins the folder at the front.
        let added = root.appendingPathComponent("p00.jpg")
        try SaveFlowTests.writeImage(added, type: .jpeg)
        viewer.list.insert([RemovedGroup(index: 0, group: ImageGroup(primary: added))])
        viewer.syncListKeepingDisplayed()

        for _ in 0..<300 where viewer.displayedItem?.group.primary != groups[2].primary {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewer.displayedItem?.group.primary, groups[2].primary,
                       "the requested photo is shown after the list changed")
        XCTAssertEqual(viewer.displayedItem?.listIndex, 3, "at its new place in the list")
    }
}

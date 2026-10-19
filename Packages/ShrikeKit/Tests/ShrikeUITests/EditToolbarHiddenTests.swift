//
//  EditToolbarHiddenTests.swift
//  ShrikeUITests
//
//  With the
//  viewer toolbar hidden (the user's setting), edit mode in a window
//  still shows the edit toolbar (Cancel, tools, Undo/Redo, Reset, Done)
//  for the whole session. On exit the viewer toolbar comes back hidden,
//  and the user's setting is never written as "shown".
//

import AppKit
import XCTest
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class EditToolbarHiddenTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditToolbarHidden-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func viewer() throws -> ViewerWindow {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        viewer.setContentSize(NSSize(width: 900, height: 600))
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    func testHiddenViewerToolbarStillShowsTheEditToolbar() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let viewerToolbar = try XCTUnwrap(viewer.toolbar)
        viewerToolbar.isVisible = false
        let content = viewer.contentRootForTesting
        // AppKit's own toolbar autosave (the user's "toolbar hidden").
        let key = "NSToolbar Configuration \(viewerToolbar.identifier)"
        func savedShown() -> Int? {
            (UserDefaults.standard.dictionary(forKey: key)?["TB Is Shown"] as? NSNumber)?.intValue
        }
        let savedBefore = savedShown()

        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertTrue(viewer.toolbar === viewer.contentRootForTesting.editToolbarController.toolbar)
        XCTAssertEqual(viewer.toolbar?.isVisible, true, "the edit toolbar shows for the session")
        let ids = viewer.toolbar?.items.map(\.itemIdentifier) ?? []
        for id in [EditToolbarController.ItemID.cancel,
                   EditToolbarController.ItemID.undoRedo, EditToolbarController.ItemID.reset,
                   EditToolbarController.ItemID.done] {
            XCTAssertTrue(ids.contains(id), "\(id.rawValue) is in the edit toolbar")
        }
        // The canvas sits below the shown toolbar (crop handles never
        // under it): the image view top is the content layout rect top.
        content.layoutSubtreeIfNeeded()
        let imageTop = content.imageView.convert(content.imageView.bounds, to: nil).maxY
        XCTAssertLessThanOrEqual(imageTop, viewer.contentLayoutRect.maxY + 0.5)

        content.editModeController.finalizeExit()
        XCTAssertTrue(viewer.toolbar === viewerToolbar)
        XCTAssertFalse(viewerToolbar.isVisible, "the user's hidden toolbar comes back hidden")
        XCTAssertEqual(savedShown(), savedBefore, "\"shown\" was never saved into the user's setting")
        XCTAssertNotEqual(savedShown(), 1)
    }

    func testShownViewerToolbarComesBackShown() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let viewerToolbar = try XCTUnwrap(viewer.toolbar)
        viewerToolbar.isVisible = true
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertEqual(viewer.toolbar?.isVisible, true)
        content.editModeController.finalizeExit()
        XCTAssertTrue(viewer.toolbar === viewerToolbar)
        XCTAssertTrue(viewerToolbar.isVisible)
    }
}

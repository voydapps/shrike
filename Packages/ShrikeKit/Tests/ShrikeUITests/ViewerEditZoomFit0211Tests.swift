//
//  ViewerEditZoomFit0211Tests.swift
//  ShrikeUITests
//
//  0.2.10 audit item 2: edit, full screen on, off, Esc, shrink, edit again left the photo
//  zoomed in under the tool column.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerEditZoomFit0211Tests: XCTestCase {

    private var root: URL!
    private var savedInspector = false

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-editzoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        Prefs.viewerInspectorVisibleWindowed = true
        ReduceMotion.overrideForTesting = true
    }

    override func tearDown() async throws {
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        ReduceMotion.overrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewer(width: CGFloat, height: CGFloat) -> ViewerWindow {
        let url = root.appendingPathComponent("p-\(UUID().uuidString.prefix(6)).jpg")
        XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
        var services = ShrikeServices.makeDefault()
        services.backupStore = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: width, height: height))
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants(width: 3000, height: 2000)
        viewer.contentRootForTesting.animatesPanelFades = false
        viewer.setFrameOrigin(NSPoint(x: 100, y: 100))
        return viewer
    }

    private func enterEdit(_ viewer: ViewerWindow) {
        viewer.contentRootForTesting.enterEditMode(image: SaveFlowTests.image(width: 3000, height: 2000), url: nil, landOn: nil)
        viewer.contentView?.layoutSubtreeIfNeeded()
    }

    private func isFit(_ viewer: ViewerWindow) -> Bool {
        if case .bestFit = viewer.imageViewForTesting.contentMode { return true }
        return false
    }

    private func settle(_ viewer: ViewerWindow) { viewer.contentView?.layoutSubtreeIfNeeded() }

    /// The photo is in fit mode and drawn at the fit scale.
    private func assertFitted(_ viewer: ViewerWindow, _ what: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        let iv = viewer.imageViewForTesting
        XCTAssertTrue(isFit(viewer), "\(what): fit mode, was \(iv.contentMode)", file: file, line: line)
        XCTAssertEqual(iv.pixelScale, iv.fitPixelScale, accuracy: 1e-6, "\(what): drawn at fit", file: file, line: line)
        XCTAssertNil(iv.zoomPresentationForTesting, "\(what): no leftover zoom drawing", file: file, line: line)
    }

    /// In edit mode the photo lies inside the fit area (clear of the tool column).
    private func assertClearOfToolColumn(_ viewer: ViewerWindow, _ what: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let iv = viewer.imageViewForTesting
        let area = iv.fitArea
        let drawn = iv.drawnImageRect
        XCTAssertLessThanOrEqual(drawn.maxX, area.maxX + 0.5, "\(what): photo ends before the column", file: file, line: line)
        XCTAssertGreaterThanOrEqual(drawn.minX, area.minX - 0.5, file: file, line: line)
    }

    // The 0.2.10 audit sequence: edit, full screen on, off, Esc, shrink, edit again.
    func testAuditSequenceStaysFitted() {
        let viewer = makeViewer(width: 480, height: 600)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        let nc = NotificationCenter.default
        let iv = viewer.imageViewForTesting
        func resize(to width: CGFloat) {
            var f = viewer.frame
            f.size.width = width
            viewer.setFrame(f, display: false)
            settle(viewer)
        }
        enterEdit(viewer)
        assertFitted(viewer, "edit")
        nc.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        viewer.fullScreenOverrideForTesting = true
        resize(to: 1500)
        nc.post(name: NSWindow.didEnterFullScreenNotification, object: viewer)
        settle(viewer)
        assertFitted(viewer, "full screen on")
        assertClearOfToolColumn(viewer, "full screen on")
        nc.post(name: NSWindow.willExitFullScreenNotification, object: viewer)
        viewer.fullScreenOverrideForTesting = false
        resize(to: 648)
        nc.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        settle(viewer)
        assertFitted(viewer, "full screen off")
        viewer.contentRootForTesting.editModeController.finalizeExit()
        settle(viewer)
        assertFitted(viewer, "Esc")
        resize(to: 480)
        assertFitted(viewer, "shrunk")
        enterEdit(viewer)
        assertFitted(viewer, "edit again")
        assertClearOfToolColumn(viewer, "edit again")
        XCTAssertEqual(iv.fitInsets.right, 312, accuracy: 0.5)
    }

    // A fixed zoom left over from the full-screen edit canvas (the audit symptom: stuck
    // until Command-0) is gone when edit ends, and the next edit starts fitted.
    func testLeftoverZoomFromFullScreenIsClearedWhenEditEnds() {
        let viewer = makeViewer(width: 480, height: 600)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        let iv = viewer.imageViewForTesting
        enterEdit(viewer)
        viewer.fullScreenOverrideForTesting = true
        var f = viewer.frame
        f.size.width = 1500
        viewer.setFrame(f, display: false)
        settle(viewer)
        // The edit fit of the big canvas, kept as a fixed zoom.
        iv.setPixelScale(iv.fitPixelScale * 1.02, anchor: nil)
        XCTAssertFalse(isFit(viewer), "the case needs a fixed zoom")
        viewer.fullScreenOverrideForTesting = false
        f.size.width = 648
        viewer.setFrame(f, display: false)
        settle(viewer)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        settle(viewer)
        assertFitted(viewer, "after Esc")
        f.size.width = 480
        viewer.setFrame(f, display: false)
        settle(viewer)
        assertFitted(viewer, "after the shrink")
        enterEdit(viewer)
        assertFitted(viewer, "edit again")
        assertClearOfToolColumn(viewer, "edit again")
    }

    // Edit started while the user had zoomed in: the photo is fitted to the edit canvas.
    func testEditStartsFittedWhenZoomedIn() {
        let viewer = makeViewer(width: 900, height: 600)
        defer { viewer.close() }
        let iv = viewer.imageViewForTesting
        settle(viewer)
        iv.setPixelScale(1.0, anchor: nil)
        XCTAssertFalse(isFit(viewer))
        enterEdit(viewer)
        assertFitted(viewer, "edit start")
        assertClearOfToolColumn(viewer, "edit start")
        viewer.contentRootForTesting.editModeController.finalizeExit()
        settle(viewer)
        assertFitted(viewer, "edit end")
    }

    // Leaving edit (Done, Cancel or Esc) inside full screen: fitted to the full-screen canvas.
    func testLeavingEditInsideFullScreenIsFitted() {
        let viewer = makeViewer(width: 900, height: 600)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        let iv = viewer.imageViewForTesting
        enterEdit(viewer)
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        viewer.fullScreenOverrideForTesting = true
        iv.setPixelScale(iv.fitPixelScale * 1.5, anchor: nil)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        settle(viewer)
        assertFitted(viewer, "left edit in full screen")
    }
}

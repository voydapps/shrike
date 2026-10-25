//
//  ViewerEditWidth028Tests.swift
//  ShrikeUITests
//
//  Spec 27 V7 and N2: edit mode needs a 648 pt canvas. The inspector steps
//  aside first, then the window widens (and returns on exit unless the user
//  resized). The edit toolbar is never left hidden.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerEditWidth028Tests: XCTestCase {

    private var root: URL!
    private var savedInspector = false
    private var savedAutoHide = false

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-editwidth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedInspector = Prefs.viewerInspectorVisibleWindowed
        savedAutoHide = Prefs.viewerToolbarAutoHide
        Prefs.viewerInspectorVisibleWindowed = false
        ReduceMotion.overrideForTesting = true   // frames change at once
    }

    override func tearDown() async throws {
        Prefs.viewerInspectorVisibleWindowed = savedInspector
        Prefs.viewerToolbarAutoHide = savedAutoHide
        ReduceMotion.overrideForTesting = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func makeViewer(width: CGFloat, height: CGFloat = 400) -> ViewerWindow {
        let url = root.appendingPathComponent("p-\(UUID().uuidString.prefix(6)).jpg")
        XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: .up))
        var services = ShrikeServices.makeDefault()
        services.backupStore = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: width, height: height))
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = RotateDirectionTests.quadrants()
        viewer.contentRootForTesting.animatesPanelFades = false
        viewer.setFrameOrigin(NSPoint(x: 100, y: 100))
        return viewer
    }

    private func contentWidth(_ w: ViewerWindow) -> CGFloat { w.contentRect(forFrameRect: w.frame).width }

    private func enterEdit(_ viewer: ViewerWindow) {
        viewer.contentRootForTesting.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: nil)
        viewer.contentView?.layoutSubtreeIfNeeded()
    }

    func testDerivation() {
        XCTAssertEqual(EditLayout.minCanvasWidth, 648)
        XCTAssertEqual(EditLayout.columnWidth, 296)
        XCTAssertEqual(ViewerSplitController.canvasWidthForEditPanel, 648)
    }

    // 1 and 2. A 480 pt window widens to 648; the inspector goes aside; leaving returns it.
    func testNarrowWindowWidensAndReturns() throws {
        Prefs.viewerInspectorVisibleWindowed = true
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        let split = try XCTUnwrap(viewer.splitController)
        XCTAssertTrue(split.isInspectorShown)
        let original = viewer.frame
        enterEdit(viewer)
        XCTAssertFalse(split.isInspectorShown, "the inspector steps aside first")
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5)
        XCTAssertEqual(viewer.contentMinSize.width, 648, accuracy: 0.5)
        XCTAssertEqual(viewer.frame.minX, original.minX, accuracy: 0.5, "the left edge stays")

        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertEqual(viewer.frame.width, original.width, accuracy: 0.5, "back to the old size")
        XCTAssertEqual(viewer.frame.minX, original.minX, accuracy: 0.5)
        XCTAssertEqual(viewer.minSize.width, 480, accuracy: 0.5)
        XCTAssertTrue(split.isInspectorShown, "the inspector reopens on exit")
        XCTAssertTrue(Prefs.viewerInspectorVisibleWindowed)
    }

    // 2. A window the user widened to 900 meanwhile stays at 900.
    func testWindowTheUserResizedStaysOnExit() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        enterEdit(viewer)
        var frame = viewer.frame
        frame.size.width = 900
        viewer.setFrame(frame, display: false)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertEqual(viewer.frame.width, 900, accuracy: 0.5)
        XCTAssertEqual(viewer.minSize.width, 480, accuracy: 0.5)
    }

    // 3. The right edge is kept inside the screen.
    func testWidenedWindowStaysInsideTheScreen() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        viewer.setFrameOrigin(NSPoint(x: 700, y: 100))
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        viewer.editScreenVisibleFrameForTesting = visible
        let rightBefore = viewer.frame.maxX
        enterEdit(viewer)
        XCTAssertLessThanOrEqual(viewer.frame.maxX, visible.maxX + 0.5)
        XCTAssertGreaterThan(rightBefore, visible.maxX - 1 - 0, "the case needs a window near the edge")
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5)
        viewer.contentRootForTesting.editModeController.finalizeExit()
    }

    // 0.2.10 audit item 3: a frame set from code or Accessibility goes past contentMinSize;
    // the window widens again at once, and the old size still comes back on exit.
    func testShrinkingWhileEditingWidensAgain() {
        let viewer = makeViewer(width: 900, height: 500)
        defer { viewer.close() }
        let original = viewer.frame
        enterEdit(viewer)
        XCTAssertEqual(viewer.frame, original, "wide enough: nothing yet")
        var narrow = viewer.frame
        narrow.size.width = 480
        viewer.setFrame(narrow, display: false)
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5, "widened again")
        XCTAssertEqual(viewer.frame.minX, original.minX, accuracy: 0.5)
        viewer.contentRootForTesting.layoutSubtreeIfNeeded()
        let content = viewer.contentRootForTesting
        let insets = content.currentFitInsets()
        XCTAssertGreaterThanOrEqual(content.imageView.frame.width - insets.left - insets.right, 319.5,
                                    "the photo keeps at least 320 pt beside the tool column")
        let strip = content.filmstripForTesting
        XCTAssertTrue(strip.isHidden || content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(strip.frame),
                      "the filmstrip is either not shown in edit mode or fully inside the window")
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertEqual(viewer.frame.width, narrow.width, accuracy: 0.5, "back to the size the window was shrunk to")
    }

    // The sequence of the audit: edit, leave (the Cancel / Don't Save path), shrink to 480, edit again.
    func testEditLeaveShrinkEditAgainStillWidens() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        enterEdit(viewer)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertNil(viewer.editWidenRestore, "nothing left over from the first edit")
        var narrow = viewer.frame
        narrow.size.width = 480
        viewer.setFrame(narrow, display: false)
        enterEdit(viewer)
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5)
        viewer.contentRootForTesting.editModeController.finalizeExit()
    }

    // 4. A canvas that is already wide enough changes nothing.
    func testWideWindowIsLeftAlone() {
        let viewer = makeViewer(width: 1000, height: 600)
        defer { viewer.close() }
        let before = viewer.frame
        enterEdit(viewer)
        XCTAssertEqual(viewer.frame, before)
        XCTAssertNil(viewer.editWidenRestore)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertEqual(viewer.frame, before)
    }

    // 5. At the minimum the photo's fit width is at least 320.
    func testFitWidthAtTheMinimumCanvas() {
        let viewer = makeViewer(width: 480, height: 400)
        defer { viewer.close() }
        enterEdit(viewer)
        let content = viewer.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        let insets = content.currentFitInsets()
        let canvas = content.imageView.frame.width
        XCTAssertEqual(canvas, 648, accuracy: 1)
        XCTAssertGreaterThanOrEqual(canvas - insets.left - insets.right, 319.5)
        viewer.contentRootForTesting.editModeController.finalizeExit()
    }

    // 6. N2: the edit toolbar is held open and shown, at 480, after ⌘I, a resize, key loss.
    func testEditToolbarIsNeverLeftHidden() throws {
        Prefs.viewerToolbarAutoHide = true
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        let hider = try XCTUnwrap(viewer.autoHider)
        hider.hideForTesting()
        XCTAssertFalse(hider.isShown, "precondition: the bar was idle-hidden")
        enterEdit(viewer)
        XCTAssertTrue(hider.isShown, "entering edit shows the bar")
        XCTAssertTrue(hider.currentHolds().contains(.editMode))

        // ⌘I, a resize and the window losing key never hide it.
        let split = try XCTUnwrap(viewer.splitController)
        split.setInspectorShown(true, animated: false)
        split.editCanvasWidth(300)
        var frame = viewer.frame
        frame.size.width += 40
        viewer.setFrame(frame, display: false)
        hider.hideIfAllowed()
        XCTAssertTrue(hider.isShown)
        XCTAssertTrue(hider.currentHolds().contains(.editMode))
        XCTAssertTrue(hider.currentHolds().contains(.notKey), "an offscreen window is not key: it keeps its state")
        hider.hideIfAllowed()
        XCTAssertTrue(hider.isShown, "idle time does not hide the edit bar")

        // Leave and enter again: still shown.
        viewer.contentRootForTesting.editModeController.finalizeExit()
        hider.hideForTesting()
        enterEdit(viewer)
        XCTAssertTrue(hider.isShown)
        viewer.contentRootForTesting.editModeController.finalizeExit()
    }

    // 1. The 150 ms resize time belongs to the edit-width resize only.
    func testResizeTimeIsScopedToTheEditWidthResize() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.close() }
        var target = viewer.frame
        target.size.width += 400
        let plain = NSWindow(contentRect: viewer.frame, styleMask: viewer.styleMask, backing: .buffered, defer: true)
        XCTAssertEqual(viewer.animationResizeTime(target), plain.animationResizeTime(target), accuracy: 0.0001,
                       "the zoom button and other resizes keep the system's time")
        viewer.editWidthResizing = true
        XCTAssertEqual(viewer.animationResizeTime(target), EditLayout.resizeDuration)
        viewer.editWidthResizing = false
        XCTAssertFalse(viewer.editWidthResizing)
    }

    // 5. Edit started windowed, ended in full screen: the old size returns when full screen ends.
    func testWidenedWindowReturnsAfterFullScreenExit() throws {
        Prefs.viewerInspectorVisibleWindowed = true
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        let split = try XCTUnwrap(viewer.splitController)
        let original = viewer.frame
        enterEdit(viewer)
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5)
        viewer.fullScreenOverrideForTesting = true
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertNotNil(viewer.editWidenRestore, "kept until full screen ends")
        XCTAssertTrue(viewer.editWidenReturnPending)
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5, "no resize inside full screen")
        // Leaving full screen: AppKit puts the inspector back, then the widened frame returns.
        viewer.fullScreenOverrideForTesting = false
        split.willExitFullScreen()
        viewer.finishEditWidthReturnAfterFullScreen()
        XCTAssertEqual(viewer.frame.width, original.width, accuracy: 0.5, "back to the pre-edit size")
        XCTAssertEqual(viewer.frame.minX, original.minX, accuracy: 0.5)
        XCTAssertNil(viewer.editWidenRestore)
        XCTAssertFalse(viewer.editWidenReturnPending)
    }

    // 5. The real order: full screen starts first (the inspector goes), edit ends in it,
    // full screen ends (the inspector comes back), then the old size returns.
    func testRealFullScreenSequenceReturnsToTheOldSize() throws {
        Prefs.viewerInspectorVisibleWindowed = true
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        let split = try XCTUnwrap(viewer.splitController)
        let original = viewer.frame
        enterEdit(viewer)
        split.willEnterFullScreen()
        viewer.fullScreenOverrideForTesting = true
        viewer.contentRootForTesting.editModeController.finalizeExit()
        viewer.fullScreenOverrideForTesting = false
        split.willExitFullScreen()
        viewer.finishEditWidthReturnAfterFullScreen()
        XCTAssertEqual(viewer.frame.width, original.width, accuracy: 0.5)
        XCTAssertEqual(viewer.frame.minX, original.minX, accuracy: 0.5)
    }

    // 5. A window the user resized in full screen's aftermath keeps its width.
    func testResizedWindowStaysAfterFullScreenExit() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        enterEdit(viewer)
        viewer.fullScreenOverrideForTesting = true
        viewer.contentRootForTesting.editModeController.finalizeExit()
        viewer.fullScreenOverrideForTesting = false
        var frame = viewer.frame
        frame.size.width = 900
        viewer.setFrame(frame, display: false)
        viewer.finishEditWidthReturnAfterFullScreen()
        XCTAssertEqual(viewer.frame.width, 900, accuracy: 0.5)
    }

    // 5. Edit started again inside full screen and still on when full screen ends: no shrink.
    func testNoShrinkWhileStillEditingAfterFullScreenExit() {
        let viewer = makeViewer(width: 480, height: 320)
        defer { viewer.fullScreenOverrideForTesting = nil; viewer.close() }
        enterEdit(viewer)
        viewer.fullScreenOverrideForTesting = true
        viewer.contentRootForTesting.editModeController.finalizeExit()
        enterEdit(viewer)   // second edit, inside full screen
        viewer.fullScreenOverrideForTesting = false
        viewer.finishEditWidthReturnAfterFullScreen()
        XCTAssertEqual(contentWidth(viewer), 648, accuracy: 0.5, "still editing: stays wide")
        XCTAssertEqual(viewer.contentMinSize.width, 648, accuracy: 0.5)
        viewer.contentRootForTesting.editModeController.finalizeExit()
        XCTAssertEqual(contentWidth(viewer), 480, accuracy: 0.5, "the normal exit gives the size back")
    }
}

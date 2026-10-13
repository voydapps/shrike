//
//  EditColumn028Tests.swift
//  ShrikeUITests
//
//  Spec 27 V3 and P3-4: the edit-mode right column reads as a panel. With no
//  tool chosen the card spans the whole band; the histogram docks inside the
//  column and never sits on the photo. The photo's fit area does not change.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class EditColumn028Tests: XCTestCase {

    private var savedHistogram = false

    override func setUp() async throws {
        savedHistogram = Prefs.viewerHistogramVisible
        Prefs.viewerHistogramVisible = true
    }

    override func tearDown() async throws {
        Prefs.viewerHistogramVisible = savedHistogram
        ReduceMotion.overrideForTesting = nil
    }

    private func makeContent(_ mode: ViewerContentView.WindowMode, size: NSSize = NSSize(width: 1400, height: 900)) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.animatesPanelFades = false
        content.windowMode = mode
        content.imageView.image = SaveFlowTests.image(width: 600, height: 400)
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func photoRect(_ content: ViewerContentView) -> NSRect {
        content.convert(content.imageView.drawnImageRect, from: content.imageView)
    }

    private func enter(_ content: ViewerContentView, tool: EditTool?) {
        content.enterEditMode(image: SaveFlowTests.image(width: 600, height: 400), url: nil, landOn: tool)
        content.layoutSubtreeIfNeeded()
    }

    // Vector 1.
    func testFitInsetsAreUnchanged() {
        let content = makeContent(.windowed)
        enter(content, tool: nil)
        let insets = content.currentFitInsets()
        let panel = content.editModeController.parameterPanel
        XCTAssertEqual(insets.left, ViewerContentView.editHandleMargin, accuracy: 0.5)
        XCTAssertEqual(insets.right, ViewerContentView.editHandleMargin + (content.imageView.frame.maxX - panel.frame.minX),
                       accuracy: 0.5)
        XCTAssertEqual(insets.right, 16 + 296, accuracy: 0.5, "the 296 pt column is reserved")
        content.editModeController.finalizeExit()
    }

    // Vector 2: no tool = the whole band; a tool = its content.
    func testNoToolCardSpansTheBandAndAPickedToolShrinksToContent() {
        ReduceMotion.overrideForTesting = true
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            let content = makeContent(mode)
            enter(content, tool: nil)
            let panel = content.editModeController.parameterPanel
            let band = content.editModeController.parameterPanel.bandHeightProvider?() ?? 0
            XCTAssertGreaterThan(band, 300, "\(mode)")
            XCTAssertEqual(panel.frame.height, band, accuracy: 1, "\(mode): the empty card is as tall as the band")
            XCTAssertTrue(panel.fillsBand)
            let card = try? XCTUnwrap(panel._installed as? ChooseToolPanel)
            if let card {
                // Title and body sit in the middle of the card.
                let title = card.convert(card.titleLabel.bounds, from: card.titleLabel)
                let body = card.convert(card.bodyLabel.bounds, from: card.bodyLabel)
                let stack = title.union(body)
                XCTAssertEqual(stack.midY, card.bounds.midY, accuracy: 2, "\(mode): vertically centred")
                XCTAssertEqual(stack.midX, card.bounds.midX, accuracy: 2, "\(mode): horizontally centred")
                // The text column (the label's alignment rect: its frame has 2 pt of cell padding a side).
                let bodyText = card.bodyLabel.alignmentRect(forFrame: card.bodyLabel.frame)
                XCTAssertLessThanOrEqual(bodyText.width, ChooseToolPanel.textWidth + 0.5, "\(mode)")
            }

            content.editModeController.perform(.selectTool(.crop))
            content.layoutSubtreeIfNeeded()
            XCTAssertFalse(panel.fillsBand)
            XCTAssertEqual(panel.frame.height, panel.contentHeight, accuracy: 1, "\(mode): content height")
            XCTAssertLessThanOrEqual(panel.frame.height, band + 1)
            content.editModeController.finalizeExit()
        }
    }

    // Vector 3: picking a tool never moves the photo.
    func testPickingEachToolDoesNotMoveThePhoto() {
        ReduceMotion.overrideForTesting = true
        let content = makeContent(.windowed)
        enter(content, tool: nil)
        let before = photoRect(content)
        for tool in EditChromeTools.order {
            content.editModeController.perform(.selectTool(tool))
            content.layoutSubtreeIfNeeded()
            let now = photoRect(content)
            XCTAssertEqual(now.minX, before.minX, accuracy: 0.5, "\(tool)")
            XCTAssertEqual(now.minY, before.minY, accuracy: 0.5, "\(tool)")
            XCTAssertEqual(now.width, before.width, accuracy: 0.5, "\(tool)")
            XCTAssertEqual(now.height, before.height, accuracy: 0.5, "\(tool)")
        }
        content.editModeController.finalizeExit()
    }

    // Vector 4: the docked histogram never overlaps the photo, window and full screen.
    func testHistogramDocksInTheColumnAndStaysOffThePhoto() {
        ReduceMotion.overrideForTesting = true
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            let content = makeContent(mode)
            let panelKind = EditTool.color
            enter(content, tool: panelKind)
            let hud = content.histogramOverlayFrameForTesting()
            let panel = content.editModeController.parameterPanel.frame
            XCTAssertTrue(content.histogramOverlayVisibleForTesting, "\(mode): the Color panel leaves room")
            XCTAssertEqual(hud.width, 280, accuracy: 0.5)
            XCTAssertEqual(hud.maxX, content.bounds.maxX - 16, accuracy: 0.5, "\(mode): 16 pt from the edge")
            XCTAssertFalse(hud.intersects(panel), "\(mode): below the tool panel")
            XCTAssertFalse(hud.intersects(photoRect(content)), "\(mode): not on the photo")
            XCTAssertGreaterThanOrEqual(content.editColumnFreeHeight, 160)
            content.editModeController.finalizeExit()
        }
    }

    // Hidden with no tool, with Levels, and when the column has no room.
    func testHistogramIsHiddenWhenTheColumnHasNoRoom() {
        ReduceMotion.overrideForTesting = true
        let content = makeContent(.windowed)
        enter(content, tool: nil)
        _ = content.histogramOverlayFrameForTesting()
        XCTAssertFalse(content.editHistogramRoom, "the full-height card leaves no room")
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        content.editModeController.perform(.selectTool(.levels))
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.editHistogramRoom, "Levels shows its own")
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        content.editModeController.perform(.selectTool(.color))
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.editHistogramRoom)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)

        // A short window: the Color panel leaves less than 160 pt.
        let short = makeContent(.windowed, size: NSSize(width: 1400, height: 560))
        enter(short, tool: .color)
        _ = short.histogramOverlayFrameForTesting()
        XCTAssertLessThan(short.editColumnFreeHeight, 160)
        XCTAssertFalse(short.histogramOverlayVisibleForTesting)
        short.editModeController.finalizeExit()
        content.editModeController.finalizeExit()
    }

    // Vector 5: leaving edit puts the histogram back where it was.
    func testLeavingEditRestoresTheHistogramFrame() {
        ReduceMotion.overrideForTesting = true
        for mode in [ViewerContentView.WindowMode.windowed, .fullscreen] {
            let content = makeContent(mode)
            let before = content.histogramOverlayFrameForTesting()
            enter(content, tool: .color)
            XCTAssertNotEqual(content.histogramOverlayFrameForTesting().width, before.width, "\(mode): docked while editing")
            content.editModeController.finalizeExit()
            content.layoutSubtreeIfNeeded()
            let after = content.histogramOverlayFrameForTesting()
            XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, "\(mode)")
            XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "\(mode)")
            XCTAssertEqual(after.width, before.width, accuracy: 0.5, "\(mode)")
            XCTAssertEqual(after.height, before.height, accuracy: 0.5, "\(mode)")
        }
    }

    // Vector 6: under Reduce Motion the height change is not animated.
    func testReduceMotionChangesTheHeightAtOnce() {
        ReduceMotion.overrideForTesting = true
        let content = makeContent(.windowed)
        enter(content, tool: nil)
        let panel = content.editModeController.parameterPanel
        content.editModeController.perform(.selectTool(.crop))
        // No animation group ran: the constraint already holds the final height.
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(panel.frame.height, panel.contentHeight, accuracy: 1)
    }
}

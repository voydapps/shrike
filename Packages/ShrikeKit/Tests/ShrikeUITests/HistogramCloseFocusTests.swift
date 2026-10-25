//
//  HistogramCloseFocusTests.swift
//  ShrikeUITests
//
//  UX-02 check P3-1: ⌃H right after clicking the histogram × looked dead
//  once. A click on the × never takes focus, focus is put back on the photo
//  if it was lost, and the key reaches the window.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class HistogramCloseFocusTests: XCTestCase {

    private var dir: URL!
    private var savedHistogram = false

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-histclose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedHistogram = Prefs.viewerHistogramVisible
        Prefs.viewerHistogramVisible = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerHistogramVisible = savedHistogram
    }

    private func controlH() throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{08}", charactersIgnoringModifiers: "h",
            isARepeat: false, keyCode: 4))
    }

    func testControlHWorksRightAfterClickingTheCloseButton() throws {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 1000, height: 700))
        viewer.markDisplayedForTesting(0)
        viewer.contentView?.layoutSubtreeIfNeeded()
        let content = viewer.contentRootForTesting
        _ = content.histogramOverlayFrameForTesting()          // builds the panel
        let overlay = try XCTUnwrap(content.histogramOverlayIfBuiltForTesting)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        XCTAssertFalse(overlay.closeButton.acceptsFirstResponder, "a click never takes focus")

        // The photo has focus; the click happens; focus is still there.
        viewer.makeFirstResponder(content)
        overlay.closeButton.performClick(nil)
        XCTAssertFalse(Prefs.viewerHistogramVisible, "the × hides it")
        XCTAssertTrue(viewer.firstResponder === content, "focus stays on the photo")

        // Focus dropped on the way (the window itself): it comes back.
        content.toggleHistogramOverlay()
        XCTAssertTrue(Prefs.viewerHistogramVisible)
        viewer.makeFirstResponder(nil)
        overlay.closeButton.performClick(nil)
        XCTAssertFalse(Prefs.viewerHistogramVisible)
        XCTAssertTrue(viewer.firstResponder === content, "focus comes back to the photo")

        // ⌃H right after the click: shows it, then hides it.
        viewer.keyDown(with: try controlH())
        XCTAssertTrue(Prefs.viewerHistogramVisible, "⌃H shows it again")
        viewer.keyDown(with: try controlH())
        XCTAssertFalse(Prefs.viewerHistogramVisible, "and hides it")
    }
}

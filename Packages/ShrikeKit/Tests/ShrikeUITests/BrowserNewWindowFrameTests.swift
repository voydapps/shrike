//
//  BrowserNewWindowFrameTests.swift
//  ShrikeUITests
//
//  Every new Browser (Go to Folder, Open Folder, the viewer's
//  Show in Browser) starts at the saved Browser size, and steps 24 pt
//  right and down from a Browser that is already open. Browsers are made
//  directly (never through `WindowCoordinator.openBrowser`, which adds to
//  Open Recent) and never shown.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserNewWindowFrameTests: XCTestCase {

    private var dir: URL!
    private var controllers: [BrowserWindowController] = []

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-browser-frame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.window?.close() }
        controllers = []
        try? FileManager.default.removeItem(at: dir)
    }

    private func browser() -> BrowserWindowController {
        let controller = BrowserWindowController(services: .makeDefault(), initialFolder: dir)
        controllers.append(controller)
        return controller
    }

    func testCascadedFrameSteps24ptRightAndDown() {
        let other = NSRect(x: 100, y: 200, width: 1000, height: 700)
        let size = NSSize(width: 900, height: 600)
        let visible = NSRect(x: 0, y: 0, width: 2000, height: 1200)
        let frame = BrowserWindowController.cascadedFrame(size: size, from: other, visible: visible)
        XCTAssertEqual(frame.size, size, "keeps the saved size")
        XCTAssertEqual(frame.minX, other.minX + 24)
        XCTAssertEqual(frame.maxY, other.maxY - 24, "top edge 24 pt lower")

        // Near the right and bottom edges it stays on the screen.
        let corner = NSRect(x: 1500, y: 20, width: 600, height: 500)
        let kept = BrowserWindowController.cascadedFrame(size: NSSize(width: 800, height: 600),
                                                         from: corner, visible: visible)
        XCTAssertTrue(visible.contains(kept), "\(kept) stays inside \(visible)")

        let smallScreen = NSRect(x: 0, y: 0, width: 900, height: 650)
        let oversized = BrowserWindowController.cascadedFrame(
            size: NSSize(width: 1100, height: 800),
            from: NSRect(x: 100, y: 100, width: 700, height: 500), visible: smallScreen
        )
        XCTAssertEqual(oversized.size, smallScreen.size, "an oversized saved Browser fits a smaller display")
        XCTAssertTrue(smallScreen.contains(oversized))
    }

    func testBrowserUsesAContainedMinimumLayoutAtSmallDisplayWidths() {
        let standardMinimum = BrowserWindowController.minimumLayout(forVisibleWidth: 1024)
        XCTAssertFalse(standardMinimum.collapseSidebar)
        XCTAssertFalse(standardMinimum.collapseInspector)
        XCTAssertEqual(standardMinimum.minimumWidth, 1022,
                       "the three panes fit inside a 1024 pt display without growing the window")

        let narrow = BrowserWindowController.minimumLayout(forVisibleWidth: 900)
        XCTAssertTrue(narrow.collapseSidebar, "the folder tree is optional when the display is narrow")
        XCTAssertFalse(narrow.collapseInspector, "keep the inspector available at 900 pt")
        XCTAssertEqual(narrow.minimumWidth, 822)

        let veryNarrow = BrowserWindowController.minimumLayout(forVisibleWidth: 700)
        XCTAssertTrue(veryNarrow.collapseSidebar)
        XCTAssertTrue(veryNarrow.collapseInspector)
        XCTAssertEqual(veryNarrow.minimumWidth, BrowserToolbarRoom.contentMinimumWidth)
        XCTAssertLessThanOrEqual(veryNarrow.minimumWidth, 700)

        let compact = BrowserWindowController.minimumLayout(forVisibleWidth: 400)
        XCTAssertTrue(compact.collapseSidebar)
        XCTAssertTrue(compact.collapseInspector)
        XCTAssertEqual(compact.minimumWidth, 400,
                       "the grid remains reachable even below the standard toolbar minimum")
    }

    func testANewBrowserTakesTheSavedSizeAndCascadesFromTheOpenOne() throws {
        let first = browser()
        let firstWindow = try XCTUnwrap(first.window)
        XCTAssertEqual(firstWindow.frameAutosaveName, BrowserWindowController.windowAutosaveName,
                       "the first Browser owns the autosave name")
        let visible = try XCTUnwrap((firstWindow.screen ?? NSScreen.main)?.visibleFrame)
        let savedSize = NSSize(width: min(1100, visible.width), height: min(720, visible.height))
        firstWindow.setFrame(NSRect(x: min(180, visible.maxX - savedSize.width),
                                    y: min(160, visible.maxY - savedSize.height),
                                    width: savedSize.width, height: savedSize.height), display: false)
        firstWindow.saveFrame(usingName: BrowserWindowController.windowAutosaveName)

        let second = browser()
        let secondWindow = try XCTUnwrap(second.window)
        XCTAssertEqual(secondWindow.frame.size, firstWindow.frame.size,
                       "the saved size, not the 1280 x 800 default")
        second.cascade(from: firstWindow)
        XCTAssertEqual(secondWindow.frame.size, savedSize)
        let expected = BrowserWindowController.cascadedFrame(size: savedSize, from: firstWindow.frame,
                                                              visible: visible)
        XCTAssertEqual(secondWindow.frame, expected)
        XCTAssertTrue(visible.contains(secondWindow.frame), "the complete new Browser stays on screen")

        // Closing the first gives the name back: the next Browser owns it.
        firstWindow.close()
        secondWindow.close()
        let third = browser()
        XCTAssertEqual(third.window?.frameAutosaveName, BrowserWindowController.windowAutosaveName)
        XCTAssertEqual(third.window?.frame.size, savedSize)
    }
}

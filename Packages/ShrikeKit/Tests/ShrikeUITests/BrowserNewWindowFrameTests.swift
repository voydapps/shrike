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
        dir = FileManager.default.temporaryDirectory
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
    }

    func testANewBrowserTakesTheSavedSizeAndCascadesFromTheOpenOne() throws {
        let first = browser()
        let firstWindow = try XCTUnwrap(first.window)
        XCTAssertEqual(firstWindow.frameAutosaveName, BrowserWindowController.windowAutosaveName,
                       "the first Browser owns the autosave name")
        firstWindow.setFrame(NSRect(x: 180, y: 160, width: 1100, height: 720), display: false)
        firstWindow.saveFrame(usingName: BrowserWindowController.windowAutosaveName)

        let second = browser()
        let secondWindow = try XCTUnwrap(second.window)
        XCTAssertEqual(secondWindow.frame.size, firstWindow.frame.size,
                       "the saved size, not the 1280 x 800 default")
        second.cascade(from: firstWindow)
        XCTAssertEqual(secondWindow.frame.size, NSSize(width: 1100, height: 720))
        XCTAssertEqual(secondWindow.frame.minX, firstWindow.frame.minX + 24, accuracy: 0.5)
        XCTAssertEqual(secondWindow.frame.maxY, firstWindow.frame.maxY - 24, accuracy: 0.5)

        // Closing the first gives the name back: the next Browser owns it.
        firstWindow.close()
        secondWindow.close()
        let third = browser()
        XCTAssertEqual(third.window?.frameAutosaveName, BrowserWindowController.windowAutosaveName)
        XCTAssertEqual(third.window?.frame.size, NSSize(width: 1100, height: 720))
    }
}

//
//  BrowserWindowFrameStabilityTests.swift
//  ShrikeUITests
//
//  Switching the Browser view (⌘1 grid, ⌘2 filmstrip, ⌘3 list) never
//  changes the window frame; a saved frame that is shorter than the
//  window minimum is lifted to it.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserWindowFrameStabilityTests: XCTestCase {

    private var dir: URL!
    /// AppKit's autosave key for the Browser frame (`UserDefaults.standard`).
    /// The tests below move Browsers that autosave under it, so the value is
    /// put back afterwards; the user's saved frame is never lost.
    private static let frameKey = "NSWindow Frame \(BrowserWindowController.windowAutosaveName)"
    private var savedFrame: String?

    override func setUp() async throws {
        savedFrame = UserDefaults.standard.string(forKey: Self.frameKey)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-frame-stability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for window in NSApp.windows where window is BrowserWindow { window.close() }
        if let savedFrame {
            UserDefaults.standard.set(savedFrame, forKey: Self.frameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.frameKey)
        }
    }

    private func settle(_ window: NSWindow) async {
        // Auto Layout may resize the window on the next display pass.
        for _ in 0..<3 {
            try? await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    func testSwitchingViewsKeepsTheWindowFrame() async throws {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 1986, height: 600)] {
            let browser = BrowserWindowController(services: .makeDefault(), initialFolder: dir)
            defer { browser.window?.close() }
            let window = try XCTUnwrap(browser.window)
            window.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: size), display: true)
            window.orderFront(nil)
            await settle(window)
            let start = window.frame
            XCTAssertEqual(start.size.height, size.height, accuracy: 1, "test set-up")
            let sequence: [ShrikeCommand] = [.viewAsFilmstrip, .viewAsGrid, .viewAsList, .viewAsFilmstrip,
                                             .viewAsList, .viewAsGrid]
            for command in sequence {
                browser.perform(command)
                await settle(window)
                XCTAssertEqual(window.frame, start, "\(command) at \(size)")
            }
        }
    }

    func testASavedFrameShorterThanTheMinimumIsLiftedToIt() async throws {
        let name = BrowserWindowController.windowAutosaveName
        let probe = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 184),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        probe.setFrame(NSRect(x: 100, y: 100, width: 1000, height: 184), display: false)
        probe.saveFrame(usingName: name)
        let browser = BrowserWindowController(services: .makeDefault(), initialFolder: dir)
        defer { browser.window?.close() }
        let window = try XCTUnwrap(browser.window)
        XCTAssertGreaterThanOrEqual(window.frame.height, window.minSize.height)
        XCTAssertGreaterThanOrEqual(window.frame.width, window.minSize.width)
    }

    /// Photos arriving in the folder, a selection and the inspector's info
    /// filling in (what happens after the window opened) never resize the
    /// window by themselves, in any view.
    func testPhotosLoadingAndTheInspectorFillingNeverResizeTheWindow() async throws {
        var urls: [URL] = []
        for i in 0..<30 {
            let url = dir.appendingPathComponent(String(format: "P%03d.jpg", i))
            XCTAssertTrue(RotateDirectionTests.writeQuadrantJPEG(url, orientation: i % 3 == 0 ? .up : .right))
            urls.append(url)
        }
        for mode in BrowserViewMode.allCases {
            for size in [NSSize(width: 1986, height: 600), NSSize(width: 1280, height: 800)] {
                let browser = BrowserWindowController(services: .makeDefault(), initialFolder: dir)
                defer { browser.window?.close() }
                let window = try XCTUnwrap(browser.window)
                window.setFrame(NSRect(origin: NSPoint(x: 100, y: 100), size: size), display: true)
                browser.contentController.setMode(mode)
                window.orderFront(nil)
                let start = window.frame
                for _ in 0..<60 where browser.contentController.allItems.count < urls.count {
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertEqual(browser.contentController.allItems.count, urls.count, "listing arrived")
                await settle(window)
                browser.select(url: urls[4])
                await browser.waitForInspectorInfo()
                for _ in 0..<10 {
                    try await Task.sleep(for: .milliseconds(100))
                    window.contentView?.layoutSubtreeIfNeeded()
                }
                XCTAssertEqual(window.frame, start, "\(mode) at \(size)")
            }
        }
    }
}

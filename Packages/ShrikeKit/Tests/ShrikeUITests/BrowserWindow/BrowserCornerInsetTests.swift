//
//  BrowserCornerInsetTests.swift
//  ShrikeUITests
//
//  The Browser's bottom bar keeps its ends out of the
//  window's rounded corners (16 pt on macOS 26, whose corners are large;
//  8 pt on macOS 14 / 15). Measured at the minimum window width, in a
//  window that is never shown.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class BrowserCornerInsetTests: XCTestCase {

    func testTheBottomBarEndsClearTheWindowCorners() async throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-corner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        var frame = window.frame
        frame.size.width = window.minSize.width
        window.setFrame(frame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()

        let bar = browser.bottomBar
        bar.setStatus("IMG_0001.jpg · 3456 × 5184 · 9.3 MB")
        bar.setSliderHidden(false)
        window.contentView?.layoutSubtreeIfNeeded()

        let expected: CGFloat
        if #available(macOS 26.0, *) { expected = 16 } else { expected = 8 }
        XCTAssertEqual(WindowCornerInset.side, expected)
        let width = window.frame.width
        let status = bar.statusField.convert(bar.statusField.bounds, to: nil)
        let slider = bar.slider.convert(bar.slider.bounds, to: nil)
        XCTAssertGreaterThanOrEqual(status.minX, expected - 0.5, "status text clear of the bottom-left corner")
        XCTAssertLessThanOrEqual(slider.maxX, width - expected + 0.5, "slider clear of the bottom-right corner")
        XCTAssertGreaterThan(status.width, 0)
        XCTAssertGreaterThan(slider.width, 0)
    }
}

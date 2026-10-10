//
//  ViewerFirstTextureSizeTests.swift
//  ShrikeUITests
//
//  A new viewer's first photos are
//  decoded for the window, not for the whole screen (4096 px textures,
//  ~45 MB each, where a 1200 x 800 pt window needs ~15 MB).
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ViewerFirstTextureSizeTests: XCTestCase {

    func testSavedFrameStringGivesTheSize() {
        let size = ViewerWindow.frameSize(saved: "680 479 1200 800 0 0 2560 1677 ")
        XCTAssertEqual(size, NSSize(width: 1200, height: 800))
        XCTAssertNil(ViewerWindow.frameSize(saved: nil))
        XCTAssertNil(ViewerWindow.frameSize(saved: "garbage"))
        XCTAssertNil(ViewerWindow.frameSize(saved: "0 0 0 800"))
    }

    func testFirstTextureFollowsTheWindowNotTheScreen() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let pref = Prefs.maxDisplayLongEdge
        let scale = screen.backingScaleFactor
        let small = ViewerWindow.initialTextureLongEdge(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(small, max(256, min(pref, Int((400 * scale).rounded(.up)))))

        let tiny = ViewerWindow.initialTextureLongEdge(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
        XCTAssertEqual(tiny, 256, "never below the queue's floor")

        let huge = ViewerWindow.initialTextureLongEdge(frame: NSRect(x: 0, y: 0, width: 100_000, height: 100_000))
        let visible = screen.visibleFrame.size
        let screenPx = Int((max(visible.width, visible.height) * scale).rounded(.up))
        XCTAssertEqual(huge, max(256, min(pref, screenPx)), "never above the screen or the pref")
        XCTAssertLessThanOrEqual(small, huge)
    }

    func testFrameHintIsUsedOnce() throws {
        guard NSScreen.main != nil else { throw XCTSkip("no screen") }
        let hint = NSRect(x: 0, y: 0, width: 300, height: 200)
        ViewerWindow.nextFrameHint = hint
        XCTAssertEqual(ViewerWindow.takeInitialTextureLongEdge(), ViewerWindow.initialTextureLongEdge(frame: hint))
        XCTAssertNil(ViewerWindow.nextFrameHint, "one use")
    }
}

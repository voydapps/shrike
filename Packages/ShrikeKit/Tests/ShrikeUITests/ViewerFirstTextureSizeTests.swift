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

    /// A screen narrower than 1200 pt (the 1024 x 768 CI runner, a small laptop): the
    /// window is built at the screen's size, and the early decode asks for exactly that
    /// size, so the first layout needs nothing larger and the photo is decoded once.
    func testSmallScreenBuildsTheWindowAndTheEarlyDecodeForTheSameSize() {
        let visible = NSSize(width: 1024, height: 700)
        let window = ViewerWindow.defaultWindowSize(visible: visible)
        XCTAssertEqual(window, NSSize(width: 1024, height: 700), "clamped to the screen")
        for scale in [CGFloat(1), 2] {
            let early = ViewerWindow.initialTextureLongEdge(frame: nil, visible: visible, scale: scale, pref: 4096,
                                                            defaultSizeForTesting: true)
            XCTAssertEqual(early, Int(1024 * scale), "early decode = the window's long edge at the screen's scale")
        }
        // A big screen keeps the generous default.
        let big = ViewerWindow.defaultWindowSize(visible: NSSize(width: 2560, height: 1400))
        XCTAssertEqual(big, NSSize(width: 1200, height: 800))
    }

    func testNewViewerIsNeverWiderThanTheScreen() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let services = ShrikeServices.makeDefault()
        let viewer = ViewerWindow(groups: [], startIndex: 0, services: services)
        defer { viewer.close() }
        XCTAssertLessThanOrEqual(viewer.frame.width, screen.visibleFrame.width + 0.5)
        XCTAssertLessThanOrEqual(viewer.frame.height, screen.visibleFrame.height + 0.5)
    }
}

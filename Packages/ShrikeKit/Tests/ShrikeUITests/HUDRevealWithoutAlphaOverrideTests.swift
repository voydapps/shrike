//
//  HUDRevealWithoutAlphaOverrideTests.swift
//  ShrikeUITests
//
//  Audit 2026-10-24 M1 / M2 / L13. HUDSurfaceView no longer overrides
//  `alphaValue` (a `didSet` there crashes on animator() views). The
//  look is built when a surface is un-hidden, so the usual
//  "alpha 0, un-hide, fade in" show still gets its fill.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class HUDRevealWithoutAlphaOverrideTests: XCTestCase {

    func testUnhidingAtAlphaZeroBuildsTheLookBeforeTheFade() {
        HUDGlass.forceFallbackForTesting = true
        defer { HUDGlass.forceFallbackForTesting = false }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: true)
        let surface = HUDSurfaceView(frame: NSRect(x: 10, y: 10, width: 120, height: 40))
        surface.alphaValue = 0
        surface.isHidden = true
        window.contentView?.addSubview(surface)
        XCTAssertNil(surface.fillLayerForTesting, "nothing is built while hidden")

        surface.isHidden = false                       // the show pattern: un-hide at alpha 0 ...
        XCTAssertNotNil(surface.fillLayerForTesting, "the fill exists before the fade starts")
        surface.alphaValue = 1                         // ... then fade in
        XCTAssertNotNil(surface.fillLayerForTesting)
    }

    func testNoAlphaOverrideOnTheBaseClass() {
        // The class has no `alphaValue` override: setting it on a hidden surface builds nothing.
        let surface = HUDSurfaceView(frame: NSRect(x: 0, y: 0, width: 50, height: 20))
        surface.isHidden = true
        surface.alphaValue = 1
        XCTAssertNil(surface.fillLayerForTesting)
        XCTAssertFalse(surface.isRevealed)
    }

    func testZoomBadgeIsHiddenFromTheStartAndAfterTheFade() {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.zoomBadgeForTesting.isHidden, "not in the accessibility tree before the first zoom")
        XCTAssertFalse(content.zoomBadgeShownForTesting)
        content.forceZoomBadgeVisibleForTesting()
        XCTAssertTrue(content.zoomBadgeShownForTesting)
        content.hideZoomBadgeForTesting()
        content.zoomBadgeForTesting.isHidden = true
        XCTAssertFalse(content.zoomBadgeShownForTesting, "checks isHidden, not just alpha")
    }
}

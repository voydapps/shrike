//
//  SmallPolish028Tests.swift
//  ShrikeUITests
//
//  Spec 27: P3-10 (key words), P3-11 (Welcome), N8 (cell label), C1 (Compare dim).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class SmallPolish028Tests: XCTestCase {

    // MARK: P3-10

    func testSpecialKeysAreWords() {
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.escape), "Esc")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.pageUp), "Page Up")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.pageDown), "Page Down")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.home), "Home")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.end), "End")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.tab), "⇥")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.left), "←")
        XCTAssertEqual(SpecialKey.glyph(for: SpecialKey.down), "↓")
        XCTAssertFalse(SpecialKey.glyph(for: SpecialKey.escape).contains("⎋"))
    }

    // MARK: P3-11

    func testWelcomeBorderAndTaglineContrast() {
        for appearance in [Contrast.dark, Contrast.light] {
            let surface = NSColor.windowBackgroundColor
            XCTAssertGreaterThanOrEqual(
                Contrast.ratio(WelcomeDropZone.idleBorderColor, on: surface, in: appearance), 3.0, "\(appearance.name)")
        }
        // The tagline is the system's secondary label (spec: 4.5:1 on the dark surface).
        // In the light appearance the system's own colour measures 3.9:1; not repainted.
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(.secondaryLabelColor, on: .windowBackgroundColor, in: Contrast.dark), 4.5)
    }

    func testOpenFolderIsThePrimaryButton() {
        let welcome = WelcomeWindowController(recentURLs: { [] })
        defer { welcome.close() }
        XCTAssertEqual(welcome.openFolderButton.keyEquivalent, "\r")
        XCTAssertEqual(welcome.openButton.keyEquivalent, "")
        XCTAssertEqual(welcome.openFolderButton.accentFillMechanism,
                       { if #available(macOS 26, *) { return "prominent" } else { return "accent" } }())
    }

    // MARK: V5

    func testEditedChipIsA20By16ChipWithTheRawChipBackdrop() {
        let cell = ThumbnailItem()
        cell.loadView()
        cell.applyBadges(ItemBadges(hasRAW: true, edited: true))
        XCTAssertTrue(cell.badgeStateForTesting.pencil, "still reported as the pencil")
        XCTAssertEqual(cell.editedChipForTesting.image?.size, NSSize(width: 20, height: 16))
        XCTAssertEqual(Badges.editedChipSize, NSSize(width: 20, height: 16))
        XCTAssertEqual(Badges.chipFill, NSColor.black.withAlphaComponent(0.55))
        XCTAssertEqual(Badges.editedChipSymbol, "pencil.line")
        XCTAssertEqual(Badges.editedChipSymbolPointSize, 11)
        XCTAssertEqual(Badges.editedChipSymbolWeight, .semibold)
        XCTAssertEqual(cell.editedChipForTesting.toolTip, "Edited by Shrike. The original is kept.")
        XCTAssertEqual(Badges.editedTooltip, cell.editedChipForTesting.toolTip)
    }

    func testPillMarkIsAFullOpacity16PointSymbol() {
        XCTAssertEqual(Badges.editedPillPointSize, 16)
        let text = PillMarks.marksText(PillMarks(edited: true))
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if value is NSTextAttachment { found = true }
        }
        XCTAssertTrue(found)
    }

    // MARK: P3-10b, N10

    func testShortcutsWindowAsksForSearchFocusWhenOpenedAndWhenKey() {
        let controller = ShortcutsWindowController()
        defer { controller.window?.close() }
        let before = controller.modelForTesting.focusTick
        controller.show()
        XCTAssertGreaterThan(controller.modelForTesting.focusTick, before)
        let mid = controller.modelForTesting.focusTick
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        XCTAssertGreaterThan(controller.modelForTesting.focusTick, mid)
    }

    func testLoupeHasATwoLineRing() {
        let loupe = LoupeView(frame: .zero)
        let ring = loupe.ringLayersForTesting
        XCTAssertEqual(ring.outerAlpha, 0.85, accuracy: 0.01)
        XCTAssertEqual(ring.innerAlpha, 0.35, accuracy: 0.01)
    }

    // MARK: N8

    func testCellLabelOrder() {
        XCTAssertEqual(
            CellAccessibility.label(name: "a.jpg", rating: 3, flagged: true, edited: true, isPair: true, failed: true),
            "a.jpg, 3 stars, flagged, edited, RAW and JPEG pair, can't preview")
        XCTAssertEqual(CellAccessibility.label(name: "a.jpg", rating: 0, flagged: false, edited: true, isPair: false, failed: false),
                       "a.jpg, edited")
        XCTAssertEqual(CellAccessibility.label(name: "a.jpg", rating: 1, flagged: false, isPair: false, failed: false),
                       "a.jpg, 1 star")
    }

    // MARK: C1

    func testUnfocusedFooterAlphaPassesContrastOnTheNearBlackPane() {
        XCTAssertEqual(ComparePaneView.unfocusedFooterAlpha, 0.6)
        let pane = NSColor.black
        let text = NSColor.white.withAlphaComponent(ComparePaneView.unfocusedFooterAlpha)
        XCTAssertGreaterThanOrEqual(Contrast.ratio(text, on: pane, in: Contrast.dark), 4.5)
    }

    func testOnlyTheFooterDimsNeverThePhoto() {
        let panes = (0..<3).map { _ in ComparePaneView(frame: NSRect(x: 0, y: 0, width: 300, height: 300)) }
        for (i, pane) in panes.enumerated() { pane.isFocused = (i == 1) }
        XCTAssertEqual(panes.map(\.footerAlphaForTesting), [0.6, 1.0, 0.6])
        for pane in panes {
            XCTAssertEqual(pane.imageView.alphaValue, 1)
            // Nothing sits above the image except the footer, the error line and the ring.
            for sub in pane.subviews where sub !== pane.imageView && sub !== pane.footer
                && !(sub is NSTextField) && !String(describing: type(of: sub)).contains("Ring") {
                XCTFail("unexpected overlay \(sub)")
            }
        }
    }
}

//
//  BrokenPhotoTests.swift
//  ShrikeUITests
//
//  Spec 25 §2: the error card wraps and has buttons; the inspector shows
//  the broken-file glyph; sizes under 1 KB read as bytes.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class BrokenPhotoTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-broken-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func badFile() throws -> URL {
        let url = dir.appendingPathComponent("bad.jpg")
        try Data(repeating: 0x41, count: 100).write(to: url)
        return url
    }

    func testErrorCardTextWrapsInsideTheCardAndHasTwoButtons() {
        let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.layoutSubtreeIfNeeded()
        let card = overlay.cardFrameForTesting
        XCTAssertEqual(card.width, 320)
        let body = overlay.bodyFrameForTesting
        XCTAssertGreaterThanOrEqual(body.minX, 24 - 4)
        XCTAssertLessThanOrEqual(body.maxX, 320 - 24 + 4, "text stays inside the card")
        XCTAssertGreaterThan(body.height, 20, "the text wraps onto two lines")
        XCTAssertEqual(overlay.nextButton.title, "Next")
        XCTAssertEqual(overlay.revealButton.title, "Reveal in Finder")
        XCTAssertEqual(overlay.nextButton.keyEquivalent, "", "a stray Return must not skip")
        XCTAssertEqual(overlay.nextButton.toolTip, "Next Image  ·  →")
        XCTAssertTrue(overlay.revealButton.toolTip?.hasPrefix("Reveal in Finder  ·  ") ?? false)
    }

    func testErrorCardButtonsCallBackAndNextCanBeDisabled() {
        let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var next = 0, reveal = 0
        overlay.onNext = { next += 1 }
        overlay.onReveal = { reveal += 1 }
        overlay.nextButton.performClick(nil)
        overlay.revealButton.performClick(nil)
        XCTAssertEqual([next, reveal], [1, 1])
        overlay.setNextEnabled(false)
        XCTAssertFalse(overlay.nextButton.isEnabled)
    }

    func testErrorCardLetsClicksThroughOutsideTheCard() {
        let overlay = ErrorOverlayView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        overlay.layoutSubtreeIfNeeded()
        XCTAssertNil(overlay.hitTest(NSPoint(x: 5, y: 5)))
        let card = overlay.cardFrameForTesting
        XCTAssertNotNil(overlay.hitTest(NSPoint(x: card.midX, y: card.midY)))
    }

    func testInspectorPreviewShowsTheBrokenGlyphForAnUnreadableFile() async throws {
        let url = try badFile()
        let view = InspectorPreviewImageView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        view.show(url)
        await view.waitForLoad()
        XCTAssertTrue(view.isShowingBroken)
        XCTAssertNil(view.image)
    }

    func testSizeOfABadFileReadsInBytes() throws {
        let url = try badFile()
        let size = try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(FileSizeText.string(Int64(size)), "100 bytes")
    }

    func testBrokenGlyphIsOneSharedSymbol() {
        XCTAssertNotNil(Badges.brokenFileGlyph(pointSize: 16))
        XCTAssertNotNil(Badges.brokenFileGlyph(pointSize: 32))
    }
}

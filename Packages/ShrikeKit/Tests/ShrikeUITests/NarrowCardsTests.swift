//
//  NarrowCardsTests.swift
//  ShrikeUITests
//
//  Spec 21b §6 (audit M3): the "Can't open" card and the Copy/Move folder card
//  never stick out of a narrow viewer canvas (240 pt: 480 pt window + inspector).
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class NarrowCardsTests: XCTestCase {

    private func host(_ view: NSView, width: CGFloat, height: CGFloat = 400) -> NSView {
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.widthAnchor.constraint(equalToConstant: width),
            canvas.heightAnchor.constraint(equalToConstant: height),
        ])
        view.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            view.topAnchor.constraint(equalTo: canvas.topAnchor),
            view.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])
        for _ in 0..<3 { canvas.layoutSubtreeIfNeeded() }
        return canvas
    }

    func testErrorCardFitsEveryCanvasWidth() {
        for (canvas, expected) in [(CGFloat(240), CGFloat(208)), (300, 268), (452, 420), (900, 420)] {
            let overlay = ErrorOverlayView(frame: .zero)
            _ = host(overlay, width: canvas)
            let card = overlay.cardFrameForTesting
            XCTAssertEqual(card.width, expected, accuracy: 0.5, "canvas \(canvas)")
            XCTAssertGreaterThanOrEqual(card.minX, 15.5, "16 pt left at \(canvas)")
            XCTAssertLessThanOrEqual(card.maxX, canvas - 15.5, "16 pt right at \(canvas)")
        }
    }

    func testErrorCardBodyWrapsAndButtonsStackWhenNarrow() {
        let narrow = ErrorOverlayView(frame: .zero)
        _ = host(narrow, width: 240)
        let wide = ErrorOverlayView(frame: .zero)
        _ = host(wide, width: 900)
        XCTAssertTrue(narrow.buttonsAreStackedForTesting)
        XCTAssertFalse(wide.buttonsAreStackedForTesting)
        XCTAssertGreaterThan(narrow.bodyLineCountForTesting, wide.bodyLineCountForTesting, "wraps to more lines")
        XCTAssertLessThanOrEqual(narrow.bodyFrameForTesting.width, 208 - 48 + 6, "text stays inside the 24 pt padding")
        XCTAssertTrue(narrow.nextButton.frame.minX >= 0)
        XCTAssertEqual(narrow.nextButton.frame.width, narrow.revealButton.frame.width, accuracy: 1, "stacked, same width")
        XCTAssertGreaterThan(narrow.nextButton.frame.minY, narrow.revealButton.frame.minY, "Next Photo above Reveal in Finder")
    }

    func testFolderCardFitsANarrowCanvas() {
        for (canvas, expected) in [(CGFloat(240), CGFloat(216)), (300, 276), (384, 360), (900, 360)] {
            let hud = DestinationHUDView(verb: .copy, slots: [nil, nil, nil], last: nil)
            _ = host(hud, width: canvas, height: 500)
            let panel = hud.panelFrameForTesting
            XCTAssertEqual(panel.width, expected, accuracy: 0.5, "canvas \(canvas)")
            XCTAssertGreaterThanOrEqual(panel.minX, 11.5)
            XCTAssertLessThanOrEqual(panel.maxX, canvas - 11.5)
        }
    }
}

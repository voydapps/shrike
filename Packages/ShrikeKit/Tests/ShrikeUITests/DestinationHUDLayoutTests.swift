//
//  DestinationHUDLayoutTests.swift
//  ShrikeUITests
//
//  The Copy / Move HUD stays inside the window's contentLayoutRect
//  (never under the title bar or toolbar), and keeps its 20 %-above-centre
//  spot when there is room.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class DestinationHUDLayoutTests: XCTestCase {

    private func host(height: CGFloat) -> (NSWindow, DestinationHUDView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: height),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let hud = DestinationHUDView(verb: .move, slots: Array(repeating: nil, count: 9), last: nil)
        hud.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hud.topAnchor.constraint(equalTo: content.topAnchor),
            hud.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return (window, hud)
    }

    func testShortWindowKeepsTheHUDInsideTheContentLayoutRect() {
        let (tall, tallHUD) = host(height: 900)
        defer { tall.close() }
        let panelHeight = tallHUD.panelFrameInWindowForTesting.height
        XCTAssertGreaterThan(panelHeight, 100)
        // Room to spare: 20 % above centre, as before.
        let layout = tall.contentLayoutRect
        let frame = tallHUD.panelFrameInWindowForTesting
        XCTAssertEqual(frame.midY, tall.contentView!.bounds.height * 0.7, accuracy: 1)
        XCTAssertTrue(layout.contains(frame))

        // Just enough room: the whole panel inside the layout rect.
        let titlebar = tall.frame.height - layout.height
        let (short, shortHUD) = host(height: panelHeight + 2 * DestinationHUDView.margin + titlebar + 20)
        defer { short.close() }
        let shortLayout = short.contentLayoutRect
        let shortFrame = shortHUD.panelFrameInWindowForTesting
        XCTAssertLessThanOrEqual(shortFrame.maxY, shortLayout.maxY - DestinationHUDView.margin + 0.5,
                                 "the top is never under the title bar")
        XCTAssertGreaterThanOrEqual(shortFrame.minY, shortLayout.minY + DestinationHUDView.margin - 0.5)

        // Too short to fit: the top (the title) still shows.
        let (tiny, tinyHUD) = host(height: panelHeight * 0.6)
        defer { tiny.close() }
        XCTAssertLessThanOrEqual(tinyHUD.panelFrameInWindowForTesting.maxY,
                                 tiny.contentLayoutRect.maxY - DestinationHUDView.margin + 0.5)
    }
}

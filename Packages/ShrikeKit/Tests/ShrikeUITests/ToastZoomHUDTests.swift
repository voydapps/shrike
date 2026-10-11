//
//  ToastZoomHUDTests.swift
//  ShrikeUITests
//
//  UX-02 check P3-3: a toast and the zoom HUD both live at the top centre
//  (spec 24 §1.5). They must never intersect, whatever the safe area is.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class ToastZoomHUDTests: XCTestCase {

    private func makeContent(_ mode: ViewerContentView.WindowMode) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func assertApart(_ content: ViewerContentView, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        content.zoomBadgeForTesting.alphaValue = 1
        content.toastHost.show("All panels unpinned.")
        content.toastHost.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        let badge = content.zoomBadgeForTesting.frame
        let toast = content.toastHost.frame
        XCTAssertGreaterThan(badge.height, 0, label, file: file, line: line)
        XCTAssertGreaterThan(toast.height, 0, label, file: file, line: line)
        XCTAssertFalse(badge.intersects(toast), "\(label): badge \(badge) vs toast \(toast)", file: file, line: line)
        // Same column, toast under the badge (view is not flipped: y grows up).
        XCTAssertLessThanOrEqual(toast.maxY, badge.minY, label, file: file, line: line)
    }

    func testToastAndZoomHUDDoNotIntersectInWindowAndFullScreen() {
        assertApart(makeContent(.windowed), "windowed")
        assertApart(makeContent(.fullscreen), "full screen")
    }

    func testToastStaysClearEvenWhenTheSafeAreaIsDeep() {
        // A deep safe area (titlebar + unified toolbar) pushes the HUD down
        // to where the toast's own offset (120) would have met it: here the
        // HUD ends 130 pt from the top.
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            badge.topAnchor.constraint(equalTo: container.topAnchor, constant: 100),
            badge.widthAnchor.constraint(equalToConstant: 96),
            badge.heightAnchor.constraint(equalToConstant: 30),
        ])
        let toast = ToastHostView(placement: .viewer)
        toast.install(in: container)
        toast.keepBelow(badge, gap: 12)
        toast.show("All panels unpinned.")
        toast.alphaValue = 1
        container.layoutSubtreeIfNeeded()
        XCTAssertFalse(badge.frame.intersects(toast.frame), "badge \(badge.frame) vs toast \(toast.frame)")
        XCTAssertLessThanOrEqual(toast.frame.maxY, badge.frame.minY - 12 + 0.5)
    }
}

//
//  ViewerLazyChromeTests.swift
//  ShrikeUITests
//
//  The viewer's content view builds less at launch.
//  The full-screen (HUD) inspector's SwiftUI host is built the first
//  time the panel shows, not in `init`. A timing harness prints the
//  content view build time (no GUI launch).
//

import AppKit
import XCTest
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerLazyChromeTests: XCTestCase {

    func testTheFullScreenInspectorBuildsItsContentOnFirstShow() {
        let content = ViewerContentView(services: .makeDefault())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = content
        content.animatesPanelFades = false
        content.layoutSubtreeIfNeeded()
        let inspector = content.inspectorForTesting
        XCTAssertFalse(inspector.hostingViewBuiltForTesting, "not built by init or the windowed layout")
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(inspector.hostingViewBuiltForTesting, "not built by entering full screen")
        content.evaluateZonesForTesting(at: NSPoint(x: 1435, y: 450))
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
        XCTAssertTrue(inspector.hostingViewBuiltForTesting, "built when the panel first shows")
        content.layoutSubtreeIfNeeded()
        let host = inspector.contentViewForTesting
        XCTAssertEqual(host.frame.maxY, inspector.bounds.maxY - InspectorPanel.headerHeight, accuracy: 0.5,
                       "under the header row")
        XCTAssertEqual(host.frame.width, inspector.bounds.width, accuracy: 0.5)
    }

    /// Median wall time to build a `ViewerContentView` and lay it out
    /// in a 1200 x 800 frame, over 25 builds after 3 warm-ups. Printed
    /// as "BUILD content=<ms> inspector=<ms>".
    func testContentViewBuildTime() {
        let services = ShrikeServices.makeDefault()
        func time(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        func median(_ runs: Int, _ body: () -> Void) -> Double {
            for _ in 0..<3 { body() }
            let samples = (0..<runs).map { _ in time(body) }.sorted()
            return samples[samples.count / 2]
        }
        let content = median(25) {
            let view = ViewerContentView(services: services)
            view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
            view.layoutSubtreeIfNeeded()
        }
        let inspector = median(25) { _ = InspectorPanel() }
        print(String(format: "BUILD content=%.2f inspector=%.2f", content, inspector))
        XCTAssertGreaterThan(content, 0)
    }
}

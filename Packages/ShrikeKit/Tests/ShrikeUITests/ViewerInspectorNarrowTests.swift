//
//  ViewerInspectorNarrowTests.swift
//  ShrikeUITests
//
//  In a narrow window the viewer inspector was clipped on the
//  left ("lder", "mensions"): its content was 280 pt wide (a fixed
//  248 pt histogram + padding) in a narrower column. The content now
//  fits 240 pt, the column never shrinks below 240 pt, and the canvas
//  keeps 240 pt beside it.
//

import AppKit
import SwiftUI
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerInspectorNarrowTests: XCTestCase {

    private func model() -> InspectorViewModel {
        let model = InspectorViewModel()
        model.url = URL(fileURLWithPath: "/tmp/shrike-narrow/P1250300.JPG")
        model.indexSummary = "4 of 19"
        var facts = InspectorFacts()
        facts.file = [
            InspectorRow("Folder", "ux-fin"), InspectorRow("Size", "10 MB"),
            InspectorRow("Dimensions", "3456 × 5184 (17.9 MP)"), InspectorRow("Type", "JPEG"),
            InspectorRow("Colour profile", "sRGB IEC61966-2.1"),
        ]
        facts.capture = [
            InspectorRow("Date taken", "25 Jan 2026 at 06:41:11"),
            InspectorRow("Camera", "OLYMPUS CORPORATION E-P7"),
            InspectorRow("Lens", "OM 25mm F1.8 II"), InspectorRow("White balance", "Auto"),
        ]
        model.facts = facts
        return model
    }

    /// The SwiftUI content asks for no more than the narrowest column.
    func testContentFitsTheNarrowestColumn() {
        let host = NSHostingController(rootView: InspectorContent(model: model()))
        let width = ViewerSplitController.inspectorMinimumWidth
        let size = host.sizeThatFits(in: CGSize(width: width, height: 2000))
        XCTAssertLessThanOrEqual(size.width, width + 0.5, "content wider than the 240 pt column")
    }

    /// A 480 and a 640 pt window: the inspector column is at least 240 pt
    /// and its content lies inside it (nothing drawn left of the column).
    func testInspectorStaysInsideItsColumnInANarrowWindow() throws {
        for windowWidth in [CGFloat(480), 640] {
            let canvas = NSView()
            let split = ViewerSplitController(canvas: canvas, model: model())
            _ = split.view
            split.splitView.autosaveName = nil
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 520),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = split
            window.setContentSize(NSSize(width: windowWidth, height: 520))
            split.inspectorController.materialize()
            split.inspectorItem.isCollapsed = false
            window.contentView?.layoutSubtreeIfNeeded()
            defer { window.close() }

            let column = split.inspectorController.view
            let host = try XCTUnwrap(split.inspectorController.contentView)
            XCTAssertGreaterThanOrEqual(column.frame.width, ViewerSplitController.inspectorMinimumWidth - 0.5,
                                        "\(windowWidth): column narrower than 240 pt")
            XCTAssertGreaterThanOrEqual(canvas.frame.width, ViewerSplitController.canvasMinimumWidth - 0.5,
                                        "\(windowWidth): canvas squeezed")
            XCTAssertEqual(host.frame.minX, 0, accuracy: 0.5, "\(windowWidth): content starts at the column edge")
            XCTAssertEqual(host.frame.width, column.frame.width, accuracy: 0.5,
                           "\(windowWidth): content as wide as the column")
            XCTAssertLessThanOrEqual(column.frame.maxX, window.contentView!.bounds.width + 0.5)
        }
    }
}

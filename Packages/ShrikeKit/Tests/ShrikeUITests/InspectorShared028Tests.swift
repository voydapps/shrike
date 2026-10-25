//
//  InspectorShared028Tests.swift
//  ShrikeUITests
//
//  Spec 27 V1 (one inspector design, readable headers) and V6 (narrow forms).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class InspectorShared028Tests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI")
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: V1

    func testHeaderAndRowColoursPassContrast() {
        // Headers: primary label colour, on the Browser pane (follows the system) and the HUD (dark).
        for appearance in [Contrast.dark, Contrast.light] {
            XCTAssertGreaterThanOrEqual(
                Contrast.ratio(.labelColor, on: InspectorLayout.browserPaneBackground, in: appearance), 4.5, "\(appearance.name)")
            XCTAssertGreaterThanOrEqual(
                Contrast.ratio(ShrikeAccent.linkText, on: InspectorLayout.browserPaneBackground, in: appearance), 4.5, "link \(appearance.name)")
            XCTAssertGreaterThanOrEqual(
                Contrast.ratio(InspectorLayout.rowLabelColor, on: InspectorLayout.browserPaneBackground, in: appearance), 4.5, "row label \(appearance.name)")
        }
        // Row labels (secondary) on the dark inspector surface (spec: about 5.2:1).
        XCTAssertGreaterThanOrEqual(
            Contrast.ratio(.secondaryLabelColor, on: NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 40 / 255, alpha: 1),
                           in: Contrast.dark), 4.5)
    }

    func testBothPanelsUseTheSharedViews() throws {
        for file in ["BrowserWindow/InspectorPaneView.swift", "ViewerWindow/Panels/InspectorPanel.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("InspectorSectionHeader("), "\(file) uses the shared header")
            XCTAssertTrue(text.contains("InspectorRowView("), "\(file) uses the shared row")
            XCTAssertFalse(text.contains(".tertiary"), "\(file): no faint header colour")
        }
    }

    func testBothInspectorsLabelRatingAndFlagTheSame() throws {
        for file in ["BrowserWindow/InspectorPaneView.swift", "ViewerWindow/Panels/InspectorPanel.swift"] {
            let text = try source(file)
            XCTAssertTrue(text.contains("\"Rating & Flag\""), "\(file): heading is Rating & Flag")
            XCTAssertTrue(text.contains("\"Flagged\""), "\(file): flag control is Flagged")
            XCTAssertFalse(text.contains("\"Culling\""), "\(file): no Culling heading")
            XCTAssertFalse(text.contains("Toggle(\"Flag\""), "\(file): no bare Flag toggle")
        }
    }

    func testBrowserInspectorHasNoTextSmallerThan12() throws {
        let text = try source("BrowserWindow/InspectorPaneView.swift")
        XCTAssertFalse(text.contains("size: 11"))
        XCTAssertFalse(text.contains(".caption"))
        XCTAssertEqual(InspectorLayout.rowFontSize, 12)
        XCTAssertEqual(InspectorLayout.headerFontSize, 13)
        XCTAssertEqual(InspectorLayout.rowGap, 4)
        XCTAssertEqual(InspectorLayout.sectionGap, 16)
    }

    // MARK: V6

    func testNarrowFormsDropMegapixelsAndSeconds() {
        XCTAssertTrue(InspectorRows.isCompact(width: 260))
        XCTAssertFalse(InspectorRows.isCompact(width: 300))
        XCTAssertEqual(InspectorRows.compactValue(label: "Dimensions", value: "5184 × 3456 (17.9 MP)"), "5184 × 3456")
        XCTAssertEqual(InspectorRows.compactValue(label: "Date taken", value: "23 Aug 2021 at 10:04:39"),
                       "23 Aug 2021, 10:04")
        XCTAssertEqual(InspectorRows.compactValue(label: "Colour profile", value: "sRGB IEC61966-2.1"),
                       "sRGB IEC61966-2.1", "wraps instead")
        XCTAssertEqual(InspectorRows.compactValue(label: "Camera", value: "Canon EOS R5"), "Canon EOS R5")
    }

    func testNoValueTruncatesInTheMiddle() throws {
        for file in ["BrowserWindow/InspectorPaneView.swift", "ViewerWindow/Panels/InspectorPanel.swift",
                     "Shared/InspectorRows.swift"] {
            let text = try source(file)
            XCTAssertFalse(text.contains("byTruncatingMiddle"), file)
            // The title (and values) tail-truncate; Browser preview names keep a reserved two lines.
            if file != "BrowserWindow/InspectorPaneView.swift" {
                XCTAssertFalse(text.contains(".truncationMode(.middle)"), file)
            }
        }
        XCTAssertEqual(InspectorLayout.valueLineLimit, 2)
    }
}

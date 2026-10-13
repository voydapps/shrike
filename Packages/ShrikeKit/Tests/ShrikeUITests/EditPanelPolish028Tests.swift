//
//  EditPanelPolish028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-8: one reset pattern, a clean Resize panel, one number rule.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class EditPanelPolish028Tests: XCTestCase {

    private func allViews(in root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(allViews(in:))
    }

    func testValueTextTable() {
        XCTAssertEqual(EditValueText.text(value: 0, step: 0.01, signed: true), "+0.00")
        XCTAssertEqual(EditValueText.text(value: -0.254, step: 0.01, signed: true), "-0.25")
        XCTAssertEqual(EditValueText.text(value: 12.5, step: 0.5, unit: "°"), "12.5°")
        XCTAssertEqual(EditValueText.text(value: 0, step: 1), "0")
        XCTAssertEqual(EditValueText.text(value: 0, step: 1, signed: true), "+0")
        XCTAssertEqual(EditValueText.text(value: 0, step: 0.5, unit: "°"), "0°")
        XCTAssertEqual(EditValueText.text(value: 12, step: 1, signed: true, unit: "°"), "+12°")
        XCTAssertEqual(EditValueText.decimals(forStep: 0.01), 2)
        XCTAssertEqual(EditValueText.decimals(forStep: 0.5), 1)
        XCTAssertEqual(EditValueText.decimals(forStep: 1), 0)
    }

    func testResetButtonTitlesAreNamedForTheTool() {
        let titles = [
            CropPanel()._resetButton.title,
            RotatePanel()._resetButton.title,
            ResizePanel()._resetButton.title,
            ColorAdjustPanel()._resetAllButton.title,
            LevelsPanel()._resetButton.title,
        ]
        XCTAssertEqual(titles, ["Reset Crop", "Reset Rotation", "Reset Resize", "Reset Color", "Reset Levels"])
    }

    /// One pattern: the reset button spans the panel's full content width in all five panels.
    func testResetButtonsSpanTheFullPanelWidth() {
        func check(_ view: NSView, _ button: NSButton, _ name: String) {
            let host = EditParameterPanel()
            host.install(view)
            host.frame = NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900)
            host.layoutSubtreeIfNeeded()
            let r = button.convert(button.bounds, to: host)
            XCTAssertGreaterThanOrEqual(r.width, EditParameterPanel.panelWidth - 2 * 16 - 1, "\(name): \(r)")
            XCTAssertEqual(r.minX, 16, accuracy: 1, name)
        }
        let crop = CropPanel(); check(crop, crop._resetButton, "Crop")
        let rotate = RotatePanel(); check(rotate, rotate._resetButton, "Rotate")
        let resize = ResizePanel(); check(resize, resize._resetButton, "Resize")
        let color = ColorAdjustPanel(); check(color, color._resetAllButton, "Color")
        let levels = LevelsPanel(); check(levels, levels._resetButton, "Levels")
    }

    func testResizePanelHasNoOrAndNoBareScaleLabel() {
        let panel = ResizePanel()
        let labels = allViews(in: panel).compactMap { ($0 as? NSTextField)?.isEditable == false ? ($0 as? NSTextField)?.stringValue : nil }
        XCTAssertFalse(labels.contains("Or"))
        XCTAssertTrue(labels.contains("Width"))
        XCTAssertTrue(labels.contains("Height"))
        XCTAssertTrue(labels.contains("Scale"))
        // The "%" lives inside the field, not as a sibling row label.
        let percentField = allViews(in: panel).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Resize percent" }
        XCTAssertNotNil(percentField)
        let siblings = percentField?.superview?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        XCTAssertFalse(siblings.contains("%"))
    }

    func testResizePreviewStrings() {
        let source = CGSize(width: 5184, height: 3456)
        XCTAssertEqual(ResizePanel.previewText(source: source, width: 2592, height: 1728), "New size: 2592 × 1728 px")
        XCTAssertEqual(ResizePanel.previewText(source: source, width: 5184, height: 3456), "Same size as the original.")
    }
}

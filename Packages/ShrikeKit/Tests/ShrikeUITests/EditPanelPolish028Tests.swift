//
//  EditPanelPolish028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-8: one reset pattern, a clean Resize panel, one number rule.
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

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
        // The decorative unit is a sibling outside the native field.
        let percentField = allViews(in: panel).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Resize percent" }
        XCTAssertNotNil(percentField)
        let siblings = percentField?.superview?.subviews.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
        XCTAssertTrue(siblings.contains("%"))
        XCTAssertFalse(percentField?.subviews.contains { ($0 as? NSTextField)?.stringValue == "%" } ?? true)
    }

    func testResizePreviewStrings() {
        let source = CGSize(width: 5184, height: 3456)
        XCTAssertEqual(ResizePanel.previewText(source: source, width: 2592, height: 1728), "New size: 2592 × 1728 px")
        XCTAssertEqual(ResizePanel.previewText(source: source, width: 5184, height: 3456), "Same size as the current photo.")
        XCTAssertEqual(ResizePanel.previewText(source: source, width: 0, height: 3456), "Same size as the current photo.")
    }
    func testResizePercentTextDoesNotShareSpaceWithItsSuffixAtEitherChromeSize() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        for larger in [false, true] {
            Prefs.largerChrome = larger
            let panel = ResizePanel()
            let host = EditParameterPanel()
            host.install(panel)
            host.frame = NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900)
            host.layoutSubtreeIfNeeded()
            let field = panel._percentField
            let cell = try XCTUnwrap(field.cell as? NSTextFieldCell)
            let suffix = try XCTUnwrap(allViews(in: panel).compactMap { $0 as? NSTextField }.first { $0.stringValue == "%" })
            let suffixRect = field.convert(suffix.bounds, from: suffix)
            XCTAssertFalse(suffix.isAccessibilityElement())
            XCTAssertFalse(suffix.isEditable)
            XCTAssertFalse(suffix.isSelectable)
            XCTAssertFalse(suffix.acceptsFirstResponder)
            XCTAssertTrue(suffix.superview === field.superview)
            let nativeGap = suffix.alignmentRect(forFrame: suffix.frame).minX
                - field.alignmentRect(forFrame: field.frame).maxX
            XCTAssertEqual(nativeGap, 8, accuracy: 0.5,
                           "The percent unit has an eight-point native alignment gap")
            XCTAssertGreaterThanOrEqual(suffixRect.minX - field.bounds.maxX, 3,
                                        "The decorative unit frame stays outside the native field")
            print("PERCENT_UNIT large=\(larger) fieldFrame=\(field.frame) unitFrame=\(suffix.frame) unitInField=\(suffixRect) alignmentGap=\(nativeGap)")
            for value in ["100", "100.0", "999999999999999"] {
                field.stringValue = value
                let text = cell.drawingRect(forBounds: field.bounds)
                XCTAssertLessThanOrEqual(text.maxX + 3, suffixRect.minX,
                                         "Numeric text and the percent glyph need separate space")
                XCTAssertEqual(field.stringValue, value, "Layout must not rewrite the numeric value")
                if value.count <= 5 {
                    let font = try XCTUnwrap(field.font)
                    let measured = (value as NSString).size(withAttributes: [.font: font]).width
                    XCTAssertGreaterThanOrEqual(text.width, measured + 1, "Common percent values fit without scrolling")
                }
            }
            let narrow = cell.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 32, height: field.bounds.height))
            XCTAssertGreaterThanOrEqual(narrow.width, 0, "Narrow bounds must not create a negative text area")
            XCTAssertLessThanOrEqual(narrow.maxX, 32)
            XCTAssertGreaterThanOrEqual(suffixRect.minX, field.bounds.maxX + 3,
                                        "The separate unit never consumes numeric field space")
        }
    }

    func testResizePercentReservationTracksLiveChromeFontChanges() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = false
        let panel = ResizePanel()
        let host = EditParameterPanel()
        host.install(panel)
        host.frame = NSRect(x: 0, y: 0, width: EditParameterPanel.panelWidth, height: 900)
        let observation = ChromeTextObservation(root: host)
        host.layoutSubtreeIfNeeded()
        let field = panel._percentField
        let before = try XCTUnwrap(field.font).pointSize
        Prefs.largerChrome = true
        NotificationCenter.default.post(name: .shrikeChromePreferencesChanged, object: nil)
        host.layoutSubtreeIfNeeded()
        let suffix = try XCTUnwrap(allViews(in: panel).compactMap { $0 as? NSTextField }.first { $0.stringValue == "%" })
        let suffixRect = field.convert(suffix.bounds, from: suffix)
        let text = try XCTUnwrap(field.cell).drawingRect(forBounds: field.bounds)
        XCTAssertEqual(field.font?.pointSize, before + 2)
        XCTAssertLessThanOrEqual(text.maxX + 3, suffixRect.minX)
        let common = ("100.0" as NSString).size(withAttributes: [.font: try XCTUnwrap(field.font)]).width
        XCTAssertGreaterThanOrEqual(text.width, common + 1)
        withExtendedLifetime(observation) {}
    }

}

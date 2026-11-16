//
//  EditModeL12Tests.swift
//  ShrikeUITests
//
//  Spec 28 §11 (L-12): the text-only Choose a Tool card, Apply Crop only with a pending
//  crop and Reset as a quiet link, slider values, and the histogram rule in edit mode.
//

import AppKit
import XCTest
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class EditModeL12Tests: XCTestCase {

    private func allViews(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap(allViews(in:)) }

    func testChooseToolCardIsTextOnly() {
        let card = ChooseToolPanel(inFullScreen: false)
        XCTAssertTrue(allViews(in: card).compactMap { $0 as? NSButton }.isEmpty, "no chips")
        XCTAssertEqual(card.titleLabel.stringValue, "Choose a Tool")
        XCTAssertEqual(card.titleLabel.font?.pointSize, 15)
        XCTAssertEqual(card.bodyLabel.stringValue, "Pick Crop, Rotate, Resize, Color or Levels in the bar at the top.")
        XCTAssertEqual(card.ruleLabel.stringValue, "Crop and Resize need Apply. Rotate, Color and Levels change the photo at once.")
        XCTAssertEqual(ChooseToolPanel.body(inFullScreen: true), "Pick Crop, Rotate, Resize, Color or Levels in the bar at the bottom.")
    }

    func testApplyCropOnlyWithAPendingCropAndResetIsAQuietLink() {
        let crop = CropPanel()
        XCTAssertFalse(crop._applyButton.isEnabled)
        crop.hasPendingChange = true
        XCTAssertTrue(crop._applyButton.isEnabled)
        crop.hasPendingChange = false
        XCTAssertFalse(crop._applyButton.isEnabled)
        XCTAssertEqual(crop._applyButton.title, "Apply Crop")
        XCTAssertFalse(crop._resetButton.isBordered)
        XCTAssertEqual(crop._resetButton.title, "Reset Crop")
        let resize = ResizePanel()
        XCTAssertFalse(resize._resetButton.isBordered)
        XCTAssertEqual(resize._resetButton.title, "Reset Resize")
        XCTAssertTrue(RotatePanel()._resetButton.isBordered, "the other three keep the bordered Reset")
    }

    func testSignedValues() {
        XCTAssertEqual(EditValueText.text(value: 0, step: 0.01, signed: true), "0")
        XCTAssertEqual(EditValueText.text(value: 0.004, step: 0.01, signed: true), "0", "rounds to rest")
        XCTAssertEqual(EditValueText.text(value: -0.004, step: 0.01, signed: true), "0", "never −0.00")
        XCTAssertEqual(EditValueText.text(value: 0.35, step: 0.01, signed: true), "+0.35")
        XCTAssertEqual(EditValueText.text(value: -0.2, step: 0.01, signed: true), "\u{2212}0.20")
        XCTAssertEqual(EditValueText.spoken(value: 0, step: 0.01), "0")
        XCTAssertEqual(EditValueText.spoken(value: 0.35, step: 0.01), "plus 0.35")
        XCTAssertEqual(EditValueText.spoken(value: -0.2, step: 0.01), "minus 0.20")
    }

    func testHistogramInEveryEditStateButLevels() {
        for tool: EditTool? in [nil, .crop, .rotate, .resize, .color] {
            XCTAssertTrue(ViewerContentView.editHistogramShows(tool: tool, freeHeight: 300), "\(String(describing: tool))")
        }
        XCTAssertFalse(ViewerContentView.editHistogramShows(tool: .levels, freeHeight: 300))
        XCTAssertFalse(ViewerContentView.editHistogramShows(tool: .crop, freeHeight: 100), "no room")
    }

    func testQuietResetLinkIs12PointSecondaryAndUnderlinesOnHover() throws {
        let saved = Prefs.largerChrome
        defer { Prefs.largerChrome = saved }
        Prefs.largerChrome = false
        for link in [CropPanel()._resetButton, ResizePanel()._resetButton] {
            let quiet = try XCTUnwrap(link as? EditQuietLinkButton)
            XCTAssertEqual(quiet.font?.pointSize, 12)
            XCTAssertEqual(quiet.contentTintColor, .secondaryLabelColor)
            XCTAssertEqual(quiet.alignment, .center)
            quiet.setHoveredForTesting(true)
            let hovered = quiet.attributedTitle
            XCTAssertEqual(hovered.string, quiet.title)
            XCTAssertEqual(hovered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int,
                           NSUnderlineStyle.single.rawValue)
            XCTAssertEqual((hovered.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 12)
            quiet.setHoveredForTesting(false)
            XCTAssertNil(quiet.attributedTitle.attribute(.underlineStyle, at: 0, effectiveRange: nil))
            XCTAssertEqual(quiet.font?.pointSize, 12, "the plain title keeps the scalable font")
        }
    }
}

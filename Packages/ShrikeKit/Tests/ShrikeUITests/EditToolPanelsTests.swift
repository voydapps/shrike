//
//  EditToolPanelsTests.swift
//  ShrikeUITests
//
//  Pure-math / pure-logic unit tests for the four edit-mode tool panels.
//  These are the parts of the panels that DON'T require instantiating an
//  NSView: aspect-math, interpolation-popup round-trips, debounce intervals,
//  and params propagation. The AppKit widgets themselves are exercised by
//  higher-level integration tests.
//
//  Covers:
//    - CropPanel.complement(…) pure ratio math for every preset
//    - CropPanel.Aspect.ratio matches the advertised W/H
//    - RotatePanel.idleCommitDelay == 0.500 (coalescer)
//    - ResizePanel.interpolation(forPopupIndex:) ↔ popupIndex(for:) round-trip
//    - ColorAdjustPanel.idleCommitDelay == 0.016 (1 vsync)
//    - ColorAdjustPanel slider events propagate to params + fire onParamsChanged
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeEdit

@MainActor
final class EditToolPanelsTests: XCTestCase {

    // MARK: - CropPanel.complement — pure ratio math

    func testCropComplement_Square_WidthDrivesHeight() {
        let h = CropPanel.complement(ratio: 1.0, edited: 400, editedSide: .width)
        XCTAssertEqual(h, 400)
    }

    func testCropComplement_Square_HeightDrivesWidth() {
        let w = CropPanel.complement(ratio: 1.0, edited: 400, editedSide: .height)
        XCTAssertEqual(w, 400)
    }

    func testCropComplement_ThreeByTwo_WidthDrivesHeight() {
        // 3:2 ratio, W = 300 → H = 200.
        let h = CropPanel.complement(ratio: 3.0 / 2.0,
                                     edited: 300,
                                     editedSide: .width)
        XCTAssertEqual(h, 200)
    }

    func testCropComplement_ThreeByTwo_HeightDrivesWidth() {
        let w = CropPanel.complement(ratio: 3.0 / 2.0,
                                     edited: 200,
                                     editedSide: .height)
        XCTAssertEqual(w, 300)
    }

    func testCropComplement_FourByThree_RoundTrip() {
        // W=800 → H=600; H=600 → W=800.
        let h = CropPanel.complement(ratio: 4.0 / 3.0,
                                     edited: 800,
                                     editedSide: .width)
        XCTAssertEqual(h, 600)
        let w = CropPanel.complement(ratio: 4.0 / 3.0,
                                     edited: 600,
                                     editedSide: .height)
        XCTAssertEqual(w, 800)
    }

    func testCropComplement_SixteenByNine_RoundTrip() {
        let h = CropPanel.complement(ratio: 16.0 / 9.0,
                                     edited: 1920,
                                     editedSide: .width)
        XCTAssertEqual(h, 1080)
        let w = CropPanel.complement(ratio: 16.0 / 9.0,
                                     edited: 1080,
                                     editedSide: .height)
        XCTAssertEqual(w, 1920)
    }

    func testCropComplement_Golden_RoundsReasonably() {
        // Golden ratio ≈ 1.618 — 1000 / 1.618 ≈ 618.
        let h = CropPanel.complement(ratio: 1.6180339887,
                                     edited: 1000,
                                     editedSide: .width)
        XCTAssertEqual(h, 618)
        // 618 * 1.618 ≈ 999.97 → rounds to 1000.
        let w = CropPanel.complement(ratio: 1.6180339887,
                                     edited: 618,
                                     editedSide: .height)
        XCTAssertEqual(w, 1000)
    }

    func testCropComplement_ZeroRatio_ReturnsInput() {
        // Defensive — nonsense ratio returns the input unchanged rather
        // than div-by-zero.
        let out = CropPanel.complement(ratio: 0,
                                       edited: 400,
                                       editedSide: .width)
        XCTAssertEqual(out, 400)
    }

    func testCropComplement_NeverReturnsZero() {
        // Very small edited value against large ratio should still
        // clamp to at least 1.
        let out = CropPanel.complement(ratio: 1.0 / 1000.0,
                                       edited: 1,
                                       editedSide: .height)
        XCTAssertGreaterThanOrEqual(out, 1)
    }

    // MARK: - CropPanel.Aspect ratios

    func testCropAspect_RatiosAreAsAdvertised() {
        XCTAssertNil(CropPanel.Aspect.freeform.ratio)
        XCTAssertNil(CropPanel.Aspect.original.ratio,
                     "Original is panel-level; ratio resolved against source image")
        XCTAssertEqual(CropPanel.Aspect.square.ratio, 1.0)
        XCTAssertEqual(CropPanel.Aspect.threeByTwo.ratio, 1.5)
        XCTAssertEqual(CropPanel.Aspect.fourByThree.ratio!, 4.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(CropPanel.Aspect.sixteenByNine.ratio!, 16.0 / 9.0, accuracy: 1e-12)
        XCTAssertEqual(CropPanel.Aspect.golden.ratio!, 1.6180339887, accuracy: 1e-9)
    }

    func testCropAspect_AllCasesHaveTitle() {
        for preset in CropPanel.Aspect.allCases {
            XCTAssertFalse(preset.title.isEmpty,
                           "\(preset) missing a title — the popup would render empty")
        }
    }

    // MARK: - RotatePanel idle debounce

    func testRotatePanel_IdleCommitDelayMatchesSpec() {
        // Coalescer: rotate slider flushes after 500 ms of idle.
        XCTAssertEqual(RotatePanel.idleCommitDelay, 0.500, accuracy: 1e-6)
    }

    // MARK: - ResizePanel interpolation popup round-trip

    func testResizeInterpolation_RoundTripsForAllCases() {
        let all: [Interpolation] = [.lanczos, .bicubic, .bilinear, .nearest]
        for interp in all {
            let idx = ResizePanel.popupIndex(for: interp)
            let round = ResizePanel.interpolation(forPopupIndex: idx)
            XCTAssertEqual(round, interp,
                           "Round-trip broke for \(interp) at index \(idx)")
        }
    }

    func testResizeInterpolation_LanczosIsIndexZero() {
        // Declares Lanczos as the default — it must be the
        // first popup entry so popup selection starts there naturally.
        XCTAssertEqual(ResizePanel.popupIndex(for: .lanczos), 0)
        XCTAssertEqual(ResizePanel.interpolation(forPopupIndex: 0), .lanczos)
    }

    func testResizeInterpolation_OutOfRangeIndexFallsBackToLanczos() {
        XCTAssertEqual(ResizePanel.interpolation(forPopupIndex: -1), .lanczos)
        XCTAssertEqual(ResizePanel.interpolation(forPopupIndex: 99), .lanczos)
    }

    // MARK: - ColorAdjustPanel debounce

    func testColorAdjustPanel_IdleCommitDelayMatchesSpec() {
        // Color sliders use ~1 vsync debounce so the live
        // preview can actually redraw on slow moves.
        XCTAssertEqual(ColorAdjustPanel.idleCommitDelay, 0.016, accuracy: 1e-6)
    }

    // MARK: - ColorAdjustPanel slider → params propagation

    func testColorAdjustPanel_BrightnessSliderUpdatesParams() {
        let panel = ColorAdjustPanel()

        var drafts: [ColorAdjustParams] = []
        panel.onParamsChanged = { drafts.append($0) }

        panel._brightnessSlider.doubleValue = 0.5
        panel._brightnessSlider.sendAction(
            panel._brightnessSlider.action!,
            to: panel._brightnessSlider.target!
        )

        XCTAssertEqual(panel.params.brightness, 0.5, accuracy: 1e-9)
        XCTAssertEqual(panel.params.contrast, 0.0)
        XCTAssertEqual(panel.params.saturation, 0.0)
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts.first?.brightness ?? -999, 0.5, accuracy: 1e-9)
    }

    func testColorAdjustPanel_SetParamsSyncsSliders() {
        let panel = ColorAdjustPanel()
        let incoming = ColorAdjustParams(brightness: 0.2,
                                         contrast: -0.4,
                                         saturation: 0.8)
        panel.setParams(incoming)

        XCTAssertEqual(panel.params, incoming)
        XCTAssertEqual(panel._brightnessSlider.doubleValue, 0.2, accuracy: 1e-9)
        XCTAssertEqual(panel._contrastSlider.doubleValue, -0.4, accuracy: 1e-9)
        XCTAssertEqual(panel._saturationSlider.doubleValue, 0.8, accuracy: 1e-9)
    }

    func testColorAdjustPanel_ApplyFiresCommittedThenApply() {
        let panel = ColorAdjustPanel()
        panel.setParams(ColorAdjustParams(brightness: 0.1,
                                          contrast: 0.2,
                                          saturation: -0.3))

        var committed: [ColorAdjustParams] = []
        var applyCount = 0
        panel.onParamsCommitted = { committed.append($0) }
        panel.onApply = { applyCount += 1 }

        panel._applyButton.sendAction(
            panel._applyButton.action!,
            to: panel._applyButton.target!
        )

        XCTAssertEqual(committed.count, 1,
                       "Apply must flush one committed-params event")
        XCTAssertEqual(committed.first?.brightness ?? -999, 0.1, accuracy: 1e-9)
        XCTAssertEqual(applyCount, 1)
    }

    func testColorAdjustPanel_ResetAllZerosOutAndCommitsIdentity() {
        let panel = ColorAdjustPanel()
        panel.setParams(ColorAdjustParams(brightness: 0.5,
                                          contrast: 0.5,
                                          saturation: 0.5))

        var committed: [ColorAdjustParams] = []
        var resetCount = 0
        panel.onParamsCommitted = { committed.append($0) }
        panel.onResetAll = { resetCount += 1 }

        panel._resetAllButton.sendAction(
            panel._resetAllButton.action!,
            to: panel._resetAllButton.target!
        )

        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(panel.params, .identity)
        XCTAssertTrue(panel.params.isIdentity)
        XCTAssertEqual(committed.count, 1,
                       "Reset-all must flush an identity commit so the recipe updates")
        XCTAssertTrue(committed.first?.isIdentity ?? false)
    }

    // MARK: - RotatePanel quick buttons

    func testRotatePanel_QuickCWIsPositiveOne() {
        let panel = RotatePanel()
        var quarters: [Int] = []
        panel.onQuickRotate = { quarters.append($0) }

        panel._quickCW.sendAction(
            panel._quickCW.action!,
            to: panel._quickCW.target!
        )

        XCTAssertEqual(quarters, [1])
    }

    func testRotatePanel_QuickCCWIsNegativeOne() {
        let panel = RotatePanel()
        var quarters: [Int] = []
        panel.onQuickRotate = { quarters.append($0) }

        panel._quickCCW.sendAction(
            panel._quickCCW.action!,
            to: panel._quickCCW.target!
        )

        XCTAssertEqual(quarters, [-1])
    }

    func testRotatePanel_QuickHalfIsPositiveTwo() {
        let panel = RotatePanel()
        var quarters: [Int] = []
        panel.onQuickRotate = { quarters.append($0) }

        panel._quickHalf.sendAction(
            panel._quickHalf.action!,
            to: panel._quickHalf.target!
        )

        XCTAssertEqual(quarters, [2])
    }

    func testRotatePanel_SetAngleClampsToSpecRange() {
        let panel = RotatePanel()
        panel.setAngle(90)
        XCTAssertEqual(panel.angle, 45, "Angle must clamp to +45°")

        panel.setAngle(-180)
        XCTAssertEqual(panel.angle, -45, "Angle must clamp to −45°")

        panel.setAngle(12.5)
        XCTAssertEqual(panel.angle, 12.5, accuracy: 1e-9)
    }

    // MARK: - ResizePanel currentSpec

    func testResizePanel_CurrentSpecNilWhenFieldsEmpty() {
        let panel = ResizePanel()
        // Default W/H fields are empty — no spec.
        XCTAssertNil(panel.currentSpec())
    }

    func testResizePanel_CurrentSpecReflectsFields() {
        let panel = ResizePanel()
        panel.sourcePixelSize = CGSize(width: 4000, height: 3000)
        // Setting sourcePixelSize auto-populates W/H when blank.
        let spec = panel.currentSpec()
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.width, 4000)
        XCTAssertEqual(spec?.height, 3000)
        XCTAssertEqual(spec?.interpolation, .lanczos)
        XCTAssertTrue(spec?.preventUpscale ?? false,
                      "Don't-upscale defaults to on")
    }
}

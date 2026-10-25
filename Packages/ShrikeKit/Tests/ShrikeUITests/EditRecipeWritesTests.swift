//
//  EditRecipeWritesTests.swift
//  ShrikeUITests
//
//  The crop frame sits on the
//  displayed image, inside `contentLayoutRect`, and re-fits after a 90°
//  rotate with W / H swapped.
//  Slider drags coalesce into one undo step each
//  and never overwrite another op; the panels re-read the recipe.
//  The Hue slider.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class EditRecipeWritesTests: XCTestCase {

    override func setUp() async throws {
        EditToolTransitionModal.responderForTesting = { _ in .keep }
    }
    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
    }

    // MARK: Helpers

    /// Left half red, right half blue.
    private static func splitImage(width: Int = 400, height: Int = 200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    private static func grey(width: Int = 64, height: Int = 48) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// RGBA of the pixel at (x, y), y from the top.
    private static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &out, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return out
    }

    private func controller(image: CGImage, tool: EditTool) -> (EditModeController, () -> CGImage?) {
        let c = EditModeController()
        var last: CGImage?
        c.onPresentImage = { last = $0 }
        c.enter(image: image, url: nil, landOn: tool)
        return (c, { last })
    }

    private func colourPanel(_ c: EditModeController) throws -> ColorAdjustPanel {
        try XCTUnwrap(c._installedToolForTesting as? ColorAdjustPanel)
    }

    /// One slider drag: a few frames, then mouse up.
    private func drag(_ slider: NSSlider, in panel: ColorAdjustPanel, to values: [Double]) {
        for v in values {
            slider.doubleValue = v
            _ = slider.sendAction(slider.action, to: slider.target)
        }
        panel.onEditEnded?(panel.params)
    }

    // MARK:

    private func applyHalfSize(_ c: EditModeController) throws -> ResizePanel {
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel._widthField.stringValue = "200"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        panel.onApply?(try XCTUnwrap(panel.pendingSpec))
        return panel
    }

    func testAppliedResizeUndoDoesNotReapplyOnSwitchOrDone() async throws {
        for (settleHistory, switchTool) in [(true, false), (true, true), (false, false), (false, true)] {
            let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .resize)
            let panel = try applyHalfSize(c)
            await c.settleForTesting()
            c.performUndo()
            if settleHistory {
                await c.settleForTesting()
                XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
                XCTAssertNil(panel.pendingSpec)
                XCTAssertEqual(panel._widthField.integerValue, 400)
                XCTAssertEqual(panel._heightField.integerValue, 300)
            }
            let recipe = try XCTUnwrap(c.recipe)
            var saves = 0, exited = false
            c.onSaveRequested = { saves += 1 }
            c.onExitOutcome = { exited = $0 == .exited }
            if switchTool { c.selectTool(.color); await c.settleForTesting() }
            c.done()
            for _ in 0..<200 where !exited && saves == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(exited)
            XCTAssertEqual(saves, 0, "Undo must not be silently undone when finishing")
            let operations = await recipe.snapshot()
            XCTAssertTrue(operations.isEmpty)
        }
    }

    func testAppliedResizeResetDoesNotReapplyOnSwitchOrDone() async throws {
        for (settleHistory, switchTool) in [(true, false), (true, true), (false, false), (false, true)] {
            let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .resize)
            let panel = try applyHalfSize(c)
            await c.settleForTesting()
            c.revertPendingEdits()
            if settleHistory {
                await c.settleForTesting()
                XCTAssertNil(panel.pendingSpec)
                XCTAssertEqual(panel._widthField.integerValue, 400)
                XCTAssertEqual(panel._heightField.integerValue, 300)
            }
            let recipe = try XCTUnwrap(c.recipe)
            var saves = 0, exited = false
            c.onSaveRequested = { saves += 1 }
            c.onExitOutcome = { exited = $0 == .exited }
            if switchTool { c.selectTool(.color); await c.settleForTesting() }
            c.done()
            for _ in 0..<200 where !exited && saves == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(exited)
            XCTAssertEqual(saves, 0)
            let operations = await recipe.snapshot()
            XCTAssertTrue(operations.isEmpty)
        }
    }

    func testResetDiscardsUnappliedResizeWithoutGeometryChange() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .resize)
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        panel._widthField.stringValue = "200"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        XCTAssertNotNil(panel.pendingSpec)
        c.revertPendingEdits()
        await c.settleForTesting()
        XCTAssertNil(panel.pendingSpec)
        XCTAssertEqual(panel._widthField.integerValue, 400)
        c.selectTool(.color)
        await c.settleForTesting()
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        let operations = await c.recipe!.snapshot()
        XCTAssertTrue(operations.isEmpty)
    }

    func testAppliedResizeRedoRestoresControlsWithoutAddingAnotherResize() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .resize)
        let panel = try applyHalfSize(c)
        await c.settleForTesting()
        c.performUndo()
        await c.settleForTesting()
        c.performRedo()
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        XCTAssertEqual(panel._widthField.integerValue, 200)
        XCTAssertEqual(panel._heightField.integerValue, 150)
        XCTAssertNil(panel.pendingSpec)
        c.selectTool(.color)
        await c.settleForTesting()
        var saves = 0
        c.onSaveRequested = { saves += 1 }
        c.done()
        for _ in 0..<200 where saves == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(saves, 1)
        let operations = await c.recipe!.snapshot()
        XCTAssertEqual(operations.count, 1, "Redo restores one resize, with no implicit duplicate")
    }

    func testDelayedAppliedResizeRenderPreservesNewTypedTarget() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .resize)
        let renderer = EditRenderer()
        var gate: CheckedContinuation<Void, Never>?
        var first = true
        c.renderOverrideForTesting = { recipe, original, hint in
            let snapshot = await recipe.snapshot()
            if first {
                first = false
                await withCheckedContinuation { gate = $0 }
            }
            return await renderer.render(recipe: EditRecipe(operations: snapshot), from: original, qualityHint: hint)
        }
        let panel = try applyHalfSize(c)
        for _ in 0..<200 where gate == nil { try await Task.sleep(for: .milliseconds(10)) }
        panel._widthField.stringValue = "100"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        gate?.resume()
        await c.settleForTesting()
        XCTAssertEqual(panel.pendingSpec?.width, 100)
        XCTAssertEqual(panel.pendingSpec?.height, 75)
        c.selectTool(.color)
        await c.settleForTesting()
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
        let operations = await c.recipe!.snapshot()
        XCTAssertEqual(operations.count, 2)
    }

    func testResetClearsPendingCropAfterColorWithoutReapplyingOnSwitchOrDone() async throws {
        for switchTool in [false, true] {
            let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .color)
            let color = try colourPanel(c)
            drag(color._brightnessSlider, in: color, to: [0.2])
            await c.settleForTesting()
            c.selectTool(.crop)
            await c.settleForTesting()
            c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
            c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
            XCTAssertNotNil(c.pendingCropRect())
            let recipe = try XCTUnwrap(c.recipe)
            c.revertPendingEdits()
            XCTAssertNil(c.pendingCropRect(), "Reset consumes the current unapplied crop synchronously")
            var saves = 0, exited = false
            c.onSaveRequested = { saves += 1 }
            c.onExitOutcome = { exited = $0 == .exited }
            if switchTool { c.selectTool(.color); await c.settleForTesting() }
            c.done()
            for _ in 0..<200 where !exited && saves == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(exited)
            XCTAssertEqual(saves, 0)
            let operations = await recipe.snapshot()
            XCTAssertTrue(operations.isEmpty)
        }
    }

    func testCropDrawnAfterResetBeginsSurvivesItsDelayedRender() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .color)
        let color = try colourPanel(c)
        drag(color._brightnessSlider, in: color, to: [0.2])
        await c.settleForTesting()
        c.selectTool(.crop)
        await c.settleForTesting()
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        let renderer = EditRenderer()
        var gate: CheckedContinuation<Void, Never>?
        var first = true
        c.renderOverrideForTesting = { recipe, original, hint in
            let snapshot = await recipe.snapshot()
            if first {
                first = false
                await withCheckedContinuation { gate = $0 }
            }
            return await renderer.render(recipe: EditRecipe(operations: snapshot), from: original, qualityHint: hint)
        }
        c.revertPendingEdits()
        for _ in 0..<200 where gate == nil { try await Task.sleep(for: .milliseconds(10)) }
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 100, height: 75))
        gate?.resume()
        await c.settleForTesting()
        XCTAssertEqual(c.pendingCropRect()?.width ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(c.pendingCropRect()?.height ?? 0, 0.25, accuracy: 0.0001)
        c.selectTool(.color)
        await c.settleForTesting()
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        let operations = await c.recipe!.snapshot()
        XCTAssertEqual(operations.count, 1)
        guard case .crop = operations.first else { return XCTFail("Only the new crop remains after Reset") }
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 75))
    }

    func testResetCancelsCurrentColorPanelsDeferredCommit() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .color)
        let color = try colourPanel(c)
        color._brightnessSlider.doubleValue = 0.2
        _ = color._brightnessSlider.sendAction(color._brightnessSlider.action, to: color._brightnessSlider.target)
        let pending = try XCTUnwrap(color.pendingCommitForTesting)
        c.revertPendingEdits()
        await pending.value
        await c.settleForTesting()
        let operations = await c.recipe!.snapshot()
        XCTAssertTrue(operations.isEmpty)
    }

    func testToolSwitchAndResetCancelRemovedRotatePanelsDeferredCommit() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .rotate)
        let rotate = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
        rotate._angleSlider.doubleValue = 10
        _ = rotate._angleSlider.sendAction(rotate._angleSlider.action, to: rotate._angleSlider.target)
        let pending = try XCTUnwrap(rotate.pendingCommitForTesting)
        c.selectTool(.crop)
        await c.settleForTesting()
        c.revertPendingEdits()
        await pending.value
        await c.settleForTesting()
        let operations = await c.recipe!.snapshot()
        XCTAssertTrue(operations.isEmpty)
    }

    func testSavePreparationCancelsDeferredRotateCommitWithoutDuplicatingPreview() async throws {
        let autoCrop = Prefs.editAutoCropOnFreeRotate
        defer { Prefs.editAutoCropOnFreeRotate = autoCrop }
        Prefs.editAutoCropOnFreeRotate = false
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .rotate)
        let rotate = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
        rotate._angleSlider.doubleValue = 10
        _ = rotate._angleSlider.sendAction(rotate._angleSlider.action, to: rotate._angleSlider.target)
        let pending = try XCTUnwrap(rotate.pendingCommitForTesting)
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        await pending.value
        await c.settleForTesting()
        let operations = await c.recipe!.snapshot()
        XCTAssertEqual(operations.count, 1)
        guard case .rotate(let angle) = operations.first else { return XCTFail("Latest preview must remain in the recipe") }
        XCTAssertEqual(angle, 10)
    }

    func testImmediateRotateUndoAndRedoDoNotReappendDeferredSliderState() async throws {
        for redo in [false, true] {
            let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .rotate)
            let rotate = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
            rotate._angleSlider.doubleValue = 10
            _ = rotate._angleSlider.sendAction(rotate._angleSlider.action, to: rotate._angleSlider.target)
            let pending = try XCTUnwrap(rotate.pendingCommitForTesting)
            c.performUndo()
            if redo { c.performRedo() }
            await pending.value
            await c.settleForTesting()
            let operations = await c.recipe!.snapshot()
            XCTAssertEqual(operations.count, redo ? 1 : 0)
        }
    }

    func testUnappliedCropSurvivesToolRoundTripAndDone() async throws {
        let (c, output) = controller(image: Self.grey(width: 400, height: 300), tool: .crop)
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        var saves = 0
        c.onSaveRequested = { saves += 1 }
        c.selectTool(.color)
        await c.settleForTesting()
        c.selectTool(.crop)
        await c.settleForTesting()
        c.selectTool(.crop)
        await c.settleForTesting()
        c.done()
        for _ in 0..<200 where saves == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(saves, 1)
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(output()?.width, 200)
        XCTAssertEqual(output()?.height, 150)
        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
        c.performRedo()
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
        c.revertPendingEdits()
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 400, height: 300))
    }

    func testApplyCropThenImmediateSwitchDoesNotApplyTwice() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .crop)
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        (c._installedToolForTesting as? CropPanel)?._applyButton.performClick(nil)
        c.selectTool(.color)
        await c.settleForTesting()
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150))
    }

    func testCropToResizeUsesLogicalSizeBeforeRenderAndPreservesPendingResize() async throws {
        let (c, output) = controller(image: Self.grey(width: 400, height: 300), tool: .crop)
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        c.selectTool(.resize)
        await c.settleForTesting()
        let panel = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        XCTAssertEqual(panel.sourcePixelSize, CGSize(width: 200, height: 150))
        panel._widthField.stringValue = "100"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        c.selectTool(.color)
        await c.settleForTesting()
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2)
        XCTAssertEqual(output()?.width, 100)
        XCTAssertEqual(output()?.height, 75)
    }

    func testDelayedGeometryRenderPreservesNewCropAndLogicalResizeSize() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .crop)
        let renderer = EditRenderer()
        var gate: CheckedContinuation<Void, Never>?
        var first = true
        c.renderOverrideForTesting = { recipe, original, hint in
            let snapshot = await recipe.snapshot()
            if first {
                first = false
                await withCheckedContinuation { gate = $0 }
            }
            return await renderer.render(recipe: EditRecipe(operations: snapshot), from: original, qualityHint: hint)
        }
        c.onPresentImage = { image in
            c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        }
        c.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 300))
        c.selectTool(.resize)
        await c.waitForToolTransitionForTesting()
        let resize = try XCTUnwrap(c._installedToolForTesting as? ResizePanel)
        XCTAssertEqual(resize.sourcePixelSize, CGSize(width: 200, height: 300))
        for _ in 0..<200 where gate == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(gate)
        c.selectTool(.crop)
        c.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 100, height: 150))
        gate?.resume()
        await c.settleForTesting()
        XCTAssertEqual(c.pendingCropRect()?.width ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(c.pendingCropRect()?.height ?? 0, 0.5, accuracy: 0.0001)
        let prepared = await c.prepareForSave()
        XCTAssertTrue(prepared)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 100, height: 150))
        c.onPresentImage = nil
    }

    func testCropThenColourDragKeepsTheCrop() async throws {
        let (c, _) = controller(image: Self.grey(width: 400, height: 300), tool: .crop)
        let overlay = c.cropOverlay
        overlay.imagePixelSize = CGSize(width: 400, height: 300)
        overlay.imageFrame = CGRect(x: 0, y: 0, width: 400, height: 300)
        overlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 150))
        let cropPanel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        cropPanel._applyButton.performClick(nil)
        await c.settleForTesting()

        c.selectTool(.color)
        await c.settleForTesting()
        let panel = try colourPanel(c)
        drag(panel._brightnessSlider, in: panel, to: [0.1, 0.2, 0.3])
        await c.settleForTesting()

        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "crop + one colour step: \(ops)")
        guard case .crop = ops.first else { return XCTFail("the crop was overwritten: \(ops)") }
        guard case .colorAdjust(let p) = ops.last else { return XCTFail() }
        XCTAssertEqual(p.brightness, 0.3, accuracy: 1e-9)
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 150), "the crop still draws")
    }

    func testColourAThenBThenUndoShowsA() async throws {
        let (c, lastImage) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        drag(panel._brightnessSlider, in: panel, to: [0.1, 0.2])
        await c.settleForTesting()
        let imageA = try XCTUnwrap(lastImage())
        drag(panel._brightnessSlider, in: panel, to: [0.4, 0.5])
        await c.settleForTesting()
        let imageB = try XCTUnwrap(lastImage())
        XCTAssertNotEqual(Self.pixel(imageA, 5, 5), Self.pixel(imageB, 5, 5))

        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(panel._brightnessSlider.doubleValue, 0.2, accuracy: 1e-9, "the slider shows a")
        XCTAssertEqual(c.effectiveColor.brightness, 0.2, accuracy: 1e-9)
        let undone = try XCTUnwrap(lastImage())
        XCTAssertEqual(Self.pixel(undone, 5, 5), Self.pixel(imageA, 5, 5), "the pixels show a")

        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(panel._brightnessSlider.doubleValue, 0, accuracy: 1e-9)
        let empty = await c.recipe!.snapshot()
        XCTAssertTrue(empty.isEmpty, "two drags were two undo steps")
    }

    func testFramesOfOneDragAreOneStepAndNoChangeAddsNoStep() async throws {
        let (c, _) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        drag(panel._contrastSlider, in: panel, to: [0.05, 0.1, 0.15, 0.2, 0.25])
        await c.settleForTesting()
        var ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
        // A "drag" that ends where it started changes nothing.
        drag(panel._contrastSlider, in: panel, to: [0.25])
        await c.settleForTesting()
        ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 1)
    }

    func testIdleEndsTheDrag() async throws {
        let (c, _) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        let slider = panel._saturationSlider
        let staleIdle = c.coalesceIdleForTesting
        slider.doubleValue = 0.3
        _ = slider.sendAction(slider.action, to: slider.target)
        // Wait for the controller's own idle event (the real 500 ms timer), not a guess at
        // how long it takes: a fixed sleep failed on a loaded CI machine.
        var idle = c.coalesceIdleForTesting
        for _ in 0..<200 where idle == nil || idle == staleIdle {
            try await Task.sleep(for: .milliseconds(10)); idle = c.coalesceIdleForTesting
        }
        var idleTask = try XCTUnwrap(idle, "the first slider move starts the idle timer")
        // A later write cancels and replaces the timer: follow it until the last one has run out.
        while true {
            await idleTask.value
            try await Task.sleep(for: .milliseconds(20))
            guard let current = c.coalesceIdleForTesting, current != idleTask else { break }
            idleTask = current
        }
        XCTAssertFalse(idleTask.isCancelled, "the timer that ended the drag ran to its end")
        slider.doubleValue = 0.6
        _ = slider.sendAction(slider.action, to: slider.target)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "500 ms idle ends the drag")
    }

    func testFreeRotateReplacesOnlyItsOwnOp() async throws {
        // This existing case asserts the legacy expanded-canvas operation;
        // make its intended checkbox state independent of user preferences.
        let autoCrop = Prefs.editAutoCropOnFreeRotate
        defer { Prefs.editAutoCropOnFreeRotate = autoCrop }
        Prefs.editAutoCropOnFreeRotate = false
        let (c, _) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        drag(panel._brightnessSlider, in: panel, to: [0.3])
        await c.settleForTesting()
        c.selectTool(.rotate)
        await c.settleForTesting()
        let rotate = try XCTUnwrap(c._installedToolForTesting as? RotatePanel)
        rotate.onAngleChanged?(2)
        rotate.onAngleChanged?(4)
        rotate.onAngleCommitted?(5)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "\(ops)")
        guard case .colorAdjust = ops.first, case .rotate(let d) = ops.last else { return XCTFail("\(ops)") }
        XCTAssertEqual(d, 5, accuracy: 1e-9)
    }

    func testCropAfterRotate90LandsWhereTheFrameWasDrawn() async throws {
        let source = Self.splitImage()   // 400 × 200: red left, blue right
        let (c, lastImage) = controller(image: source, tool: .crop)
        c.appendSnapped90(quarters: 1)
        await c.settleForTesting()
        XCTAssertEqual(c.currentPixelSize, CGSize(width: 200, height: 400), "W and H swap")
        let rotated = try XCTUnwrap(lastImage())
        let topColour = Self.pixel(rotated, 100, 50)
        let bottomColour = Self.pixel(rotated, 100, 350)
        XCTAssertNotEqual(topColour, bottomColour)

        // The frame on screen: the rotated image drawn at 100 × 200 pt.
        let overlay = c.cropOverlay
        overlay.imageFrame = CGRect(x: 30, y: 10, width: 100, height: 200)
        overlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 200, height: 200))  // top half
        let crop = try XCTUnwrap(c.pendingCropRect())
        XCTAssertEqual(crop.originY, 0, accuracy: 1e-6)
        XCTAssertEqual(crop.height, 0.5, accuracy: 1e-6)
        let cropPanel = try XCTUnwrap(c._installedToolForTesting as? CropPanel)
        cropPanel._applyButton.performClick(nil)
        await c.settleForTesting()

        let result = try XCTUnwrap(lastImage())
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 200)
        XCTAssertEqual(Self.pixel(result, 100, 100), topColour, "the top half of the rotated image")
        XCTAssertEqual(cropPanel._widthField.integerValue, 200)
        XCTAssertEqual(cropPanel._heightField.integerValue, 200)
    }

    // MARK: Hue

    func testHueSliderWritesHueAndResets() async throws {
        let (c, _) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        XCTAssertEqual(panel._hueSlider.minValue, -180)
        XCTAssertEqual(panel._hueSlider.maxValue, 180)
        XCTAssertEqual(panel._hueSlider.doubleValue, 0)
        drag(panel._hueSlider, in: panel, to: [30, 90])
        await c.settleForTesting()
        XCTAssertEqual(c.effectiveColor.hue ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(panel._hueValueLabel.stringValue, "+90°")
        c.performUndo()
        await c.settleForTesting()
        XCTAssertEqual(panel._hueSlider.doubleValue, 0, "undo brings the slider back")
        XCTAssertEqual(panel._hueValueLabel.stringValue, "0°")
    }

    // MARK: The frame on the displayed image

    func testCropFrameSitsOnTheDisplayedImageAndRefitsAfterRotate() async throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-cropframe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wide.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Self.splitImage(width: 1200, height: 600), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        let services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 900, height: 700))
        let content = viewer.contentRootForTesting
        let deadline = Date().addingTimeInterval(8)
        func readyForEdit() -> Bool {
            content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
                && viewer.displayedItem?.listIndex == 0 && viewer.displayedItem?.group.primary == url
                && content.imageView.sourceID == FileImageSource(url: url).id
                && viewer.canPerform(.editImage)
        }
        while !readyForEdit(), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(readyForEdit(), "the actual photo is accepted before crop entry")
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive, "crop shell entered before frame measurement")
        XCTAssertTrue(content.editModeController.isActive, "crop source finished loading")
        await content.editModeController.settleForTesting()
        viewer.contentView?.layoutSubtreeIfNeeded()

        func assertFrameOnImage(_ label: String) {
            let overlay = content.editModeController.cropOverlay
            let drawn = content.imageView.drawnImageRect
            let expected = CGRect(x: drawn.minX, y: content.imageView.bounds.height - drawn.maxY,
                                  width: drawn.width, height: drawn.height)
            XCTAssertEqual(overlay._imageFrame.minX, expected.minX, accuracy: 0.5, label)
            XCTAssertEqual(overlay._imageFrame.minY, expected.minY, accuracy: 0.5, label)
            XCTAssertEqual(overlay._imageFrame.width, expected.width, accuracy: 0.5, label)
            XCTAssertEqual(overlay._imageFrame.height, expected.height, accuracy: 0.5, label)
            XCTAssertNotEqual(overlay._imageFrame, overlay.bounds, "\(label): never the view bounds")
            // Inside contentLayoutRect: never under the toolbar.
            let inWindow = overlay.convert(overlay._cropRect, to: nil)
            XCTAssertLessThanOrEqual(inWindow.maxY, viewer.contentLayoutRect.maxY + 0.5, label)
        }
        assertFrameOnImage("on entry")
        let before = content.editModeController.cropOverlay._imageFrame

        content.editModeController.appendSnapped90(quarters: 1)
        await content.editModeController.settleForTesting()
        viewer.contentView?.layoutSubtreeIfNeeded()
        assertFrameOnImage("after rotate")
        let after = content.editModeController.cropOverlay._imageFrame
        XCTAssertGreaterThan(before.width, before.height)
        XCTAssertGreaterThan(after.height, after.width, "the frame re-fits to the rotated image")
        XCTAssertEqual(content.editModeController.cropOverlay._cropRect, after, "the crop starts on the whole image")
        XCTAssertEqual(content.editModeController.currentPixelSize, CGSize(width: 600, height: 1200))
    }
}

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
        slider.doubleValue = 0.3
        _ = slider.sendAction(slider.action, to: slider.target)
        try await Task.sleep(nanoseconds: UInt64((EditModeController.coalesceIdle + 0.2) * 1e9))
        slider.doubleValue = 0.6
        _ = slider.sendAction(slider.action, to: slider.target)
        await c.settleForTesting()
        let ops = await c.recipe!.snapshot()
        XCTAssertEqual(ops.count, 2, "500 ms idle ends the drag")
    }

    func testFreeRotateReplacesOnlyItsOwnOp() async throws {
        let (c, _) = controller(image: Self.grey(), tool: .color)
        let panel = try colourPanel(c)
        drag(panel._brightnessSlider, in: panel, to: [0.3])
        await c.settleForTesting()
        c.selectTool(.rotate)
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
        let dir = FileManager.default.temporaryDirectory
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
        viewer.markDisplayedForTesting(0)
        let content = viewer.contentRootForTesting
        let deadline = Date().addingTimeInterval(8)
        while (content.imageView.image == nil || content.imageView.isCurrentImagePlaceholder),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
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

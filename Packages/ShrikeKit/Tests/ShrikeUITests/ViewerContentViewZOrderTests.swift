//
//  ViewerContentViewZOrderTests.swift
//  ShrikeUITests
//
//  Pins the feedback-pipeline z-order contract for `ViewerContentView`.
//  the bottom→top order of the tracked surfaces must be:
//
//      image < canvas dim
//          < filmstrip < toolbar < inspector
//          < position overlay < PREVIEW badge < error overlay
//
//  Chrome panels land between canvasDim and the feedback surfaces so
//  that (a) the dim can paint *under* a revealed edge panel (so the
//  panel stays legible while the canvas dims) and (b) the position
//  overlay, PREVIEW badge, and error overlay all paint on TOP of the
//  chrome panels — the user must be able to read them even when a
//  panel is pinned. Zoom badge, toast, loupe, histogram overlay, LIVE
//  badge, and page indicator are not part of this contract — their
//  ordering is managed per-overlay.
//
//  Regression this guards:
//    * Pre-v1: error overlay was inserted immediately after the canvas
//      dim (z-index 3 of 15), which meant the hover-revealed toolbar,
//      the position overlay pill, and the PREVIEW badge all painted on
//      top of it.
//    * The four chrome panels (filmstrip /
//      toolbar / inspector) slot between canvasDim and
//      navPositionOverlay, in that exact sibling order. Getting this
//      wrong means a pinned inspector panel hides the PREVIEW pill, or
//      the canvas dim paints over a pinned filmstrip.
//

import XCTest
import CoreGraphics
@testable import ShrikeUI

@MainActor
final class ViewerContentViewZOrderTests: XCTestCase {

    func testFeedbackPipelineSubviewOrder_MatchesSpec() {
        let services = ShrikeServices.makeDefault()
        let content = ViewerContentView(services: services)
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        content.layoutSubtreeIfNeeded()
        // The full-screen capsule ("toolbar") is built on
        // the first full-screen entry, in its slot between the filmstrip
        // and the inspector.
        XCTAssertFalse(content.feedbackPipelineSubviewOrderForTesting().contains("toolbar"))
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        let expected = [
            "imageView",
            "canvasDim",
            "filmstrip",
            "toolbar",
            "inspector",
            "navPositionOverlay",
            "previewBadge",
            "errorOverlay",
        ]

        XCTAssertEqual(
            content.feedbackPipelineSubviewOrderForTesting(),
            expected,
            "z-order must be image < canvasDim "
            + "< filmstrip < toolbar < inspector "
            + "< navPositionOverlay < previewBadge < errorOverlay"
        )
    }

    /// Once edit mode is active with Crop selected, the
    /// crop overlay must sit *above* the image canvas but *below* the
    /// navigation position overlay, so the "N of M" pill remains
    /// legible during a crop operation and the error overlay (which
    /// lives above navPositionOverlay in the base z-order) can still
    /// paint over it.
    func testEditModeCropOverlay_SitsAboveImageButBelowPositionOverlay() {
        let services = ShrikeServices.makeDefault()
        let content = ViewerContentView(services: services)
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        content.layoutSubtreeIfNeeded()

        // Synthesize a tiny 2×2 CGImage — enough to drive enterEditMode;
        // no decoding required.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: 2,
            height: 2,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = ctx.makeImage()!

        content.enterEditMode(image: image, url: nil, landOn: .crop)

        let order = content.editModeSubviewOrderForTesting()
        // The filtered order must be exactly: imageView, cropOverlay,
        // navPositionOverlay — i.e., cropOverlay slotted strictly
        // between them.
        XCTAssertEqual(
            order,
            ["imageView", "cropOverlay", "navPositionOverlay"],
            "edit-mode z-order must be imageView < cropOverlay < navPositionOverlay"
        )
    }

    /// The crop overlay's dim outside the crop rect sat over the chrome
    /// panels, so their glyphs looked disabled. The chrome paints above the overlay.
    func testChromeIsAboveTheCropDim() {
        let services = ShrikeServices.makeDefault()
        let content = ViewerContentView(services: services)
        content.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        content.windowMode = .fullscreen
        content.windowMode = .windowed
        content.layoutSubtreeIfNeeded()
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        content.enterEditMode(image: ctx.makeImage()!, url: nil, landOn: .crop)

        let order = content.editModeSubviewOrderForTesting(includingChrome: true)
        let crop = order.firstIndex(of: "cropOverlay")
        XCTAssertNotNil(crop)
        for chrome in ["filmstrip", "navPositionOverlay"] {
            let index = order.firstIndex(of: chrome)
            XCTAssertNotNil(index, chrome)
            XCTAssertGreaterThan(index ?? -1, crop ?? Int.max, "\(chrome) paints above the crop dim: \(order)")
        }
        XCTAssertLessThan(order.firstIndex(of: "imageView") ?? Int.max, crop ?? -1)
    }
}

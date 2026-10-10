//
//  ZoomMotionTests.swift
//  ShrikeRenderingTests
//
//  Motion rows for the canvas: a keyboard / menu zoom step
//  is 80 ms ease-out around its anchor, a pinch released below Fit goes
//  back to Fit in 120 ms ease-out, and under Reduce Motion both are
//  instant. The zoom itself is at the target at once;
//  only the drawing follows. Offscreen view, fake Reduce Motion source.
//

import AppKit
import XCTest
@testable import ShrikeRendering

@MainActor
final class ZoomMotionTests: XCTestCase {

    private var window: NSWindow!
    private var view: MetalImageView!

    override func setUp() async throws {
        MetalImageView.reduceMotionOverrideForTesting = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = view
        // 1600 × 1200 in an 800 × 600 canvas: Fit is below 100 %.
        view.image = Self.solidImage(width: 1600, height: 1200)
        try XCTSkipUnless(view.hasTextureForTesting, "no Metal device")
    }

    override func tearDown() async throws {
        MetalImageView.reduceMotionOverrideForTesting = nil
        view.finishZoomAnimationForTesting()
        window.orderOut(nil)
        window = nil
        view = nil
    }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// The horizontal scale the next frame draws (clip-space units).
    private var drawnScale: Float { view.clipSpaceTransform().columns.0.x }

    // MARK: Zoom step (80 ms ease-out)

    func testZoomStepJumpsTheModelAndEasesTheDrawing() {
        let fit = view.fitPixelScale
        let drawnBefore = drawnScale
        view.stepZoom(in: true)
        let target = view.pixelScale

        // The zoom (badge, VoiceOver, the next step) is at the target now.
        XCTAssertGreaterThan(target, fit * 1.01)
        XCTAssertFalse(view.isAtFit)
        XCTAssertEqual(view.lastZoomAnimationDurationForTesting, MetalImageView.zoomStepDuration)
        XCTAssertEqual(MetalImageView.zoomStepDuration, 0.08)
        XCTAssertFalse(view.isZoomAnimating, "a step is not a smart-zoom animation")

        // The drawing has already moved (no frame of lag) but not all the way.
        guard let shown = view.zoomPresentationForTesting else {
            return XCTFail("the zoom step did not animate")
        }
        XCTAssertGreaterThan(shown.pixelScale, fit)
        XCTAssertLessThan(shown.pixelScale, target)
        XCTAssertGreaterThan(drawnScale, drawnBefore)

        // Ends on the model.
        view.finishZoomAnimationForTesting()
        XCTAssertNil(view.zoomPresentationForTesting)
        XCTAssertEqual(view.pixelScale, target, accuracy: 1e-9)
    }

    func testZoomStepEndsOnItsOwnTimer() async {
        view.stepZoom(in: true)
        XCTAssertNotNil(view.zoomPresentationForTesting)
        let deadline = Date().addingTimeInterval(2)
        while view.zoomPresentationForTesting != nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(view.zoomPresentationForTesting, "the 80 ms step never finished")
    }

    func testSecondStepStartsFromTheFirstTarget() {
        view.stepZoom(in: true)
        let first = view.pixelScale
        view.stepZoom(in: true)
        XCTAssertGreaterThan(view.pixelScale, first * 1.01, "the second step skipped a rung")
        guard let shown = view.zoomPresentationForTesting else {
            return XCTFail("the second step did not animate")
        }
        XCTAssertLessThan(shown.pixelScale, view.pixelScale)
    }

    func testFitCancelsARunningStepAtOnce() {
        view.stepZoom(in: true)
        XCTAssertNotNil(view.zoomPresentationForTesting)
        view.contentMode = .bestFit
        XCTAssertNil(view.zoomPresentationForTesting)
        XCTAssertTrue(view.isAtFit)
    }

    func testANewPhotoIsNeverAnimated() {
        view.stepZoom(in: true)
        XCTAssertNotNil(view.zoomPresentationForTesting)
        view.image = Self.solidImage(width: 1200, height: 900)
        XCTAssertNil(view.zoomPresentationForTesting, "next / previous must not animate")
    }

    // MARK: Pinch release below Fit (120 ms ease-out)

    private func pinchBelowFitAndRelease() -> (below: Double, fit: Double) {
        let centre = CGPoint(x: 400, y: 300)
        view.handleMagnify(magnification: -0.4, phase: .began, anchor: centre)
        let below = view.pixelScale
        view.handleMagnify(magnification: 0, phase: .ended, anchor: centre)
        return (below, view.fitPixelScale)
    }

    func testPinchReleaseBelowFitEasesBackToFit() {
        let (below, fit) = pinchBelowFitAndRelease()
        XCTAssertLessThan(below, fit * 0.9, "the pinch never went below Fit")
        XCTAssertTrue(view.isAtFit, "the zoom is at Fit at once")
        XCTAssertEqual(view.lastZoomAnimationDurationForTesting, MetalImageView.pinchReleaseDuration)
        XCTAssertEqual(MetalImageView.pinchReleaseDuration, 0.12)
        guard let shown = view.zoomPresentationForTesting else {
            return XCTFail("the release did not animate")
        }
        XCTAssertGreaterThan(shown.pixelScale, below)
        XCTAssertLessThan(shown.pixelScale, fit)
        view.finishZoomAnimationForTesting()
        XCTAssertNil(view.zoomPresentationForTesting)
    }

    // MARK: Reduce Motion on

    func testReduceMotionZoomStepIsInstant() {
        MetalImageView.reduceMotionOverrideForTesting = true
        let fit = view.fitPixelScale
        view.stepZoom(in: true)
        XCTAssertGreaterThan(view.pixelScale, fit * 1.01)
        XCTAssertNil(view.zoomPresentationForTesting, "Reduce Motion: the step must be instant")
    }

    func testReduceMotionPinchReleaseIsInstant() {
        MetalImageView.reduceMotionOverrideForTesting = true
        let (below, fit) = pinchBelowFitAndRelease()
        XCTAssertLessThan(below, fit * 0.9)
        XCTAssertTrue(view.isAtFit)
        XCTAssertNil(view.zoomPresentationForTesting, "Reduce Motion: the release must be instant")
    }

    func testReduceMotionIsReadEachTime() {
        MetalImageView.reduceMotionOverrideForTesting = true
        view.stepZoom(in: true)
        XCTAssertNil(view.zoomPresentationForTesting)
        MetalImageView.reduceMotionOverrideForTesting = false
        view.stepZoom(in: true)
        XCTAssertNotNil(view.zoomPresentationForTesting, "the setting was cached")
    }

    func testOneSharedReduceMotionSource() {
        MetalImageView.reduceMotionOverrideForTesting = true
        XCTAssertTrue(ReduceMotion.isOn)
        MetalImageView.reduceMotionOverrideForTesting = false
        XCTAssertFalse(ReduceMotion.isOn)
    }
}

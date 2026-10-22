//
//  ZoomToFitInvariantTests.swift
//  ShrikeRenderingTests
//
//  Spec 27 B1: Zoom to Fit from any prior state ends at Fit.
//

import AppKit
import XCTest
@testable import ShrikeRendering

@MainActor
final class ZoomToFitInvariantTests: XCTestCase {
    private var window: NSWindow!
    private var view: MetalImageView!

    override func setUp() async throws {
        MetalImageView.reduceMotionOverrideForTesting = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = view
        // Keep Fit above the ladder's 25% floor on smaller hosted runners.
        // The tested invariant requires a legal zoom-out step below Fit.
        view.image = Self.solidImage(width: 3000, height: 1800)
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

    private func assertAtFit(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .bestFit = view.contentMode else {
            return XCTFail("\(message): contentMode is \(view.contentMode)", file: file, line: line)
        }
        XCTAssertTrue(view.isAtFit, message, file: file, line: line)
        XCTAssertEqual(view.pixelScale, view.fitPixelScale, accuracy: 1e-9, message, file: file, line: line)
        XCTAssertFalse(view.isZoomAnimating, message, file: file, line: line)
        XCTAssertNil(view.zoomPresentationForTesting, message, file: file, line: line)
    }

    func testFitAfterSixWheelZoomOuts() {
        let point = CGPoint(x: 600, y: 400)
        for _ in 0..<6 {
            view.setPixelScale(ZoomLadder.lowest(fit: view.fitPixelScale), anchor: point)
        }
        XCTAssertFalse(view.isAtFit, "precondition: zoomed out")
        XCTAssertLessThan(view.pixelScale, view.fitPixelScale * 0.9, "precondition: below Fit")
        view.zoomToFit()
        assertAtFit("after zoom-out")
    }

    /// The real path: Command + precise scroll, six events of -60.
    func testFitAfterCommandScrollZoomOut() throws {
        for _ in 0..<6 {
            let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                           wheel1: -60, wheel2: 0, wheel3: 0))
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.flags = .maskCommand
            let event = try XCTUnwrap(NSEvent(cgEvent: cg))
            view.scrollWheel(with: event)
        }
        XCTAssertFalse(view.isAtFit, "precondition: zoomed out (pixelScale \(view.pixelScale), fit \(view.fitPixelScale))")
        XCTAssertLessThan(view.pixelScale, view.fitPixelScale * 0.9,
                          "precondition: command scroll moved below Fit")
        view.zoomToFit()
        assertAtFit("after command scroll zoom-out")
    }

    func testFitAfterSteppedZoomOutWithPresentation() {
        for _ in 0..<6 { view.stepZoom(in: false) }
        view.zoomToFit()
        assertAtFit("after stepped zoom-out")
    }

    func testFitFrom100And1600And25() {
        for scale in [1.0, 16.0, 0.25] {
            view.setPixelScale(scale, anchor: CGPoint(x: 300, y: 200))
            view.zoomToFit()
            assertAtFit("from \(scale)")
        }
    }

    func testFitWithAStandInTextureCap() {
        view.standInLogicalSizeForTesting = CGSize(width: 600, height: 400)
        view.setPixelScale(0.25, anchor: CGPoint(x: 300, y: 200))
        view.zoomToFit()
        assertAtFit("with a stand-in cap")
        view.standInLogicalSizeForTesting = nil
    }

    func testFitWhileAResolutionSwapIsMarked() {
        view.setPixelScale(0.25, anchor: CGPoint(x: 300, y: 200))
        view.swappingResolutionForTesting = true
        view.zoomToFit()
        view.swappingResolutionForTesting = false
        assertAtFit("while swapping resolution")
    }

    func testFitWhileZoomAnimationRunning() {
        view.toggleZoomForTesting(at: CGPoint(x: 300, y: 200))
        view.zoomToFit()
        assertAtFit("with animation running")
    }
}

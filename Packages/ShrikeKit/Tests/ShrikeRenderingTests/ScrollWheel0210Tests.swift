//
//  ScrollWheel0210Tests.swift
//  ShrikeRenderingTests
//
//  0.2.10 audit items 7 and 8 on the real view: the wheel still changes the
//  image when no photo is on the canvas (a folder of broken photos), and the
//  Command + scroll zoom is gentle.
//

import AppKit
import XCTest
@testable import ShrikeRendering
@testable import ShrikeCore

@MainActor
private final class NavRecorder: MetalImageViewDelegate {
    var steps: [Bool] = []
    func metalImageViewDidChangeZoom(_ view: MetalImageView, zoom: Double) {}
    func metalImageViewDidChangePan(_ view: MetalImageView, pan: CGPoint) {}
    func metalImageViewDidPresentFirstDrawable(_ view: MetalImageView) {}
    func metalImageView(_ view: MetalImageView, requestsNavigation forward: Bool) { steps.append(forward) }
    func metalImageView(_ view: MetalImageView, canNavigate forward: Bool) -> Bool { true }
    func metalImageViewDidFinishUserZoom(_ view: MetalImageView) {}
}

@MainActor
final class ScrollWheel0210Tests: XCTestCase {
    private var window: NSWindow!
    private var view: MetalImageView!
    private var recorder: NavRecorder!
    private var savedWheel = true

    override func setUp() async throws {
        MetalImageView.reduceMotionOverrideForTesting = false
        savedWheel = Prefs.scrollWheelNavigates
        Prefs.scrollWheelNavigates = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        window.contentView = view
        recorder = NavRecorder()
        view.delegate = recorder
    }

    override func tearDown() async throws {
        Prefs.scrollWheelNavigates = savedWheel
        MetalImageView.reduceMotionOverrideForTesting = nil
        view.finishZoomAnimationForTesting()
        window.orderOut(nil)
        window = nil
        view = nil
    }

    private func event(dy: Int32, units: CGScrollEventUnit, continuous: Bool, ms: Double, flags: CGEventFlags = []) throws -> NSEvent {
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                                       wheel1: dy, wheel2: 0, wheel3: 0))
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
        cg.flags = flags
        cg.timestamp = CGEventTimestamp(1_000_000_000 + UInt64(ms * 1_000_000))
        return try XCTUnwrap(NSEvent(cgEvent: cg))
    }

    /// Item 7: no texture (every photo so far was broken): the wheel still steps.
    func testWheelStepsWithoutAPhotoOnTheCanvas() throws {
        XCTAssertFalse(view.hasTextureForTesting)
        for spacing in [10.0, 15, 25, 40] {
            recorder.steps = []
            for i in 0..<4 {
                view.scrollWheel(with: try event(dy: -1, units: .line, continuous: false, ms: 5000 * spacing + Double(i) * spacing))
            }
            XCTAssertEqual(recorder.steps, [true, true, true, true], "\(spacing) ms")
        }
        recorder.steps = []
        view.scrollWheel(with: try event(dy: 1, units: .line, continuous: false, ms: 900_000))
        XCTAssertEqual(recorder.steps, [false])
        // Command + wheel with no photo neither zooms nor crashes.
        view.scrollWheel(with: try event(dy: 1, units: .line, continuous: false, ms: 950_000, flags: .maskCommand))
    }

    /// Item 8: six Command + scroll events of 40 pt zoom about 4x, not to 1600 %.
    func testCommandScrollZoomIsGentle() throws {
        view.image = Self.solidImage(width: 5184, height: 3456)
        try XCTSkipUnless(view.hasTextureForTesting, "no Metal device")
        let fit = view.fitPixelScale
        for i in 0..<6 {
            view.scrollWheel(with: try event(dy: 40, units: .pixel, continuous: true, ms: Double(i) * 20, flags: .maskCommand))
        }
        let ratio = view.pixelScale / fit
        XCTAssertEqual(ratio, pow(1.12, 12), accuracy: 0.3, "6 x 40 pt = 12 lines of 12 %")
        XCTAssertLessThan(view.pixelScale, 4)
    }

    private static func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}

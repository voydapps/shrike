//
//  MotionTests.swift
//  ShrikeUITests
//
//  Motion rows outside the canvas: the full-screen bottom
//  stack fades in with an 8 pt rise (ease-out) and only fades under
//  Reduce Motion ("nothing slides"); a grid thumbnail fades in over
//  80 ms, and shows at once under Reduce Motion. Offscreen views and a
//  fake Reduce Motion source (the canvas rows are in ZoomMotionTests).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class MotionTests: XCTestCase {

    private let pinKeys = [
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.exifPanel.pinnedFullscreen",
        "shrike.viewer.histogramVisible",
    ]
    private var window: NSWindow?

    override func setUp() {
        super.setUp()
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        ReduceMotion.overrideForTesting = false
    }

    override func tearDown() {
        ReduceMotion.overrideForTesting = nil
        for key in pinKeys { ShrikeDefaults.store.removeObject(forKey: key) }
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    /// A full-screen viewer content view in an offscreen window, with the
    /// real (animated) panel fades.
    private func makeContent() -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = content
        window = w
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        content.animatesPanelFades = true
        return content
    }

    private func controlPoints(_ f: CAMediaTimingFunction) -> [Float] {
        (0..<4).flatMap { i -> [Float] in
            var p: [Float] = [0, 0]
            f.getControlPoint(at: i, values: &p)
            return p
        }
    }

    private func isEaseOut(_ f: CAMediaTimingFunction?) -> Bool {
        guard let f else { return false }
        return controlPoints(f) == controlPoints(CAMediaTimingFunction(name: .easeOut))
    }

    private func rise(on view: NSView) -> CABasicAnimation? {
        view.layer?.animation(forKey: ViewerContentView.stackRiseKey) as? CABasicAnimation
    }

    // MARK: Full-screen stack reveal

    func testStackRevealRisesEightPointsWithEaseOut() {
        let content = makeContent()
        content.togglePanel(.filmstrip)   // pinned
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))   // the pointer rests in the bottom zone: capsule + strip   // the stack shows
        defer { content.togglePanel(.filmstrip) }
        for view in [content.filmstripForTesting, content.toolbarForTesting] as [NSView] {
            XCTAssertFalse(view.isHidden, "\(type(of: view)) shows")
            guard let anim = rise(on: view) else {
                XCTFail("\(type(of: view)) does not rise")
                continue
            }
            XCTAssertEqual(anim.keyPath, "position.y")
            XCTAssertTrue(anim.isAdditive, "the rise must not move the layout")
            XCTAssertEqual((anim.fromValue as? NSNumber)?.doubleValue ?? 0, -8, accuracy: 0.001,
                           "starts 8 pt low")
            XCTAssertEqual((anim.toValue as? NSNumber)?.doubleValue ?? 1, 0, accuracy: 0.001)
            XCTAssertEqual(anim.duration, ViewerContentView.fadeInDuration, accuracy: 0.0001)
            XCTAssertTrue(isEaseOut(anim.timingFunction))
        }
    }

    func testHidingTheStackDropsTheRise() {
        let content = makeContent()
        content.togglePanel(.filmstrip)
        XCTAssertNotNil(rise(on: content.filmstripForTesting))
        content.togglePanel(.filmstrip)
        XCTAssertNil(rise(on: content.filmstripForTesting))
        XCTAssertNil(rise(on: content.toolbarForTesting))
    }

    /// Reduce Motion on, nothing slides; the stack still fades.
    func testReduceMotionStackFadesButDoesNotRise() {
        ReduceMotion.overrideForTesting = true
        let content = makeContent()
        content.togglePanel(.filmstrip)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 40))   // the pointer rests in the bottom zone: capsule + strip
        defer { content.togglePanel(.filmstrip) }
        for view in [content.filmstripForTesting, content.toolbarForTesting] as [NSView] {
            XCTAssertFalse(view.isHidden)
            XCTAssertNil(rise(on: view), "Reduce Motion: \(type(of: view)) must not slide")
        }
    }

    /// Reduce Motion: the side panels (not the stack) show at once.
    func testReduceMotionSidePanelsAreInstant() {
        ReduceMotion.overrideForTesting = true
        let content = makeContent()
        content.togglePanel(.inspector)
        defer { content.togglePanel(.inspector) }
        XCTAssertFalse(content.inspectorForTesting.isHidden)
        XCTAssertEqual(content.inspectorForTesting.alphaValue, 1, accuracy: 0.001)
        XCTAssertNil(rise(on: content.inspectorForTesting))
    }

    // MARK: Grid thumbnail fade

    private func thumbnailImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        return ctx.makeImage()!
    }

    func testThumbnailFadesInOver80Milliseconds() {
        let item = ThumbnailItem(nibName: nil, bundle: nil)
        item.loadView()
        item.showThumbnail(thumbnailImage())
        guard let fade = item.thumbnailFadeForTesting else {
            return XCTFail("the thumbnail did not fade in")
        }
        XCTAssertEqual(fade.keyPath, "opacity")
        XCTAssertEqual((fade.fromValue as? NSNumber)?.doubleValue ?? 1, 0, accuracy: 0.001)
        XCTAssertEqual((fade.toValue as? NSNumber)?.doubleValue ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(fade.duration, 0.08, accuracy: 0.0001)
        XCTAssertTrue(isEaseOut(fade.timingFunction))

        item.prepareForReuse()
        XCTAssertNil(item.thumbnailFadeForTesting, "a reused cell starts clean")
    }

    func testReduceMotionThumbnailShowsAtOnce() {
        ReduceMotion.overrideForTesting = true
        let item = ThumbnailItem(nibName: nil, bundle: nil)
        item.loadView()
        item.showThumbnail(thumbnailImage())
        XCTAssertNil(item.thumbnailFadeForTesting, "Reduce Motion: no thumbnail fade")
    }
}

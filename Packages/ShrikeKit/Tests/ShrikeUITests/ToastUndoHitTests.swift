//
//  ToastUndoHitTests.swift
//  ShrikeUITests
//
//  Spec 27 B2 (the Undo control is hit-testable over the full pill height)
//  and N6 (a flat pill, no wide halo).
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ToastUndoHitTests: XCTestCase {

    private var container: NSView!
    private var window: NSWindow!
    private var toast: ToastHostView!
    private var ran = 0

    override func setUp() async throws {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        toast = ToastHostView(placement: .viewer)
        toast.install(in: container)
        ran = 0
    }

    override func tearDown() async throws {
        toast.dismiss(animated: false)
        window.orderOut(nil)
        window = nil
    }

    private func showTrash() {
        toast.show(.trashed("Moved IMG_0001.jpg to the Trash."), action: { [self] in ran += 1 })
        toast.alphaValue = 1
        container.layoutSubtreeIfNeeded()
    }

    /// The nine points of the button rect, 1 pt inside, in container coordinates.
    private func ninePoints() -> [NSPoint] {
        let button = toast.actionButtonForTesting
        let r = button.convert(button.bounds, to: container).insetBy(dx: 1, dy: 1)
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        return xs.flatMap { x in ys.map { NSPoint(x: x, y: $0) } }
    }

    func testButtonFillsThePillHeightAndIsAtLeast44Wide() {
        showTrash()
        let button = toast.actionButtonForTesting
        XCTAssertEqual(button.frame.height, toast.frame.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        let inPill = button.convert(button.bounds, to: toast)
        XCTAssertEqual(inPill.maxX, toast.bounds.maxX, accuracy: 0.5, "reaches the pill's trailing edge")
    }

    func testNineHitPointsReachTheButtonAtOnceAndLater() async {
        showTrash()
        for delay in [0, 50, 300] {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            for p in ninePoints() {
                let hit = container.hitTest(container.convert(p, to: container.superview))
                XCTAssertTrue(hit === toast.actionButtonForTesting, "\(p) after \(delay) ms hit \(String(describing: hit))")
            }
        }
    }

    func testCornerClickRunsTheActionAndLabelClickDoesNot() {
        showTrash()
        let corner = NSPoint(x: toast.actionButtonForTesting.convert(toast.actionButtonForTesting.bounds, to: container).maxX - 1,
                             y: toast.actionButtonForTesting.convert(toast.actionButtonForTesting.bounds, to: container).maxY - 1)
        XCTAssertTrue(container.hitTest(container.convert(corner, to: container.superview)) === toast.actionButtonForTesting)
        toast.actionButtonForTesting.performClick(nil)
        XCTAssertEqual(ran, 1)

        showTrash()
        let label = toast.labelForTesting
        let p = label.convert(NSPoint(x: label.bounds.midX, y: label.bounds.midY), to: container)
        let hit = container.hitTest(container.convert(p, to: container.superview))
        XCTAssertFalse(hit === toast.actionButtonForTesting)
        XCTAssertTrue(toast.isShowing, "a click on the label leaves the toast alone")
        XCTAssertEqual(ran, 1)
    }

    func testSecondToastIgnoresAPressThatBeganOnTheFirst() {
        showTrash()
        toast.beginPressForTesting()
        var secondRan = 0
        toast.show(.trashed("Moved IMG_0002.jpg to the Trash."), action: { secondRan += 1 })
        toast.performToastAction(nil)
        XCTAssertEqual(secondRan, 0)
        XCTAssertEqual(ran, 0)
        // A fresh press on the second one works.
        toast.beginPressForTesting()
        toast.performToastAction(nil)
        XCTAssertEqual(secondRan, 1)
    }

    func testPointerRestingInsideAtShowPausesTheClock() {
        // Place the pointer where the toast will be: top centre.
        toast.pointerInWindowForTesting = NSPoint(x: 400, y: 600 - 120 - 16)
        showTrash()
        XCTAssertTrue(toast.isPaused)
        toast.dismiss(animated: false)
        toast.pointerInWindowForTesting = NSPoint(x: 5, y: 5)
        showTrash()
        XCTAssertFalse(toast.isPaused)
    }

    func testHiddenZoomHUDDoesNotMoveTheToast() {
        let hud = NSView(frame: .zero)
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 110),
            hud.widthAnchor.constraint(equalToConstant: 96),
            hud.heightAnchor.constraint(equalToConstant: 30),
        ])
        toast.keepBelow(hud, gap: 12)

        hud.alphaValue = 0
        showTrash()
        let hidden = toast.frame
        XCTAssertFalse(toast.avoidanceActiveForTesting)

        toast.dismiss(animated: false)
        hud.alphaValue = 1
        showTrash()
        XCTAssertTrue(toast.avoidanceActiveForTesting)
        XCTAssertGreaterThan(toast.frame.minY, hidden.minY - 0.5 - 1000)   // pushed below the HUD
        XCTAssertLessThanOrEqual(toast.frame.maxY, hud.frame.minY - 12 + 0.5)

        // Without any HUD at all the frame equals the hidden-HUD frame.
        let bare = ToastHostView(placement: .viewer)
        let other = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        bare.install(in: other)
        bare.show(.trashed("Moved IMG_0001.jpg to the Trash."))
        bare.alphaValue = 1
        other.layoutSubtreeIfNeeded()
        XCTAssertEqual(bare.frame.size, hidden.size)
        XCTAssertEqual(bare.frame.origin.y, hidden.origin.y, accuracy: 0.5)
    }

    func testFlatPill() {
        showTrash()
        let layer = toast.layer
        XCTAssertNotNil(layer)
        XCTAssertLessThanOrEqual(layer?.shadowRadius ?? 99, 4)
        XCTAssertLessThanOrEqual(layer?.shadowOpacity ?? 1, 0.25)
        XCTAssertEqual(toast.fillLayerForTesting?.borderWidth ?? 0, 0.5, accuracy: 0.001, "the hairline")
        XCTAssertEqual(ToastHostView.pillStyle.fill.alphaComponent, 0.82, accuracy: 0.001)
    }
}

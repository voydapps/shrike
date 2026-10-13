//
//  ToastHostsAndHUD028Tests.swift
//  ShrikeUITests
//
//  Spec 27 B2: the Undo hit check in each of the three hosts (viewer in a
//  window, viewer in full screen, Browser), and the zoom HUD's show / hide
//  driving the toast's avoidance without ever moving a toast on screen.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ToastHostsAndHUD028Tests: XCTestCase {

    private func ninePoints(_ toast: ToastHostView) -> [NSPoint] {
        let button = toast.actionButtonForTesting
        let r = button.convert(button.bounds, to: toast.superview).insetBy(dx: 1, dy: 1)
        let xs = [r.minX, r.midX, r.maxX], ys = [r.minY, r.midY, r.maxY]
        return xs.flatMap { x in ys.map { NSPoint(x: x, y: $0) } }
    }

    /// Nine points x (0, 50, 300 ms): the button is the hit view each time.
    private func assertNineHits(_ toast: ToastHostView, label: String,
                                file: StaticString = #filePath, line: UInt = #line) async {
        guard let host = toast.superview else { return XCTFail("\(label): toast not installed", file: file, line: line) }
        for delay in [0, 50, 300] {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
            for p in ninePoints(toast) {
                let inSuper = NSPoint(x: p.x + host.frame.origin.x, y: p.y + host.frame.origin.y)
                let hit = host.hitTest(inSuper)
                XCTAssertTrue(hit === toast.actionButtonForTesting,
                              "\(label): \(p) after \(delay) ms hit \(String(describing: hit))", file: file, line: line)
            }
        }
    }

    func testNineHitsInTheWindowedViewer() async {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.animatesPanelFades = false
        content.windowMode = .windowed
        var ran = 0
        content.toast(.trashed("Moved IMG_0001.jpg to the Trash."), action: { ran += 1 })
        content.toastHost.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        await assertNineHits(content.toastHost, label: "viewer window")
        content.toastHost.actionButtonForTesting.performClick(nil)
        XCTAssertEqual(ran, 1)
    }

    func testNineHitsInTheFullScreenViewer() async {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        var ran = 0
        content.toast(.trashed("Moved IMG_0001.jpg to the Trash."), action: { ran += 1 })
        content.toastHost.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.toastHost.superview === content.zoomBadgeForTesting.superview,
                      "the capsule toast and the zoom HUD share a parent")
        await assertNineHits(content.toastHost, label: "viewer full screen")
        content.toastHost.actionButtonForTesting.performClick(nil)
        XCTAssertEqual(ran, 1)
    }

    func testNineHitsInTheBrowser() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-toast028-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: root)
        defer { browser.close() }
        var ran = 0
        browser.toast(.trashed("Moved IMG_0001.jpg to the Trash."), action: { ran += 1 })
        browser.toastHost.alphaValue = 1
        browser.window?.contentView?.layoutSubtreeIfNeeded()
        browser.toastHost.superview?.layoutSubtreeIfNeeded()
        await assertNineHits(browser.toastHost, label: "Browser")
        browser.toastHost.actionButtonForTesting.performClick(nil)
        XCTAssertEqual(ran, 1)
    }

    // MARK: HUD show / hide

    private func makeHost() -> (NSView, ToastHostView, ZoomBadgeView) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let hud = ZoomBadgeView()
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 110),
            hud.widthAnchor.constraint(equalToConstant: 96),
            hud.heightAnchor.constraint(equalToConstant: 30),
        ])
        hud.alphaValue = 0
        let toast = ToastHostView(placement: .viewer)
        toast.install(in: container)
        toast.keepBelow(hud, gap: 12)
        return (container, toast, hud)
    }

    func testHUDPulseDuringAToastDoesNotMoveItAndTheNextShowAvoidsTheHUD() {
        let (container, toast, hud) = makeHost()
        toast.show(.trashed("Moved IMG_0001.jpg to the Trash."))
        toast.alphaValue = 1
        container.layoutSubtreeIfNeeded()
        let before = toast.frame
        XCTAssertFalse(toast.avoidanceActiveForTesting)

        hud.alphaValue = 1                       // the HUD pulses while the toast is up
        toast.refreshAvoidance()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(toast.frame, before, "a toast on screen never moves")
        XCTAssertFalse(toast.avoidanceActiveForTesting)

        toast.dismiss(animated: false)           // the end of the toast applies the wanted state
        XCTAssertTrue(toast.avoidanceActiveForTesting)
        toast.show(.trashed("Moved IMG_0002.jpg to the Trash."))
        toast.alphaValue = 1
        container.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(toast.frame.maxY, hud.frame.minY - 12 + 0.5, "pushed below the HUD")
    }

    func testHUDHidingDuringAToastDoesNotMoveItAndDismissReleasesIt() {
        let (container, toast, hud) = makeHost()
        hud.alphaValue = 1
        toast.refreshAvoidance()
        toast.show(.trashed("Moved IMG_0001.jpg to the Trash."))
        toast.alphaValue = 1
        container.layoutSubtreeIfNeeded()
        XCTAssertTrue(toast.avoidanceActiveForTesting)
        let before = toast.frame

        // The animator path: the model value drops at once, so the check right after reads 0.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            hud.animator().alphaValue = 0
        }
        XCTAssertEqual(hud.alphaValue, 0, accuracy: 0.0001)
        toast.refreshAvoidance()
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(toast.frame, before, "a toast on screen never moves")
        XCTAssertTrue(toast.avoidanceActiveForTesting)

        toast.dismiss(animated: false)
        XCTAssertFalse(toast.avoidanceActiveForTesting)
    }

    func testHUDIsHiddenAndShownThroughIsHiddenToo() {
        let (_, toast, hud) = makeHost()
        hud.alphaValue = 1
        toast.refreshAvoidance()
        XCTAssertTrue(toast.avoidanceActiveForTesting)
        hud.isHidden = true
        toast.refreshAvoidance()
        XCTAssertFalse(toast.avoidanceActiveForTesting)
        hud.isHidden = false
        toast.refreshAvoidance()
        XCTAssertTrue(toast.avoidanceActiveForTesting)
    }

    /// The viewer wires its own zoom HUD's show and hide to the toast.
    func testViewerZoomHUDShowAndHideDriveTheToast() {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.animatesPanelFades = false
        XCTAssertFalse(content.toastHost.avoidanceActiveForTesting, "hidden HUD: no rule")
        content.userChangedZoom()                     // the HUD pulses in
        XCTAssertTrue(content.toastHost.avoidanceActiveForTesting)
        content.hideZoomBadgeForTesting()             // and out
        XCTAssertFalse(content.toastHost.avoidanceActiveForTesting)
    }
}

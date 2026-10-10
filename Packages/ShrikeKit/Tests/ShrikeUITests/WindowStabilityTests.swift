//
//  WindowStabilityTests.swift
//  ShrikeUITests
//
//  Window stability:
//  - windows never resize themselves (the Browser inspector on selection,
//    the Copy / Move HUD in a short viewer);
//  - the viewer toolbar comes back after full screen;
//  - after ⌘Z from the empty state the photo is drawn again.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class WindowStabilityTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-p1-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func writeJPEG(_ name: String, width: Int = 1600, height: Int = 1200) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func browser(_ count: Int) async throws -> BrowserWindowController {
        for i in 0..<count { _ = try writeJPEG(String(format: "P%04d.JPG", i), width: 5184, height: 3888) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let ok = await waitUntil { browser.contentController.visibleItems.count == count }
        XCTAssertTrue(ok)
        return browser
    }

    // MARK: P1-A

    func testBrowserFrameStaysPutWhenTheSelectionChanges() async throws {
        let browser = try await browser(4)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1072, height: 580))
        window.contentView?.layoutSubtreeIfNeeded()
        let before = window.frame
        let items = browser.contentController.visibleItems
        for run in 0..<8 {
            browser.contentController.select(url: items[run % items.count].url)
            browser.browserContentDidSelect([items[run % items.count]])
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(15))
        }
        await browser.waitForInspectorInfo()
        try await Task.sleep(for: .milliseconds(200))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.size.width, before.size.width, accuracy: 0.5, "no jump to 1507 pt")
        XCTAssertEqual(window.frame.size.height, before.size.height, accuracy: 0.5, "no growth on fast clicks")
    }

    func testBrowserGoesNarrowWithTheInspectorShownAndAPhotoSelected() async throws {
        let browser = try await browser(2)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        browser.contentController.selectAll()
        browser.browserContentDidSelect(browser.contentController.selectedItems)
        try await Task.sleep(for: .milliseconds(300))
        // Sidebar min 160 + grid min 360 + inspector min 240 (+ dividers).
        let narrow: CGFloat = 800
        window.setContentSize(NSSize(width: narrow, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.width, narrow + 0.5, "the inspector never sets a minimum width")
        XCTAssertLessThan(window.frame.width, 1000)
    }

    func testDestinationHUDNeverGrowsTheWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let before = window.frame
        let content = window.contentView!
        let hud = DestinationHUDView(verb: .copy, slots: Array(repeating: nil, count: 9), last: nil)
        hud.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            hud.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            hud.topAnchor.constraint(equalTo: content.topAnchor),
            hud.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        XCTAssertEqual(window.frame.height, before.height, accuracy: 0.5, "580 → 775 pt must not happen")
        XCTAssertEqual(window.frame.width, before.width, accuracy: 0.5)
        hud.removeFromSuperview()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.height, before.height, accuracy: 0.5)
    }

    // MARK: P1-C

    func testToolbarComesBackAfterFullScreenToTheUsersSetting() throws {
        let url = try writeJPEG("a.jpg")
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        let toolbar = try XCTUnwrap(viewer.toolbar)
        toolbar.isVisible = true
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        XCTAssertFalse(toolbar.isVisible, "no NSToolbar in full screen")
        center.post(name: NSWindow.didEnterFullScreenNotification, object: viewer)
        center.post(name: NSWindow.willExitFullScreenNotification, object: viewer)
        // AppKit puts back the toolbar it saw when full screen began
        // (hidden) during the exit; the delegate path then restores ours.
        toolbar.isVisible = false
        center.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        XCTAssertTrue(toolbar.isVisible, "the toolbar is back after full screen")

        // A user who hid the toolbar keeps it hidden.
        toolbar.isVisible = false
        center.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        center.post(name: NSWindow.willExitFullScreenNotification, object: viewer)
        center.post(name: NSWindow.didExitFullScreenNotification, object: viewer)
        XCTAssertFalse(toolbar.isVisible)
    }

    // MARK: P1-D

    func testUndoFromTheEmptyStateDrawsThePhotoAgain() async throws {
        let url = try writeJPEG("only.jpg")
        let trash = dir.deletingLastPathComponent().appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.setContentSize(NSSize(width: 800, height: 600))
        viewer.contentView?.layoutSubtreeIfNeeded()
        viewer.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { item in
            let dest = trash.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
            try FileManager.default.moveItem(at: item, to: dest)
            return dest
        })
        let view = viewer.imageViewForTesting
        let shown = await waitUntil { view.image != nil && view.hasTextureForTesting }
        XCTAssertTrue(shown)
        viewer.markDisplayedForTesting(0)
        viewer.dispatch(.deleteToTrash)
        await viewer.waitForPendingTrash()
        XCTAssertTrue(viewer.isShowingEmptyState)
        XCTAssertFalse(view.hasTextureForTesting)

        viewer.performUndo()
        let back = await waitUntil { view.image != nil && view.hasTextureForTesting }
        XCTAssertTrue(back, "a current texture after undo")
        XCTAssertFalse(viewer.isShowingEmptyState)
        XCTAssertFalse(view.isHidden, "the canvas is visible")
        XCTAssertGreaterThan(view.drawableSizeForTesting.width, 100, "the drawable is sized for the view, not 1 × 1")
        XCTAssertGreaterThan(view.drawableSizeForTesting.height, 100)
    }
}

//
//  ViewerToolbarHoverTests.swift
//  ShrikeUITests
//
//  Every item of the viewer's and the Browser's toolbar shows a hover
//  platter that can be seen (white 14 % dark / black 8 % light), drawn by
//  `ToolbarHover` over the item under the pointer. On macOS 26 the
//  system's own hover disc was 8 of 255 levels lighter than the glass
//  (measured on screen 2026-10-11). Hover itself with a real pointer was
//  checked on screen; here the pointer is placed by calling the overlay.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerToolbarHoverTests: XCTestCase {

    private var window: NSWindow?
    private var hover: ToolbarHover?

    override func tearDown() async throws {
        window?.toolbar = nil
        window?.close()
        window = nil
        hover = nil
        try await super.tearDown()
    }

    private func settle(_ w: NSWindow) {
        for _ in 0..<60 {
            w.contentView?.superview?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private func makeViewerWindow(_ appearance: NSAppearance.Name) -> (ViewerWindowToolbar, NSWindow) {
        let bar = ViewerWindowToolbar(host: nil)
        bar.toolbar.autosavesConfiguration = false
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 200),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: appearance)
        w.toolbarStyle = .unified
        w.toolbar = bar.toolbar
        window = w
        settle(w)
        hover = ToolbarHover(window: w)
        settle(w)
        return (bar, w)
    }

    /// The pointer positions that hit each item: the middle of the item's
    /// control, or of each segment of a group.
    private func itemPoints(_ hover: ToolbarHover) -> [(id: String, point: NSPoint)] {
        guard let bar = hover.toolbarView else { return [] }
        var out: [(String, NSPoint)] = []
        for viewer in bar.subviews where String(describing: type(of: viewer)) == "NSToolbarItemViewer" {
            guard let item = viewer.value(forKey: "item") as? NSToolbarItem else { continue }
            let id = item.itemIdentifier.rawValue
            if let group = item as? NSToolbarItemGroup, !group.subitems.isEmpty,
               let picker = viewer.subviews.first(where: { String(describing: type(of: $0)).contains("GroupPicker") }) {
                let frame = bar.convert(picker.bounds, from: picker)
                let width = frame.width / CGFloat(group.subitems.count)
                for i in group.subitems.indices {
                    out.append(("\(id)#\(i)", hover.overlay.convert(
                        NSPoint(x: frame.minX + width * (CGFloat(i) + 0.5), y: frame.midY), from: bar)))
                }
                continue
            }
            func first(_ v: NSView) -> NSControl? {
                for s in v.subviews {
                    if let c = s as? NSControl, !(c is NSTextField), c.bounds.width > 0 { return c }
                    if let c = first(s) { return c }
                }
                return nil
            }
            if let c = first(viewer) {
                let center = bar.convert(NSPoint(x: c.bounds.midX, y: c.bounds.midY), from: c)
                out.append((id, hover.overlay.convert(center, from: bar)))
            }
        }
        return out
    }

    /// The overlay drawn offscreen (alpha of the pixel at `point`, 0...1).
    private func platterAlpha(_ hover: ToolbarHover, at point: NSPoint) -> CGFloat {
        let overlay = hover.overlay
        guard let layer = overlay.layer else { return 0 }
        let size = overlay.bounds.size
        let scale: CGFloat = 1
        let w = Int(size.width * scale), h = Int(size.height * scale)
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            if !overlay.isFlipped {
                // CGContext rows start at the bottom already: draw as is.
            } else {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            layer.render(in: ctx)
        }
        // Row 0 of the buffer is the top of the image.
        let x = Int(point.x), yFromBottom = Int(point.y)
        let row = overlay.isFlipped ? yFromBottom : h - 1 - yFromBottom
        guard x >= 0, x < w, row >= 0, row < h else { return 0 }
        return CGFloat(buf[(row * w + x) * 4 + 3]) / 255
    }

    func testEveryViewerItemHasTrackingAndDrawsAVisiblePlatter() throws {
        guard ToolbarHover.isNeeded else { throw XCTSkip("macOS 26 draws it") }
        let (bar, _) = makeViewerWindow(.darkAqua)
        let hover = try XCTUnwrap(self.hover)
        XCTAssertNotNil(hover.overlay.superview, "the overlay is in the toolbar")
        XCTAssertNil(hover.overlay.hitTest(NSPoint(x: 5, y: 5)), "it never takes a click")
        XCTAssertTrue(hover.overlay.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.mouseEnteredAndExited) },
                      "tracking: moves, enter, exit")
        _ = bar
        let points = itemPoints(hover)
        // Default items: nav (2), Show in Browser, zoom, rotate (2), rating, flag, share, edit, trash,
        // histogram, full screen, inspector.
        XCTAssertGreaterThanOrEqual(points.count, 14, points.map(\.id).joined(separator: ", "))
        for (id, point) in points {
            hover.pointerLeft()
            XCTAssertEqual(platterAlpha(hover, at: point), 0, accuracy: 0.001, "\(id): nothing before the pointer")
            hover.pointerMoved(to: point)
            XCTAssertNotNil(hover.target, "\(id): the pointer is on an item")
            XCTAssertEqual(hover.platterAlphaForTesting, ToolbarHover.darkAlpha, accuracy: 0.01, "\(id): white 14 % (dark)")
            XCTAssertEqual(platterAlpha(hover, at: point), ToolbarHover.darkAlpha, accuracy: 0.02, "\(id): drawn on the item")
            hover.pointerLeft()
            XCTAssertNil(hover.target, "\(id): gone with the pointer")
            XCTAssertEqual(platterAlpha(hover, at: point), 0, accuracy: 0.001, "\(id): not drawn after")
        }
    }

    func testLightToolbarGetsABlackPlatterAndAGapGetsNone() throws {
        guard ToolbarHover.isNeeded else { throw XCTSkip("macOS 26 draws it") }
        _ = makeViewerWindow(.aqua)
        let hover = try XCTUnwrap(self.hover)
        let (_, point) = try XCTUnwrap(itemPoints(hover).first)
        hover.pointerMoved(to: point)
        XCTAssertEqual(hover.platterAlphaForTesting, ToolbarHover.lightAlpha, accuracy: 0.01)
        XCTAssertEqual(platterAlpha(hover, at: point), ToolbarHover.lightAlpha, accuracy: 0.02)
        hover.pointerMoved(to: NSPoint(x: 1, y: 1))
        XCTAssertNil(hover.target, "a gap shows no platter")
    }

    func testTheBrowserToolbarHasTheSameHover() async throws {
        guard ToolbarHover.isNeeded else { throw XCTSkip("macOS 26 draws it") }
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-hovertb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let w = try XCTUnwrap(browser.window)
        w.setContentSize(NSSize(width: 1400, height: 800))
        settle(w)
        let hover = try XCTUnwrap(browser.toolbarHover)
        XCTAssertTrue(hover.attach())
        settle(w)
        let points = itemPoints(hover)
        // Back / Forward (2), view mode (3), Sort, Filter, Inspector at least.
        XCTAssertGreaterThanOrEqual(points.count, 6, points.map(\.id).joined(separator: ", "))
        var shown = 0
        for (id, point) in points {
            hover.pointerLeft()
            hover.pointerMoved(to: point)
            // Back / Forward are off in an empty history.
            guard hover.target != nil else { continue }
            shown += 1
            XCTAssertEqual(platterAlpha(hover, at: point), hover.platterAlphaForTesting, accuracy: 0.02, "\(id)")
            XCTAssertGreaterThan(hover.platterAlphaForTesting, 0.05, "\(id): visible")
        }
        XCTAssertGreaterThanOrEqual(shown, 5, "most browser items hover")
        hover.pointerLeft()
    }
}

//
//  ViewerEditRailWindowTests.swift
//  ShrikeUITests
//
//  A new windowed viewer shows no
//  edit rail and draws no pin glyph anywhere; View › Show Edit Rail
//  (⇧⌘E) shows and hides the rail in a window and carries a check mark.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerEditRailWindowTests: XCTestCase {

    private var dir: URL!
    private let keys = [
        "shrike.viewer.editRail.visibleInWindowed",
        "shrike.viewer.editRail.pinnedFullscreen",
    ]

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-rail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for key in keys { ShrikeDefaults.store.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        for key in keys { ShrikeDefaults.store.removeObject(forKey: key) }
    }

    private func services() throws -> ShrikeServices {
        let support = dir.appendingPathComponent(".support", isDirectory: true)
        let thumbs = try ThumbnailCache(diskURL: support.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: support.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String) throws -> URL {
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func pins(in view: NSView) -> [PinCornerOverlay] {
        var out: [PinCornerOverlay] = []
        if let pin = view as? PinCornerOverlay { out.append(pin) }
        for sub in view.subviews { out += pins(in: sub) }
        return out
    }

    private func makeViewer() throws -> ViewerWindow {
        let url = try writeJPEG("a.jpg")
        let window = ViewerWindow(imageSources: [FileImageSource(url: url)], startIndex: 0, services: try services())
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    func testNewWindowedViewerShowsTheRailWithNoPinGlyph() throws {
        // The rail is on by default; a window has no pin.
        Prefs.editRailPinnedFullscreen = true
        let window = try makeViewer()
        defer { window.close() }
        let root = window.contentRootForTesting
        root.animatesPanelFades = false
        root.simulateFirstFrameForTesting()
        XCTAssertEqual(root.windowMode, .windowed)
        XCTAssertFalse(root.editRailForTesting.isHidden, "the rail shows in a new window (default on)")
        XCTAssertFalse(root.editRailForTesting.pinGlyphShownForTesting)
        let visiblePins = pins(in: try XCTUnwrap(window.contentView)).filter { !$0.isHiddenOrHasHiddenAncestor }
        XCTAssertTrue(visiblePins.isEmpty, "no pin glyph is drawn in a window: \(visiblePins)")
        XCTAssertEqual(window.panelMenuTitle(.toggleEditRail), "Hide Edit Rail")
    }

    func testShowEditRailTogglesTheRailInAWindowWithACheckMark() throws {
        let window = try makeViewer()
        defer { window.close() }
        let root = window.contentRootForTesting
        root.animatesPanelFades = false
        Prefs.editRailVisibleInWindowed = false
        root.simulateFirstFrameForTesting()
        XCTAssertTrue(root.editRailForTesting.isHidden)
        XCTAssertEqual(window.panelMenuTitle(.toggleEditRail), "Show Edit Rail")
        XCTAssertTrue(window.canPerform(.toggleEditRail))

        window.perform(.toggleEditRail)
        XCTAssertTrue(Prefs.editRailVisibleInWindowed)
        XCTAssertFalse(root.editRailForTesting.isHidden, "⇧⌘E shows the rail")
        XCTAssertEqual(window.panelMenuTitle(.toggleEditRail), "Hide Edit Rail")
        XCTAssertFalse(root.editRailForTesting.pinGlyphShownForTesting, "still no pin in a window")
        XCTAssertFalse(Prefs.editRailPinnedFullscreen, "the full-screen pin is not touched")

        // No hover logic in a window: moving off the rail keeps it.
        root.evaluateZonesForTesting(at: NSPoint(x: 450, y: 300))
        XCTAssertFalse(root.editRailForTesting.isHidden)

        window.perform(.toggleEditRail)
        XCTAssertFalse(Prefs.editRailVisibleInWindowed)
        XCTAssertTrue(root.editRailForTesting.isHidden, "⇧⌘E hides it again")
        XCTAssertEqual(window.panelMenuTitle(.toggleEditRail), "Show Edit Rail")
    }

    // Rail inventory, with Levels after Color.
    func testRailInventoryIsCropRotateResizeColorLevels() {
        let rail = EditRail()
        XCTAssertEqual(rail.buttonActionsForTesting(),
                       [.crop, .selectEditTool(.rotate), .resize, .colorAdjust, .selectEditTool(.levels)])
        let titles = rail.buttonTitlesForTesting()
        XCTAssertEqual(titles.count, 5)
        XCTAssertTrue(titles[1].hasPrefix("Rotate"), "\(titles)")
        XCTAssertTrue(titles[4].hasPrefix("Levels"), "\(titles)")
    }
}

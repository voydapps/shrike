//
//  EditFitAreaTests.swift
//  ShrikeUITests
//
//  In edit mode
//  the photo fits the canvas minus the side panel, a shown rail and the
//  full-screen capsule, with room for the crop handles on every side, so
//  every handle is on screen and clickable. At rest in a window with
//  auto-hide off, the photo fits below the titlebar/toolbar.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class EditFitAreaTests: XCTestCase {

    private var dir: URL!
    private var saved: (autoHide: Bool, railWindow: Bool, railPinned: Bool, inspector: Bool) = (true, false, false, false)
    /// Half a crop handle (10 pt square).
    private let hs: CGFloat = 5

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-editfit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        saved = (Prefs.viewerToolbarAutoHide, Prefs.editRailVisibleInWindowed,
                 Prefs.editRailPinnedFullscreen, Prefs.viewerInspectorVisibleWindowed)
        Prefs.viewerInspectorVisibleWindowed = false
        MetalImageView.reduceMotionOverrideForTesting = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.viewerToolbarAutoHide = saved.autoHide
        Prefs.editRailVisibleInWindowed = saved.railWindow
        Prefs.editRailPinnedFullscreen = saved.railPinned
        Prefs.viewerInspectorVisibleWindowed = saved.inspector
        MetalImageView.reduceMotionOverrideForTesting = nil
    }

    private func writeJPEG(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 1600, height: 1200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8, _ cond: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A 4:3 photo in a 900 × 640 window: at Fit it is height-limited, so
    /// it reaches the top of whatever area it fits in.
    private func viewer(toolbarShown: Bool = true) async throws -> ViewerWindow {
        let url = writeJPEG("f.jpg")
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0,
                                  services: ShrikeServices(thumbnailCache: thumbs, metadataStore: meta))
        viewer.setContentSize(NSSize(width: 900, height: 640))
        viewer.toolbar?.isVisible = toolbarShown
        let content = viewer.contentRootForTesting
        try await waitUntil("photo") {
            content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        content.layoutSubtreeIfNeeded()
        return viewer
    }

    private func edit(_ viewer: ViewerWindow) async {
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        viewer.contentRootForTesting.layoutSubtreeIfNeeded()
    }

    /// The photo as drawn, in content-view coordinates.
    private func imageRect(_ content: ViewerContentView) -> CGRect {
        content.imageView.convert(content.imageView.drawnImageRect, to: content)
    }

    /// Every crop handle (the full-image frame) clears the panel, the
    /// canvas edges and whatever `bottomLimit` / `topLimit` say.
    private func assertHandlesClear(_ content: ViewerContentView, topLimit: CGFloat, bottomLimit: CGFloat,
                                    leftLimit: CGFloat, _ label: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let r = imageRect(content)
        XCTAssertGreaterThan(r.width, 100, "\(label): the photo is drawn", file: file, line: line)
        let panel = content.editModeController.parameterPanel.frame
        XCTAssertLessThanOrEqual(r.maxX + hs, panel.minX + 0.5,
                                 "\(label): the right handles clear the side panel", file: file, line: line)
        XCTAssertLessThanOrEqual(r.maxY + hs, topLimit + 0.5,
                                 "\(label): the top handles are visible", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minY - hs, bottomLimit - 0.5,
                                    "\(label): the bottom handles are visible", file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.minX - hs, leftLimit - 0.5,
                                    "\(label): the left handles are visible", file: file, line: line)
        // The crop frame sits on the drawn photo.
        let overlay = content.editModeController.cropOverlay
        let frameInContent = overlay.convert(overlay.imageFrame, to: content)
        XCTAssertEqual(frameInContent.minX, r.minX, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(frameInContent.maxY, r.maxY, accuracy: 0.5, file: file, line: line)
    }

    /// The side panel ends above the docked filmstrip; without
    /// it the panel keeps its 32 pt bottom margin.
    func testEditPanelEndsAboveTheDockedFilmstrip() async throws {
        let savedFilmstrip = Prefs.filmstripVisibleInWindowed
        defer { Prefs.filmstripVisibleInWindowed = savedFilmstrip }
        for docked in [true, false] {
            Prefs.filmstripVisibleInWindowed = docked
            let viewer = try await viewer()
            let content = viewer.contentRootForTesting
            await edit(viewer)
            let panel = content.editModeController.parameterPanel.frame
            let strip = content.filmstripForTesting
            // Edit mode hides the docked strip, so the panel
            // keeps its 32 pt bottom margin whether the strip is on or off.
            XCTAssertTrue(strip.isHidden || strip.frame.height < 1,
                          "docked=\(docked): no filmstrip in edit mode")
            XCTAssertEqual(panel.minY, 32, accuracy: 0.5, "no strip: 32 pt from the bottom")
            XCTAssertGreaterThan(panel.height, 200, "the panel still has room")
            content.editModeController.finalizeExit()
            viewer.close()
        }
    }

    /// Pixel sizes are plain integers ("3456", never "3.456").
    func testCropAndResizeFieldsShowPlainIntegers() {
        let crop = CropPanel()
        crop.setDimensions(width: 3456, height: 5184)
        XCTAssertEqual(crop._widthField.stringValue, "3456")
        XCTAssertEqual(crop._heightField.stringValue, "5184")
        let resize = ResizePanel()
        resize.sourcePixelSize = CGSize(width: 12000, height: 8000)
        XCTAssertEqual(resize._widthField.stringValue, "12000")
        XCTAssertEqual(resize._heightField.stringValue, "8000")
        XCTAssertEqual(resize.currentSpec()?.width, 12000)
    }

    func testWindowEditFitsClearOfPanelToolbarAndRail() async throws {
        for toolbarShown in [true, false] {
            for rail in [false, true] {
                Prefs.editRailVisibleInWindowed = rail
                let viewer = try await viewer(toolbarShown: toolbarShown)
                let content = viewer.contentRootForTesting
                await edit(viewer)
                let label = "window, toolbar \(toolbarShown ? "shown" : "hidden"), rail \(rail ? "shown" : "hidden")"
                let top = content.convert(NSPoint(x: 0, y: viewer.contentLayoutRect.maxY), from: nil).y
                let iv = content.imageView.frame
                let left = rail ? max(iv.minX, content.editRailForTesting.frame.maxX) : iv.minX
                assertHandlesClear(content, topLimit: min(top, iv.maxY), bottomLimit: iv.minY,
                                   leftLimit: left, label)
                content.editModeController.finalizeExit()
                content.layoutSubtreeIfNeeded()
                XCTAssertEqual(content.imageView.fitInsets.right, 0, "\(label): the insets go on exit")
                viewer.close()
            }
        }
    }

    func testFullScreenEditFitsClearOfCapsuleAndScreenEdges() async throws {
        for pinned in [false, true] {
            let viewer = try await viewer()
            let content = viewer.contentRootForTesting
            content.windowMode = .fullscreen
            if content.isEditRailShown != pinned { content.togglePanel(.editRail) }
            XCTAssertEqual(content.isEditRailShown, pinned)
            await edit(viewer)
            let label = "full screen, rail \(pinned ? "pinned" : "hidden")"
            XCTAssertTrue(content.editCapsule.isDescendant(of: content))
            let iv = content.imageView.frame
            let capsule = content.editCapsule.frame
            XCTAssertGreaterThan(capsule.height, 0)
            let left = pinned ? content.editRailForTesting.frame.maxX : iv.minX
            // Top: the screen edge. Bottom: above the capsule.
            assertHandlesClear(content, topLimit: iv.maxY, bottomLimit: capsule.maxY,
                               leftLimit: left, label)
            content.editModeController.finalizeExit()
            content.windowMode = .windowed
            viewer.close()
        }
    }

    /// "Fit rect": auto-hide off → the photo fits
    /// `contentLayoutRect` (below the toolbar); auto-hide on → the whole
    /// content bounds, so it does not move when the titlebar hides.
    func testRestFitFollowsTheAutoHidePref() async throws {
        Prefs.viewerToolbarAutoHide = false
        for shown in [true, false] {
            let viewer = try await viewer(toolbarShown: shown)
            let content = viewer.contentRootForTesting
            content.needsLayout = true
            content.layoutSubtreeIfNeeded()
            XCTAssertTrue(content.imageView.isAtFit)
            let top = viewer.contentLayoutRect.maxY
            let r = content.imageView.convert(content.imageView.drawnImageRect, to: nil)
            XCTAssertLessThanOrEqual(r.maxY, top + 0.5, "auto-hide off, toolbar \(shown): below the titlebar")
            XCTAssertGreaterThan(r.maxY, top - 2, "…and it uses the height it has")
            viewer.close()
        }

        Prefs.viewerToolbarAutoHide = true
        let viewer = try await viewer(toolbarShown: true)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        guard viewer.autoHider?.isActive == true else {
            throw XCTSkip("titlebar container not found on this OS (auto-hide is off)")
        }
        XCTAssertEqual(content.imageView.fitArea, content.imageView.bounds)
        let r = content.imageView.convert(content.imageView.drawnImageRect, to: nil)
        XCTAssertGreaterThan(r.maxY, viewer.contentLayoutRect.maxY + 10, "auto-hide on: the full content bounds")
        // Edit mode fits below the toolbar, and exit gives the whole canvas back.
        await edit(viewer)
        XCTAssertLessThanOrEqual(imageRect(content).maxY + hs,
                                 content.convert(NSPoint(x: 0, y: viewer.contentLayoutRect.maxY), from: nil).y + 0.5)
        content.editModeController.finalizeExit()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.imageView.fitArea, content.imageView.bounds)
    }
}

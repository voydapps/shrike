//
//  CropLaterSessionTests.swift
//  ShrikeUITests
//
//  The crop frame takes the mouse and the keys in EVERY Crop session of a
//  window, not only the first one (seen on screen: after the first
//  session the arrows, Esc, Tab and handle drags did nothing).
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class CropLaterSessionTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        EditExitModal.responderForTesting = { _ in .discard }
        dir = TestScratch.directory
            .appendingPathComponent("shrike-croplater-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
        EditExitModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 8,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func viewer() async throws -> ViewerWindow {
        let urls = (0..<3).map { writeJPEG("c\($0).jpg") }
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: 900, height: 640))
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.canPerform(.editImage) && content.imageView.image != nil
                && !content.imageView.isCurrentImagePlaceholder
        }
        return viewer
    }

    private func key(_ viewer: ViewerWindow, _ chars: String, _ code: UInt16,
                     _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    private func mouse(_ type: NSEvent.EventType, _ viewer: ViewerWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: viewer.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    private func enterCrop(_ viewer: ViewerWindow, _ label: String) async throws {
        let content = viewer.contentRootForTesting
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        await content.editModeController.settleForTesting()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isEditModeActive, label)
        XCTAssertEqual(content.editModeController.currentTool, .crop, label)
        XCTAssertTrue(content.editModeController.cropOverlay.acceptsGeometryInput,
                      "\(label): the frame accepts input on entry")
    }

    /// (i) a handle drag, (ii) Tab to the frame + ⌥←, (iii) Esc, Esc.
    private func checkFrameWorks(_ viewer: ViewerWindow, _ label: String) async throws {
        let content = viewer.contentRootForTesting
        let overlay = content.editModeController.cropOverlay
        XCTAssertFalse(overlay.isHidden, label)
        XCTAssertFalse(overlay.hasKeyboardFocusIndication, "\(label): no focus ring before focus")

        // (i) Drag the bottom-right corner 40 pt up and left.
        let start = overlay.cropRect
        XCTAssertGreaterThan(start.width, 100, label)
        // The events go to the frame itself: in a test process that is not
        // the active app, the window spends the first click on activation.
        let corner = overlay.convert(NSPoint(x: start.maxX, y: start.maxY), to: nil)
        let frameView = try XCTUnwrap(viewer.contentView)
        let hit = frameView.hitTest(frameView.superview?.convert(corner, from: nil) ?? corner)
        XCTAssertTrue(hit === overlay, "\(label): a click on the handle reaches the frame: \(String(describing: hit))")
        overlay.mouseDown(with: try mouse(.leftMouseDown, viewer, at: corner))
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, viewer, at: NSPoint(x: corner.x - 20, y: corner.y + 20)))
        overlay.mouseDragged(with: try mouse(.leftMouseDragged, viewer, at: NSPoint(x: corner.x - 40, y: corner.y + 40)))
        overlay.mouseUp(with: try mouse(.leftMouseUp, viewer, at: NSPoint(x: corner.x - 40, y: corner.y + 40)))
        // The click gave the frame the keyboard; start the key part from a field.
        XCTAssertEqual(overlay.cropRect.minX, start.minX, accuracy: 0.5, "\(label): the top-left stays")
        XCTAssertEqual(overlay.cropRect.width, start.width - 40, accuracy: 0.5, "\(label): the drag resized the frame")
        XCTAssertEqual(overlay.cropRect.height, start.height - 40, accuracy: 0.5, "\(label): the drag resized the frame")

        // (ii) From the last panel field ONE Tab reaches the frame; ⌥← shrinks it.
        let heightField = try XCTUnwrap(EditNavigationTests.textField(
            labelled: "Crop height, pixels", in: content.editModeController.parameterPanel), label)
        XCTAssertTrue(viewer.makeFirstResponder(heightField), label)
        viewer.sendEvent(try key(viewer, "\t", 48))
        XCTAssertTrue(viewer.firstResponder === overlay, "\(label): Tab reached the frame: \(String(describing: viewer.firstResponder))")
        XCTAssertTrue(overlay.hasKeyboardFocusIndication, "\(label): the frame shows its focus ring")
        let before = try XCTUnwrap(overlay.integralPixelRect)
        viewer.sendEvent(try key(viewer, SpecialKey.left, 123, [.option, .function, .numericPad]))
        let after = try XCTUnwrap(overlay.integralPixelRect)
        XCTAssertEqual(after.width, before.width - 1, "\(label): ⌥← shrank the frame")
        XCTAssertNotEqual(overlay.focusRingType, .none, label)
        XCTAssertEqual(overlay.focusRingMaskBounds, overlay.cropRect.integral.insetBy(dx: -1, dy: -1),
                       "\(label): the ring follows the frame")
        // Tab leaves the frame; Shift-Tab comes back.
        viewer.sendEvent(try key(viewer, "\t", 48))
        XCTAssertFalse(viewer.firstResponder === overlay, "\(label): Tab left the frame")
        viewer.sendEvent(try key(viewer, "\u{19}", 48, .shift))
        XCTAssertTrue(viewer.firstResponder === overlay, "\(label): Shift-Tab came back")

        // (iii) Esc: focus to the photo, still editing; Esc: leaves.
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        XCTAssertTrue(viewer.firstResponder === content.imageView, "\(label): one Esc gives focus to the photo")
        XCTAssertFalse(overlay.hasKeyboardFocusIndication, "\(label): no focus ring after Esc")
        XCTAssertTrue(content.isEditModeActive, label)
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        try await waitUntil("\(label): second Esc left edit mode") { !content.isEditModeActive }
        await viewer.waitForEditExit()
        XCTAssertFalse(viewer.firstResponder === overlay, "\(label): no hidden frame keeps the keyboard")
    }

    func testFrameWorksInEverySessionLeftWithEscEsc() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        for round in 1...3 {
            try await enterCrop(viewer, "session \(round)")
            try await checkFrameWorks(viewer, "session \(round)")
        }
    }

    func testFrameWorksAfterTheToolbarCancel() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        try await enterCrop(viewer, "first")
        content.editModeController.perform(.cancel)   // the toolbar's Cancel
        try await waitUntil("Cancel left edit mode") { !content.isEditModeActive }
        await viewer.waitForEditExit()
        XCTAssertTrue(content.editModeController.cropOverlay.acceptsGeometryInput, "after Cancel")
        try await enterCrop(viewer, "second, same photo")
        try await checkFrameWorks(viewer, "second, same photo")
    }

    func testFrameWorksAfterNextPhoto() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        try await enterCrop(viewer, "first")
        try await checkFrameWorks(viewer, "first")
        viewer.perform(.nextImage)
        try await waitUntil("next photo") {
            viewer.displayedItem?.listIndex == 1 && content.imageView.image != nil
                && !content.imageView.isCurrentImagePlaceholder && viewer.canPerform(.editImage)
        }
        try await enterCrop(viewer, "next photo")
        try await checkFrameWorks(viewer, "next photo")
    }

    /// A frame that has the keyboard when it is hidden gives it back.
    func testHiddenFrameNeverKeepsTheKeyboard() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let overlay = content.editModeController.cropOverlay
        try await enterCrop(viewer, "Cancel")
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        content.editModeController.perform(.cancel)
        try await waitUntil("Cancel left edit mode") { !content.isEditModeActive }
        XCTAssertFalse(viewer.firstResponder === overlay, "after Cancel")
        try await enterCrop(viewer, "tool switch")
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        content.editModeController.selectTool(.rotate)
        try await waitUntil("on Rotate") { content.editModeController.currentTool == .rotate }
        XCTAssertFalse(viewer.firstResponder === overlay, "after Crop → Rotate")
        // While input is off (a save or a question), Tab and Esc still work.
        content.editModeController.selectTool(.crop)
        try await waitUntil("back on Crop") { content.editModeController.currentTool == .crop }
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        overlay.acceptsGeometryInput = false
        viewer.sendEvent(try key(viewer, "\t", 48))
        XCTAssertFalse(viewer.firstResponder === overlay, "Tab leaves a frame whose input is off")
        overlay.acceptsGeometryInput = true
    }

    /// Esc Esc with a change asks; Don't Save leaves; the next session works.
    func testDirtySessionAsksThenTheNextSessionWorks() async throws {
        var asked = 0
        EditExitModal.responderForTesting = { _ in asked += 1; return .discard }
        let viewer = try await viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        try await enterCrop(viewer, "dirty")
        content.editModeController.appendSnapped90(quarters: 1)
        await content.editModeController.settleForTesting()
        content.layoutSubtreeIfNeeded()
        viewer.makeFirstResponder(content.editModeController.cropOverlay)
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        try await waitUntil("Don't Save left edit mode") { !content.isEditModeActive }
        await viewer.waitForEditExit()
        XCTAssertEqual(asked, 1, "the unsaved-changes question was asked")
        try await enterCrop(viewer, "after Don't Save")
        try await checkFrameWorks(viewer, "after Don't Save")
    }

    func testCropRotateCropInOneSession() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        // A first session left through Esc Esc, then Crop → Rotate (with a change) → Crop.
        try await enterCrop(viewer, "first")
        try await checkFrameWorks(viewer, "first")
        try await enterCrop(viewer, "second")
        content.editModeController.selectTool(.rotate)
        await content.editModeController.settleForTesting()
        content.editModeController.appendSnapped90(quarters: 1)
        await content.editModeController.settleForTesting()
        content.editModeController.selectTool(.crop)
        try await waitUntil("back on Crop") {
            content.editModeController.currentTool == .crop && !content.editModeController.isTransitioning
        }
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.editModeController.cropOverlay.acceptsGeometryInput)
        try await checkFrameWorks(viewer, "Crop after Rotate")
    }
}

//
//  EditNavigationTests.swift
//  ShrikeUITests
//
//  In edit mode every way of
//  leaving the photo (→ ← Space ⇧Space Home End Page Up/Down, a
//  filmstrip click) goes through the exit alert when there are changes,
//  then does the navigation that was asked. Cancel stays, still editing.
//  With no change it leaves edit mode and moves at once.
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
final class EditNavigationTests: XCTestCase {

    private var dir: URL!
    private var asked = 0

    override func setUp() async throws {
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        dir = TestScratch.directory
            .appendingPathComponent("shrike-editnav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        asked = 0
    }

    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
        EditExitModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func answer(_ choice: EditExitModal.Choice) {
        EditExitModal.responderForTesting = { [weak self] _ in
            self?.asked += 1
            return choice
        }
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

    /// Five photos, editing photo `start`; `dirty` adds one rotate.
    private func editingViewer(start: Int = 2, dirty: Bool) async throws -> ViewerWindow {
        let urls = (0..<5).map { writeJPEG("n\($0).jpg") }
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: start, services: services)
        viewer.setContentSize(NSSize(width: 900, height: 640))
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.canPerform(.editImage) && viewer.displayedItem?.listIndex == start
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        viewer.enterEditMode(landOn: .color)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        if dirty {
            content.editModeController.appendSnapped90(quarters: 1)
            await content.editModeController.settleForTesting()
            XCTAssertTrue(content.editModeController.hasPendingEdits)
        }
        return viewer
    }

    private struct KeyCase {
        let name: String
        let key: String
        let mods: NSEvent.ModifierFlags
        let target: Int
    }

    /// From photo 2 of 5.
    private let keyCases: [KeyCase] = [
        KeyCase(name: "→", key: SpecialKey.right, mods: [], target: 3),
        KeyCase(name: "←", key: SpecialKey.left, mods: [], target: 1),
        KeyCase(name: "Space", key: " ", mods: [], target: 3),
        KeyCase(name: "⇧Space", key: " ", mods: .shift, target: 1),
        KeyCase(name: "Home", key: SpecialKey.home, mods: [], target: 0),
        KeyCase(name: "End", key: SpecialKey.end, mods: [], target: 4),
        KeyCase(name: "Page Up", key: SpecialKey.pageUp, mods: [], target: 1),
        KeyCase(name: "Page Down", key: SpecialKey.pageDown, mods: [], target: 3),
    ]

    func testEveryNavigationKeyAsksThenGoesOnAfterDontSave() async throws {
        for c in keyCases {
            let viewer = try await editingViewer(dirty: true)
            answer(.discard)
            XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: c.key, modifiers: c.mods)),
                          "\(c.name) is handled in edit mode")
            await viewer.waitForEditExit()
            XCTAssertEqual(asked, 1, "\(c.name) showed the exit alert")
            XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive, "\(c.name): Don't Save left edit mode")
            try await waitUntil("\(c.name) went to \(c.target)") { viewer.displayedItem?.listIndex == c.target }
            viewer.close()
            asked = 0
        }
    }

    func testCancelStaysOnThePhotoStillEditing() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.cancel)
        for c in keyCases {
            XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: c.key, modifiers: c.mods)))
            await viewer.waitForEditExit()
        }
        XCTAssertEqual(asked, keyCases.count, "every key asked")
        for _ in 0..<3 {
            await withCheckedContinuation { cont in DispatchQueue.main.async { cont.resume() } }
            for _ in 0..<20 { await Task.yield() }
        }   // everything already queued on the main queue / actor has run
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2, "Cancel stays on the photo")
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive, "Cancel keeps editing")
        XCTAssertTrue(viewer.contentRootForTesting.editModeController.hasPendingEdits)
    }

    func testNoChangesLeavesAndMovesAtOnce() async throws {
        for c in [keyCases[0], keyCases[3], keyCases[5]] {
            let viewer = try await editingViewer(dirty: false)
            answer(.cancel)
            XCTAssertTrue(viewer.handleKeySnapshot(KeyEventSnapshot(key: c.key, modifiers: c.mods)))
            await viewer.waitForEditExit()
            XCTAssertEqual(asked, 0, "\(c.name): nothing to lose, no alert")
            try await waitUntil("\(c.name) moved") { viewer.displayedItem?.listIndex == c.target }
            // Spec 25 §3.3: edit mode starts again on the new photo, with no tool.
            try await waitUntil("\(c.name) editing again") { viewer.contentRootForTesting.isEditModeActive }
            XCTAssertNil(viewer.contentRootForTesting.editModeController.currentTool, c.name)
            viewer.close()
        }
    }

    /// Edit mode hides the filmstrip, so no filmstrip click
    /// can leave the photo. The old "click asks, then goes" path is gone.
    func testWindowFilmstripStaysInEditMode() async throws {
        let stripWas = Prefs.filmstripVisibleInWindowed
        Prefs.filmstripVisibleInWindowed = true
        defer { Prefs.filmstripVisibleInWindowed = stripWas }
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        viewer.contentView?.layoutSubtreeIfNeeded()
        let strip = viewer.contentRootForTesting.filmstripForTesting
        XCTAssertFalse(strip.isHidden, "the window keeps its docked strip in edit mode (spec 25 §3.3)")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2)
    }

    func testWindowedEditingFilmstripNavigationResumesEditingOnTheTarget() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        answer(.cancel)
        viewer.contentRootForTesting.onFilmstripJump?(3)
        await viewer.waitForEditExit()
        try await waitUntil("windowed filmstrip target settled") {
            viewer.navCoalescer.isIdle && viewer.displayedItem?.listIndex == 3
        }
        await viewer.waitForEditReentryForTesting()
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertNil(viewer.contentRootForTesting.editModeController.currentTool)
        XCTAssertEqual(viewer.contentRootForTesting.editModeController.sourceURL, viewer.displayedItem?.group.primary)
    }

    func testFullscreenNavigationDoesNotRequestWindowedEditReentry() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.windowMode = .fullscreen
        answer(.cancel)
        // A synthetic callback exercises the existing fullscreen policy;
        // actual fullscreen editing does not expose the filmstrip.
        content.onFilmstripJump?(3)
        await viewer.waitForEditExit()
        try await waitUntil("fullscreen target settled") {
            viewer.navCoalescer.isIdle && viewer.displayedItem?.listIndex == 3
        }
        await viewer.waitForEditReentryForTesting()
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(content.isEditModeActive)
    }

    /// With keyboard focus on the crop frame, → nudges it and
    /// does not leave the photo.
    func testArrowNudgesTheCropFrameWhenItHasFocus() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.editModeController.selectTool(.crop)
        await content.editModeController.settleForTesting()
        content.layoutSubtreeIfNeeded()
        let overlay = content.editModeController.cropOverlay
        XCTAssertFalse(overlay.isHidden)
        let px = overlay.imagePixelSize
        overlay.setRectFromImageSpace(CGRect(x: px.width * 0.2, y: px.height * 0.2,
                                             width: px.width * 0.5, height: px.height * 0.5))
        let before = overlay.cropRect
        answer(.discard)
        viewer.makeFirstResponder(overlay)
        let right = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, characters: SpecialKey.right,
            charactersIgnoringModifiers: SpecialKey.right, isARepeat: false, keyCode: 124))
        overlay.keyDown(with: right)
        XCTAssertEqual(overlay.cropRect.minX, before.minX + 1, accuracy: 0.01, "→ nudged the frame 1 px")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2)
    }

    static func textField(labelled label: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == label { return field }
        for sub in view.subviews { if let found = textField(labelled: label, in: sub) { return found } }
        return nil
    }

    private func key(_ viewer: ViewerWindow, _ chars: String, _ code: UInt16,
                     _ mods: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0,
            windowNumber: viewer.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
    }

    /// Spec 28 §15 through the real responder chain (`ViewerWindow.sendEvent`):
    /// with focus on the crop frame the arrows move the frame and never change
    /// photos; Tab reaches the panel fields and comes back; one Esc gives the
    /// keyboard back to the photo, a second Esc leaves edit mode as before.
    func testCropFrameKeysThroughTheWindow() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.editModeController.selectTool(.crop)
        await content.editModeController.settleForTesting()
        content.layoutSubtreeIfNeeded()
        let overlay = content.editModeController.cropOverlay
        let px = overlay.imagePixelSize
        overlay.setRectFromImageSpace(CGRect(x: px.width * 0.2, y: px.height * 0.2,
                                             width: px.width * 0.5, height: px.height * 0.5))
        answer(.discard)
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        let before = try XCTUnwrap(overlay.integralPixelRect)
        viewer.sendEvent(try key(viewer, SpecialKey.right, 124))
        viewer.sendEvent(try key(viewer, SpecialKey.down, 125))
        let moved = try XCTUnwrap(overlay.integralPixelRect)
        XCTAssertEqual(moved.minX, before.minX + 1, "→ moved the frame 1 image pixel")
        XCTAssertEqual(moved.minY, before.minY + 1, "↓ moved the frame 1 image pixel")
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2, "the arrows did not change photos")
        XCTAssertTrue(viewer.firstResponder === overlay)

        // Tab: on to a panel field, and Shift-Tab back to the frame.
        viewer.sendEvent(try key(viewer, "\t", 48))
        let afterTab = viewer.firstResponder
        XCTAssertFalse(afterTab === overlay, "Tab left the frame")
        let fieldEditor = (afterTab as? NSText)?.isFieldEditor == true || afterTab is NSTextField
        XCTAssertTrue(fieldEditor, "Tab reached a panel field: \(String(describing: afterTab))")
        viewer.sendEvent(try key(viewer, "\u{19}", 48, .shift))
        XCTAssertTrue(viewer.firstResponder === overlay, "Shift-Tab came back to the frame: \(String(describing: viewer.firstResponder))")

        // §15 (28a round 5, FAIL 2): from the last field (H) ONE Tab reaches the
        // frame (not the filmstrip); Shift-Tab goes back into H.
        let heightField = try XCTUnwrap(Self.textField(labelled: "Crop height, pixels",
                                                       in: content.editModeController.parameterPanel))
        XCTAssertTrue(viewer.makeFirstResponder(heightField))
        viewer.sendEvent(try key(viewer, "\t", 48))
        XCTAssertTrue(viewer.firstResponder === overlay, "Tab from H reached the frame: \(String(describing: viewer.firstResponder))")
        viewer.sendEvent(try key(viewer, "\u{19}", 48, .shift))
        let backInH = (viewer.firstResponder as? NSText)?.delegate as? NSTextField
        XCTAssertTrue(backInH === heightField, "Shift-Tab from the frame went back to H: \(String(describing: viewer.firstResponder))")
        viewer.sendEvent(try key(viewer, "\t", 48))
        XCTAssertTrue(viewer.firstResponder === overlay)

        // Esc once: focus back to the photo, still editing.
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        XCTAssertTrue(viewer.firstResponder === content.imageView, "one Esc gives focus to the photo")
        XCTAssertTrue(content.isEditModeActive)
        // Now the arrows change photos again (edits are discarded by `answer`).
        // Esc twice: leaves edit mode as before.
        viewer.sendEvent(try key(viewer, "\u{1b}", 53))
        try await waitUntil("left edit mode") { !content.isEditModeActive }
    }

    /// 28a round 4 (a): ⌃⌥ + arrows through the window pull the top-left corner (§15).
    func testControlOptionArrowsPullTheTopLeftCornerThroughTheWindow() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.editModeController.selectTool(.crop)
        await content.editModeController.settleForTesting()
        content.layoutSubtreeIfNeeded()
        let overlay = content.editModeController.cropOverlay
        let px = overlay.imagePixelSize
        overlay.setRectFromImageSpace(CGRect(x: px.width * 0.2, y: px.height * 0.2,
                                             width: px.width * 0.5, height: px.height * 0.5))
        answer(.discard)
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        let mods: NSEvent.ModifierFlags = [.control, .option, .function, .numericPad]
        let start = try XCTUnwrap(overlay.integralPixelRect)
        viewer.sendEvent(try key(viewer, SpecialKey.left, 123, mods))
        var r = try XCTUnwrap(overlay.integralPixelRect)
        // As ⌥ (← / ↑ shrink, → / ↓ grow) with the top-left corner pulling (§15 table).
        XCTAssertEqual(r.minX, start.minX + 1, "⌃⌥← shrinks the width from the left")
        XCTAssertEqual(r.maxX, start.maxX, "the right edge stays")
        viewer.sendEvent(try key(viewer, SpecialKey.up, 126, mods))
        r = try XCTUnwrap(overlay.integralPixelRect)
        XCTAssertEqual(r.minY, start.minY + 1, "⌃⌥↑ shrinks the height from the top")
        XCTAssertEqual(r.maxY, start.maxY)
        viewer.sendEvent(try key(viewer, SpecialKey.right, 124, mods))
        viewer.sendEvent(try key(viewer, SpecialKey.down, 125, mods))
        r = try XCTUnwrap(overlay.integralPixelRect)
        XCTAssertEqual(r, start, "⌃⌥→ / ⌃⌥↓ grow from the top-left back")
        XCTAssertEqual(viewer.displayedItem?.listIndex, 2)
    }
}

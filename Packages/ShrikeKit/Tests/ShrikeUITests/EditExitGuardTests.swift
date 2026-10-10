//
//  EditExitGuardTests.swift
//  ShrikeUITests
//
//  Unsaved edits are never lost silently. Closing
//  the window (⌘W, close button, Window ▸ Close all go through
//  `windowShouldClose`) and navigating away (keys / Go menu / filmstrip)
//  while editing show the edit exit alert. Save / Don't Save go on;
//  Cancel keeps editing.
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
final class EditExitGuardTests: XCTestCase {

    private var dir: URL!
    private var asked: [EditExitModal.Content] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-editguard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        asked = []
    }

    override func tearDown() async throws {
        EditExitModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func answer(_ choice: EditExitModal.Choice) {
        EditExitModal.responderForTesting = { [weak self] content in
            self?.asked.append(content)
            return choice
        }
    }

    private func writeJPEG(_ name: String, width: Int = 320, height: Int = 200) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

    /// A viewer on three photos, in edit mode on the first. `dirty` adds
    /// one rotate so leaving has something to lose.
    private func editingViewer(dirty: Bool) async throws -> ViewerWindow {
        let urls = (0..<3).map { writeJPEG("p\($0).jpg") }
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: 800, height: 600))
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.displayedItem?.listIndex == 0
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        if dirty {
            content.editModeController.appendSnapped90(quarters: 1)
            await content.editModeController.settleForTesting()
            XCTAssertTrue(content.editModeController.hasPendingEdits)
        }
        return viewer
    }

    // MARK: Close

    func testCloseWhileEditingAsksAndCancelKeepsTheWindow() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.cancel)
        XCTAssertFalse(viewer.delegate?.windowShouldClose?(viewer) ?? true,
                       "the window stays while the alert decides")
        await viewer.waitForEditExit()
        XCTAssertEqual(asked.map(\.buttons), [["Save", "Cancel", "Don't Save"]])
        XCTAssertFalse(viewer.didTearDown)
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive, "Cancel keeps editing")
        XCTAssertTrue(viewer.contentRootForTesting.editModeController.hasPendingEdits)
    }

    func testCloseWhileEditingDontSaveCloses() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.discard)
        XCTAssertFalse(viewer.delegate?.windowShouldClose?(viewer) ?? true)
        await viewer.waitForEditExit()
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(viewer.didTearDown, "Don't Save closes the window")
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
    }

    func testCloseWhileEditingSaveWritesTheFileThenCloses() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        let url = try XCTUnwrap(viewer.displayedItem?.group.primary)
        answer(.save)
        XCTAssertFalse(viewer.delegate?.windowShouldClose?(viewer) ?? true)
        await viewer.waitForEditExit()
        XCTAssertTrue(viewer.didTearDown, "a successful Save closes the window")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 200, "the rotate was written")
    }

    func testCloseWithoutEditModeClosesAtOnce() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        viewer.contentRootForTesting.editModeController.attemptExit(reason: .userToggled)
        try await waitUntil("left edit mode") { !viewer.contentRootForTesting.isEditModeActive }
        answer(.cancel)
        XCTAssertTrue(viewer.delegate?.windowShouldClose?(viewer) ?? false)
        XCTAssertTrue(asked.isEmpty)
    }

    func testCloseWhileEditingWithNoChangesClosesWithoutAsking() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        answer(.cancel)
        _ = viewer.delegate?.windowShouldClose?(viewer)
        await viewer.waitForEditExit()
        XCTAssertTrue(asked.isEmpty, "nothing to lose, no alert")
        XCTAssertTrue(viewer.didTearDown)
    }

    // MARK: Navigate

    func testNextPhotoWhileEditingAsksAndCancelStays() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.cancel)
        viewer.dispatch(.nextImage)
        await viewer.waitForEditExit()
        XCTAssertEqual(asked.count, 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0, "Cancel stays on the photo")
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
    }

    func testNextPhotoWhileEditingDontSaveGoesOn() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.discard)
        viewer.dispatch(.nextImage)
        await viewer.waitForEditExit()
        XCTAssertEqual(asked.count, 1)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        try await waitUntil("next photo") { viewer.displayedItem?.listIndex == 1 }
    }

    func testGoMenuLastAndFilmstripClickAsk() async throws {
        let viewer = try await editingViewer(dirty: true)
        defer { viewer.close() }
        answer(.cancel)
        viewer.dispatch(.lastImage)
        await viewer.waitForEditExit()
        viewer.contentRootForTesting.onFilmstripJump?(2)
        await viewer.waitForEditExit()
        XCTAssertEqual(asked.count, 2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(viewer.displayedItem?.listIndex, 0)

        answer(.discard)
        viewer.contentRootForTesting.onFilmstripJump?(2)
        await viewer.waitForEditExit()
        try await waitUntil("filmstrip target") { viewer.displayedItem?.listIndex == 2 }
    }

    func testNextPhotoWhileEditingWithNoChangesGoesWithoutAsking() async throws {
        let viewer = try await editingViewer(dirty: false)
        defer { viewer.close() }
        answer(.cancel)
        viewer.dispatch(.nextImage)
        await viewer.waitForEditExit()
        XCTAssertTrue(asked.isEmpty)
        try await waitUntil("next photo") { viewer.displayedItem?.listIndex == 1 }
    }

    // MARK: Alert keys

    func testAlertButtonsAndKeysFollowTheSpec() {
        let alert = EditExitModal.makeAlert(EditExitModal.content(fileName: "a.jpg", writable: true))
        XCTAssertEqual(alert.buttons.map(\.title), ["Save", "Cancel", "Don't Save"])
        XCTAssertEqual(alert.buttons[0].keyEquivalent, "\r", "Save is the default (Return)")
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}", "Cancel takes Esc")
        XCTAssertEqual(alert.buttons[2].keyEquivalent, "d")
        XCTAssertEqual(alert.buttons[2].keyEquivalentModifierMask, [.command], "Don't Save is ⌘D")
    }
}

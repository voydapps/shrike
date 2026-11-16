//
//  EditExitCommandTests.swift
//  ShrikeUITests
//
//  The command way to leave edit mode (`viewer.perform(.exitEditMode)`,
//  the path of a menu item or a custom shortcut) works in every state, the
//  same as Esc and the toolbar's Cancel.
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
final class EditExitCommandTests: XCTestCase {

    private var dir: URL!
    private var questions = 0

    override func setUp() async throws {
        questions = 0
        EditToolTransitionModal.responderForTesting = { _ in .discard }
        EditExitModal.responderForTesting = { [weak self] _ in self?.questions += 1; return .discard }
        dir = TestScratch.directory
            .appendingPathComponent("shrike-editexit-\(UUID().uuidString)", isDirectory: true)
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
        let urls = (0..<2).map { writeJPEG("e\($0).jpg") }
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

    private func enterCrop(_ viewer: ViewerWindow) async {
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        await viewer.contentRootForTesting.editModeController.settleForTesting()
        viewer.contentRootForTesting.layoutSubtreeIfNeeded()
    }

    private func leaveByCommand(_ viewer: ViewerWindow, _ label: String) async throws {
        let content = viewer.contentRootForTesting
        XCTAssertTrue(content.isEditModeActive, label)
        XCTAssertTrue(viewer.canPerform(.exitEditMode), "\(label): the command is enabled in edit mode")
        viewer.perform(.exitEditMode)
        try await waitUntil("\(label): the command left edit mode") { !content.isEditModeActive }
        await viewer.waitForEditExit()
        XCTAssertFalse(viewer.canPerform(.exitEditMode), "\(label): nothing to leave afterwards")
    }

    func testNoChanges() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        await enterCrop(viewer)
        try await leaveByCommand(viewer, "no changes")
        XCTAssertEqual(questions, 0, "nothing to lose: no question")
    }

    func testPendingChangesAskFirst() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let controller = viewer.contentRootForTesting.editModeController
        await enterCrop(viewer)
        viewer.dispatch(.editRotate90(quarters: 1))
        await controller.settleForTesting()
        try await leaveByCommand(viewer, "pending changes")
        XCTAssertEqual(questions, 1, "the unsaved-edits question was asked once")
    }

    func testRightAfterEntering() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        viewer.enterEditMode(landOn: .crop)
        let content = viewer.contentRootForTesting
        try await waitUntil("edit mode on") { content.isEditModeActive }
        viewer.perform(.exitEditMode)
        try await waitUntil("left right after entering") { !content.isEditModeActive }
        await viewer.waitForEditExit()
    }

    func testWithTheCropFrameFocused() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        await enterCrop(viewer)
        let overlay = viewer.contentRootForTesting.editModeController.cropOverlay
        XCTAssertTrue(viewer.makeFirstResponder(overlay))
        try await leaveByCommand(viewer, "crop frame focused")
        XCTAssertFalse(viewer.firstResponder === overlay)
        // The next session's frame takes input again.
        await enterCrop(viewer)
        XCTAssertTrue(viewer.contentRootForTesting.editModeController.cropOverlay.acceptsGeometryInput)
        try await leaveByCommand(viewer, "second session")
    }

    func testInFullScreen() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        let center = NotificationCenter.default
        center.post(name: NSWindow.willEnterFullScreenNotification, object: viewer)
        viewer.fullScreenTransition.animate(viewer, to: NSRect(x: 0, y: 0, width: 1512, height: 982), duration: 0)
        center.post(name: NSWindow.didEnterFullScreenNotification, object: viewer)
        viewer.contentRootForTesting.layoutSubtreeIfNeeded()
        XCTAssertEqual(viewer.contentRootForTesting.windowMode, .fullscreen)
        await enterCrop(viewer)
        try await leaveByCommand(viewer, "full screen")
    }

    /// Done by command (Return's command) applies and leaves, as the key does.
    func testDoneCommandIsEnabledInEditModeOnly() async throws {
        let viewer = try await viewer()
        defer { viewer.close() }
        XCTAssertFalse(viewer.canPerform(.editDone))
        await enterCrop(viewer)
        XCTAssertTrue(viewer.canPerform(.editDone))
        try await leaveByCommand(viewer, "after Done check")
    }
}

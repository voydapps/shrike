//
//  InfoBackupRowRefreshTests.swift
//  ShrikeUITests
//
//  The viewer's Info "Original backup available" row follows the file after
//  an Undo or Redo of a write (here a rotate), not only after navigation.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class InfoBackupRowRefreshTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-inforow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 320, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testBackupRowFollowsUndoAndRedoOfARotate() async throws {
        let url = writeJPEG("i1.jpg")
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        let panel = viewer.contentRootForTesting.inspectorPanel
        let shown = await waitUntil { viewer.canPerform(.rotateRight) && viewer.displayedItem != nil }
        XCTAssertTrue(shown)
        func available() -> Bool { panel.viewModel.originalKeptSince?.hasPrefix("Original backup available") == true }
        XCTAssertFalse(available())

        viewer.perform(.rotateRight)
        viewer.flushPendingOrientation()
        await viewer.waitForOrientationWrites()
        let afterRotate = await waitUntil { available() && viewer.isDisplayedEdited }
        XCTAssertTrue(afterRotate, "the rotate made a backup: \(String(describing: panel.viewModel.originalKeptSince))")

        viewer.windowUndoManager.undo()
        await viewer.waitForOrientationWrites()
        let afterUndo = await waitUntil { !available() && !viewer.isDisplayedEdited }
        XCTAssertTrue(afterUndo, "after Undo: \(String(describing: panel.viewModel.originalKeptSince)), edited \(viewer.isDisplayedEdited)")
        XCTAssertFalse(viewer.canPerform(.revertToOriginal), "the menu agrees with the Info row")

        viewer.windowUndoManager.redo()
        await viewer.waitForOrientationWrites()
        let afterRedo = await waitUntil { available() && viewer.isDisplayedEdited }
        XCTAssertTrue(afterRedo, "after Redo: \(String(describing: panel.viewModel.originalKeptSince))")
    }
}

//
//  EditExitChangedFileTests.swift
//  ShrikeUITests
//
//  0.2.28 gate D1: leaving edit mode with Don't Save after another app made
//  the photo's file smaller used to crash. The pre-edit image is a lazy
//  CGImage that reads its pixels from the file; the file's pages were gone.
//  Now the pre-edit image is not touched when the file changed: the window
//  decodes the file again.
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
final class EditExitChangedFileTests: XCTestCase {

    private var dir: URL!
    private var savedWatch = true

    override func setUp() async throws {
        savedWatch = ViewerWindow.watchFoldersForTesting
        ViewerWindow.watchFoldersForTesting = false
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        dir = TestScratch.directory
            .appendingPathComponent("shrike-editchanged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ViewerWindow.watchFoldersForTesting = savedWatch
        EditToolTransitionModal.responderForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// A JPEG of random pixels: it compresses badly, so the file is large.
    private func writeJPEG(_ url: URL, width: Int, height: Int, noisy: Bool, quality: Double = 0.95) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if noisy, let data = ctx.data {
            let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * height)
            var generator = SystemRandomNumberGenerator()
            for i in 0..<(ctx.bytesPerRow * height) { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
        } else {
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ label: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out: \(label)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeViewer(_ url: URL) throws -> ViewerWindow {
        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        var services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.setContentSize(NSSize(width: 800, height: 600))
        return viewer
    }

    /// The pre-edit image is lazy and file-backed here (the shown photo is
    /// much larger than its display size). The edit loader is stubbed so the
    /// edit session does not read the file; only the restore could.
    func testDiscardAfterTheFileShrankShowsTheNewFileAndDoesNotCrash() async throws {
        let url = dir.appendingPathComponent("big.jpg")
        writeJPEG(url, width: 3000, height: 2000, noisy: true)
        let bigSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(bigSize, 2_000_000, "the test file must be several MB so its pages can vanish")

        let viewer = try makeViewer(url)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.canPerform(.editImage) && viewer.displayedItem?.listIndex == 0
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        let before = content.imageView.image
        viewer.editSourceLoaderForTesting = { _ in SaveFlowTests.image(width: 300, height: 200) }
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        XCTAssertTrue(content.hasPreEditImageForTesting)
        content.editModeController.appendSnapped90(quarters: 1)
        await content.editModeController.settleForTesting()

        // Another app replaces the file with a much smaller one.
        writeJPEG(url, width: 90, height: 60, noisy: false, quality: 0.3)
        let smallSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        XCTAssertLessThan(smallSize, bigSize / 50)
        XCTAssertTrue(content.preEditFileChangedForTesting)

        content.editModeController.finalizeExit()   // Don't Save
        XCTAssertFalse(content.isEditModeActive)
        XCTAssertFalse(content.hasPreEditImageForTesting)

        try await waitUntil("the new file is shown") {
            guard let shown = content.imageView.image else { return false }
            return shown.width == 90 && shown.height == 60
        }
        XCTAssertFalse(content.imageView.image === before, "the old pre-edit image is not put back")
    }

    func testDiscardOfAnUnchangedFileStillPutsTheSamePhotoBack() async throws {
        let url = dir.appendingPathComponent("same.jpg")
        writeJPEG(url, width: 1600, height: 1000, noisy: true)
        let viewer = try makeViewer(url)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        try await waitUntil("first photo") {
            viewer.canPerform(.editImage) && viewer.displayedItem?.listIndex == 0
                && content.imageView.image != nil && !content.imageView.isCurrentImagePlaceholder
        }
        let before = content.imageView.image
        viewer.editSourceLoaderForTesting = { _ in SaveFlowTests.image(width: 300, height: 200) }
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertFalse(content.preEditFileChangedForTesting)
        content.editModeController.finalizeExit()
        XCTAssertTrue(content.imageView.image === before, "unchanged file: the same image comes back at once")
    }
}

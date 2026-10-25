//
//  RotateSelectionTests.swift
//  ShrikeUITests
//
//  Browser rotates the selection (one undo step), export follows
//  orientation, edit mode waits for the full image, and Discard shows
//  the pre-edit image directly.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeEdit
import ShrikeIO
@testable import ShrikeUI

@MainActor
final class RotateSelectionTests: XCTestCase {

    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("RotateSelectionTests-\(UUID().uuidString)", isDirectory: true)
        let photos = dir.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        store = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var photos: URL { dir.appendingPathComponent("photos", isDirectory: true) }

    private func services() -> ShrikeServices {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        return services
    }

    private func orientation(_ url: URL) -> Int {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return -1 }
        return props[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Raw 16 × 8: left half red, right half blue.
    private static func splitImage() -> CGImage {
        let ctx = CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 8, y: 0, width: 8, height: 8))
        return ctx.makeImage()!
    }

    private static func writeSplit(_ url: URL, orientation: Int) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, splitImage(),
                                   [kCGImagePropertyOrientation: orientation,
                                    kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    // The Browser rotates the whole selection; ⌘Z undoes it in one step.
    func testBrowserRotatesSelectionAsOneUndoStep() async throws {
        let a = photos.appendingPathComponent("a.jpg")
        let b = photos.appendingPathComponent("b.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        try SaveFlowTests.writeImage(b, type: .jpeg)
        let browser = BrowserWindowController(services: services(), initialFolder: photos)
        defer { browser.close() }
        let loaded = await waitUntil { browser.contentController.visibleItems.count == 2 }
        XCTAssertTrue(loaded)
        browser.contentController.selectAll()
        XCTAssertTrue(browser.canPerform(.rotateRight))

        browser.perform(.rotateRight)
        browser.perform(.rotateRight)
        await browser.waitForOrientationWrites()
        XCTAssertEqual(orientation(a), 3, "two presses add up to one 180° write")
        XCTAssertEqual(orientation(b), 3)

        let undo = try XCTUnwrap(browser.window?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Rotate")
        undo.undo()
        await browser.waitForOrientationWrites()
        XCTAssertEqual(orientation(a), 1)
        XCTAssertEqual(orientation(b), 1)
        XCTAssertFalse(undo.canUndo, "one step for the whole selection")
        undo.redo()
        await browser.waitForOrientationWrites()
        XCTAssertEqual(orientation(a), 3)
    }

    // Edit mode waits for the full, upright image; Discard shows the
    // image that was on screen before, with no other frame between.
    func testEditModeUsesFullImageAndDiscardRestoresPreEditImage() async throws {
        let url = photos.appendingPathComponent("p.jpg")
        Self.writeSplit(url, orientation: 6)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services())
        defer { viewer.close() }
        let accepted = await waitUntil { viewer.canPerform(.editImage) }
        XCTAssertTrue(accepted, "the actual photo is accepted before replacing its preview")
        let content = viewer.contentRootForTesting
        let preview = SaveFlowTests.image(width: 2, height: 4)
        content.imageView.setPlaceholderImage(preview, sourceID: FileImageSource(url: url).id)
        XCTAssertTrue(viewer.canPerform(.editImage))

        viewer.enterEditMode(landOn: .resize)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        let source = try XCTUnwrap(content.editModeController.originalImage)
        XCTAssertEqual(source.width, 8, "oriented: the 16 × 8 file shows 8 wide")
        XCTAssertEqual(source.height, 16)

        content.editModeController.appendSnapped90(quarters: 1)
        // Await the write and its render (no polling timeout: flaky
        // under load before).
        await content.editModeController.settleForTesting()
        XCTAssertTrue(content.imageView.image !== preview)
        content.editModeController.finalizeExit()
        XCTAssertTrue(content.imageView.image === preview)
    }

    // A portrait JPEG (Orientation 6), crop the top half,
    // save: the file is upright, holds the top half, Orientation = 1.
    func testExportFollowsOrientation() async throws {
        let url = photos.appendingPathComponent("portrait.jpg")
        Self.writeSplit(url, orientation: 6)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services())
        defer { viewer.close() }
        let accepted = await waitUntil { viewer.canPerform(.editImage) }
        XCTAssertTrue(accepted, "the actual photo is accepted before replacing its preview")
        let content = viewer.contentRootForTesting
        content.imageView.setPlaceholderImage(SaveFlowTests.image(width: 2, height: 4), sourceID: FileImageSource(url: url).id)
        XCTAssertTrue(viewer.canPerform(.editImage))
        viewer.enterEditMode(landOn: .crop)
        await viewer.waitForEditLoad()
        XCTAssertTrue(content.isEditModeActive)
        let recipe = try XCTUnwrap(content.editModeController.recipe)
        let top = CropTool.normalise(rect: CGRect(x: 0, y: 0, width: 8, height: 8), in: CGSize(width: 8, height: 16))
        await recipe.append(.crop(top))

        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertEqual(orientation(url), 1)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 8)
        // The top half of the upright photo is the red one.
        var pixel = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -4, y: -4, width: 8, height: 8))
        XCTAssertGreaterThan(Int(pixel[0]), Int(pixel[2]), "red top half kept, not the blue bottom")
    }
}

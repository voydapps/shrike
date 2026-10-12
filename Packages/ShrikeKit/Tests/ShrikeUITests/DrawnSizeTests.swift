//
//  DrawnSizeTests.swift
//  ShrikeUITests
//
//  Spec 25 §1: every place that shows a size shows the size of the image
//  as drawn right now (rotate, undo, external change).
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO

@MainActor
final class DrawnSizeTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-drawn-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
    }

    override func tearDown() async throws {
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: root)
    }

    private func viewer(_ url: URL) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = SaveFlowTests.image()
        return viewer
    }

    private func settle(_ viewer: ViewerWindow, containing text: String) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if viewer.subtitle.contains(text) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return viewer.subtitle.contains(text)
    }

    // Vector 1: the swap is immediate, survives the write, and a reopened viewer agrees.
    func testRotateSwapsTheDrawnSizeAtOnceAndKeepsItAfterTheWrite() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)   // 16 x 8
        let viewer = viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        let landscape = await settle(viewer, containing: "16 × 8")
        XCTAssertTrue(landscape, viewer.subtitle)

        viewer.dispatch(.rotateRight)
        XCTAssertTrue(viewer.subtitle.contains("8 × 16"), viewer.subtitle)
        XCTAssertEqual(viewer.imageViewForTesting.sourcePixelSize, CGSize(width: 8, height: 16))
        await viewer.waitForOrientationWrites()
        let kept = await settle(viewer, containing: "8 × 16")
        XCTAssertTrue(kept, viewer.subtitle)
        let deadline = Date().addingTimeInterval(3)
        while viewer.imageViewForTesting.sourcePixelSize != CGSize(width: 8, height: 16), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewer.imageViewForTesting.sourcePixelSize, CGSize(width: 8, height: 16))

        let again = self.viewer(url)
        defer { again.close() }
        again.updateTitle()
        let portrait = await settle(again, containing: "8 × 16")
        XCTAssertTrue(portrait, again.subtitle)
    }

    // Vector 1b: a turn pressed before the size read returned still ends portrait.
    func testRotateBeforeTheFirstReadReturnedStillEndsPortrait() async throws {
        let url = dir.appendingPathComponent("early.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        viewer.dispatch(.rotateRight)     // nothing cached yet
        let portrait = await settle(viewer, containing: "8 × 16")
        XCTAssertTrue(portrait, viewer.subtitle)
        XCTAssertEqual(viewer.headerPixelSizes[url], CGSize(width: 8, height: 16))
    }

    // Vector 2: net zero within the quiet period returns to the original, no write.
    func testRotateThenBackIsTheOriginalSize() async throws {
        let url = dir.appendingPathComponent("b.jpg")
        let before = try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        _ = await settle(viewer, containing: "16 × 8")
        viewer.dispatch(.rotateRight)
        viewer.dispatch(.rotateLeft)
        XCTAssertTrue(viewer.subtitle.contains("16 × 8"), viewer.subtitle)
        await viewer.waitForOrientationWrites()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // Vector 4: undo returns to the original size after it lands.
    func testUndoReturnsTheOriginalSize() async throws {
        let url = dir.appendingPathComponent("c.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        _ = await settle(viewer, containing: "16 × 8")
        viewer.dispatch(.rotateRight)
        await viewer.waitForOrientationWrites()
        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        let back = await settle(viewer, containing: "16 × 8")
        XCTAssertTrue(back, viewer.subtitle)
    }

    // Vector 6: the file is overwritten from outside.
    func testExternalChangeReadsTheNewSize() async throws {
        let url = dir.appendingPathComponent("d.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        _ = await settle(viewer, containing: "16 × 8")

        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, SaveFlowTests.image(width: 100, height: 50), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        viewer.didChangeFileOnDisk(url, fit: false)
        XCTAssertNil(viewer.headerPixelSizes[url], "the cached size is dropped")
        viewer.updateTitle()
        let changed = await settle(viewer, containing: "100 × 50")
        XCTAssertTrue(changed, viewer.subtitle)
    }
}

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

private func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 3) == .success
}

@MainActor
final class DrawnSizeTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = TestScratch.directory
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

    /// A viewer on `url` once its own first paint has landed. It used to
    /// be handed a stand-in image with no source ID instead; the viewer's
    /// real paint then still came later, and its new source ID cleared
    /// the drawn size. Here that paint landed after the header read; on
    /// the slower runner it sometimes landed after the rotate, and the
    /// size stayed nil because the same item is not titled again.
    private func viewer(_ url: URL) async -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        let deadline = Date().addingTimeInterval(10)
        while viewer.imageViewForTesting.sourceID == nil || viewer.displayedItem == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(viewer.imageViewForTesting.sourceID, "The viewer painted its own photo")
        XCTAssertNotNil(viewer.displayedItem)
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
        let viewer = await viewer(url)
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

        let again = await self.viewer(url)
        defer { again.close() }
        again.updateTitle()
        let portrait = await settle(again, containing: "8 × 16")
        XCTAssertTrue(portrait, again.subtitle)
    }

    /// A delayed filesystem notification can arrive after Shrike's own
    /// orientation write has completed. The redraw must keep the known
    /// rotated dimensions attached to the replacement pixels while the
    /// asynchronous header-size read is in flight.
    func testDelayedWatcherRedrawAfterRotateKeepsKnownDrawnSize() async throws {
        let watching = ViewerWindow.watchFoldersForTesting
        ViewerWindow.watchFoldersForTesting = false
        defer { ViewerWindow.watchFoldersForTesting = watching }
        let url = dir.appendingPathComponent("delayed-watcher.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = await viewer(url)
        defer { viewer.close() }
        viewer.updateTitle()
        let landscape = await settle(viewer, containing: "16 × 8")
        XCTAssertTrue(landscape, viewer.subtitle)

        viewer.dispatch(.rotateRight)
        await viewer.waitForOrientationWrites()
        XCTAssertEqual(viewer.imageViewForTesting.sourcePixelSize, CGSize(width: 8, height: 16))

        let metadataReadStarted = DispatchSemaphore(value: 0)
        let allowMetadataRead = DispatchSemaphore(value: 0)
        defer { allowMetadataRead.signal() }
        viewer.headerPixelSizeReaderForTesting = { url in
            metadataReadStarted.signal()
            allowMetadataRead.wait()
            return WindowTitles.headerPixelSize(of: url)
        }
        // Model a decoded source replacement: setImage clears the size
        // when its source identity changes, while the old dimensions are
        // still the only known value until metadata finishes loading.
        let displayed = try XCTUnwrap(viewer.imageViewForTesting.image)
        viewer.imageViewForTesting.setImage(displayed, sourceID: nil)
        viewer.imageViewForTesting.sourcePixelSize = CGSize(width: 8, height: 16)
        let redrawsBeforeWatcher = viewer.redrawCount
        // Exercise a late FolderWatcher modification after the orientation
        // write completes. The read is explicitly gated so the assertion
        // checks the size during refresh, not after metadata happens to land.
        viewer.didChangeFileOnDisk(url, fit: false)
        let deadline = Date().addingTimeInterval(3)
        while viewer.redrawCount == redrawsBeforeWatcher, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewer.redrawCount, redrawsBeforeWatcher + 1)
        let metadataReadHasStarted = await Task.detached {
            waitForSignal(metadataReadStarted)
        }.value
        XCTAssertTrue(metadataReadHasStarted, "metadata read should be waiting at the test gate")
        XCTAssertEqual(viewer.imageViewForTesting.sourcePixelSize, CGSize(width: 8, height: 16))
        allowMetadataRead.signal()
        viewer.headerPixelSizeReaderForTesting = nil
        let portrait = await settle(viewer, containing: "8 × 16")
        XCTAssertTrue(portrait, viewer.subtitle)
        XCTAssertEqual(viewer.imageViewForTesting.sourcePixelSize, CGSize(width: 8, height: 16))
    }

    // Vector 1b: a turn pressed before the size read returned still ends portrait.
    func testRotateBeforeTheFirstReadReturnedStillEndsPortrait() async throws {
        let url = dir.appendingPathComponent("early.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = await viewer(url)
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
        let viewer = await viewer(url)
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
        let viewer = await viewer(url)
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
        let viewer = await viewer(url)
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

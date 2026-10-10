//
//  RotateFlowTests.swift
//  ShrikeUITests
//
//  One
//  rotate concept. Temp folders and a temp `BackupStore` only.
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
final class RotateFlowTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-rotate-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
    }

    override func tearDown() async throws {
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: root)
    }

    private func viewer(_ urls: [URL]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        // Pixels on screen, so the rotate commands apply.
        viewer.imageViewForTesting.image = SaveFlowTests.image()
        return viewer
    }

    private func orientation(_ url: URL) -> Int {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyOrientation] as? Int) ?? 1
    }

    private func storedPixels(_ url: URL) -> Data? {
        let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        return image.dataProvider?.data as Data?
    }

    func testWriteOpsAreTheFewestForTheNetTurn() {
        XCTAssertEqual(ViewerWindow.writeOps(for: .up), [])
        XCTAssertEqual(ViewerWindow.writeOps(for: .right), [.rotate(quarters: 1)])
        XCTAssertEqual(ViewerWindow.writeOps(for: .down), [.rotate(quarters: 2)])
        let pending = PendingOrientation(url: URL(fileURLWithPath: "/x.jpg"),
                                         ops: Array(repeating: .rotate(quarters: 1), count: 4))
        XCTAssertEqual(pending.net, .up)
        for o in ExifOrientation.allCases {
            let ops = ViewerWindow.writeOps(for: o)
            XCTAssertEqual(ops.reduce(ExifOrientation.up) { $0.applying($1) }, o)
        }
    }

    // ⌘R writes the tag only; ⌘Z restores.
    func testRotateRightWritesTheTagLosslesslyAndUndoRestores() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        let before = try SaveFlowTests.writeImage(url, type: .jpeg)
        let pixels = storedPixels(url)
        let viewer = viewer([url])
        defer { viewer.close() }
        viewer.dispatch(.rotateRight)
        XCTAssertEqual(viewer.imageViewForTesting.rotationDegrees, 90)
        XCTAssertNil(viewer.contentRootForTesting.toastHost.content)
        await viewer.waitForOrientationWrites()
        XCTAssertEqual(orientation(url), 6)
        XCTAssertEqual(storedPixels(url), pixels)
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Rotate")

        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(orientation(url), 1)
    }

    // Four presses within the quiet period write nothing.
    func testFourPressesWriteNothing() async throws {
        let url = dir.appendingPathComponent("b.jpg")
        let before = try SaveFlowTests.writeImage(url, type: .jpeg)
        let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        let viewer = viewer([url])
        defer { viewer.close() }
        for _ in 0..<4 { viewer.dispatch(.rotateRight) }
        await viewer.waitForOrientationWrites()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, mtime)
        XCTAssertFalse(viewer.undoManagerForTesting.canUndo)
    }

    // (GIF stands in for WebP): view only, toast once.
    func testViewOnlyTypeTurnsTheViewAndToastsOnce() async throws {
        let url = dir.appendingPathComponent("party.gif")
        let before = try SaveFlowTests.writeImage(url, type: .gif)
        let viewer = viewer([url])
        defer { viewer.close() }
        viewer.dispatch(.rotateRight)
        XCTAssertEqual(viewer.imageViewForTesting.rotationDegrees, 90)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, RotateCopy.viewOnlyRotate)
        viewer.contentRootForTesting.toastHost.dismiss(animated: false)
        viewer.dispatch(.rotateRight)
        XCTAssertNil(viewer.contentRootForTesting.toastHost.content)
        await viewer.waitForOrientationWrites()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    // ⌘R then → : the write happens at navigation.
    func testNavigationWritesThePendingRotate() async throws {
        ViewerWindow.orientationWriteDelay = .seconds(30)
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)
        try SaveFlowTests.writeImage(b, type: .jpeg)
        let viewer = viewer([a, b])
        defer { viewer.close() }
        viewer.dispatch(.rotateRight)
        viewer.markDisplayedForTesting(1)
        XCTAssertEqual(viewer.imageViewForTesting.rotationDegrees, 0)
        await viewer.orientationWriteChain?.value
        XCTAssertEqual(orientation(a), 6)
        XCTAssertEqual(orientation(b), 1)
    }

    // In edit mode ⌘R turns the recipe, not the file.
    func testEditModeRotateKeysTurnTheRecipe() {
        XCTAssertEqual(ViewerKeyMap.action(for: .rotateRight, context: .editMode), .editRotate90(quarters: 1))
        XCTAssertEqual(ViewerKeyMap.action(for: .rotateLeft, context: .editMode), .editRotate90(quarters: -1))
        XCTAssertNil(ViewerKeyMap.action(for: .flipHorizontal, context: .editMode))
    }
}

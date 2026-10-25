//
//  FilmstripReload028Tests.swift
//  ShrikeUITests
//
//  Spec 27 B4: after Cmd-R the strip's cell takes the new orientation.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class FilmstripReload028Tests: XCTestCase {

    private var root: URL!
    private var dir: URL!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-stripreload-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ViewerWindow.orientationWriteDelay = .milliseconds(50)
    }

    override func tearDown() async throws {
        ViewerWindow.orientationWriteDelay = .milliseconds(500)
        try? FileManager.default.removeItem(at: root)
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return cond()
    }

    /// A viewer with a two-cell strip (a.jpg 16 x 8 landscape, b.jpg the same).
    private func stripViewer() async throws -> (ViewerWindow, FilmstripView, ShrikeServices, URL, URL) {
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        try SaveFlowTests.writeImage(a, type: .jpeg)   // 16 x 8
        try SaveFlowTests.writeImage(b, type: .jpeg)
        var services = ShrikeServices.makeDefault()
        services.backupStore = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
        let viewer = ViewerWindow(groups: [ImageGroup(primary: a), ImageGroup(primary: b)], startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        viewer.imageViewForTesting.image = SaveFlowTests.image()
        let strip = viewer.contentRootForTesting.filmstripForTesting
        viewer.contentRootForTesting.updateFilmstripNeighbors(
            [(idx: 0, source: FileImageSource(url: a)), (idx: 1, source: FileImageSource(url: b))],
            current: 0, services: services)
        let landscape = await waitFor { (strip.cellAspectForTesting(url: a)?.aspect ?? 0) > 1.5
            && (strip.cellAspectForTesting(url: b)?.aspect ?? 0) > 1.5 }
        XCTAssertTrue(landscape, "both cells start landscape")
        return (viewer, strip, services, a, b)
    }

    /// Lookups the cache has served so far (hits plus misses).
    private func lookups(_ services: ShrikeServices) async -> Int {
        let s = await services.thumbnailCache.statistics()
        return s.memoryHits + s.diskHits + s.misses
    }

    func testStripCellTakesThePortraitAspectAfterARotateAndBackAfterUndo() async throws {
        let (viewer, strip, _, a, b) = try await stripViewer()
        defer { viewer.close() }

        viewer.dispatch(.rotateRight)
        await viewer.waitForOrientationWrites()
        let portrait = await waitFor { (strip.cellAspectForTesting(url: a)?.aspect ?? 9) < 0.7 }
        XCTAssertTrue(portrait, "the strip cell is portrait after the turn: \(String(describing: strip.cellAspectForTesting(url: a)))")
        let other = strip.cellAspectForTesting(url: b)?.aspect ?? 0
        XCTAssertGreaterThan(other, 1.5, "the other cell is untouched")

        // Vector 2: Cmd-Z brings the landscape cell back.
        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        let landscape = await waitFor { (strip.cellAspectForTesting(url: a)?.aspect ?? 0) > 1.5 }
        XCTAssertTrue(landscape, "the strip cell is landscape again after undo: \(String(describing: strip.cellAspectForTesting(url: a)))")
    }

    /// Vector 3: Edit > Done with a Rotate (the saved file is turned) updates the strip.
    func testStripCellUpdatesWhenEditDoneSavesARotate() async throws {
        let (viewer, strip, _, a, b) = try await stripViewer()
        defer { viewer.close() }
        viewer.contentRootForTesting.enterEditMode(image: SaveFlowTests.image(), url: a, landOn: .rotate)
        viewer.contentRootForTesting.editModeController.appendSnapped90(quarters: 1)
        let recipe = try XCTUnwrap(viewer.contentRootForTesting.editModeController.recipe)
        let deadline = Date().addingTimeInterval(2)
        while await recipe.operations.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }

        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let portrait = await waitFor { (strip.cellAspectForTesting(url: a)?.aspect ?? 9) < 0.7 }
        XCTAssertTrue(portrait, "the strip cell follows the saved file: \(String(describing: strip.cellAspectForTesting(url: a)))")
        XCTAssertGreaterThan(strip.cellAspectForTesting(url: b)?.aspect ?? 0, 1.5)
    }

    /// Vector 4: one rotate asks the thumbnail cache once, for that one cell.
    func testARotateAsksForExactlyOneThumbnail() async throws {
        let (viewer, strip, services, a, _) = try await stripViewer()
        defer { viewer.close() }
        try await Task.sleep(for: .milliseconds(200))   // let the first loads settle
        let before = await lookups(services)
        viewer.dispatch(.rotateRight)
        await viewer.waitForOrientationWrites()
        let portrait = await waitFor { (strip.cellAspectForTesting(url: a)?.aspect ?? 9) < 0.7 }
        XCTAssertTrue(portrait)
        try await Task.sleep(for: .milliseconds(200))
        let after = await lookups(services)
        XCTAssertEqual(after - before, 1, "one thumbnail call for one turned photo")
    }
}

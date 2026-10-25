//
//  OpenRequestRoutingTests.swift
//  ShrikeUITests
//
//  Regression for the P0 "launch with a file shows nothing": AppKit calls
//  `application(_:open:)` before `applicationDidFinishLaunching`, so the
//  request must be buffered and replayed once services exist.
//

import Foundation
import XCTest
@testable import ShrikeUI

@MainActor
final class OpenRequestRoutingTests: XCTestCase {

    private var folder: URL!

    // Async overrides run on the main actor, like the tests. A sync
    // `setUpWithError()` override is nonisolated and can't write `folder`
    // (fails to compile with `swift test -c release`).
    override func setUp() async throws {
        try await super.setUp()
        folder = TestScratch.directory
            .appendingPathComponent("OpenRequestRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["b.jpg", "a.JPG", "img10.png", "img2.png", "notes.txt"] {
            try Data([0]).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
        try await super.tearDown()
    }

    // MARK: - Queue

    func testRequestsBeforeActivationAreBufferedThenFlushedAsOneBatch() {
        let queue = OpenRequestQueue()
        let a = URL(fileURLWithPath: "/x/a.jpg"), b = URL(fileURLWithPath: "/x/b.jpg")
        queue.submit([a])
        queue.submit([b])
        XCTAssertTrue(queue.hasPending)

        var batches: [[URL]] = []
        let flushed = queue.activate { batches.append($0) }

        XCTAssertTrue(flushed)
        XCTAssertEqual(batches, [[a, b]])
        XCTAssertFalse(queue.hasPending)
    }

    func testActivationWithNothingPendingReportsNoFlush() {
        let queue = OpenRequestQueue()
        var batches: [[URL]] = []
        XCTAssertFalse(queue.activate { batches.append($0) })
        XCTAssertTrue(batches.isEmpty)
    }

    func testRequestsAfterActivationAreDeliveredImmediately() {
        let queue = OpenRequestQueue()
        var batches: [[URL]] = []
        queue.activate { batches.append($0) }
        let a = URL(fileURLWithPath: "/x/a.jpg")
        queue.submit([a])
        XCTAssertEqual(batches, [[a]])
        queue.submit([])
        XCTAssertEqual(batches.count, 1, "empty submits are ignored")
    }

    // MARK: - Routing (WindowCoordinator)

    func testSingleImageExpandsToFinderSortedSiblingsStartingOnIt() async {
        let (groups, start) = await WindowCoordinator.viewerList(
            for: [folder.appendingPathComponent("img10.png")], showHidden: false
        )
        XCTAssertEqual(groups.map(\.primary.lastPathComponent),
                       ["a.JPG", "b.jpg", "img2.png", "img10.png"])
        XCTAssertEqual(start, 3)
    }

    func testStartIndexSurvivesDifferentPathSpelling() async throws {
        // `/tmp/...` vs `/private/tmp/...` style mismatch: build the opened
        // URL through a symlinked parent so it differs from the listing.
        let link = TestScratch.directory
            .appendingPathComponent("OpenRequestRoutingLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }

        let (groups, start) = await WindowCoordinator.viewerList(
            for: [link.appendingPathComponent("b.jpg")], showHidden: false
        )
        XCTAssertEqual(groups[start].primary.lastPathComponent, "b.jpg")
    }

    func testFoldersGoToBrowserAndMultipleFilesKeepTheirOrder() async {
        let sub = folder.appendingPathComponent("sub", isDirectory: true)
        let b = folder.appendingPathComponent("b.jpg")
        let a = folder.appendingPathComponent("a.JPG")
        let request = WindowCoordinator.classify([sub, b, a])
        XCTAssertEqual(request.folders, [sub])
        XCTAssertEqual(request.images, [b, a])
        let (groups, start) = await WindowCoordinator.viewerList(for: request.images, showHidden: false)
        XCTAssertEqual(groups.map(\.primary.lastPathComponent), ["b.jpg", "a.JPG"],
                       "2+ images from one folder: only those, in the given order")
        XCTAssertEqual(start, 0)
    }

    func testFolderOnlyOpensNoViewer() {
        let request = WindowCoordinator.classify([folder])
        XCTAssertTrue(request.images.isEmpty)
        XCTAssertEqual(request.folders, [folder])
    }

    func testNonImageIsUnopenable() {
        let request = WindowCoordinator.classify([folder.appendingPathComponent("notes.txt")])
        XCTAssertTrue(request.images.isEmpty)
        XCTAssertEqual(request.unopenable.map(\.lastPathComponent), ["notes.txt"])
    }

    /// The opened file is always in the list and is where
    /// the viewer starts, even with an unusual extension.
    func testOpenedJFIFStartsOnItself() async throws {
        let jfif = folder.appendingPathComponent("photo.jfif")
        try Data([0]).write(to: jfif)
        let (groups, start) = await WindowCoordinator.viewerList(for: [jfif], showHidden: false)
        XCTAssertEqual(groups[start].primary.lastPathComponent, "photo.jfif")
    }

    func testImagesFromSeveralFoldersSortByFolderThenName() async throws {
        let other = folder.appendingPathComponent("sub/z.jpg")
        try Data([0]).write(to: other)
        let b = folder.appendingPathComponent("b.jpg")
        let a = folder.appendingPathComponent("a.JPG")
        let (groups, _) = await WindowCoordinator.viewerList(for: [other, b, a], showHidden: false)
        XCTAssertEqual(groups.map(\.primary.lastPathComponent), ["a.JPG", "b.jpg", "z.jpg"])
    }
}

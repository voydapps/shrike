//
//  FinderTagWriterTests.swift
//  ShrikeIOTests
//
//  FinderTagWriter: writes run off the caller's thread, in call order, and
//  one failing file never stops the rest. Real tags on files in a unique
//  temp directory only.
//

import XCTest
import Foundation
import os
@testable import ShrikeIO

final class FinderTagWriterTests: XCTestCase {

    private var dir: URL!
    private var writer: FinderTagWriter!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeFinderTagWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        writer = FinderTagWriter(label: "test.finder-tags.\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func file(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    // MARK: - Order

    func testQuickSyncEnqueuesApplyInCallOrder() async throws {
        let photo = try file("a.jpg")
        let order = OSAllocatedUnfairLock<[Int]>(initialState: [])
        for i in 0..<50 {
            writer.enqueue(.set(["T\(i)"]), on: [photo]) { result in
                XCTAssertTrue(result.succeeded)
                XCTAssertFalse(Thread.isMainThread)
                order.withLock { $0.append(i) }
            }
        }
        await writer.flush()
        XCTAssertEqual(order.withLock { $0 }, Array(0..<50))
        XCTAssertEqual(FinderTags.read(photo), ["T49"])
    }

    func testAddAndRemoveBuildOnEarlierQueuedWrites() async throws {
        let photo = try file("b.jpg")
        writer.enqueue(.add(["Alpha"]), on: [photo])
        writer.enqueue(.add(["Beta", "alpha"]), on: [photo])
        writer.enqueue(.remove(["ALPHA"]), on: [photo])
        let result = await writer.add(["Gamma"], to: [photo])
        XCTAssertEqual(result.tags[photo], ["Beta", "Gamma"])
        XCTAssertEqual(FinderTags.read(photo), ["Beta", "Gamma"])
    }

    @MainActor
    func testAsyncCallsFromMainActorTasksKeepCallOrder() async throws {
        let photo = try file("c.jpg")
        var tasks: [Task<Void, Never>] = []
        for i in 0..<20 {
            // add X, remove X, add X, … : any swap leaves a different result.
            let name = "T\(i / 2)"
            tasks.append(Task {
                _ = i.isMultiple(of: 2)
                    ? await self.writer.add([name], to: [photo])
                    : await self.writer.remove([name], from: [photo])
            })
        }
        tasks.append(Task { _ = await self.writer.add(["Last"], to: [photo]) })
        for task in tasks { await task.value }
        XCTAssertEqual(FinderTags.read(photo), ["Last"])
    }

    // MARK: - Errors per file

    func testFailureOnOneFileDoesNotStopTheOthers() async throws {
        let first = try file("d1.jpg")
        let missing = dir.appendingPathComponent("gone.jpg")
        let last = try file("d2.jpg")
        let result = await writer.add(["Keep"], to: [first, missing, last])
        XCTAssertEqual(result.failures, [.fileNotFound(missing)])
        XCTAssertEqual(result.failedURLs, [missing])
        XCTAssertEqual(result.tags, [first: ["Keep"], last: ["Keep"]])
        XCTAssertEqual(FinderTags.read(first), ["Keep"])
        XCTAssertEqual(FinderTags.read(last), ["Keep"])
    }

    func testRemoveFromMissingFileIsReported() async {
        let missing = dir.appendingPathComponent("gone.jpg")
        let result = await writer.remove(["Any"], from: [missing])
        XCTAssertEqual(result.failures, [.fileNotFound(missing)])
    }

    func testReadOnlyFileFailsAndOthersAreWritten() async throws {
        let locked = try file("ro.jpg")
        let open = try file("rw.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let result = await writer.set(["Red"], on: [locked, open])
        XCTAssertEqual(result.failedURLs, [locked])
        if case .writeFailed = result.failures.first {} else {
            XCTFail("expected .writeFailed, got \(result.failures)")
        }
        XCTAssertEqual(FinderTags.read(open), ["Red"])
    }

    // MARK: - Values

    func testSetCleansNamesLikeTheSyncAPI() async throws {
        let photo = try file("e.jpg")
        let result = await writer.set(["  Client ", "client", "", "Venice"], on: [photo])
        XCTAssertEqual(result.tags[photo], ["Client", "Venice"])
        XCTAssertEqual(FinderTags.read(photo), ["Client", "Venice"])
        let cleared = await writer.set([], on: [photo])
        XCTAssertEqual(cleared.tags[photo], [])
        XCTAssertEqual(FinderTags.read(photo), [])
    }

    func testPerFileEditsForUndoSnapshots() async throws {
        let a = try file("f1.jpg"), b = try file("f2.jpg")
        try FinderTags.write(a, tags: ["Old"])
        let result = await writer.write([
            FinderTagEdit(url: a, change: .set(["A"])),
            FinderTagEdit(url: b, change: .set(["B1", "B2"])),
        ])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(FinderTags.read(a), ["A"])
        XCTAssertEqual(FinderTags.read(b), ["B1", "B2"])
    }

    func testErrorCarriesItsURL() {
        let url = URL(fileURLWithPath: "/x/y.jpg")
        XCTAssertEqual(FinderTagsError.fileNotFound(url).url, url)
        XCTAssertEqual(FinderTagsError.writeFailed(url, "nope").url, url)
    }
}

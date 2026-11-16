//
//  WelcomeDropOnceTests.swift
//  ShrikeUITests
//
//  Pass 2p task 4: the Welcome drop zone classifies one drag once; the
//  drop reuses the answer from `draggingEntered` (same pasteboard change
//  count and URLs), as the sidebar's `droppedFolders` does.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class WelcomeDropOnceTests: XCTestCase {

    func testTheDropReusesTheAnswerOfTheSameDrag() throws {
        let folder = TestScratch.directory.appendingPathComponent("shrike-2p4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pb = NSPasteboard(name: NSPasteboard.Name("shrike-2p4-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([folder as NSURL])

        let entered = WelcomeDropZone.openable(pb)
        XCTAssertTrue(entered.ok, "a folder can be opened")
        XCTAssertEqual(entered.urls.map(\.lastPathComponent), [folder.lastPathComponent])
        try FileManager.default.removeItem(at: folder)
        XCTAssertTrue(WelcomeDropZone.openable(pb).ok, "the drop of the same drag reuses its answer")

        pb.clearContents()
        pb.writeObjects([folder as NSURL])
        XCTAssertFalse(WelcomeDropZone.openable(pb).ok, "a new drag checks again")
    }
}

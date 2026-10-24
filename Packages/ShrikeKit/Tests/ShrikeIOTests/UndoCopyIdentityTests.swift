//
//  UndoCopyIdentityTests.swift
//  ShrikeIOTests
//
//  Audit 2026-10-24 FS-8: on a volume without a Trash, Undo Copy deletes
//  for good, so it must only delete the file the copy made.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class UndoCopyIdentityTests: XCTestCase {

    var tmp: IOTempDir!
    var trash: FakeTrash!

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("UndoCopyIdentity")
        trash = FakeTrash(folder: tmp.url.appendingPathComponent("_trash", isDirectory: true))
        trash.noTrash = true
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func makeOps() -> FileOps {
        let trash = self.trash!
        return FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { try trash.trash($0) })
    }

    private func copyOne() async throws -> (FileOps, FileOpReceipt, URL) {
        let src = try tmp.file("P1.jpg", "original bytes", in: "cam")
        let dest = tmp.url.appendingPathComponent("share", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let ops = makeOps()
        var last: FileOpProgress?
        for try await p in ops.copy([ImageGroup(primary: src)], to: dest, conflicts: .always(.keepBoth)) { last = p }
        let receipt = try XCTUnwrap(last).receipt
        return (ops, receipt, dest.appendingPathComponent("P1.jpg"))
    }

    func testUnchangedCopyIsRemovedOnAVolumeWithoutTrash() async throws {
        let (ops, receipt, copy) = try await copyOne()
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        try await ops.undo(receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
    }

    func testDifferentFileAtTheCopysPathIsKept() async throws {
        let (ops, receipt, copy) = try await copyOne()
        // Another program (or the user) puts a different file at that name.
        try FileManager.default.removeItem(at: copy)
        try Data("somebody else's photo".utf8).write(to: copy)
        do {
            try await ops.undo(receipt)
            XCTFail("Undo must report that it left the file")
        } catch let error as FileOpsError {
            XCTAssertEqual(error.url, copy)
        }
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "somebody else's photo")
    }

    func testEditedCopyIsKept() async throws {
        let (ops, receipt, copy) = try await copyOne()
        // Edited in place (same inode, new size and time).
        let handle = try FileHandle(forWritingTo: copy)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" edited".utf8))
        try handle.close()
        do { try await ops.undo(receipt); XCTFail("expected a report") } catch is FileOpsError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    }
}

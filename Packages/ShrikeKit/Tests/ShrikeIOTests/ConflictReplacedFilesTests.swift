//
//  ConflictReplacedFilesTests.swift
//  ShrikeIOTests
//
//  Audit 2026-10-24 FS-6: the Replace alert must name the other files of the
//  same photo that Replace moves to the Trash.
//

import XCTest
@testable import ShrikeIO
import ShrikeCore

final class ConflictReplacedFilesTests: XCTestCase {

    var tmp: IOTempDir!

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("ConflictReplaced")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    func testRawAndSidecarOfTheSamePhotoAreNamed() throws {
        let dest = tmp.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let jpg = dest.appendingPathComponent("IMG_1.jpg")
        for name in ["IMG_1.jpg", "IMG_1.CR3", "IMG_1.xmp", "IMG_2.jpg"] {
            try Data([1]).write(to: dest.appendingPathComponent(name))
        }
        let incoming = ImageGroup(primary: tmp.url.appendingPathComponent("IMG_1.jpg"))
        let conflict = FileConflict(incoming: incoming, existing: [jpg], destinationFolder: dest, remainingConflicts: 0)
        let extra = conflict.otherFilesReplaced.map(\.lastPathComponent).sorted()
        XCTAssertEqual(extra, ["IMG_1.CR3", "IMG_1.xmp"])
        XCTAssertFalse(extra.contains("IMG_2.jpg"), "another photo is never touched")
    }

    func testNothingExtraWhenOnlyTheClashingFileExists() throws {
        let dest = tmp.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let jpg = dest.appendingPathComponent("IMG_1.jpg")
        try Data([1]).write(to: jpg)
        let conflict = FileConflict(incoming: ImageGroup(primary: tmp.url.appendingPathComponent("IMG_1.jpg")),
                                    existing: [jpg], destinationFolder: dest, remainingConflicts: 0)
        XCTAssertTrue(conflict.otherFilesReplaced.isEmpty)
    }

    /// A full group replacing a full group: all three clash, so all three go; the alert
    /// must name the two besides the primary (gate 0.2.28: it said "the existing file").
    func testFullGroupOnFullGroupNamesEveryOtherFile() throws {
        let dest = tmp.url.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        var existing: [URL] = []
        for name in ["IMG_9001.JPG", "IMG_9001.CR2", "IMG_9001.xmp", "IMG_9002.JPG"] {
            let url = dest.appendingPathComponent(name)
            try Data([1]).write(to: url)
            if name.hasPrefix("IMG_9001") { existing.append(url) }
        }
        let incoming = ImageGroup(primary: tmp.url.appendingPathComponent("IMG_9001.JPG"))
        let conflict = FileConflict(incoming: incoming, existing: existing, destinationFolder: dest, remainingConflicts: 0)
        XCTAssertTrue(conflict.otherFilesReplaced.isEmpty, "all of them clash; none is only 'also' replaced")
        XCTAssertEqual(conflict.allOtherFilesReplaced.map(\.lastPathComponent).sorted(), ["IMG_9001.CR2", "IMG_9001.xmp"])
    }
}

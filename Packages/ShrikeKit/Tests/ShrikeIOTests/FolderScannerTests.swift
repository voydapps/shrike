//
//  FolderScannerTests.swift
//  ShrikeIOTests
//
//  Folder listing, grouping, `including`, sibling folders.
//  Temp directories only.
//

import XCTest
import ShrikeCore
@testable import ShrikeIO

final class FolderScannerTests: XCTestCase {

    var tmp: IOTempDir!

    override func setUp() {
        super.setUp()
        tmp = IOTempDir("FolderScanner")
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func names(_ groups: [ImageGroup]) -> [String] { groups.map(\.primary.lastPathComponent) }

    // MARK: imageGroups

    func testListsSupportedImagesInFinderOrderAndGroupsPairs() async throws {
        let dir = try tmp.dir("cam")
        for name in ["IMG_10.jpg", "IMG_2.JPG", "IMG_2.ORF", "IMG_2.xmp", "IMG_1.heic", "IMG_1.MOV",
                     "notes.txt", "clip.mov", "sigma.X3F", "doc.pdf"] {
            try tmp.file(name, in: "cam")
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub.jpg"),
                                                withIntermediateDirectories: true)

        let groups = try await FolderScanner.imageGroups(in: dir, grouping: .default)
        XCTAssertEqual(names(groups), ["IMG_1.heic", "IMG_2.JPG", "IMG_10.jpg"])
        XCTAssertEqual(groups[0].livePhotoMovie?.lastPathComponent, "IMG_1.MOV")
        XCTAssertEqual(groups[1].rawURL?.lastPathComponent, "IMG_2.ORF")
        XCTAssertEqual(groups[1].sidecarURLs.map(\.lastPathComponent), ["IMG_2.xmp"])
    }

    func testX3FTravelsWithItsJPEG() async throws {
        let dir = try tmp.dir("sigma")
        for name in ["S1.JPG", "S1.X3F", "S2.X3F", "K1.jpg", "K1.KDC"] { try tmp.file(name, in: "sigma") }
        let groups = try await FolderScanner.imageGroups(in: dir, grouping: .default)
        XCTAssertEqual(names(groups), ["K1.jpg", "S1.JPG"], "lone S2.X3F not listed")
        XCTAssertEqual(groups[0].rawURL?.lastPathComponent, "K1.KDC")
        XCTAssertEqual(groups[1].rawURL?.lastPathComponent, "S1.X3F")
    }

    func testGroupingDisabledListsEveryImage() async throws {
        let dir = try tmp.dir("cam")
        for name in ["a.JPG", "a.ORF", "a.xmp"] { try tmp.file(name, in: "cam") }
        let groups = try await FolderScanner.imageGroups(in: dir, grouping: .disabled)
        XCTAssertEqual(names(groups), ["a.JPG", "a.ORF"])
    }

    func testShowBothFilesKeepsCompanionsOnDisk() async throws {
        let dir = try tmp.dir("both")
        for name in ["P1.JPG", "P1.ORF", "P1.xmp", "P1.MOV"] { try tmp.file(name, in: "both") }
        let groups = try await FolderScanner.imageGroups(in: dir, grouping: .showBothFiles)
        XCTAssertEqual(names(groups), ["P1.JPG", "P1.ORF"])
        XCTAssertEqual(groups[0].livePhotoMovie?.lastPathComponent, "P1.MOV")
        XCTAssertEqual(groups[1].sidecarURLs.map(\.lastPathComponent), ["P1.xmp"])
    }

    func testHiddenFilesFollowShowHidden() async throws {
        let dir = try tmp.dir("h")
        try tmp.file(".secret.jpg", in: "h")
        try tmp.file("shown.jpg", in: "h")
        let hidden = try await FolderScanner.imageGroups(in: dir, showHidden: false, grouping: .default)
        XCTAssertEqual(names(hidden), ["shown.jpg"])
        let all = try await FolderScanner.imageGroups(in: dir, showHidden: true, grouping: .default)
        XCTAssertEqual(names(all), [".secret.jpg", "shown.jpg"])
    }

    func testIncludingUnknownOrHiddenFileIsAlwaysListed() async throws {
        let dir = try tmp.dir("inc")
        try tmp.file("a.jpg", in: "inc")
        let odd = try tmp.file("b.xyz", in: "inc")
        let hidden = try tmp.file(".c.jpg", in: "inc")
        let loneX3F = try tmp.file("d.x3f", in: "inc")

        let withOdd = try await FolderScanner.imageGroups(in: dir, including: odd, grouping: .default)
        XCTAssertEqual(names(withOdd), ["a.jpg", "b.xyz"])
        // An X3F is never listed on its own, even when opened.
        let withX3F = try await FolderScanner.imageGroups(in: dir, including: loneX3F, grouping: .default)
        XCTAssertEqual(names(withX3F), ["a.jpg"])
        XCTAssertNil(FolderScanner.index(of: loneX3F, in: withX3F))
        let withHidden = try await FolderScanner.imageGroups(in: dir, including: hidden, grouping: .default)
        XCTAssertEqual(names(withHidden), [".c.jpg", "a.jpg"])
    }

    func testIncludingMatchesAcrossURLForms() async throws {
        let dir = try tmp.dir("forms")
        try tmp.file("a.jpg", in: "forms")
        try tmp.file("b.jpg", in: "forms")
        // Unresolved /var/... form of a /private/var/... file.
        let unresolved = URL(fileURLWithPath: dir.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
            .appendingPathComponent("b.jpg")
        let groups = try await FolderScanner.imageGroups(in: dir, including: unresolved, grouping: .default)
        XCTAssertEqual(names(groups), ["a.jpg", "b.jpg"], "no duplicate for another URL form")
        XCTAssertEqual(FolderScanner.index(of: unresolved, in: groups), 1)
        // Case-only difference.
        let upper = dir.appendingPathComponent("B.JPG")
        XCTAssertEqual(FolderScanner.index(of: upper, in: groups), 1)
    }

    func testIncludingOutsideFolderIsIgnored() async throws {
        let dir = try tmp.dir("inside")
        try tmp.file("a.jpg", in: "inside")
        let outside = try tmp.file("elsewhere.jpg", in: "other")
        let groups = try await FolderScanner.imageGroups(in: dir, including: outside, grouping: .default)
        XCTAssertEqual(names(groups), ["a.jpg"])
    }

    func testIndexFindsCompanion() async throws {
        let dir = try tmp.dir("pair")
        try tmp.file("P1.JPG", in: "pair")
        let raw = try tmp.file("P1.ORF", in: "pair")
        let groups = try await FolderScanner.imageGroups(in: dir, including: raw, grouping: .default)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(FolderScanner.index(of: raw, in: groups), 0)
    }

    func testMissingFolderThrows() async {
        let missing = tmp.url.appendingPathComponent("gone", isDirectory: true)
        do {
            _ = try await FolderScanner.imageGroups(in: missing)
            XCTFail("expected notADirectory")
        } catch {
            XCTAssertEqual(error as? FolderScannerError, .notADirectory(missing))
        }
    }

    func testRunsOffTheMainActor() async throws {
        let dir = try tmp.dir("offmain")
        try tmp.file("a.jpg", in: "offmain")
        let groups = try await Self.scanFromMainActor(dir)
        XCTAssertEqual(groups.count, 1)
    }

    @MainActor
    private static func scanFromMainActor(_ dir: URL) async throws -> [ImageGroup] {
        try await FolderScanner.imageGroups(in: dir, grouping: .default)
    }

    // MARK: siblingFolders

    func testSiblingFoldersSkipEmptyHiddenAndFiles() async throws {
        for (folder, file) in [("Day 1", "a.jpg"), ("Day 2", "b.jpg"), ("Day 3", nil),
                               ("Day 10", "c.ORF"), (".hidden", "d.jpg"), ("Day 11", "notes.txt")] {
            let d = try tmp.dir(folder)
            if let file { try Data("x".utf8).write(to: d.appendingPathComponent(file)) }
        }
        try tmp.file("Day 2.5.jpg")   // a file, not a folder
        let day2 = tmp.url.appendingPathComponent("Day 2", isDirectory: true)

        let siblings = await FolderScanner.siblingFolders(of: day2)
        XCTAssertEqual(siblings.previous?.lastPathComponent, "Day 1")
        XCTAssertEqual(siblings.next?.lastPathComponent, "Day 10", "Day 3 is empty; natural sort puts 10 after 3")

        let day10 = tmp.url.appendingPathComponent("Day 10", isDirectory: true)
        let fromTen = await FolderScanner.siblingFolders(of: day10)
        XCTAssertEqual(fromTen.previous?.lastPathComponent, "Day 2")
        XCTAssertNil(fromTen.next, "Day 11 has no image")

        let prev = await FolderScanner.adjacentFolder(of: day10, .previous)
        XCTAssertEqual(prev?.lastPathComponent, "Day 2")
    }

    func testSiblingFoldersDoNotRecurse() async throws {
        let a = try tmp.dir("A")
        try tmp.file("a.jpg", in: "A")
        let nested = try tmp.dir("B/deeper")
        try Data("x".utf8).write(to: nested.appendingPathComponent("deep.jpg"))
        let siblings = await FolderScanner.siblingFolders(of: a)
        XCTAssertNil(siblings.next, "B has an image only two levels down")
    }

    func testSiblingFoldersSkipSymlinkedDirectories() async throws {
        let a = try tmp.dir("A")
        try tmp.file("a.jpg", in: "A")
        let outside = try tmp.dir("zz-outside-target")
        try Data("x".utf8).write(to: outside.appendingPathComponent("o.jpg"))
        let link = tmp.url.appendingPathComponent("B-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let siblings = await FolderScanner.siblingFolders(of: a)
        XCTAssertEqual(siblings.next?.lastPathComponent, "zz-outside-target")
        XCTAssertNotEqual(siblings.next?.lastPathComponent, "B-link")
    }

    func testSiblingFoldersAtRootIsEmpty() async {
        let siblings = await FolderScanner.siblingFolders(of: URL(fileURLWithPath: "/"))
        XCTAssertEqual(siblings, .none)
    }

    func testContainsImage() throws {
        let yes = try tmp.dir("yes")
        try tmp.file("x.png", in: "yes")
        let no = try tmp.dir("no")
        try tmp.file("x.txt", in: "no")
        XCTAssertTrue(FolderScanner.containsImage(yes))
        XCTAssertFalse(FolderScanner.containsImage(no))
    }
}

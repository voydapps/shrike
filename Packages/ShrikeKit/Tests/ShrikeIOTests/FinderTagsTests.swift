//
//  FinderTagsTests.swift
//  ShrikeIOTests
//
//  Round-trips real Finder tags on files in a unique temp directory.
//

import XCTest
import Foundation
@testable import ShrikeIO

final class FinderTagsTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeFinderTagsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    func testNewFileHasNoTags() {
        XCTAssertEqual(FinderTags.read(file), [])
        XCTAssertEqual(FinderTags.readWithColors(file), [])
    }

    func testWriteReadRoundTrip() throws {
        try FinderTags.write(file, tags: ["Client", "Venice"])
        XCTAssertEqual(FinderTags.read(file), ["Client", "Venice"])

        // Visible to a fresh URL instance too (no stale resource cache).
        XCTAssertEqual(FinderTags.read(URL(fileURLWithPath: file.path)), ["Client", "Venice"])

        try FinderTags.write(file, tags: [])
        XCTAssertEqual(FinderTags.read(file), [])
    }

    func testWriteDedupesCaseInsensitivelyAndTrims() throws {
        try FinderTags.write(file, tags: ["Venice", " venice ", "", "Client"])
        XCTAssertEqual(FinderTags.read(file), ["Venice", "Client"])
    }

    func testAddRemoveToggle() throws {
        XCTAssertEqual(try FinderTags.add(["A"], to: file), ["A"])
        XCTAssertEqual(try FinderTags.add(["a", "B"], to: file), ["A", "B"])
        XCTAssertEqual(try FinderTags.remove(["b"], from: file), ["A"])
        XCTAssertEqual(try FinderTags.remove(["missing"], from: file), ["A"])
        XCTAssertFalse(try FinderTags.toggle("A", on: file))
        XCTAssertEqual(FinderTags.read(file), [])
        XCTAssertTrue(try FinderTags.toggle("Keep", on: file))
        XCTAssertEqual(FinderTags.read(file), ["Keep"])
    }

    func testTagsLandInFinderXattr() throws {
        try FinderTags.write(file, tags: ["Venice"])
        let entries = FinderTags.readXattrEntries(file)
        XCTAssertNotNil(entries)
        XCTAssertEqual(entries?.map { FinderTags.parseEntry($0).name }, ["Venice"])
        XCTAssertEqual(FinderTags.readWithColors(file).map(\.name), ["Venice"])
    }

    /// Writing a standard colour tag's (localised) name stores its colour,
    /// so the popover's colour toggles only need names.
    @MainActor
    func testStandardColourNameGetsItsColour() throws {
        let red = try XCTUnwrap(FinderTags.knownTags().first { $0.color == .red })
        try FinderTags.write(file, tags: [red.name, "Venice"])
        XCTAssertEqual(FinderTags.readWithColors(file),
                       [FinderTag(name: red.name, color: .red), FinderTag(name: "Venice", color: .none)])
    }

    func testParseEntry() {
        XCTAssertEqual(FinderTags.parseEntry("Red\n6"), FinderTag(name: "Red", color: .red))
        XCTAssertEqual(FinderTags.parseEntry("Plain"), FinderTag(name: "Plain", color: .none))
        XCTAssertEqual(FinderTags.parseEntry("Odd\nx"), FinderTag(name: "Odd", color: .none))
        XCTAssertEqual(FinderTags.parseEntry("Multi\nline\n2"), FinderTag(name: "Multi\nline", color: .green))
    }

    func testWriteToMissingFileThrows() {
        let missing = dir.appendingPathComponent("gone.jpg")
        XCTAssertThrowsError(try FinderTags.write(missing, tags: ["x"])) { error in
            XCTAssertEqual(error as? FinderTagsError, .fileNotFound(missing))
        }
        XCTAssertEqual(FinderTags.read(missing), [])
    }

    @MainActor
    func testKnownTagsAreTheSevenColoursInFinderOrder() {
        let tags = FinderTags.knownTags()
        XCTAssertEqual(tags.map(\.color), FinderTagColor.finderMenuOrder)
        XCTAssertTrue(tags.allSatisfy { !$0.name.isEmpty })
        XCTAssertNotNil(FinderTagColor.red.nsColor)
        XCTAssertNil(FinderTagColor.none.nsColor)
    }

    @MainActor
    func testUserDefinedTagsFromFinderPlist() throws {
        let plist: [String: Any] = [
            "values": ["FinderTagDict": ["value": ["FinderTags": [
                ["n": "Client", "l": 4],
                ["n": "Venice"],
                ["n": ""],
            ]]]],
        ]
        let url = dir.appendingPathComponent("finder.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)

        XCTAssertEqual(FinderTags.userDefinedTags(finderPreferences: url),
                       [FinderTag(name: "Client", color: .blue), FinderTag(name: "Venice")])

        let all = FinderTags.allUserTags(finderPreferences: url)
        XCTAssertEqual(Array(all.prefix(7)).map(\.color), FinderTagColor.finderMenuOrder)
        XCTAssertEqual(all.suffix(2).map(\.name), ["Client", "Venice"])

        // Unreadable plist → just the standard seven.
        let none = FinderTags.allUserTags(finderPreferences: dir.appendingPathComponent("missing.plist"))
        XCTAssertEqual(none.count, 7)
    }
}

//
//  DestinationSlotsTests.swift
//  ShrikeCoreTests
//
//  Copy / Move destination slots. Uses a private UserDefaults suite and temp folders.
//

import XCTest
@testable import ShrikeCore

final class DestinationSlotsTests: XCTestCase {

    var defaults: UserDefaults!
    var slots: DestinationSlots!
    var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = makeTestDefaults()
        slots = DestinationSlots(defaults: defaults)
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DestinationSlots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testStartsWithNineEmptySlots() {
        XCTAssertEqual(slots.slots().count, 9)
        XCTAssertTrue(slots.slots().allSatisfy { $0 == nil })
        XCTAssertThrowsError(try slots.resolve(1)) { XCTAssertEqual($0 as? DestinationSlotError, .empty(1)) }
    }

    func testSetResolveAndClear() throws {
        let selects = try folder("Selects")
        slots.set(4, folder: selects)

        let listed = slots.slots()
        XCTAssertEqual(listed.count, 9)
        XCTAssertEqual(listed[3]?.number, 4)
        XCTAssertEqual(listed[3]?.name, "Selects")
        XCTAssertEqual(slots.slot(4)?.url.path, selects.path)
        XCTAssertEqual(try slots.resolve(4).path, selects.path)

        slots.clear(4)
        XCTAssertNil(slots.slot(4))
        XCTAssertThrowsError(try slots.resolve(4)) { XCTAssertEqual($0 as? DestinationSlotError, .empty(4)) }
    }

    func testOutOfRangeNumbersAreIgnored() throws {
        let a = try folder("A")
        slots.set(0, folder: a)
        slots.set(10, folder: a)
        XCTAssertTrue(slots.slots().allSatisfy { $0 == nil })
        XCTAssertNil(slots.slot(0))
        XCTAssertThrowsError(try slots.resolve(10))
    }

    func testStoredAsJSONWithPathAndBookmark() throws {
        slots.set(1, folder: try folder("Client"))
        let data = try XCTUnwrap(defaults.data(forKey: DestinationSlots.Key.destinations))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json.count, 9)
        XCTAssertEqual((json[0]["path"] as? String).map { ($0 as NSString).lastPathComponent }, "Client")
        XCTAssertNotNil(json[0]["bookmark"] as? String, "bookmark data (base64 in JSON)")
        XCTAssertNil(json[1]["path"])
    }

    func testMissingFolderIsUnavailableWithItsName() throws {
        let client = try folder("Client")
        slots.set(2, folder: client)
        try FileManager.default.removeItem(at: client)
        XCTAssertEqual(slots.slot(2)?.name, "Client", "menus still show the slot")
        XCTAssertThrowsError(try slots.resolve(2)) {
            XCTAssertEqual($0 as? DestinationSlotError, .unavailable(name: "Client"))
        }
    }

    func testRenamedFolderIsFollowedAndPathUpdated() throws {
        let old = try folder("Selects")
        slots.set(3, folder: old)
        let renamed = root.appendingPathComponent("Picks", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed)

        let resolved = try slots.resolve(3)
        XCTAssertEqual(resolved.lastPathComponent, "Picks")
        XCTAssertEqual(slots.slot(3)?.url.lastPathComponent, "Picks", "stored path refreshed")
        XCTAssertEqual(slots.slot(3)?.name, "Picks")
    }

    func testLastDestinationPerVerb() throws {
        XCTAssertNil(slots.last(.copy))
        let a = try folder("A")
        let b = try folder("B")
        slots.setLast(a, for: .copy)
        slots.setLast(b, for: .move)
        XCTAssertEqual(slots.last(.copy)?.path, a.path)
        XCTAssertEqual(slots.last(.move)?.path, b.path)
        XCTAssertNotNil(defaults.data(forKey: "shrike.fileops.lastCopy"))

        try FileManager.default.removeItem(at: a)
        XCTAssertNil(slots.last(.copy), "gone folder → nil (UI opens the panel)")
    }

    func testChangeNotificationPosted() throws {
        let a = try folder("A")
        let posted = expectation(forNotification: DestinationSlots.didChangeNotification, object: nil)
        slots.set(1, folder: a)
        wait(for: [posted], timeout: 1)
    }

    func testKeysAreResetByPrefs() {
        for key in DestinationSlots.Key.all {
            XCTAssertTrue(Prefs.allUserDefaultsKeys.contains(key), key)
        }
    }
}

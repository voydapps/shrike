//
//  RenameRecoveryNoticeTests.swift
//  ShrikeUITests
//
//  B-7, spec 28 §18.1: the sheet and toast texts after a cut-off rename.
//  Window-free; file checks only under the XCTest root of ShrikeDataPaths.
//

import XCTest
import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

final class RenameRecoveryNoticeTests: XCTestCase {

    private typealias Item = RenameRecoveryNotice.Item
    private let tmp = ".shrike-rename-8F2A91C3-5B0E-4D7A-9C21-6E4F0A3B7D15-IMG_0042.jpg"

    private func item(_ name: String = "IMG_0042.jpg", temp: String? = nil, free: Bool = false) -> Item {
        Item(originalName: name, temporaryName: temp ?? tmp, folder: "~/Pictures/Trips", oldNameFree: free)
    }

    func testNothingToSay() {
        XCTAssertNil(RenameRecoveryNotice.make(items: [], backupsNotSaved: 0, historyNotRestored: 0))
    }

    func testOneItemWithCollision() {
        guard case .sheet(let title, let info)? = RenameRecoveryNotice.make(items: [item()], backupsNotSaved: 0, historyNotRestored: 0)
        else { return XCTFail("a sheet") }
        XCTAssertEqual(title, "A photo has a temporary name")
        XCTAssertEqual(info, "Shrike was closed while it was renaming “IMG_0042.jpg”. It is still in “~/Pictures/Trips”, now called “\(tmp)”. Shrike could not put the old name back, because a file with that name is already there.\n\nNames that start with a period are hidden in Finder. In Finder, press Command-Shift-Period to show them.")
    }

    func testOneItemFailedMoveAndBatchName() {
        guard case .sheet(_, let info)? = RenameRecoveryNotice.make(
            items: [item(temp: "IMG_0042 shrike-tmp-1A2B3C4D.jpg", free: true)], backupsNotSaved: 0, historyNotRestored: 0)
        else { return XCTFail("a sheet") }
        XCTAssertTrue(info.hasSuffix("Shrike could not put the old name back."))
        XCTAssertFalse(info.contains("Command-Shift-Period"), "no hidden-name paragraph without a leading period")
    }

    func testSeveralCappedAtThree() {
        let items = (1...5).map { item("IMG_000\($0).jpg", temp: "IMG_000\($0) shrike-tmp-AAAA000\($0).jpg") }
        guard case .sheet(let title, let info)? = RenameRecoveryNotice.make(items: items, backupsNotSaved: 0, historyNotRestored: 0)
        else { return XCTFail("a sheet") }
        XCTAssertEqual(title, "5 photos have temporary names")
        let lines = info.components(separatedBy: "\n")
        // Spec 28 §20.6: one folder for all: named once, in the lead.
        XCTAssertEqual(lines[0], "Shrike was closed while it was renaming these photos in “~/Pictures/Trips”, and could not put the old names back, because files with those names are already there.")
        XCTAssertEqual(lines[1], "“IMG_0001.jpg” is now")
        XCTAssertEqual(lines[2], "    “IMG_0001 shrike-tmp-AAAA0001.jpg”")
        XCTAssertFalse(info.contains("IMG_0004.jpg"))
        XCTAssertEqual(lines.last, "and 2 more")
    }

    func testSeveralFoldersNameTheFolderPerEntry() {
        var items = (1...2).map { item("IMG_000\($0).jpg", temp: "IMG_000\($0) shrike-tmp-AAAA000\($0).jpg", free: true) }
        items[1].folder = "~/Pictures/Family"
        guard case .sheet(_, let info)? = RenameRecoveryNotice.make(items: items, backupsNotSaved: 0, historyNotRestored: 0)
        else { return XCTFail("a sheet") }
        let lines = info.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "Shrike was closed while it was renaming these photos, and could not put the old names back.")
        XCTAssertEqual(lines[2], "    “IMG_0001 shrike-tmp-AAAA0001.jpg” in “~/Pictures/Trips”")
        XCTAssertEqual(lines[4], "    “IMG_0002 shrike-tmp-AAAA0002.jpg” in “~/Pictures/Family”")
    }

    func testOneFolderOldNamesFree() {
        let items = (1...2).map { item("IMG_000\($0).jpg", temp: "IMG_000\($0) shrike-tmp-AAAA000\($0).jpg", free: true) }
        guard case .sheet(_, let info)? = RenameRecoveryNotice.make(items: items, backupsNotSaved: 0, historyNotRestored: 0)
        else { return XCTFail("a sheet") }
        XCTAssertTrue(info.hasPrefix("Shrike was closed while it was renaming these photos in “~/Pictures/Trips”, and could not put the old names back.\n"), info)
    }

    func testCountsInTheSheet() {
        guard case .sheet(_, let one)? = RenameRecoveryNotice.make(items: [item()], backupsNotSaved: 1, historyNotRestored: 1)
        else { return XCTFail("a sheet") }
        let p = one.components(separatedBy: "\n\n")
        XCTAssertEqual(p[1], "Shrike lost track of the backup of 1 photo from that rename, so Revert to Original may be missing for it.")
        XCTAssertEqual(p[2], "For 1 photo from that rename, Shrike could not tell which backup belongs to it, so Revert to Original, its rating or tags may be missing. Nothing was deleted.")
        XCTAssertTrue(p[3].hasPrefix("Names that start with a period"), "hidden-name paragraph comes last")
        guard case .sheet(_, let many)? = RenameRecoveryNotice.make(items: [item()], backupsNotSaved: 4, historyNotRestored: 2)
        else { return XCTFail("a sheet") }
        XCTAssertTrue(many.contains("Shrike lost track of the backups of 4 photos from that rename, so Revert to Original may be missing for them."))
        XCTAssertTrue(many.contains("For 2 photos from that rename, Shrike could not tell which backup belongs to which photo, so Revert to Original, ratings or tags may be missing for them. Nothing was deleted."))
    }

    func testToastWithoutItems() {
        XCTAssertEqual(RenameRecoveryNotice.make(items: [], backupsNotSaved: 0, historyNotRestored: 3),
                       .toast("A rename was cut off. For 3 photos, Shrike could not tell which backup belongs to which photo, so Revert to Original, ratings or tags may be missing for them. Nothing was deleted."))
        XCTAssertEqual(RenameRecoveryNotice.make(items: [], backupsNotSaved: 1, historyNotRestored: 0),
                       .toast("A rename was cut off. Shrike lost track of the backup of 1 photo, so Revert to Original may be missing for it."))
        guard case .toast(let both)? = RenameRecoveryNotice.make(items: [], backupsNotSaved: 2, historyNotRestored: 1)
        else { return XCTFail("a toast") }
        XCTAssertEqual(both, "A rename was cut off. Shrike lost track of the backups of 2 photos and, for 1 photo, could not tell which backup belongs to it. Revert to Original, ratings or tags may be missing. Nothing was deleted.")
        XCTAssertEqual(RenameRecoveryNotice.make(items: [], backupsNotSaved: 12, historyNotRestored: 12),
                       .toast("A rename was cut off. Shrike lost track of the backups of 12 photos and, for 12 photos, could not tell which backup belongs to which. Revert to Original, ratings or tags may be missing. Nothing was deleted."))
        for word in ["history", "record", "chain", "journal"] { XCTAssertFalse(both.contains(word)) }
    }

    func testFolderTextShortensInTheMiddle() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertEqual(RenameRecoveryNotice.folderText(home.appendingPathComponent("Pictures/Trips")), "~/Pictures/Trips")
        let long = home.appendingPathComponent("Pictures/" + String(repeating: "very long folder name ", count: 4) + "/end")
        let text = RenameRecoveryNotice.folderText(long)
        XCTAssertEqual(text.count, 48)
        XCTAssertTrue(text.contains("…"))
        XCTAssertTrue(text.hasPrefix("~/Pictures"))
        XCTAssertTrue(text.hasSuffix("/end"))
    }

    func testItemsDropGoneTemporariesAndSeeFreeNames() throws {
        let dir = ShrikeDataPaths.testRoot.appendingPathComponent("rename-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tempA = dir.appendingPathComponent(".shrike-rename-X-a.jpg")
        let origA = dir.appendingPathComponent("a.jpg")
        let tempB = dir.appendingPathComponent("b shrike-tmp-12345678.jpg")
        let origB = dir.appendingPathComponent("b.jpg")
        let gone = dir.appendingPathComponent("c shrike-tmp-87654321.jpg")
        for url in [tempA, origA, tempB] { XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data())) }
        var recovery = RenameRecovery()
        recovery.needsAttention = [(UUID(), origA, tempA), (UUID(), origB, tempB),
                                   (UUID(), dir.appendingPathComponent("c.jpg"), gone)]
        let (items, temporaries) = RenameRecoveryNotice.items(from: recovery)
        XCTAssertEqual(temporaries, [tempA, tempB])
        XCTAssertEqual(items.map(\.originalName), ["a.jpg", "b.jpg"])
        XCTAssertEqual(items.map(\.oldNameFree), [false, true])
    }
}

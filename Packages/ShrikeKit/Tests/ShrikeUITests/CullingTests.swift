//
//  CullingTests.swift
//  ShrikeUITests
//
//  Rating and flag reach every image
//  member of a group, one undo step per press, redo works, pressing the
//  current rating keeps it. Temp folders and a temp database only.
//

import XCTest
import AppKit
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class CullingTests: XCTestCase {

    private var tempDir: URL!
    private var store: MetadataStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-culling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try MetadataStore(databaseURL: tempDir.appendingPathComponent("meta.sqlite"),
                                  writeFileAttributes: { false })
    }

    override func tearDown() async throws {
        CullingUndo.beforeWriteForTesting = nil
        await CullingUndo.waitForPendingWrites()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func file(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        return url
    }

    /// Waits until `condition` holds (writes are async).
    private func wait(_ condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition never held")
    }

    func testImmediateUndoAndRedoWaitForCommittedSnapshot() async throws {
        let a = try file("immediate.jpg"), raw = try file("immediate.raw")
        try await store.setRating(2, for: a)
        try await store.setRating(3, for: raw)
        let urls = [a, raw]
        let undo = UndoManager()
        undo.groupsByEvent = false
        var changes = 0
        undo.beginUndoGrouping()
        CullingUndo.perform(.rating, urls: urls, store: store, undoManager: undo,
            compute: { Culling.ratingValues(5, urls: urls, previous: $0) },
            onChange: { _ in changes += 1 })
        undo.endUndoGrouping()
        undo.undo()
        undo.redo()
        await CullingUndo.waitForPendingWrites()
        var records = await store.records(for: urls)
        XCTAssertEqual(records[a]?.rating, 5)
        XCTAssertEqual(records[raw]?.rating, 5)
        XCTAssertEqual(changes, 3)
        undo.undo()
        await CullingUndo.waitForPendingWrites()
        records = await store.records(for: urls)
        XCTAssertEqual(records[a]?.rating, 2)
        XCTAssertEqual(records[raw]?.rating, 3)
    }

    func testAlternatingFieldsAndImmediateUndoPreserveTheOtherField() async throws {
        let a = try file("alternating.jpg")
        let undo = UndoManager()
        undo.groupsByEvent = false
        func rate(_ value: Int) {
            undo.beginUndoGrouping()
            CullingUndo.perform(.rating, urls: [a], store: store, undoManager: undo,
                compute: { Culling.ratingValues(value, urls: [a], previous: $0) }, onChange: { _ in })
            undo.endUndoGrouping()
        }
        rate(1)
        undo.beginUndoGrouping()
        CullingUndo.perform(.flag, urls: [a], store: store, undoManager: undo,
            compute: { Culling.toggledFlagValues(urls: [a], leaders: [a], previous: $0) }, onChange: { _ in })
        undo.endUndoGrouping()
        rate(5)
        undo.undo()
        await CullingUndo.waitForPendingWrites()
        var record = await store.records(for: [a])[a]
        XCTAssertEqual(record?.rating, 1)
        XCTAssertEqual(record?.flagged, true)
        undo.undo()
        await CullingUndo.waitForPendingWrites()
        record = await store.records(for: [a])[a]
        XCTAssertEqual(record?.rating, 1)
        XCTAssertEqual(record?.flagged, false)
    }

    func testFailedWriteDoesNotPublishSuccessOrRemoveUnrelatedUndo() async throws {
        let a = try file("failure.jpg")
        let undo = UndoManager()
        undo.groupsByEvent = false
        let unrelated = Counter()
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: unrelated) { _ in }
        undo.setActionName("Unrelated")
        undo.endUndoGrouping()
        var changes = 0, failures = 0
        CullingUndo.beforeWriteForTesting = { throw CocoaError(.fileWriteNoPermission) }
        undo.beginUndoGrouping()
        CullingUndo.perform(.rating, urls: [a], store: store, undoManager: undo,
            compute: { Culling.ratingValues(5, urls: [a], previous: $0) },
            onChange: { _ in changes += 1 }, onFailure: { _ in failures += 1 })
        undo.endUndoGrouping()
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(undo.undoActionName, "Unrelated")
        let records = await store.records(for: [a])
        XCTAssertEqual(records[a]?.rating, 0)
    }

    func testFailedInverseAndImmediateRedoDoNotInventAChange() async throws {
        let a = try file("inverse.jpg")
        let undo = UndoManager()
        undo.groupsByEvent = false
        var changes = 0, failures = 0
        undo.beginUndoGrouping()
        CullingUndo.perform(.rating, urls: [a], store: store, undoManager: undo,
            compute: { Culling.ratingValues(4, urls: [a], previous: $0) },
            onChange: { _ in changes += 1 }, onFailure: { _ in failures += 1 })
        undo.endUndoGrouping()
        await CullingUndo.waitForPendingWrites()
        CullingUndo.beforeWriteForTesting = { throw CocoaError(.fileWriteNoPermission) }
        undo.undo()
        undo.redo()
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(failures, 1)
        let records = await store.records(for: [a])
        XCTAssertEqual(records[a]?.rating, 4)
    }

    func testImageMembersSkipSidecarsAndMovies() throws {
        let jpg = try file("P1.JPG"), raw = try file("P1.ORF"), xmp = try file("P1.xmp")
        let group = ImageGroup(primary: jpg, companions: [
            .init(url: raw, kind: .raw), .init(url: xmp, kind: .sidecar),
        ])
        XCTAssertEqual(Culling.imageURLs(of: group), [jpg, raw])
    }

    /// A pair rated 4 stars has 4 on both files.
    func testRatingAPairWritesBothFilesAndUndoRestores() async throws {
        let jpg = try file("P1.JPG"), raw = try file("P1.ORF")
        let group = ImageGroup(primary: jpg, companions: [.init(url: raw, kind: .raw)])
        let urls = Culling.imageURLs(of: group)
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = self.store!
        let changes = Counter()
        undo.beginUndoGrouping()
        CullingUndo.perform(.rating, urls: urls, store: store, undoManager: undo,
                            compute: { Culling.ratingValues(4, urls: urls, previous: $0) },
                            onChange: { _ in changes.n += 1 })
        undo.endUndoGrouping()
        await wait { changes.n == 1 }
        let saved = await store.records(for: urls)
        XCTAssertEqual(saved[jpg]?.rating, 4)
        XCTAssertEqual(saved[raw]?.rating, 4)
        XCTAssertEqual(undo.undoActionName, "Rating")

        undo.undo()
        await wait { changes.n == 2 }
        let undone = await store.records(for: urls)
        XCTAssertEqual(undone[jpg]?.rating, 0)
        XCTAssertEqual(undone[raw]?.rating, 0)
        XCTAssertTrue(undo.canRedo)

        undo.redo()
        await wait { changes.n == 3 }
        let redone = await store.records(for: urls)
        XCTAssertEqual(redone[jpg]?.rating, 4)
    }

    /// A browser multi-selection is one undo step.
    func testMultiSelectionFlagIsOneUndoStep() async throws {
        let a = try file("a.jpg"), b = try file("b.jpg"), c = try file("c.jpg")
        try await store.setFlag(true, for: b)
        let urls = [a, b, c]
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = self.store!
        let changes = Counter()
        undo.beginUndoGrouping()
        CullingUndo.perform(.flag, urls: urls, store: store, undoManager: undo,
                            compute: { Culling.toggledFlagValues(urls: urls, leaders: urls, previous: $0) },
                            onChange: { _ in changes.n += 1 })
        undo.endUndoGrouping()
        await wait { changes.n == 1 }
        let flagged = await store.records(for: urls)
        XCTAssertEqual(urls.map { flagged[$0]?.flagged }, [true, true, true])
        undo.undo()
        await wait { changes.n == 2 }
        let back = await store.records(for: urls)
        XCTAssertEqual(urls.map { back[$0]?.flagged }, [false, true, false])
        XCTAssertFalse(undo.canUndo)
    }

    func testPressingCurrentRatingKeepsIt() {
        let url = URL(fileURLWithPath: "/tmp/x.jpg")
        let values = Culling.ratingValues(3, urls: [url], previous: [url: FileRecord(rating: 3)])
        XCTAssertEqual(values[url]?.rating, 3)
    }

    func testAnnouncementsAndPillAccessibility() {
        XCTAssertEqual(Culling.ratingAnnouncement(3), "Rated 3 stars")
        XCTAssertEqual(Culling.ratingAnnouncement(1), "Rated 1 star")
        XCTAssertEqual(Culling.ratingAnnouncement(0), "Rating cleared")
        XCTAssertEqual(Culling.flagAnnouncement(true), "Flagged")
        XCTAssertEqual(Culling.flagAnnouncement(false), "Flag removed")
        XCTAssertEqual(PillMarks(rating: 3, flagged: true, hasRAW: true).accessibilitySuffix,
                       ", 3 stars, flagged, with RAW file")
        XCTAssertEqual(PillMarks().accessibilitySuffix, "")
        // Only set values are drawn: no stars for 0.
        let text = PillMarks.attributedText(base: "1 / 2", marks: PillMarks()).string
        XCTAssertEqual(text, "1 / 2")
        XCTAssertTrue(PillMarks.attributedText(base: "1 / 2", marks: PillMarks(rating: 2)).string.contains("★★"))
    }

    /// FastStone preset: ⌃3 rates, bare 3 zooms.
    func testRatingKeysPerPreset() {
        let mac = ShortcutTable.command(for: ShrikeUI.KeyEventSnapshot(key: "3"), context: .viewer, preset: .macNative)
        XCTAssertEqual(mac, .rate3)
        let fsCtrl = ShortcutTable.command(for: ShrikeUI.KeyEventSnapshot(key: "3", modifiers: .control),
                                           context: .viewer, preset: .fastStoneCompat)
        XCTAssertEqual(fsCtrl, .rate3)
        let fsBare = ShortcutTable.command(for: ShrikeUI.KeyEventSnapshot(key: "3"), context: .viewer, preset: .fastStoneCompat)
        XCTAssertEqual(fsBare, .zoom300)
    }
}

@MainActor
private final class Counter { var n = 0 }

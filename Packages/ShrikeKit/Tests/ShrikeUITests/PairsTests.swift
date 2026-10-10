//
//  PairsTests.swift
//  ShrikeUITests
//
//  The inspector's "Also:" line and the
//  RAW+JPEG pairs preference ("Show both files" lists a pair as two
//  items; changing it tells open windows to list again).
//

import XCTest
import os
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class PairsTests: XCTestCase {

    private var dir: URL!
    private var savedPref: Any?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-pairs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedPref = ShrikeDefaults.store.object(forKey: ImageGroupingPreference.key)
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.set(savedPref, forKey: ImageGroupingPreference.key)
        try? FileManager.default.removeItem(at: dir)
    }

    private func file(_ name: String, bytes: Int = 3) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0xFF, count: bytes).write(to: url)
        return url
    }

    func testAlsoLineNamesTheRAWWithItsSize() throws {
        let jpg = try file("DSC_0042.JPG"), orf = try file("DSC_0042.ORF", bytes: 2_000_000)
        let xmp = try file("DSC_0042.xmp")
        let group = ImageGroup(primary: jpg, companions: [.init(url: orf, kind: .raw), .init(url: xmp, kind: .sidecar)])
        let size = ByteCountFormatter.string(fromByteCount: 2_000_000, countStyle: .file)
        XCTAssertEqual(PairCopy.alsoLine(for: group), "Also: DSC_0042.ORF (\(size))")
        XCTAssertNil(PairCopy.alsoLine(for: ImageGroup(primary: jpg)))

        var item = try BrowserItem.make(from: jpg)
        item.group = group
        XCTAssertEqual(InspectorState.reduce([item]).alsoLine, "Also: DSC_0042.ORF (\(size))")
    }

    // "Show both files" lists the pair as 2 items.
    func testShowBothFilesListsPairAsTwoItems() async throws {
        _ = try file("P1.JPG")
        _ = try file("P1.ORF")
        let posted = expectation(forNotification: .shrikeGroupingDidChange, object: nil)
        posted.assertForOverFulfill = false
        PairsPreference.set(showAsOneItem: true)
        PairsPreference.set(showAsOneItem: false)
        await fulfillment(of: [posted], timeout: 1)
        let both = try await FolderScanner.imageGroups(in: dir, grouping: ImageGroupingPreference.options)
        XCTAssertEqual(both.count, 2)
        PairsPreference.set(showAsOneItem: true)
        let one = try await FolderScanner.imageGroups(in: dir, grouping: ImageGroupingPreference.options)
        XCTAssertEqual(one.count, 1)
        XCTAssertTrue(one[0].hasRAW)
    }

    // The change is posted on the main thread even when set from a
    // background queue: BrowserWindowController observes it with a
    // main-actor selector, which would trap if called off the main thread.
    func testGroupingChangeFromBackgroundIsPostedOnMainThread() async throws {
        PairsPreference.set(showAsOneItem: true)
        let delivered = expectation(description: "grouping change posted")
        let onMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let token = NotificationCenter.default.addObserver(
            forName: .shrikeGroupingDidChange, object: nil, queue: nil
        ) { _ in
            onMain.withLock { $0 = Thread.isMainThread }
            delivered.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }
        DispatchQueue.global().async { PairsPreference.set(showAsOneItem: false) }
        await fulfillment(of: [delivered], timeout: 2)
        XCTAssertEqual(onMain.withLock { $0 }, true)
    }
}

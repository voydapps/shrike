//
//  BrowserSortTests.swift
//  ShrikeUITests
//
//  Sort keys, values, ties, the saved choice, values read
//  off the main thread with one re-sort, and speed at 5,000 files.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserSortTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-sort-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ name: String, size: Int64 = 1, type: UTType = .jpeg, rating: Int = 0,
                      created: Date? = nil, captured: Date? = nil,
                      width: Int? = nil, height: Int? = nil) -> BrowserItem {
        BrowserItem(url: URL(fileURLWithPath: "/tmp/\(name)"), displayName: name, fileSize: size,
                    modificationDate: Date(timeIntervalSinceReferenceDate: 0), creationDate: created,
                    captureDate: captured, utType: type, pixelWidth: width, pixelHeight: height, rating: rating)
    }

    private func names(_ items: [BrowserItem]) -> [String] { items.map(\.displayName) }

    private func sorted(_ items: [BrowserItem], _ key: BrowserSortKey, _ asc: Bool = true) -> [String] {
        names(BrowserPipeline.apply(sort: BrowserSort(key: key, direction: asc ? .ascending : .descending), to: items))
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                   UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    // MARK: Menu

    func testMenuKeysAndTitles() {
        XCTAssertEqual(BrowserSortKey.allCases.map(\.rawValue),
                       ["name", "dateCaptured", "dateModified", "size", "rating", "kind", "dimensions"])
        XCTAssertEqual(BrowserSortKey.allCases.map(\.displayName),
                       ["Name", "Date Captured", "Date Modified", "Size", "Rating", "Kind", "Dimensions"])
        for (n, command) in BrowserToolbarLayout.sortCommands.enumerated() {
            let binding = ShortcutTable.menuBinding(for: command)
            XCTAssertEqual(binding?.menuKeyEquivalent, "\(n + 1)", command.rawValue)
            XCTAssertEqual(binding?.modifiers, [.control, .option, .command], command.rawValue)
        }
    }

    // MARK: Values and ties

    func testNameUsesFinderOrder() {
        let items = [item("IMG_10.jpg"), item("img_2.jpg"), item("IMG_1.jpg")]
        XCTAssertEqual(sorted(items, .name), ["IMG_1.jpg", "img_2.jpg", "IMG_10.jpg"])
        XCTAssertEqual(sorted(items, .name, false), ["IMG_10.jpg", "img_2.jpg", "IMG_1.jpg"])
    }

    func testTiesBreakByNameAscendingInBothDirections() {
        let items = [item("c.jpg", size: 5), item("b.jpg", size: 9), item("a.jpg", size: 5)]
        XCTAssertEqual(sorted(items, .size), ["a.jpg", "c.jpg", "b.jpg"])
        XCTAssertEqual(sorted(items, .size, false), ["b.jpg", "a.jpg", "c.jpg"])
        let rated = [item("z.jpg", rating: 3), item("m.jpg", rating: 3), item("a.jpg", rating: 1)]
        XCTAssertEqual(sorted(rated, .rating, false), ["m.jpg", "z.jpg", "a.jpg"])
    }

    func testKindSortsByLocalizedDescription() throws {
        let items = [item("a.png", type: .png), item("b.jpg", type: .jpeg), item("c.heic", type: .heic),
                     item("d.jpg", type: .jpeg)]
        let expected = items.sorted {
            let l = $0.utType.localizedDescription ?? "", r = $1.utType.localizedDescription ?? ""
            return l == r ? $0.displayName < $1.displayName : l.localizedStandardCompare(r) == .orderedAscending
        }
        XCTAssertEqual(sorted(items, .kind), names(expected))
        XCTAssertNotEqual(UTType.jpeg.localizedDescription, UTType.jpeg.identifier, "a name, not the UTI")
    }

    func testDateCapturedFallsBackToTheCreationDate() {
        let d = { (t: Double) in Date(timeIntervalSinceReferenceDate: t) }
        let items = [item("a.jpg", created: d(300)), item("b.jpg", created: d(900), captured: d(100)),
                     item("c.jpg", created: d(200)), item("d.jpg")]
        XCTAssertEqual(sorted(items, .dateCaptured), ["b.jpg", "c.jpg", "a.jpg", "d.jpg"], "no date at all: last")
        XCTAssertEqual(sorted(items, .dateCaptured, false), ["a.jpg", "c.jpg", "b.jpg", "d.jpg"])
        // Values read from the files win over the listing's.
        let read: [URL: SortValue] = [items[2].group.primary: .date(d(50))]
        let withRead = BrowserPipeline.apply(sort: BrowserSort(key: .dateCaptured), to: items, values: read)
        XCTAssertEqual(names(withRead).first, "c.jpg")
    }

    func testDimensionsUsePixelCountAndZeroWhenUnknown() {
        let items = [item("a.jpg", width: 100, height: 100), item("b.jpg"), item("c.jpg", width: 50, height: 50)]
        XCTAssertEqual(sorted(items, .dimensions), ["b.jpg", "c.jpg", "a.jpg"])
    }

    // MARK: Saved choice

    func testChoiceIsSaved() throws {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        content.sort = BrowserSort(key: .size, direction: .descending)
        XCTAssertEqual(Prefs.browserSortKey, "size")
        XCTAssertFalse(Prefs.browserSortAscending)
        XCTAssertEqual(BrowserSort.saved, BrowserSort(key: .size, direction: .descending))
        let next = BrowserContentViewController(services: ShrikeServices.makeDefault())
        XCTAssertEqual(next.sort, BrowserSort(key: .size, direction: .descending), "one global setting")
    }

    // MARK: Values read off the main thread

    func testDimensionsReadThenReSortOnceKeepingTheSelection() async throws {
        try writeJPEG("a.jpg", width: 300, height: 200)
        try writeJPEG("b.jpg", width: 40, height: 30)
        try writeJPEG("c.jpg", width: 120, height: 90)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let listed = await waitUntil { content.visibleItems.count == 3 }
        XCTAssertTrue(listed)
        XCTAssertEqual(names(content.visibleItems), ["a.jpg", "b.jpg", "c.jpg"])
        content.select(url: dir.appendingPathComponent("a.jpg"))

        content.sort = BrowserSort(key: .dimensions)
        XCTAssertEqual(names(content.visibleItems), ["a.jpg", "b.jpg", "c.jpg"], "old order until the values are in")
        XCTAssertTrue(content.isReadingSortValuesForTesting)
        XCTAssertTrue(browser.statusTextForTesting.hasPrefix("Sorting by Dimensions…"), browser.statusTextForTesting)
        await content.waitForSortRead()
        XCTAssertEqual(names(content.visibleItems), ["b.jpg", "c.jpg", "a.jpg"])
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["a.jpg"], "selection kept")
        XCTAssertFalse(browser.statusTextForTesting.hasPrefix("Sorting"), "progress cleared")

        // Direction flips at once: the values are already in.
        content.sort = BrowserSort(key: .dimensions, direction: .descending)
        XCTAssertFalse(content.isReadingSortValuesForTesting)
        XCTAssertEqual(names(content.visibleItems), ["a.jpg", "c.jpg", "b.jpg"])
    }

    func testFolderChangeCancelsTheRead() async throws {
        for i in 0..<3 { try writeJPEG("p\(i).jpg", width: 64 + i, height: 48) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        _ = await waitUntil { content.visibleItems.count == 3 }
        content.sort = BrowserSort(key: .dateCaptured)
        XCTAssertTrue(content.isReadingSortValuesForTesting)
        content.setItems([item("x.jpg")])
        XCTAssertEqual(browser.sortProgressText, BrowserBottomBar.sortingText(key: "Date Captured", done: 0, total: 1),
                       "a new listing drops the old read and reads its own")
        content.sort = BrowserSort(key: .size)
        XCTAssertFalse(content.isReadingSortValuesForTesting, "a key change cancels the read")
    }

    // MARK: Speed

    func testSortingFiveThousandItemsFitsInAFrame() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var items: [BrowserItem] = []
        for i in 0..<5000 {
            let n = (i * 7919) % 5000
            items.append(item(String(format: "DSC_%05d.JPG", n), size: Int64((n * 31) % 997),
                              type: n % 3 == 0 ? .png : .jpeg, rating: n % 6,
                              created: start.addingTimeInterval(Double((n * 13) % 4999))))
        }
        let listed = BrowserPipeline.nameOrdered(items)   // done off the main thread when listing
        var worst: TimeInterval = 0
        for key in BrowserSortKey.allCases {
            // The median of five runs: one slow run (another process taking
            // the CPU) does not fail the test, but a sort that got slower
            // on every run still does.
            var times: [TimeInterval] = []
            for _ in 0..<5 {
                let t0 = Date()
                let out = BrowserPipeline.apply(sort: BrowserSort(key: key, direction: .descending), to: listed)
                times.append(Date().timeIntervalSince(t0))
                XCTAssertEqual(out.count, 5000)
            }
            worst = max(worst, times.sorted()[times.count / 2])
        }
        // Debug builds run the sort several times slower than Release.
        XCTAssertLessThan(worst * 1000, 50, "worst key: \(Int(worst * 1000)) ms (debug build)")
        print("sort 5000 worst key (debug): \(Int(worst * 1000)) ms")
    }
}

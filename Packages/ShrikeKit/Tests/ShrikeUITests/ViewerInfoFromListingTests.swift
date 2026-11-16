//
//  ViewerInfoFromListingTests.swift
//  ShrikeUITests
//
//  The viewer's Info panel fills Size, Modified and Dimensions in the same
//  turn as the photo change when the paired Browser's listing knows them;
//  the header read off the main thread then confirms or corrects them.
//  Without a listing the rows fill when the read lands; a read for a photo
//  no longer shown is dropped.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ViewerInfoFromListingTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory.appendingPathComponent("shrike-info-listing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String, width: Int, height: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func value(_ panel: InspectorPanel, _ label: String) -> String? {
        panel.modelForTesting.facts.file.first { $0.label == label }?.value
    }

    private func panel() -> InspectorPanel {
        let panel = InspectorPanel()
        panel.headerReadsEnabled = true
        return panel
    }

    func testListingFillsTheRowsInTheSameTurnAndTheReadCorrectsThem() async throws {
        let url = try jpeg("a.jpg", width: 240, height: 160)
        let panel = panel()
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        panel.setListingFacts([url: InspectorFileInput(type: .jpeg, pixelWidth: 4000, pixelHeight: 3000,
                                                       fileSize: 2_000_000, modified: modified)])
        panel.updateForURL(url)
        XCTAssertEqual(value(panel, "Dimensions"), "4000 × 3000")
        XCTAssertEqual(value(panel, "Size"), FileSizeText.string(2_000_000))
        XCTAssertNotEqual(value(panel, "Modified"), InspectorRows.emptyValue)
        XCTAssertEqual(value(panel, "Folder"), dir.lastPathComponent)
        await panel.waitForInfo()
        XCTAssertEqual(value(panel, "Dimensions"), "240 × 160", "the read corrects the listing")
        let size = try XCTUnwrap(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(value(panel, "Size"), FileSizeText.string(Int64(size)))
    }

    func testWithoutListingTheRowsFillWhenTheReadLands() async throws {
        let url = try jpeg("b.jpg", width: 240, height: 160)
        let panel = panel()
        panel.updateForURL(url)
        XCTAssertEqual(value(panel, "Dimensions"), InspectorRows.emptyValue)
        XCTAssertEqual(value(panel, "Size"), InspectorRows.emptyValue)
        XCTAssertEqual(value(panel, "Modified"), InspectorRows.emptyValue)
        await panel.waitForInfo()
        XCTAssertEqual(value(panel, "Dimensions"), "240 × 160")
        XCTAssertNotEqual(value(panel, "Size"), InspectorRows.emptyValue)
        XCTAssertNotEqual(value(panel, "Modified"), InspectorRows.emptyValue)
    }

    /// A new viewer shows its first photo before the listing is handed over.
    func testListingArrivingAfterTheFirstPhotoFillsItAtOnce() async throws {
        let url = try jpeg("c.jpg", width: 240, height: 160)
        let panel = panel()
        panel.updateForURL(url)
        XCTAssertEqual(value(panel, "Size"), InspectorRows.emptyValue)
        panel.setListingFacts([url: InspectorFileInput(type: .jpeg, pixelWidth: 240, pixelHeight: 160,
                                                       fileSize: 1234, modified: Date())])
        XCTAssertEqual(value(panel, "Size"), FileSizeText.string(1234))
        XCTAssertEqual(value(panel, "Dimensions"), "240 × 160")
    }

    func testAReadForAPhotoNoLongerShownIsDropped() async throws {
        let first = try jpeg("d.jpg", width: 240, height: 160)
        let second = try jpeg("e.jpg", width: 64, height: 48)
        let panel = panel()
        panel.updateForURL(first)
        panel.updateForURL(nil)
        await panel.waitForInfo()
        try? await Task.sleep(for: .milliseconds(200))   // any late read of the first photo
        XCTAssertNil(panel.modelForTesting.url)
        XCTAssertEqual(panel.modelForTesting.facts.file, [])
        panel.updateForURL(second)
        await panel.waitForInfo()
        XCTAssertEqual(value(panel, "Dimensions"), "64 × 48")
    }

    /// After a rotate or save the listing's values are old: a later visit
    /// does not show them again.
    /// A paired viewer gets the first photo's facts at once and the rest of the
    /// listing when the walk off the main thread lands; the next photo then fills
    /// in the same turn. A walk of an older listing is dropped.
    func testTheRestOfTheListingLandsLaterAndAnOlderWalkIsDropped() async throws {
        let a = try jpeg("rest-a.jpg", width: 240, height: 160), b = try jpeg("rest-b.jpg", width: 240, height: 160)
        let panel = panel()
        let first = InspectorFileInput(type: .jpeg, pixelWidth: 4000, pixelHeight: 3000, fileSize: 1, modified: nil)
        let second = InspectorFileInput(type: .jpeg, pixelWidth: 6000, pixelHeight: 4000, fileSize: 2, modified: nil)
        let generation = panel.setListingFacts([a: first])
        panel.updateForURL(a)
        XCTAssertEqual(value(panel, "Dimensions"), "4000 × 3000", "the first photo's rows come with it")
        panel.addListingFacts([a: first, b: second], generation: generation)
        panel.updateForURL(b)
        XCTAssertEqual(value(panel, "Dimensions"), "6000 × 4000", "the next photo fills from the landed walk")
        // A newer listing: the older walk's facts are not used.
        let old = panel.setListingFacts([a: first])
        let newer = panel.setListingFacts([a: first])
        XCTAssertNotEqual(old, newer)
        panel.addListingFacts([a: first, b: second], generation: old)
        panel.updateForURL(a); panel.updateForURL(b)
        XCTAssertNotEqual(value(panel, "Dimensions"), "6000 × 4000", "a stale walk is dropped")
        await panel.waitForInfo()
    }

    /// A file changed on disk before the walk landed keeps its listing values forgotten.
    func testAWalkLandingAfterAReloadDoesNotBringBackOldValues() async throws {
        let a = try jpeg("reload-a.jpg", width: 240, height: 160), b = try jpeg("reload-b.jpg", width: 240, height: 160)
        let panel = panel()
        let old = InspectorFileInput(type: .jpeg, pixelWidth: 4000, pixelHeight: 3000, fileSize: 1, modified: nil)
        let generation = panel.setListingFacts([a: old])
        panel.updateForURL(a)
        panel.reloadFileFacts()
        panel.addListingFacts([a: old, b: old], generation: generation)
        panel.updateForURL(b); panel.updateForURL(a)
        XCTAssertNotEqual(value(panel, "Dimensions"), "4000 × 3000", "the reloaded photo's old listing value stays gone")
        await panel.waitForInfo()
        XCTAssertEqual(value(panel, "Dimensions"), "240 × 160")
    }

    func testReloadForgetsTheListingValuesOfThatPhoto() async throws {
        let url = try jpeg("f.jpg", width: 240, height: 160)
        let other = try jpeg("g.jpg", width: 64, height: 48)
        let panel = panel()
        panel.setListingFacts([url: InspectorFileInput(type: .jpeg, pixelWidth: 4000, pixelHeight: 3000,
                                                       fileSize: 99, modified: Date())])
        panel.updateForURL(url)
        panel.reloadFileFacts()
        await panel.waitForInfo()
        panel.updateForURL(other)
        panel.updateForURL(url)
        XCTAssertEqual(value(panel, "Dimensions"), InspectorRows.emptyValue)
    }

    // MARK: pass 3b - late rows without a listing do not move the panel

    /// A viewer opened from Finder has no listing: Type is known at once,
    /// Dimensions / Size / Modified show the dash and keep their place; the
    /// read fills the same rows. Only rows that did not exist before
    /// (Color profile) may be added.
    func testWithoutAListingTheLateRowsKeepTheirPlace() async throws {
        let url = try jpeg("late.jpg", width: 240, height: 160)
        let panel = panel()
        panel.updateForURL(url)
        let before = panel.modelForTesting.facts.file
        XCTAssertEqual(before.prefix(4).map(\.label), ["Type", "Dimensions", "Size", "Modified"])
        for label in ["Dimensions", "Size", "Modified"] {
            XCTAssertEqual(before.first { $0.label == label }?.value, InspectorRows.emptyValue, label)
        }
        await panel.waitForInfo()
        let after = panel.modelForTesting.facts.file
        XCTAssertEqual(after.prefix(4).map(\.label), before.prefix(4).map(\.label), "same rows, same order")
        for label in ["Dimensions", "Size", "Modified"] {
            XCTAssertNotEqual(after.first { $0.label == label }?.value, InspectorRows.emptyValue, label)
        }
        let added = Set(after.map(\.label)).subtracting(before.map(\.label))
        XCTAssertTrue(added.isSubset(of: ["Color profile"]), "rows that came late: \(added)")
    }

    /// The same, in laid-out height: the facts landing change no row height.
    /// The control (a Color profile row) must change it, or the check is blind.
    func testLandingFactsDoNotChangeTheLaidOutHeight() async throws {
        let url = try jpeg("height.jpg", width: 240, height: 160)
        let panel = panel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = panel
        panel.frame = NSRect(x: 0, y: 0, width: 300, height: 700)
        panel.updateForURL(url)
        await panel.waitForInfo()   // the real read lands first; our facts below replace it
        func height(_ facts: InspectorFacts) async -> CGFloat {
            panel.modelForTesting.facts = facts
            panel.contentViewForTesting.layoutSubtreeIfNeeded()
            panel.layoutSubtreeIfNeeded()
            // SwiftUI reports the height after its own layout turn.
            for _ in 0..<50 { await Task.yield() }
            return panel.modelForTesting.contentHeight
        }
        let known = InspectorFileInput(type: .jpeg, pixelWidth: 4000, pixelHeight: 3000, fileSize: 123_456,
                                       modified: Date(timeIntervalSince1970: 1_700_000_000),
                                       folder: dir.lastPathComponent)
        let empty = InspectorFileInput(type: .jpeg, folder: dir.lastPathComponent)
        var facts = InspectorFacts()
        facts.file = InspectorRows.fileRows(empty)
        let before = await height(facts)
        facts.file = InspectorRows.fileRows(known)
        let after = await height(facts)
        var withProfile = known
        withProfile.colorProfile = "sRGB IEC61966-2.1"
        facts.file = InspectorRows.fileRows(withProfile)
        let control = await height(facts)
        XCTAssertGreaterThan(before, 0, "the panel laid out")
        XCTAssertEqual(before, after, accuracy: 0.5, "dashes and values take the same height")
        XCTAssertGreaterThan(control, after + 5, "a new row is visible to this check")
    }
}

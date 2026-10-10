//
//  InspectorRowsTests.swift
//  ShrikeUITests
//
//  Inspector rows.
//

import XCTest
import AppKit
import ImageIO
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class InspectorRowsTests: XCTestCase {

    private let gb = Locale(identifier: "en_GB")

    // 33.86° S, 151.21° E reads "33.8600° S, 151.2100° E"
    // (the Ref tags give the sign).
    func testSouthAndWestComeFromTheRefTags() {
        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 33.86, kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.21, kCGImagePropertyGPSLongitudeRef: "E",
        ]
        let info = PhotoInfo.parse(properties: [kCGImagePropertyGPSDictionary: gps], typeIdentifier: "public.jpeg")
        XCTAssertEqual(InspectorRows.location(info), "33.8600° S, 151.2100° E")
        let west = PhotoInfo.parse(properties: [kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 40.7, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 74.0, kCGImagePropertyGPSLongitudeRef: "W",
        ] as [CFString: Any]], typeIdentifier: "public.jpeg")
        XCTAssertEqual(InspectorRows.location(west), "40.7000° N, 74.0000° W")
    }

    // No lens data → no Lens row; missing values → no rows.
    func testMissingValuesHaveNoRows() {
        var info = PhotoInfo()
        info.make = "Canon"
        info.model = "Canon EOS R5"
        info.aperture = 2.8
        info.shutter = 1.0 / 250
        info.iso = 200
        let labels = InspectorRows.capture(info, locale: gb).map(\.label)
        XCTAssertEqual(labels, ["Camera", "Aperture", "Shutter", "ISO"])
        XCTAssertFalse(labels.contains("Lens"))
        XCTAssertNil(InspectorRows.location(info))
    }

    func testCaptureFormats() {
        var info = PhotoInfo()
        info.dateTaken = Date(timeIntervalSince1970: 1_790_344_951) // 2026-09-25 14:02:31 UTC
        info.dateTakenOffsetSeconds = 0
        info.make = "FUJIFILM"
        info.model = "X-T5"
        info.lens = "M.Zuiko 25mm F1.8"
        info.aperture = 2.8
        info.shutter = 2.5
        info.iso = 200
        info.focal = 25
        info.focal35 = 50
        info.exposureBias = -0.7
        info.flashFired = false
        info.whiteBalanceAuto = true
        let rows = Dictionary(uniqueKeysWithValues: InspectorRows.capture(info, locale: gb).map { ($0.label, $0.value) })
        XCTAssertTrue(rows["Date taken"]?.contains("2026") ?? false)
        XCTAssertTrue(rows["Date taken"]?.contains("14:02:31") ?? false, "shown in the recorded offset")
        XCTAssertEqual(rows["Camera"], "FUJIFILM X-T5")
        XCTAssertEqual(rows["Lens"], "M.Zuiko 25mm F1.8")
        XCTAssertEqual(rows["Aperture"], "ƒ/2.8")
        XCTAssertEqual(rows["Shutter"], "2.5 s")
        XCTAssertEqual(rows["ISO"], "200")
        XCTAssertEqual(rows["Focal length"], "25 mm (50 mm equiv.)")
        XCTAssertEqual(rows["Exposure bias"], "\u{2212}0.7 EV")
        XCTAssertEqual(rows["Flash"], "Did not fire")
        XCTAssertEqual(rows["White balance"], "Auto")
    }

    func testFileRows() {
        var info = PhotoInfo()
        info.pixelWidth = 6000
        info.pixelHeight = 4000
        info.typeName = "JPEG"
        info.colorProfileName = "Display P3"
        let url = URL(fileURLWithPath: "/tmp/Italy 2026/DSC_0042.jpg")
        let rows = InspectorRows.file(url: url, fileSize: 12_400_000, info: info)
        XCTAssertEqual(rows.map(\.label), ["Name", "Folder", "Size", "Dimensions", "Type", "Colour profile"])
        XCTAssertEqual(rows[1].value, "Italy 2026")
        XCTAssertEqual(rows[3].value, "6000 × 4000 (24.0 MP)")
        XCTAssertEqual(InspectorRows.file(url: url, fileSize: nil, info: nil).map(\.label), ["Name", "Folder"])
        XCTAssertTrue(InspectorRows.originalKept(since: Date(timeIntervalSince1970: 1_790_344_951), locale: gb)
            .hasPrefix("Original kept since "))
    }

    // The viewer inspector's Culling row acts on the displayed item and
    // mirrors the pill marks; the File rows follow the displayed file.
    func testViewerInspectorRowsFollowTheDisplayedItem() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-insp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let jpg = dir.appendingPathComponent("P1.JPG"), orf = dir.appendingPathComponent("P1.ORF")
        try SaveFlowTests.writeImage(jpg, type: .jpeg)
        try Data(repeating: 1, count: 2048).write(to: orf)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let group = ImageGroup(primary: jpg, companions: [.init(url: orf, kind: .raw)])
        let viewer = ViewerWindow(groups: [group], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        let panel = viewer.contentRootForTesting.inspectorPanel
        // Header reads start once an inspector has been shown.
        panel.headerReadsEnabled = true
        viewer.contentRootForTesting.setCurrentURL(jpg)
        viewer.refreshInspectorFileState()
        await panel.waitForInfo()
        let model = panel.modelForTesting
        XCTAssertEqual(model.url, jpg)
        XCTAssertTrue(model.alsoLine?.hasPrefix("Also: P1.ORF") ?? false)
        XCTAssertTrue(model.facts.file.map(\.label).contains("Dimensions"))

        var opened: TagEditSession?
        viewer.tagPopoverPresenterForTesting = { opened = $0 }
        panel.onAddTag?(panel)
        XCTAssertEqual(opened?.groups.map(\.primary), [jpg])
        var marks = PillMarks()
        marks.rating = 3
        marks.flagged = true
        viewer.contentRootForTesting.setPositionMarks(marks)
        XCTAssertEqual(model.marks.rating, 3, "the stars mirror the pill marks")
        XCTAssertTrue(model.marks.flagged)
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

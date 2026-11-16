//
//  InspectorOnePanel028Tests.swift
//  ShrikeUITests
//
//  Spec 28 §7 (L-8 + H-6): the viewer's info panel and the Browser's info
//  pane build their shared rows from the same code. Each side is driven
//  through its real path (Browser: item → reduce → filled; viewer: facts).
//

import XCTest
import UniformTypeIdentifiers
@testable import ShrikeUI
import ShrikeCore

@MainActor
final class InspectorOnePanel028Tests: XCTestCase {

    private let taken = Date(timeIntervalSince1970: 1_794_265_479) // 2026-11-10 23:04:39 UTC
    private let modified = Date(timeIntervalSince1970: 1_794_300_000)
    private let url = URL(fileURLWithPath: "/tmp/Italy 2026/DSC_0042.jpg")

    private func fakeInfo() -> PhotoInfo {
        var info = PhotoInfo()
        info.pixelWidth = 6000
        info.pixelHeight = 4000
        info.colorProfileName = "Display P3"
        info.dateTaken = taken
        info.dateTakenOffsetSeconds = 0
        info.make = "FUJIFILM"
        info.model = "X-T5"
        info.aperture = 2.8
        info.shutter = 1.0 / 250
        info.iso = 200
        info.focal = 25
        info.gps = PhotoInfo.Coordinate(latitude: -33.86, longitude: 151.21)
        return info
    }

    private struct Shown: Equatable {
        var file: [[String?]]
        var capture: [[String?]]
        var location: String?
    }

    private func cells(_ rows: [InspectorRow]) -> [[String?]] { rows.map { [$0.label, $0.value, $0.tooltip] } }

    private func viewerShown(_ info: PhotoInfo?) -> Shown {
        let facts = InspectorRows.facts(url: url, fileSize: 12_400_000, info: info, modified: modified, type: .jpeg)
        // "Folder" is the viewer's own row (§7 "may differ" 3).
        return Shown(file: cells(facts.file.filter { $0.label != "Folder" }),
                     capture: cells(facts.capture), location: facts.location)
    }

    private func browserShown(_ info: PhotoInfo?) -> Shown {
        let item = BrowserItem(url: url, displayName: url.lastPathComponent, fileSize: 12_400_000,
                               modificationDate: modified, utType: .jpeg, pixelWidth: 6000, pixelHeight: 4000)
        let state = BrowserWindowController.filled(InspectorState.reduce([item]), with: info)
        return Shown(file: cells(InspectorRows.fileRows(state.fileInput)),
                     capture: cells(state.capture), location: state.location)
    }

    /// What the viewer's Info panel may show and the browser's does not
    /// (§7 "may differ"; the last entry added by 28a round 3 B.11, a designer
    /// note: the line is useful and viewer-specific, so it stays).
    static let viewerOnlyParts = ["Folder row", "N of M line under the name"]

    /// 28a B.11: the viewer's `4 of 13` line is an allowed difference.
    func testViewerShowsItsPositionLine() {
        let panel = InspectorPanel()
        panel.updateIndexSummary(index: 3, total: 13)
        XCTAssertEqual(panel.indexSummaryForTesting, "4 of 13")
        XCTAssertTrue(Self.viewerOnlyParts.contains("N of M line under the name"))
    }

    func testBothPanelsShowTheSameSharedRows() {
        let info = fakeInfo()
        let viewer = viewerShown(info)
        let browser = browserShown(info)
        XCTAssertEqual(viewer, browser)
        XCTAssertEqual(viewer.file.map { $0[0] }, ["Type", "Dimensions", "Size", "Modified", "Color profile"])
        XCTAssertEqual(viewer.file[1][1], "6000 × 4000")
        XCTAssertEqual(viewer.capture.first?[0], "Date taken")
        XCTAssertNotNil(viewer.location)
        let viewerAll = InspectorRows.file(url: url, fileSize: 12_400_000, info: info, modified: modified, type: .jpeg)
        XCTAssertEqual(viewerAll.last?.label, "Folder")
        XCTAssertEqual(viewerAll.last?.value, "Italy 2026")
    }

    func testFirstFourRowsShowADashWhenEmpty() {
        let rows = InspectorRows.fileRows(InspectorFileInput())
        XCTAssertEqual(rows.map(\.label), ["Type", "Dimensions", "Size", "Modified"])
        XCTAssertEqual(rows.map(\.value), ["—", "—", "—", "—"])
        let total = InspectorRows.fileRows(InspectorFileInput(fileSize: 1, totalSize: 2_000_000))
        XCTAssertEqual(total[2].label, "Total size")
    }

    func testOneDateFormatWithSecondsInTheTooltip() {
        let us = Locale(identifier: "en_US")
        let utc = TimeZone(identifier: "UTC")!
        let f = DateFormatter()
        f.locale = us
        f.timeZone = utc
        f.dateStyle = .medium
        f.timeStyle = .short
        XCTAssertEqual(InspectorFormat.dateTime(taken, zone: utc, locale: us), f.string(from: taken))
        XCTAssertFalse(InspectorFormat.dateTime(taken, zone: utc, locale: us).contains(":39"))
        XCTAssertTrue(InspectorFormat.dateTimeWithSeconds(taken, zone: utc, locale: us).contains("11:04:39"))
        let row = InspectorRows.capture(fakeInfo(), locale: us).first!
        XCTAssertEqual(row.value, InspectorFormat.dateTime(taken, zone: utc, locale: us))
        XCTAssertEqual(row.tooltip, InspectorFormat.dateTimeWithSeconds(taken, zone: utc, locale: us))
        let modifiedRow = InspectorRows.fileRows(InspectorFileInput(modified: modified), locale: us)[3]
        XCTAssertEqual(modifiedRow.value, InspectorFormat.dateTime(modified, locale: us))
    }

    func testClearShowsOnlyWhenRatedOrMixed() {
        XCTAssertFalse(InspectorStarsRow.showsClear(rating: 0, mixed: false))
        XCTAssertFalse(InspectorStarsRow.showsClear(rating: nil, mixed: false))
        XCTAssertTrue(InspectorStarsRow.showsClear(rating: 3, mixed: false))
        XCTAssertTrue(InspectorStarsRow.showsClear(rating: nil, mixed: true))
    }

    func testOneFontSizeConstantAndNoReservedLines() throws {
        XCTAssertEqual(InspectorStyle.smallFontSize, 12)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/ShrikeUI")
        for file in ["BrowserWindow/InspectorPaneView.swift", "ViewerWindow/Panels/InspectorPanel.swift",
                     "Shared/InspectorRows.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertFalse(text.contains("rowFontSize"), file)
            XCTAssertFalse(text.contains("reservesSpace: true"), file)
            XCTAssertFalse(text.contains("alsoLine ?? \" \""), file)
            XCTAssertFalse(text.contains("Colour profile"), file)
        }
    }

    /// 28a B.12 (debug only): an alert preview shows once, and ⌘Q ends its sheet.
    func testDebugAlertPreviewShowsOnceAndQuitEndsIt() throws {
        XCTAssertEqual(RenameRecoveryPresenter.debugAlertPreviewShows, 1)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.titled],
                             backing: .buffered, defer: true)
        window.beginSheet(sheet)
        RenameRecoveryPresenter.debugPreviewWindow = window
        RenameRecoveryPresenter.endSheetForQuit()
        XCTAssertNil(window.attachedSheet)
        window.close()
    }
}

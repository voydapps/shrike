//
//  SettingsPopupTests.swift
//  ShrikeUITests
//
//  Settings › Thumbnails › "Grid size" was
//  an empty popup. The Browser's size slider had stored 135 pt, which is
//  not one of the popup's choices, so SwiftUI found no matching tag.
//  Every numeric popup in the six tabs now lists the stored value too.
//
//  SwiftUI does not fill a popup's menu offscreen (every popup reads
//  empty there), so these tests check the choice lists the tabs draw.
//

import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class SettingsPopupTests: XCTestCase {

    func testChoicesIncludeTheStoredValueInOrder() {
        XCTAssertEqual(SettingsChoices.including(180, in: ThumbnailsTab.sizeOptions), [120, 150, 180, 210, 256])
        XCTAssertEqual(SettingsChoices.including(135, in: ThumbnailsTab.sizeOptions),
                       [120, 135, 150, 180, 210, 256], "the Browser slider's 135 pt shows")
        XCTAssertEqual(SettingsChoices.including(64, in: ThumbnailsTab.sizeOptions).first, 64)
        XCTAssertEqual(SettingsChoices.including(320, in: ThumbnailsTab.sizeOptions).last, 320)
    }

    /// Each numeric popup: its default is a choice, and any stored value
    /// (the slider, an old build, a hand edit) is listed as well.
    func testEveryNumericPopupShowsItsValue() {
        // Defaults: clear the keys in this process's test suite for a moment.
        let keys = ["shrike.thumbnails.sizePt", "shrike.cache.diskCeilingBytes", "shrike.recent.foldersLimit",
                    "shrike.backups.retentionDays", "shrike.viewer.maxDisplayLongEdge"]
        let store = ShrikeDefaults.store
        let before = keys.map { store.object(forKey: $0) }
        keys.forEach { store.removeObject(forKey: $0) }
        defer { for (k, v) in zip(keys, before) { store.set(v, forKey: k) } }
        XCTAssertEqual(Prefs.thumbnailSizePt, 180, "precondition: default grid size")
        XCTAssertTrue(ThumbnailsTab.sizeOptions.contains(Prefs.thumbnailSizePt))
        XCTAssertTrue(ThumbnailsTab.ceilingOptions.contains(Prefs.cacheDiskCeilingBytes))
        XCTAssertTrue(GeneralTab.recentOptions.contains(Prefs.recentFoldersLimit))
        XCTAssertTrue(EditingTab.retentionOptions.contains(Prefs.backupRetentionDays))
        XCTAssertTrue(PerformanceTab.longEdgeOptions.contains(Prefs.maxDisplayLongEdge))

        XCTAssertTrue(SettingsChoices.including(135, in: ThumbnailsTab.sizeOptions).contains(135))
        XCTAssertTrue(SettingsChoices.including(Int64(300 << 20), in: ThumbnailsTab.ceilingOptions)
            .contains(300 << 20))
        XCTAssertTrue(SettingsChoices.including(7, in: GeneralTab.recentOptions).contains(7))
        XCTAssertTrue(SettingsChoices.including(14, in: EditingTab.retentionOptions).contains(14))
        XCTAssertTrue(SettingsChoices.including(5000, in: PerformanceTab.longEdgeOptions).contains(5000))
    }

    /// Choosing a grid size in Settings changes the pref and the open
    /// Browser's grid and slider.
    func testChoosingAGridSizeChangesTheOpenBrowser() throws {
        let before = Prefs.thumbnailSizePt
        defer { Prefs.thumbnailSizePt = before }
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-gridsize-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        PreferencesStore().thumbnailSizePt.wrappedValue = 210
        XCTAssertEqual(Prefs.thumbnailSizePt, 210)
        XCTAssertEqual(browser.contentController.thumbnailPixelSize, 210)
        XCTAssertEqual(browser.thumbSizeSlider.integerValue, 210)
    }
}

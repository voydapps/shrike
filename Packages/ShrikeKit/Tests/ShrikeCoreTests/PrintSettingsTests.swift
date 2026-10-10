//
//  PrintSettingsTests.swift
//  ShrikeCoreTests
//
//  The `shrike.print.*` settings. Each test uses
//  its own UserDefaults suite, never the app's domain.
//

import XCTest
@testable import ShrikeCore

final class PrintSettingsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = makeTestDefaults()
    }

    private func store(_ locale: String = "it_IT") -> PrintSettingsStore {
        PrintSettingsStore(defaults: defaults, locale: Locale(identifier: locale))
    }

    func testDefaultsMatchTheSpec() {
        let s = store().load()
        XCTAssertEqual(s.scaling, .fit)
        XCTAssertFalse(s.showFileName)
        XCTAssertEqual(s.orientation, .automatic)
        XCTAssertEqual(s.contactSheetColumns, 5)
        XCTAssertEqual(s.contactSheetPaper, .a4)
        XCTAssertEqual(s.contactSheetCaption, .fileName)
        XCTAssertEqual(store("en_US").load().contactSheetPaper, .usLetter, "paper default from the region")
        XCTAssertEqual(store("fr_CA").load().contactSheetPaper, .usLetter)
        XCTAssertEqual(store("en_GB").load().contactSheetPaper, .a4)
    }

    func testSaveAndLoadRoundTrip() {
        let saved = PrintSettings(scaling: .fill, showFileName: true, orientation: .landscape,
                                  contactSheetColumns: 7, contactSheetPaper: .usLetter,
                                  contactSheetCaption: .fileNameAndDate)
        store().save(saved)
        XCTAssertEqual(store().load(), saved)
    }

    /// The stored types are: String and Bool for the two
    /// print keys, so `defaults write` works as documented.
    func testStoredValuesUseTheSpecKeysAndTypes() {
        store().update { $0.scaling = .actual; $0.showFileName = true; $0.contactSheetColumns = 8 }
        XCTAssertEqual(defaults.object(forKey: "shrike.print.scaling") as? String, "actual")
        XCTAssertEqual(defaults.object(forKey: "shrike.print.showFileName") as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: "shrike.print.orientation") as? String, "auto")
        XCTAssertEqual(defaults.object(forKey: "shrike.print.contactSheet.columns") as? Int, 8)
        XCTAssertEqual(defaults.object(forKey: "shrike.print.contactSheet.paper") as? String, "a4")
        XCTAssertEqual(defaults.object(forKey: "shrike.print.contactSheet.caption") as? String, "fileName")
    }

    func testBadStoredValuesFallBackToTheDefault() {
        defaults.set("stretch", forKey: PrintSettingsStore.Key.scaling)
        defaults.set("yes", forKey: PrintSettingsStore.Key.showFileName)
        defaults.set(3, forKey: PrintSettingsStore.Key.orientation)
        defaults.set("A3", forKey: PrintSettingsStore.Key.contactSheetPaper)
        defaults.set("everything", forKey: PrintSettingsStore.Key.contactSheetCaption)
        let s = store().load()
        XCTAssertEqual(s, PrintSettings.defaults(for: Locale(identifier: "it_IT")))
    }

    func testColumnsAreClamped() {
        defaults.set(12, forKey: PrintSettingsStore.Key.contactSheetColumns)
        XCTAssertEqual(store().load().contactSheetColumns, 8)
        defaults.set(1, forKey: PrintSettingsStore.Key.contactSheetColumns)
        XCTAssertEqual(store().load().contactSheetColumns, 3)
        var s = PrintSettings(contactSheetColumns: 0)
        XCTAssertEqual(s.contactSheetColumns, 3)
        s.contactSheetColumns = 9
        XCTAssertEqual(s.contactSheetColumns, 8)
    }

    func testResetRemovesEveryPrintKey() {
        store().save(PrintSettings(scaling: .fill, showFileName: true))
        store().reset()
        for key in PrintSettingsStore.Key.all {
            XCTAssertNil(defaults.object(forKey: key), key)
        }
        XCTAssertEqual(store().load().scaling, .fit)
    }

    func testEveryPrintKeyIsInPrefsAllKeys() {
        let registered = Set(Prefs.Key.allKeys)
        for key in PrintSettingsStore.Key.all {
            XCTAssertTrue(key.hasPrefix("shrike.print."), key)
            XCTAssertTrue(registered.contains(key), "Prefs.Key.allKeys misses \(key); resetAll won't wipe it")
        }
    }

    func testCodableRoundTripClampsColumns() throws {
        let s = PrintSettings(scaling: .actual, showFileName: true, orientation: .portrait,
                              contactSheetColumns: 4, contactSheetPaper: .usLetter, contactSheetCaption: .none)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(PrintSettings.self, from: data), s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"contactSheetColumns\":4"), json)
        XCTAssertFalse(json.contains("_columns"), json)
        let wide = Data(json.replacingOccurrences(of: "\"contactSheetColumns\":4",
                                                  with: "\"contactSheetColumns\":40").utf8)
        XCTAssertEqual(try JSONDecoder().decode(PrintSettings.self, from: wide).contactSheetColumns, 8)
    }

    func testAutomaticOrientationFollowsTheImage() {
        XCTAssertEqual(PrintSettings.Orientation.automatic.resolved(imageWidth: 6000, imageHeight: 4000), .landscape)
        XCTAssertEqual(PrintSettings.Orientation.automatic.resolved(imageWidth: 4000, imageHeight: 6000), .portrait)
        XCTAssertEqual(PrintSettings.Orientation.automatic.resolved(imageWidth: 100, imageHeight: 100), .portrait)
        XCTAssertEqual(PrintSettings.Orientation.portrait.resolved(imageWidth: 6000, imageHeight: 4000), .portrait)
        XCTAssertEqual(PrintSettings.Orientation.landscape.resolved(imageWidth: 10, imageHeight: 40), .landscape)
    }
}

//
//  PreferencesEditingTests.swift
//  ShrikeUITests
//
//  (tab order, Editing tab, dead settings wired) and
//  Canvas colour.
//

import XCTest
import AppKit
import SwiftUI
@testable import ShrikeUI
@testable import ShrikeRendering
import ShrikeCore

final class PreferencesEditingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Prefs.resetAll()
    }

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    func testTabOrder_hasEditingAndExternalEditors() {
        // External Editors sits before Advanced.
        XCTAssertEqual(PreferencesTab.allCases,
                       [.general, .editing, .shortcuts, .thumbnails, .externalEditors, .advanced])
        XCTAssertEqual(PreferencesTab.editing.title, "Editing")
    }

    @MainActor
    func testEditingResetKeys_restoreDefaults() {
        Prefs.editJPEGQualityDefault = 70
        Prefs.editStripGPSOnSave = true
        Prefs.backupRetentionDays = 7
        PreferencesTab.editing.resetToDefaults()
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 92)
        XCTAssertFalse(Prefs.editStripGPSOnSave)
        XCTAssertEqual(Prefs.backupRetentionDays, 30)
    }

    @MainActor
    func testEditingBindings_writePrefs() {
        let store = PreferencesStore()
        store.editJPEGQuality.wrappedValue = 75
        store.editHEICQuality.wrappedValue = 65
        store.editPreserveEXIFOnSave.wrappedValue = false
        store.backupRetentionDays.wrappedValue = 90
        store.metadataWriteFileAttributes.wrappedValue = false
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 75)
        XCTAssertEqual(Prefs.editHEICQualityDefault, 65)
        XCTAssertFalse(Prefs.editPreserveEXIFOnSave)
        XCTAssertEqual(Prefs.backupRetentionDays, 90)
        XCTAssertFalse(Prefs.metadataWriteFileAttributes)
    }

    @MainActor
    func testEditingTab_rendersWithoutBackupStore() {
        let store = PreferencesStore()
        _ = NSHostingView(rootView: EditingTab(backupStore: nil).environmentObject(store))
        XCTAssertEqual(EditingTab.usageLine(bytes: nil), "Backups use —.")
        XCTAssertEqual(EditingTab.retentionOptions, [7, 30, 90])
    }

    func testBackgroundAlwaysBlack_defaultsOff() {
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
    }

    //
    @MainActor
    func testCanvasColour_table() throws {
        XCTAssertEqual(ViewerContentView.canvasColor(windowed: true, alwaysBlack: true), .black)
        XCTAssertEqual(ViewerContentView.canvasColor(windowed: false, alwaysBlack: false), .black)
        XCTAssertEqual(ViewerContentView.canvasColor(windowed: true, alwaysBlack: false),
                       ViewerContentView.surfaceBase)

        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        view.canvasColor = ViewerContentView.canvasColor(windowed: true, alwaysBlack: true)
        let black = view.clearColorForDraw()
        XCTAssertEqual(black.red, 0, accuracy: 1e-6)
        XCTAssertEqual(black.green, 0, accuracy: 1e-6)
        XCTAssertEqual(black.blue, 0, accuracy: 1e-6)

        view.appearance = NSAppearance(named: .darkAqua)
        view.canvasColor = ViewerContentView.surfaceBase
        let dark = view.clearColorForDraw()
        // #1C1C1E ≈ 0.011 linear.
        XCTAssertEqual(dark.red, 0.0116, accuracy: 0.003)
        view.appearance = NSAppearance(named: .aqua)
        let light = view.clearColorForDraw()
        XCTAssertGreaterThan(light.red, 0.85)
    }
}

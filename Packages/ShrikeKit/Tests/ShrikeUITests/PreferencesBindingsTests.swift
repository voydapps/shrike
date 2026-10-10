//
//  PreferencesBindingsTests.swift
//  ShrikeUITests
//
//  Verifies every control on the Preferences window round-trips through the
//  typed `Prefs` schema. We manipulate the `Binding` values directly (as a
//  SwiftUI view would via a control) and assert the backing `Prefs.*` getter
//  observes the change.
//
//  These tests mutate `ShrikeDefaults.store` (which `Prefs` uses); we
//  reset the schema keys in `setUp`/`tearDown` to keep state clean between
//  runs.
//

import XCTest
import SwiftUI
@testable import ShrikeUI
import ShrikeCore

final class PreferencesBindingsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Prefs.resetAll()
    }

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    // MARK: - General tab bindings

    @MainActor
    func testGeneral_showHiddenFiles_bindingWritesPrefs() {
        let store = PreferencesStore()
        XCTAssertFalse(Prefs.showHiddenFiles)

        store.showHiddenFiles.wrappedValue = true
        XCTAssertTrue(Prefs.showHiddenFiles)

        store.showHiddenFiles.wrappedValue = false
        XCTAssertFalse(Prefs.showHiddenFiles)
    }

    @MainActor
    func testGeneral_recentFoldersLimit_bindingWritesPrefs() {
        let store = PreferencesStore()
        store.recentFoldersLimit.wrappedValue = 50
        XCTAssertEqual(Prefs.recentFoldersLimit, 50)
    }

    @MainActor
    func testGeneral_scrollWheelNavigates_bindingWritesPrefs() {
        let store = PreferencesStore()
        store.scrollWheelNavigates.wrappedValue = false
        XCTAssertFalse(Prefs.scrollWheelNavigates)
        store.scrollWheelNavigates.wrappedValue = true
        XCTAssertTrue(Prefs.scrollWheelNavigates)
    }

    // MARK: - Thumbnails tab bindings

    @MainActor
    func testThumbnails_sizePt_bindingWritesPrefs() {
        let store = PreferencesStore()
        store.thumbnailSizePt.wrappedValue = 210
        XCTAssertEqual(Prefs.thumbnailSizePt, 210)
    }

    @MainActor
    func testThumbnails_cacheCeiling_bindingWritesPrefs() {
        let store = PreferencesStore()
        let oneGB: Int64 = 1024 * 1024 * 1024
        store.cacheDiskCeilingBytes.wrappedValue = oneGB
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, oneGB)
    }

    // MARK: - Performance tab bindings

    @MainActor
    func testPerformance_maxDisplayLongEdge_bindingWritesPrefs() {
        let store = PreferencesStore()
        store.maxDisplayLongEdge.wrappedValue = 8192
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 8192)
    }

    // MARK: - Advanced tab bindings

    @MainActor
    func testAdvanced_viewerBackgroundAlwaysBlack_bindingWritesPrefs() {
        let store = PreferencesStore()
        // Default is true.
        store.viewerBackgroundAlwaysBlack.wrappedValue = false
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
    }

    @MainActor
    func testAdvanced_viewerPositionOverlayAutoHides_bindingWritesPrefs() {
        let store = PreferencesStore()
        store.viewerPositionOverlayAutoHides.wrappedValue = true
        XCTAssertTrue(Prefs.viewerPositionOverlayAutoHides)
    }

    // MARK: - Shortcut preset

    @MainActor
    func testShortcuts_presetWriteIsPersisted() {
        // The ShortcutsTab writes directly to `Prefs.shortcutPreset` inside
        // a `notifyAndMutate` block; replicate that pattern here.
        let store = PreferencesStore()
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)

        store.notifyAndMutate {
            Prefs.shortcutPreset = .fastStoneCompat
        }
        XCTAssertEqual(Prefs.shortcutPreset, .fastStoneCompat)
    }
}

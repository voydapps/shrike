//
//  PreferencesRootViewTests.swift
//  ShrikeUITests
//
//  Smoke tests for the SwiftUI Preferences tabs: each tab must be
//  instantiable without crashing, and the `PreferencesSelection` wrapper must
//  round-trip through `Prefs.selectedPreferencesTabRaw`.
//

import XCTest
import SwiftUI
@testable import ShrikeUI
import ShrikeCore

final class PreferencesRootViewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        clearPrefs()
    }

    override func tearDown() {
        clearPrefs()
        super.tearDown()
    }

    @MainActor
    func testEveryTab_canBeConstructed() {
        // A `Body` evaluation would require a hosting environment; we settle
        // for "the struct initialiser doesn't crash and a hosting view wraps
        // it cleanly". That's sufficient to catch type-level mistakes
        // (missing environment objects, bad generics, etc.) without spinning
        // up a real window.
        let store = PreferencesStore()
        let envView = { (view: AnyView) in view.environmentObject(store) }

        _ = envView(AnyView(GeneralTab()))
        _ = envView(AnyView(ShortcutsTab()))
        _ = envView(AnyView(ThumbnailsTab(thumbnailCache: nil)))
        _ = envView(AnyView(PerformanceTab()))
        _ = envView(AnyView(ExternalEditorsTab()))
        _ = envView(AnyView(AdvancedTab()))
    }

    @MainActor
    func testRootView_rendersForEverySelection() {
        let store = PreferencesStore()
        for tab in PreferencesTab.allCases {
            let selection = PreferencesSelection(initial: tab)
            let root = PreferencesRootView(selection: selection, thumbnailCache: nil)
                .environmentObject(store)
            // Round-trip through AnyView to force Body materialisation of
            // the outer Group.
            _ = AnyView(root)
        }
    }

    @MainActor
    func testSelection_persistsToPrefs() {
        // Default on first open.
        XCTAssertEqual(PreferencesTab.loadSelected(), .general)

        let selection = PreferencesSelection(initial: .general)
        selection.tab = .thumbnails

        XCTAssertEqual(Prefs.selectedPreferencesTabRaw, "thumbnails")
        XCTAssertEqual(PreferencesTab.loadSelected(), .thumbnails)

        selection.tab = .advanced
        XCTAssertEqual(Prefs.selectedPreferencesTabRaw, "advanced")
        XCTAssertEqual(PreferencesTab.loadSelected(), .advanced)
    }

    // MARK: - Helpers

    private func clearPrefs() {
        for key in Prefs.allUserDefaultsKeys {
            ShrikeDefaults.store.removeObject(forKey: key)
        }
    }
}

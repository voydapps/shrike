//
//  PreferencesResetTests.swift
//  ShrikeUITests
//
//  Two behaviours under test:
//    1. Per-tab `resetToDefaults()` clears *only* the keys owned by that tab.
//       Other keys stay mutated.
//    2. Global `Prefs.resetAll()` clears everything (already covered in
//       PrefsTests but we exercise it from the UI side for regression
//       coverage).
//

import XCTest
@testable import ShrikeUI
import ShrikeCore
import ShrikeIO

final class PreferencesResetTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Prefs.resetAll()
    }

    override func tearDown() {
        Prefs.resetAll()
        super.tearDown()
    }

    // MARK: - Per-tab reset isolation

    @MainActor
    func testGeneralResetKeys_coverThreeGeneralControls() {
        // The resetKeys list is part of the UI contract — the General tab
        // promises to restore exactly these three schema keys.
        XCTAssertEqual(
            Set(PreferencesTab.general.resetKeys),
            Set([
                "shrike.browser.showHiddenFiles",
                "shrike.recent.foldersLimit",
                "shrike.input.scrollWheelNavigates",
                "shrike.grouping.pairRAW",
                "shrike.metadata.writeFileAttributes",
            ])
        )
    }

    @MainActor
    func testGeneralReset_clearsGeneralKeysOnly() {
        // Mutate one key per tab.
        Prefs.showHiddenFiles = true                 // General
        Prefs.thumbnailSizePt = 256                  // Thumbnails
        Prefs.maxDisplayLongEdge = 8192              // Performance
        Prefs.viewerBackgroundAlwaysBlack = false    // Advanced
        Prefs.externalEditors = [                    // External editors
            ExternalEditorSlot(name: "X", bundleIdentifierOrPath: "/A.app", shortcut: nil)
        ]
        Prefs.shortcutPreset = .fastStoneCompat      // Shortcuts

        PreferencesTab.general.resetToDefaults()

        // General keys → defaults.
        XCTAssertFalse(Prefs.showHiddenFiles)

        // Every other tab's key → unchanged.
        XCTAssertEqual(Prefs.thumbnailSizePt, 256)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 8192)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.externalEditors.count, 1)
        XCTAssertEqual(Prefs.shortcutPreset, .fastStoneCompat)
    }

    @MainActor
    func testThumbnailsReset_clearsThumbnailsKeysOnly() {
        Prefs.thumbnailSizePt = 256
        Prefs.cacheDiskCeilingBytes = 2 * 1024 * 1024 * 1024
        Prefs.showHiddenFiles = true  // poison from another tab

        PreferencesTab.thumbnails.resetToDefaults()

        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, 512 * 1024 * 1024)
        // General's key should NOT be touched by a Thumbnails-only reset.
        XCTAssertTrue(Prefs.showHiddenFiles,
                      "Thumbnails reset must not touch General keys")
    }

    @MainActor
    func testPerformanceReset_clearsOnlyMaxDisplayLongEdge() {
        Prefs.maxDisplayLongEdge = 8192
        Prefs.viewerBackgroundAlwaysBlack = false  // Advanced key

        PreferencesTab.performance.resetToDefaults()

        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack,
                       "Performance reset must not touch Advanced keys")
    }

    @MainActor
    func testAdvancedReset_clearsViewerTogglesOnly() {
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.viewerPositionOverlayAutoHides = true
        Prefs.thumbnailSizePt = 256  // poison

        PreferencesTab.advanced.resetToDefaults()

        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)   // default off
        XCTAssertFalse(Prefs.viewerPositionOverlayAutoHides)
        XCTAssertEqual(Prefs.thumbnailSizePt, 256,
                       "Advanced reset must not touch Thumbnails keys")
    }

    @MainActor
    func testShortcutsReset_onlyClearsPreset() {
        Prefs.shortcutPreset = .fastStoneCompat
        Prefs.thumbnailSizePt = 256

        PreferencesTab.shortcuts.resetToDefaults()

        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
        XCTAssertEqual(Prefs.thumbnailSizePt, 256)
    }

    @MainActor
    func testExternalEditorsReset_clearsRegistryAndOldList() throws {
        let defaults = ShrikeDefaults.store
        Prefs.externalEditors = [
            ExternalEditorSlot(name: "X", bundleIdentifierOrPath: "/A.app", shortcut: nil)
        ]
        let registry = ExternalEditorRegistry(defaults: defaults)
        ExternalEditors.registry = registry
        defer { ExternalEditors.resetRegistryForTesting() }
        try registry.add(ExternalEditor(displayName: "Y", bundleIdentifier: nil,
                                        applicationURL: URL(fileURLWithPath: "/B.app")))
        XCTAssertNotNil(defaults.object(forKey: ExternalEditorRegistry.defaultsKey))

        PreferencesTab.externalEditors.resetToDefaults()

        XCTAssertTrue(Prefs.externalEditors.isEmpty)
        XCTAssertTrue(registry.editors.isEmpty, "the live registry is cleared too")
        XCTAssertNil(defaults.object(forKey: ExternalEditorRegistry.defaultsKey))
        XCTAssertNil(defaults.object(forKey: ExternalEditorRegistry.legacyDefaultsKey))
    }

    // MARK: - Global reset

    @MainActor
    func testResetAll_fromUISide_clearsEverything() {
        Prefs.showHiddenFiles = true
        Prefs.thumbnailSizePt = 256
        Prefs.maxDisplayLongEdge = 8192
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.shortcutPreset = .fastStoneCompat

        Prefs.resetAll()

        XCTAssertFalse(Prefs.showHiddenFiles)
        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
    }
}

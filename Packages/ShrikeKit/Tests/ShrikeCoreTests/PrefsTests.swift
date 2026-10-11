//
//  PrefsTests.swift
//  ShrikeCoreTests
//

import XCTest
@testable import ShrikeCore

final class PrefsTests: XCTestCase {

    /// `Prefs` uses `ShrikeDefaults.store`. Clean the keys we touch
    /// in setUp so tests don't leak between runs.
    override func setUp() {
        super.setUp()
        // Prefs.Key.allKeys is the schema source of truth — use it so new
        // keys don't have to be duplicated here.
        for k in Prefs.Key.allKeys {
            ShrikeDefaults.store.removeObject(forKey: k)
        }
    }

    /// Put every key back to its default, so a test that sets a pref does
    /// not change what later tests in the same run read.
    override func tearDown() {
        for k in Prefs.Key.allKeys {
            ShrikeDefaults.store.removeObject(forKey: k)
        }
        super.tearDown()
    }

    // MARK: - Scalar defaults

    func testDefaults() {
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertTrue(Prefs.scrollWheelNavigates)   // "Changes image" is the default
        XCTAssertEqual(Prefs.recentFoldersLimit, 20)
        XCTAssertFalse(Prefs.showHiddenFiles)
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, 512 * 1024 * 1024)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertTrue(Prefs.viewerPositionOverlayAutoHides,
                      "position pill auto-hides by default (spec 24 §1.2); holding it open is opt-in")
        XCTAssertEqual(Prefs.externalEditors, [])

        // Filmstrip + chrome keys.
        XCTAssertTrue(Prefs.filmstripVisibleInWindowed,
                      "docked filmstrip visible by default in windowed mode")
        XCTAssertEqual(Prefs.filmstripHeightPt, 80)
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen)
        XCTAssertFalse(Prefs.editRailPinnedFullscreen)
        XCTAssertFalse(Prefs.exifPanelPinnedFullscreen)
        XCTAssertEqual(Prefs.chromeFadeOutDelayMs, 1500)

        // Edit keys.
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 92)
        XCTAssertEqual(Prefs.editHEICQualityDefault, 80)
        XCTAssertTrue(Prefs.editPreserveEXIFOnSave)
        XCTAssertFalse(Prefs.editStripGPSOnSave)
        XCTAssertTrue(Prefs.editAutoCropOnFreeRotate)
        XCTAssertFalse(Prefs.editColorAdjustPreviewFullResAlways)
    }

    // MARK: - JSON round-trip — ShortcutPreset

    func testShortcutPreset_roundtrip() {
        Prefs.shortcutPreset = .fastStoneCompat
        XCTAssertEqual(Prefs.shortcutPreset, .fastStoneCompat)

        Prefs.shortcutPreset = .macNative
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
    }

    // MARK: - JSON round-trip — [ExternalEditorSlot]

    func testExternalEditors_roundtrip() {
        let slot1 = ExternalEditorSlot(
            name: "Photoshop",
            bundleIdentifierOrPath: "com.adobe.Photoshop",
            shortcut: ShortcutBinding(key: "e", modifiers: [.command], context: .viewer)
        )
        let slot2 = ExternalEditorSlot(
            name: "Pixelmator Pro",
            bundleIdentifierOrPath: "/Applications/Pixelmator Pro.app",
            shortcut: nil
        )
        Prefs.externalEditors = [slot1, slot2]

        let decoded = Prefs.externalEditors
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].name, "Photoshop")
        XCTAssertEqual(decoded[0].shortcut?.key, "e")
        XCTAssertEqual(decoded[1].name, "Pixelmator Pro")
        XCTAssertNil(decoded[1].shortcut)
    }

    // MARK: - Integer prefs

    func testSetAndReadIntegerPrefs() {
        Prefs.thumbnailSizePt = 240
        Prefs.recentFoldersLimit = 50
        Prefs.cacheDiskCeilingBytes = 1024 * 1024 * 1024
        Prefs.maxDisplayLongEdge = 6000

        XCTAssertEqual(Prefs.thumbnailSizePt, 240)
        XCTAssertEqual(Prefs.recentFoldersLimit, 50)
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, 1024 * 1024 * 1024)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 6000)
    }

    // MARK: - Bool prefs

    func testSetAndReadBoolPrefs() {
        Prefs.scrollWheelNavigates = false
        Prefs.showHiddenFiles = true
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.viewerPositionOverlayAutoHides = false

        XCTAssertFalse(Prefs.scrollWheelNavigates)
        XCTAssertTrue(Prefs.showHiddenFiles)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertFalse(Prefs.viewerPositionOverlayAutoHides)
    }

    // MARK: - Filmstrip + chrome prefs

    func testFilmstripVisibleInWindowed_roundtrip() {
        Prefs.filmstripVisibleInWindowed = false
        XCTAssertFalse(Prefs.filmstripVisibleInWindowed)
        Prefs.filmstripVisibleInWindowed = true
        XCTAssertTrue(Prefs.filmstripVisibleInWindowed)
    }

    func testFilmstripHeightPt_roundtripAndClamp() {
        Prefs.filmstripHeightPt = 100
        XCTAssertEqual(Prefs.filmstripHeightPt, 100)

        // Below range clamps up to 64.
        Prefs.filmstripHeightPt = 10
        XCTAssertEqual(Prefs.filmstripHeightPt, 64)

        // Above range clamps down to 120.
        Prefs.filmstripHeightPt = 500
        XCTAssertEqual(Prefs.filmstripHeightPt, 120)
    }

    func testChromePinStates_roundtrip() {
        Prefs.filmstripPinnedFullscreen = true
        Prefs.editRailPinnedFullscreen = true
        Prefs.exifPanelPinnedFullscreen = true

        XCTAssertTrue(Prefs.filmstripPinnedFullscreen)
        XCTAssertTrue(Prefs.editRailPinnedFullscreen)
        XCTAssertTrue(Prefs.exifPanelPinnedFullscreen)

        Prefs.filmstripPinnedFullscreen = false
        Prefs.editRailPinnedFullscreen = false
        Prefs.exifPanelPinnedFullscreen = false

        XCTAssertFalse(Prefs.filmstripPinnedFullscreen)
        XCTAssertFalse(Prefs.editRailPinnedFullscreen)
        XCTAssertFalse(Prefs.exifPanelPinnedFullscreen)
    }

    func testChromeFadeOutDelayMs_roundtripAndClamp() {
        Prefs.chromeFadeOutDelayMs = 100
        XCTAssertEqual(Prefs.chromeFadeOutDelayMs, 100)

        Prefs.chromeFadeOutDelayMs = -50
        XCTAssertEqual(Prefs.chromeFadeOutDelayMs, 0)

        Prefs.chromeFadeOutDelayMs = 999_999
        XCTAssertEqual(Prefs.chromeFadeOutDelayMs, 60_000)
    }

    // MARK: - Edit prefs

    func testEditJPEGQualityDefault_roundtripAndClamp() {
        Prefs.editJPEGQualityDefault = 78
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 78)

        // Below range clamps up.
        Prefs.editJPEGQualityDefault = 10
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 60)

        // Above range clamps down.
        Prefs.editJPEGQualityDefault = 500
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 100)
    }

    func testEditHEICQualityDefault_roundtripAndClamp() {
        Prefs.editHEICQualityDefault = 75
        XCTAssertEqual(Prefs.editHEICQualityDefault, 75)

        Prefs.editHEICQualityDefault = 1
        XCTAssertEqual(Prefs.editHEICQualityDefault, 60)

        Prefs.editHEICQualityDefault = 200
        XCTAssertEqual(Prefs.editHEICQualityDefault, 100)
    }

    func testEditBoolPrefs_roundtrip() {
        Prefs.editPreserveEXIFOnSave = false
        Prefs.editStripGPSOnSave = true
        Prefs.editAutoCropOnFreeRotate = false
        Prefs.editColorAdjustPreviewFullResAlways = true

        XCTAssertFalse(Prefs.editPreserveEXIFOnSave)
        XCTAssertTrue(Prefs.editStripGPSOnSave)
        XCTAssertFalse(Prefs.editAutoCropOnFreeRotate)
        XCTAssertTrue(Prefs.editColorAdjustPreviewFullResAlways)
    }

    func testRetiredKeys_areDeletedOnce() {
        let d = makeTestDefaults()
        d.set(false, forKey: "shrike.edit.rotateUseLosslessForJPEG")
        d.set("/tmp/x", forKey: "shrike.edit.trashDirOverride")
        d.set(true, forKey: "shrike.edit.stripGPSOnSave")
        Prefs.removeRetiredKeys(from: d)
        XCTAssertNil(d.object(forKey: "shrike.edit.rotateUseLosslessForJPEG"))
        XCTAssertNil(d.object(forKey: "shrike.edit.trashDirOverride"))
        XCTAssertNotNil(d.object(forKey: "shrike.edit.stripGPSOnSave"))
        Prefs.removeRetiredKeys(from: d)   // second run: no-op
    }

    // MARK: - Selected preferences tab

    func testSelectedPreferencesTab_roundtripAndClear() {
        XCTAssertNil(Prefs.selectedPreferencesTabRaw)

        Prefs.selectedPreferencesTabRaw = "thumbnails"
        XCTAssertEqual(Prefs.selectedPreferencesTabRaw, "thumbnails")

        Prefs.selectedPreferencesTabRaw = nil
        XCTAssertNil(Prefs.selectedPreferencesTabRaw)
    }

    // MARK: - Reset all

    func testResetAll_restoresEveryKeyToSchemaDefault() {
        // Mutate every typed pref.
        Prefs.shortcutPreset = .fastStoneCompat
        Prefs.thumbnailSizePt = 256
        Prefs.scrollWheelNavigates = false
        Prefs.externalEditors = [
            ExternalEditorSlot(name: "X", bundleIdentifierOrPath: "/A.app", shortcut: nil)
        ]
        Prefs.recentFoldersLimit = 50
        Prefs.showHiddenFiles = true
        Prefs.cacheDiskCeilingBytes = 2 * 1024 * 1024 * 1024
        Prefs.viewerBackgroundAlwaysBlack = false
        Prefs.maxDisplayLongEdge = 8192
        Prefs.viewerPositionOverlayAutoHides = false   // poison (default is on)
        Prefs.selectedPreferencesTabRaw = "advanced"
        Prefs.filmstripVisibleInWindowed = false
        Prefs.filmstripHeightPt = 96
        Prefs.filmstripPinnedFullscreen = true
        Prefs.editRailPinnedFullscreen = true
        Prefs.exifPanelPinnedFullscreen = true
        Prefs.chromeFadeOutDelayMs = 500
        Prefs.editJPEGQualityDefault = 78
        Prefs.editHEICQualityDefault = 90
        Prefs.editPreserveEXIFOnSave = false
        Prefs.editStripGPSOnSave = true
        Prefs.editAutoCropOnFreeRotate = false
        Prefs.editColorAdjustPreviewFullResAlways = true

        Prefs.resetAll()

        // Every read should return the documented default again.
        XCTAssertEqual(Prefs.shortcutPreset, .macNative)
        XCTAssertEqual(Prefs.thumbnailSizePt, 180)
        XCTAssertTrue(Prefs.scrollWheelNavigates)   // "Changes image" is the default
        XCTAssertEqual(Prefs.externalEditors, [])
        XCTAssertEqual(Prefs.recentFoldersLimit, 20)
        XCTAssertFalse(Prefs.showHiddenFiles)
        XCTAssertEqual(Prefs.cacheDiskCeilingBytes, 512 * 1024 * 1024)
        XCTAssertFalse(Prefs.viewerBackgroundAlwaysBlack)
        XCTAssertEqual(Prefs.maxDisplayLongEdge, 4096)
        XCTAssertTrue(Prefs.viewerPositionOverlayAutoHides)
        XCTAssertNil(Prefs.selectedPreferencesTabRaw)
        XCTAssertTrue(Prefs.filmstripVisibleInWindowed)
        XCTAssertEqual(Prefs.filmstripHeightPt, 80)
        XCTAssertFalse(Prefs.filmstripPinnedFullscreen)
        XCTAssertFalse(Prefs.editRailPinnedFullscreen)
        XCTAssertFalse(Prefs.exifPanelPinnedFullscreen)
        XCTAssertEqual(Prefs.chromeFadeOutDelayMs, 1500)
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 92)
        XCTAssertEqual(Prefs.editHEICQualityDefault, 80)
        XCTAssertTrue(Prefs.editPreserveEXIFOnSave)
        XCTAssertFalse(Prefs.editStripGPSOnSave)
        XCTAssertTrue(Prefs.editAutoCropOnFreeRotate)
        XCTAssertFalse(Prefs.editColorAdjustPreviewFullResAlways)

        // Every underlying UserDefaults key should be physically absent.
        for k in Prefs.Key.allKeys {
            XCTAssertNil(ShrikeDefaults.store.object(forKey: k),
                         "resetAll must remove \(k) from UserDefaults")
        }
    }
}

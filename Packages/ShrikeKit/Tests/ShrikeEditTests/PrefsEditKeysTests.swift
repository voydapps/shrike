//
//  PrefsEditKeysTests.swift
//  ShrikeEditTests
//
//  Covers the Prefs round-trip from the ShrikeEdit side. The
//  canonical round-trip coverage lives in `PrefsTests.swift` under
//  ShrikeCoreTests — this file only checks that the keys are reachable
//  and allKeys-registered from inside a ShrikeEdit-consumer test bundle
//  (so a future renaming over in ShrikeCore breaks a build-local test
//  rather than only a sibling module's one).
//

import XCTest
import Foundation
@testable import ShrikeCore

final class PrefsEditKeysTests: XCTestCase {

    /// Clean the keys we touch.
    override func setUp() {
        super.setUp()
        for k in Prefs.Key.allKeys where k.hasPrefix("shrike.edit.") {
            ShrikeDefaults.store.removeObject(forKey: k)
        }
    }

    /// The store is shared by every test in the process: leave no edit key behind.
    override func tearDown() {
        for k in Prefs.Key.allKeys where k.hasPrefix("shrike.edit.") {
            ShrikeDefaults.store.removeObject(forKey: k)
        }
        super.tearDown()
    }

    func test_editKeys_allRegisteredInAllKeys() {
        // Every `shrike.edit.*` key we ship must be in
        // Prefs.Key.allKeys so `resetAll()` wipes it.
        let expected: Set<String> = [
            "shrike.edit.jpegQualityDefault",
            "shrike.edit.heicQualityDefault",
            "shrike.edit.preserveEXIFOnSave",
            "shrike.edit.stripGPSOnSave",
            "shrike.edit.rotateUseLosslessForJPEG",
            "shrike.edit.autoCropOnFreeRotate",
            "shrike.edit.colorAdjustPreviewFullResAlways",
            "shrike.edit.trashDirOverride",
        ]
        let registered = Set(Prefs.Key.allKeys)
        for key in expected {
            XCTAssertTrue(registered.contains(key),
                          "Prefs.Key.allKeys missing \(key) — resetAll won't wipe it")
        }
    }

    func test_editJPEGQualityDefault_isReadableDefault() {
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 92)
    }

    func test_editJPEGQualityDefault_roundTrip() {
        Prefs.editJPEGQualityDefault = 75
        XCTAssertEqual(Prefs.editJPEGQualityDefault, 75)
    }

}

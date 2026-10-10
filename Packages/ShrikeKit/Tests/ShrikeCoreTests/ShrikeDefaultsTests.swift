//
//  ShrikeDefaultsTests.swift
//  ShrikeCoreTests
//
//  Under XCTest the settings store must be a per-process suite, never the
//  shared `UserDefaults.standard` (one xctest domain for every concurrent
//  `swift test` run).
//

import XCTest
@testable import ShrikeCore

final class ShrikeDefaultsTests: XCTestCase {

    func testStoreUnderTestsIsAPerProcessSuiteNotStandard() throws {
        XCTAssertTrue(ShrikeDataPaths.isRunningTests)
        XCTAssertFalse(ShrikeDefaults.store === UserDefaults.standard,
                       "tests must not share the xctest tool's .standard domain")
        let name = try XCTUnwrap(ShrikeDefaults.testSuiteName)
        XCTAssertTrue(name.hasPrefix(ShrikeDataPaths.testRoot.path + "/"),
                      "the store lives in the per-process temp root: \(name)")
        XCTAssertTrue(name.contains("\(ProcessInfo.processInfo.processIdentifier)"),
                      "suite name carries the pid: \(name)")
        XCTAssertFalse(name.hasPrefix(ShrikeDefaults.preferencesFolder.path), "never ~/Library/Preferences")
    }

    func testWritesStayInTheSuite() {
        let key = "shrike.tests.defaults-probe-\(UUID().uuidString)"
        defer { ShrikeDefaults.store.removeObject(forKey: key) }
        ShrikeDefaults.store.set(42, forKey: key)
        XCTAssertEqual(ShrikeDefaults.store.integer(forKey: key), 42)
        XCTAssertNil(UserDefaults.standard.object(forKey: key),
                     "a store write must not reach .standard")
    }

    // MARK: - makeTestDefaults (scratch suites)

    /// The helper's teardown block removes the suite's plist. The check
    /// runs in a teardown block added BEFORE the helper's, so it runs after
    /// it (teardown blocks run last-in, first-out).
    func testMakeTestDefaultsLeavesNoPlistAfterTheTest() throws {
        let label = "probe-\(UUID().uuidString)"
        let folder = try XCTUnwrap(ShrikeDefaults.testPreferencesFolder).path
        let library = ShrikeDefaults.preferencesFolder.path
        addTeardownBlock {
            let fm = FileManager.default
            let left = ((try? fm.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasPrefix(label) }
            XCTAssertEqual(left, [], "the scratch suite's plist is gone after the test")
            let inLibrary = ((try? fm.contentsOfDirectory(atPath: library)) ?? []).filter { $0.contains(label) }
            XCTAssertEqual(inLibrary, [], "nothing in ~/Library/Preferences")
        }
        let defaults = makeTestDefaults(label)
        defaults.set(42, forKey: "shrike.tests.probe")
        XCTAssertTrue(defaults.synchronize())
        let written = ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { $0.hasPrefix(label) && $0.hasSuffix(".plist") }
        XCTAssertEqual(written.count, 1, "the suite's plist is written in the temp root")
        XCTAssertEqual(defaults.integer(forKey: "shrike.tests.probe"), 42)
    }

    func testScratchSuitesStartEmptyAndStayApart() {
        let a = makeTestDefaults()
        let b = makeTestDefaults()
        a.set("a", forKey: "shrike.tests.probe")
        XCTAssertNil(b.object(forKey: "shrike.tests.probe"))
        XCTAssertNil(ShrikeDefaults.store.object(forKey: "shrike.tests.probe"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "shrike.tests.probe"))
    }

    func testRemoveScratchSuiteIgnoresOtherNames() throws {
        let plist = ShrikeDefaults.preferencesFolder
            .appendingPathComponent("app.shrike.plist").path
        let existed = FileManager.default.fileExists(atPath: plist)
        ShrikeDefaults.removeScratchSuite(named: "app.shrike")
        ShrikeDefaults.removeScratchSuite(named: ShrikeDefaults.preferencesFolder.path + "/app.shrike")
        let folder = try XCTUnwrap(ShrikeDefaults.testPreferencesFolder).path
        ShrikeDefaults.removeScratchSuite(named: folder + "/../../x")
        XCTAssertEqual(FileManager.default.fileExists(atPath: plist), existed, "the app's plist is never touched")
    }

    func testPrefsWriteThroughTheStore() {
        let key = Prefs.Key.slideshowIntervalSec
        let saved = ShrikeDefaults.store.object(forKey: key)
        defer { ShrikeDefaults.store.set(saved, forKey: key) }
        Prefs.slideshowIntervalSec = 7
        XCTAssertEqual(ShrikeDefaults.store.integer(forKey: key), 7)
    }
}

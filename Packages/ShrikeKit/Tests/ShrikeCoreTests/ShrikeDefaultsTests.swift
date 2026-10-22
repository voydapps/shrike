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
        XCTAssertEqual(written, [], "the scratch suite keeps its values in memory")
        XCTAssertEqual(defaults.integer(forKey: "shrike.tests.probe"), 42)
    }

    // MARK: - The in-memory test store

    /// Every call Shrike makes reads back at once, and nothing reaches
    /// `cfprefsd`: no plist appears for the store.
    func testTheStoreReadsBackEveryTypeAndWritesNoPlist() throws {
        let store = ShrikeDefaults.store
        let prefix = "shrike.tests.roundtrip-\(UUID().uuidString)."
        let keys = ["bool", "int", "double", "float", "string", "strings", "data", "url", "any"].map { prefix + $0 }
        defer { keys.forEach(store.removeObject(forKey:)) }
        for round in 0..<50 {
            store.set(round % 2 == 0, forKey: keys[0])
            store.set(round, forKey: keys[1])
            store.set(Double(round) + 0.5, forKey: keys[2])
            store.set(Float(round) + 0.25, forKey: keys[3])
            store.set("v\(round)", forKey: keys[4])
            store.set(["a", "\(round)"], forKey: keys[5])
            store.set(Data([UInt8(round)]), forKey: keys[6])
            store.set(URL(fileURLWithPath: "/tmp/\(round)"), forKey: keys[7])
            store.set(["n": round], forKey: keys[8])
            XCTAssertEqual(store.bool(forKey: keys[0]), round % 2 == 0)
            XCTAssertEqual(store.integer(forKey: keys[1]), round)
            XCTAssertEqual(store.double(forKey: keys[2]), Double(round) + 0.5)
            XCTAssertEqual(store.float(forKey: keys[3]), Float(round) + 0.25)
            XCTAssertEqual(store.string(forKey: keys[4]), "v\(round)")
            XCTAssertEqual(store.stringArray(forKey: keys[5]), ["a", "\(round)"])
            XCTAssertEqual(store.data(forKey: keys[6]), Data([UInt8(round)]))
            XCTAssertEqual(store.url(forKey: keys[7])?.path, "/tmp/\(round)")
            XCTAssertEqual(store.dictionary(forKey: keys[8])?["n"] as? Int, round)
            XCTAssertEqual(store.object(forKey: keys[1]) as? Int, round, "stored as NSNumber, as Foundation does")
            store.removeObject(forKey: keys[4])
            XCTAssertNil(store.string(forKey: keys[4]), "a removal reads back at once")
        }
        XCTAssertTrue(store.synchronize())
        let plist = try XCTUnwrap(ShrikeDefaults.testSuiteName) + ".plist"
        XCTAssertFalse(FileManager.default.fileExists(atPath: plist), "the test store never writes its plist")
    }

    func testTheStoreFollowsFoundationConversionsAndRegisteredDefaults() {
        let store = makeTestDefaults()
        store.register(defaults: ["shrike.tests.reg": 3])
        XCTAssertEqual(store.integer(forKey: "shrike.tests.reg"), 3)
        store.set(5, forKey: "shrike.tests.reg")
        XCTAssertEqual(store.integer(forKey: "shrike.tests.reg"), 5)
        store.removeObject(forKey: "shrike.tests.reg")
        XCTAssertEqual(store.integer(forKey: "shrike.tests.reg"), 3, "back to the registered value")
        store.set("YES", forKey: "shrike.tests.b")
        XCTAssertTrue(store.bool(forKey: "shrike.tests.b"))
        store.set("12", forKey: "shrike.tests.i")
        XCTAssertEqual(store.integer(forKey: "shrike.tests.i"), 12)
        store.set(7, forKey: "shrike.tests.s")
        XCTAssertEqual(store.string(forKey: "shrike.tests.s"), "7")
        XCTAssertFalse(store.bool(forKey: "shrike.tests.missing"))
        XCTAssertNil(store.stringArray(forKey: "shrike.tests.missing"))
    }

    func testTheStorePostsDidChangeAfterEveryChange() {
        let store = makeTestDefaults()
        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: store, queue: nil) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.set(1, forKey: "shrike.tests.n")
        store.set(true, forKey: "shrike.tests.n")
        store.removeObject(forKey: "shrike.tests.n")
        XCTAssertEqual(posts, 3)
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

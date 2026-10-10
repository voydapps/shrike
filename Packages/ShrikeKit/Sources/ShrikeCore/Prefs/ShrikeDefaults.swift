//
//  ShrikeDefaults.swift
//  ShrikeCore
//
//  The one settings store every Shrike preference reads and writes.
//
//  In the app it is `UserDefaults.standard` (the `app.shrike`
//  domain), so key names and stored values are unchanged.
//
//  Under XCTest every test process shares ONE `.standard` domain (the
//  xctest tool's, `com.apple.dt.xctest.tool`). Two `swift test` runs at the
//  same time then change each other's prefs mid-test. So under tests the
//  store is a per-process suite of its own.
//
//  Test suites never live in `~/Library/Preferences`. `cfprefsd` writes a
//  removed domain back to disk as an empty plist 3–25 s later, after any
//  removal order (flush first, clear keys, remove domain), even after
//  the process has exited. So a named suite always
//  leaves a file behind there (~3,300 had piled up). Instead every test
//  suite is named by an absolute path inside the per-process temp root:
//  `<ShrikeDataPaths.testRoot>/Preferences/<name>`, plist `<name>.plist`.
//  Late `cfprefsd` writes land in that temp folder, which the next test run
//  deletes with the rest of a finished process's root.
//
//  - The store: `<testRoot>/Preferences/app.shrike.tests`.
//    Removed at exit (`atexit`).
//  - Scratch suites (one test's own empty store): `makeScratchSuite`, removed
//    with `removeScratchSuite`. Each test target has an
//    `XCTestCase.makeTestDefaults(_:)` helper that does both (teardown
//    block). Tests never call `UserDefaults(suiteName:)` themselves.
//  - Old `~/Library/Preferences/app.shrike.tests-<pid>*.plist`
//    files of processes that no longer run are deleted once per test run.
//
//  Rule: Shrike code uses `ShrikeDefaults.store`, never `UserDefaults.standard`.
//  Exceptions: AppKit's own autosave (toolbar configuration, window frames,
//  split views) stays on `.standard`, and global system settings read from
//  `.standard` (e.g. `AppleActionOnDoubleClick`).
//

import Foundation

public enum ShrikeDefaults {

    /// Name prefix of the old per-process suites in `~/Library/Preferences`
    /// (`app.shrike.tests-<pid>[.<label>.<uuid>]`). Only used to
    /// delete the ones left by finished processes.
    public static let testSuitePrefix = "app.shrike.tests-"

    /// `<ShrikeDataPaths.testRoot>/Preferences` under tests; nil in the app.
    public static let testPreferencesFolder: URL? = {
        guard ShrikeDataPaths.isRunningTests else { return nil }
        let folder = ShrikeDataPaths.testRoot.appendingPathComponent("Preferences", isDirectory: true)
        // `cfprefsd` does not create missing folders for path suites.
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// This process's store suite under tests (an absolute path); nil in
    /// the app.
    public static let testSuiteName: String? = testPreferencesFolder?
        .appendingPathComponent("app.shrike.tests").path

    /// The settings store. `UserDefaults.standard` in the app; a
    /// per-process suite under tests.
    // UserDefaults isn't Sendable in the SDK; Foundation locks internally.
    nonisolated(unsafe) public static let store: UserDefaults = makeStore()

    private static func makeStore() -> UserDefaults {
        guard let name = testSuiteName else { return .standard }
        _ = staleSuitesRemoved
        // `init(suiteName:)` only fails for the app's own bundle id or
        // NSGlobalDomain; our name is neither.
        guard let suite = UserDefaults(suiteName: name) else {
            preconditionFailure("ShrikeDefaults: cannot open test suite \(name)")
        }
        atexit { ShrikeDefaults.removeOwnTestSuite() }
        return suite
    }

    /// `~/Library/Preferences`, where `cfprefsd` keeps named suites.
    static var preferencesFolder: URL {
        (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true))
            .appendingPathComponent("Preferences", isDirectory: true)
    }

    /// Removes this process's store suite (domain + plist). Runs at exit.
    static func removeOwnTestSuite() {
        guard let name = testSuiteName else { return }
        removePathSuite(name)
    }

    /// Removes a path-named suite: its domain, then its plist.
    private static func removePathSuite(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(atPath: name + ".plist")
    }

    // MARK: - Scratch suites (one test's own store)

    /// A new, empty suite for one test, named
    /// `<testRoot>/Preferences/<label>.<uuid>`. Tests only. The caller
    /// removes it with `removeScratchSuite(named:)` when the test ends;
    /// `XCTestCase.makeTestDefaults(_:)` in each test target does.
    public static func makeScratchSuite(label: String) -> (defaults: UserDefaults, name: String) {
        guard let folder = testPreferencesFolder else {
            preconditionFailure("ShrikeDefaults: scratch suites are for tests only")
        }
        precondition(!label.isEmpty && !label.contains("/"), "ShrikeDefaults: bad scratch suite label")
        _ = staleSuitesRemoved
        let name = folder.appendingPathComponent("\(label).\(UUID().uuidString)").path
        guard let suite = UserDefaults(suiteName: name) else {
            preconditionFailure("ShrikeDefaults: cannot open scratch suite \(name)")
        }
        return (suite, name)
    }

    /// Removes a scratch suite: its domain and its plist. Names outside
    /// this process's test Preferences folder are ignored, so this can
    /// never reach the app's own settings.
    public static func removeScratchSuite(named name: String) {
        guard let folder = testPreferencesFolder,
              name.hasPrefix(folder.path + "/"), !name.contains("/../") else { return }
        removePathSuite(name)
    }

    // MARK: - Old suites in ~/Library/Preferences

    /// Old test suites are cleaned once per test process, on first use of
    /// `store` or of a scratch suite.
    private static let staleSuitesRemoved: Void = removeStaleTestSuites()

    /// Deletes `~/Library/Preferences/app.shrike.tests-<pid>.plist`
    /// and `…tests-<pid>.<label>.<uuid>.plist` files (older test runs)
    /// whose process no longer runs.
    static func removeStaleTestSuites() {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: preferencesFolder.path) else { return }
        for file in names where file.hasPrefix(testSuitePrefix) && file.hasSuffix(".plist") {
            // The pid runs up to the first "." (".plist" or ".<label>").
            let pidText = file.dropFirst(testSuitePrefix.count).prefix { $0 != "." }
            guard let pid = Int32(pidText), pid > 0, pid != me,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: preferencesFolder.appendingPathComponent(file))
        }
    }
}

//
//  ShrikeDataPaths.swift
//  ShrikeCore
//
//  The base folders Shrike writes its own data into. In the app these are
//  the user's `~/Library/Application Support` and `~/Library/Caches`.
//
//  Under XCTest (`swift test`, Xcode test runs) they point into a
//  per-process temp folder instead, so no test can ever write into the
//  user's real metadata database, thumbnail cache or backups — tests
//  that build services with `ShrikeServices.makeDefault()` used to fill
//  the real Recent Folders list with temp paths.
//

import Foundation

public enum ShrikeDataPaths {

    /// The folder name under Application Support / Caches.
    public static let bundleFolderName = "app.shrike"

    /// True when the process runs tests. XCTest registers `XCTestCase`
    /// with the Objective-C runtime (`swift test` and Xcode); Xcode also
    /// sets `XCTestConfigurationFilePath`. The app never links XCTest.
    public static let isRunningTests: Bool =
        NSClassFromString("XCTestCase") != nil
        || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Per-process root used instead of `~/Library` under tests:
    /// `$TMPDIR/shrike-tests-<pid>/`. Roots left by earlier test runs
    /// (their process has exited) are deleted the first time this is read.
    public static let testRoot: URL = {
        let tmp = FileManager.default.temporaryDirectory
        if isRunningTests { removeStaleTestRoots(in: tmp) }
        return tmp.appendingPathComponent(
            "\(testRootPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static let testRootPrefix = "shrike-tests-"

    /// `~/Library/Application Support`, or `<testRoot>/Application Support`
    /// under tests.
    public static let applicationSupportBase: URL = isRunningTests
        ? testRoot.appendingPathComponent("Application Support", isDirectory: true)
        : userLibraryFolder(.applicationSupportDirectory, fallback: "Library/Application Support")

    /// `~/Library/Caches`, or `<testRoot>/Caches` under tests.
    public static let cachesBase: URL = isRunningTests
        ? testRoot.appendingPathComponent("Caches", isDirectory: true)
        : userLibraryFolder(.cachesDirectory, fallback: "Library/Caches")

    /// `<Application Support>/app.shrike` (metadata DB, backups).
    public static var applicationSupport: URL {
        applicationSupportBase.appendingPathComponent(bundleFolderName, isDirectory: true)
    }

    /// `<Caches>/app.shrike` (thumbnail cache).
    public static var caches: URL {
        cachesBase.appendingPathComponent(bundleFolderName, isDirectory: true)
    }

    /// Deletes `shrike-tests-<pid>` folders whose process no longer runs.
    private static func removeStaleTestRoots(in tmp: URL) {
        let fm = FileManager.default
        let me = ProcessInfo.processInfo.processIdentifier
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(testRootPrefix) {
            guard let pid = Int32(name.dropFirst(testRootPrefix.count)), pid != me,
                  kill(pid, 0) == -1, errno == ESRCH else { continue }
            try? fm.removeItem(at: tmp.appendingPathComponent(name, isDirectory: true))
        }
    }

    private static func userLibraryFolder(
        _ directory: FileManager.SearchPathDirectory, fallback: String
    ) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(fallback, isDirectory: true)
    }
}

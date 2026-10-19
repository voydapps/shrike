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

    /// An explicit private base for test storage. Foundation's temporary
    /// directory on macOS need not follow TMPDIR. This override is ignored
    /// outside tests and must name an existing absolute directory.
    public static let testTemporaryDirectoryEnvironmentKey = "SHRIKE_TEST_TEMP_DIRECTORY"

    /// Per-process root used instead of `~/Library` under tests. With an
    /// explicit override, both storage and stale-root cleanup stay inside
    /// that base; otherwise the existing Foundation temporary base is used.
    public static let testRoot: URL = {
        let tmp: URL
        do {
            tmp = try resolveTestTemporaryBase(
                isRunningTests: isRunningTests,
                override: ProcessInfo.processInfo.environment[testTemporaryDirectoryEnvironmentKey],
                defaultDirectory: FileManager.default.temporaryDirectory,
                validateDirectory: validatedTestTemporaryDirectory)
        } catch {
            // A bad explicit isolation request must never fall back to the
            // shared temporary directory or enumerate its stale test roots.
            preconditionFailure("ShrikeDataPaths: invalid SHRIKE_TEST_TEMP_DIRECTORY")
        }
        if isRunningTests { removeStaleTestRoots(in: tmp) }
        return tmp.appendingPathComponent(
            "\(testRootPrefix)\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()

    static let testRootPrefix = "shrike-tests-"

    enum TestTemporaryDirectoryError: Error, Equatable {
        case invalidAbsolutePath
        case notExistingDirectory
    }

    /// Selection is independently testable without consulting either the
    /// shared temporary directory or user data. Validation only runs for a
    /// syntactically valid, explicitly supplied test override.
    static func resolveTestTemporaryBase(
        isRunningTests: Bool, override: String?, defaultDirectory: URL,
        validateDirectory: (URL) throws -> URL
    ) throws -> URL {
        guard isRunningTests, let override else { return defaultDirectory }
        guard override.hasPrefix("/"), !override.hasPrefix("//"), !override.contains("\0") else {
            throw TestTemporaryDirectoryError.invalidAbsolutePath
        }
        let requested = URL(fileURLWithPath: override, isDirectory: true).standardizedFileURL
        guard requested.path != "/" else { throw TestTemporaryDirectoryError.invalidAbsolutePath }
        return try validateDirectory(requested)
    }

    static func validatedTestTemporaryDirectory(_ requested: URL) throws -> URL {
        guard requested.isFileURL else { throw TestTemporaryDirectoryError.invalidAbsolutePath }
        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        guard canonical.isFileURL, canonical.path != "/" else {
            throw TestTemporaryDirectoryError.invalidAbsolutePath
        }
        guard let values = try? canonical.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            throw TestTemporaryDirectoryError.notExistingDirectory
        }
        return canonical
    }

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

    /// Temporary storage used when the primary database or cache cannot open.
    /// Test fallbacks stay private and outside the primary storage subtrees,
    /// so an obstructed Application Support or Caches path cannot block them.
    public static var fallbackDirectory: URL {
        fallbackDirectory(isRunningTests: isRunningTests, testRoot: testRoot,
                          temporaryDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
    }

    static func fallbackDirectory(isRunningTests: Bool, testRoot: URL, temporaryDirectory: URL) -> URL {
        isRunningTests ? testRoot.appendingPathComponent("Fallback", isDirectory: true) : temporaryDirectory
    }

    /// Deletes `shrike-tests-<pid>` folders whose process no longer runs.
    static func removeStaleTestRoots(
        in tmp: URL,
        currentProcessIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessRunning: (Int32) -> Bool = { pid in
            !(kill(pid, 0) == -1 && errno == ESRCH)
        }
    ) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix(testRootPrefix) {
            guard let pid = Int32(name.dropFirst(testRootPrefix.count)), pid > 0,
                  pid != currentProcessIdentifier, !isProcessRunning(pid) else { continue }
            let candidate = tmp.appendingPathComponent(name, isDirectory: true)
            guard let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try? fm.removeItem(at: candidate)
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

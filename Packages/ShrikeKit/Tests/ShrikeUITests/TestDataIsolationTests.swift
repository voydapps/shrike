//
//  TestDataIsolationTests.swift
//  ShrikeUITests
//
//  Guard: under XCTest, `ShrikeServices.makeDefault()` and the backup store
//  must never point into the user's `~/Library`. Before this guard the
//  suite filled the real Recent Folders list with temp test folders.
//

import XCTest
import ShrikeCore
import ShrikeIO
@testable import ShrikeUI

final class TestDataIsolationTests: XCTestCase {

    private let userLibrary = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .standardizedFileURL.path + "/"

    private func assertOutsideUserLibrary(
        _ url: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let path = url.standardizedFileURL.path
        XCTAssertFalse(path.hasPrefix(userLibrary),
                       "\(label) points into ~/Library: \(path)", file: file, line: line)
        XCTAssertTrue(path.hasPrefix(ShrikeDataPaths.testRoot.standardizedFileURL.path + "/"),
                      "\(label) is not under the per-process test root: \(path)",
                      file: file, line: line)
    }

    func test_xctestIsDetected() {
        XCTAssertTrue(ShrikeDataPaths.isRunningTests)
        XCTAssertTrue(ShrikeDataPaths.testRoot.lastPathComponent
            .hasPrefix("shrike-tests-\(ProcessInfo.processInfo.processIdentifier)"))
    }

    func test_dataPaths_underTests_stayOutOfUserLibrary() {
        assertOutsideUserLibrary(ShrikeDataPaths.applicationSupport, "Application Support")
        assertOutsideUserLibrary(ShrikeDataPaths.caches, "Caches")
        assertOutsideUserLibrary(BackupStore.defaultRoot, "BackupStore.defaultRoot")
        assertOutsideUserLibrary(BackupStore.shared.root, "BackupStore.shared")
    }

    func test_defaultFactoryFallbackPaths_arePrivateWithoutOpeningThem() {
        let paths = ShrikeServices.StoragePaths.defaults
        assertOutsideUserLibrary(paths.metadataFallback, "metadata fallback")
        assertOutsideUserLibrary(paths.thumbnailFallback, "thumbnail fallback")
        XCTAssertEqual(paths.metadataFallback.lastPathComponent, "shrike-metadata-fallback.sqlite")
        XCTAssertEqual(paths.thumbnailFallback.lastPathComponent, "shrike-thumbs-fallback")
        let support = ShrikeDataPaths.applicationSupport.standardizedFileURL.path + "/"
        let caches = ShrikeDataPaths.caches.standardizedFileURL.path + "/"
        for url in [paths.metadataFallback, paths.thumbnailFallback] {
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(support))
            XCTAssertFalse(url.standardizedFileURL.path.hasPrefix(caches))
        }
    }

    func test_makeDefault_underTests_opensDatabaseAndCacheInTestRoot() async throws {
        let services = ShrikeServices.makeDefault()

        let thumbs = await services.thumbnailCache.diskDirectory
        assertOutsideUserLibrary(thumbs, "thumbnail cache")

        // The primary DB opened (not the temp fallback), and it lives in
        // the test root.
        XCTAssertTrue(services.metadataStore.isPersistent)
        let db = ShrikeDataPaths.applicationSupport.appendingPathComponent("metadata.sqlite")
        assertOutsideUserLibrary(db, "metadata DB")
        XCTAssertTrue(FileManager.default.fileExists(atPath: db.path),
                      "makeDefault() did not open its DB at \(db.path)")

        // A recent folder written through the default services lands in
        // the test DB (read back through a second store on the same file).
        let marker = URL(fileURLWithPath: "/shrike-isolation-marker-\(UUID().uuidString)",
                         isDirectory: true)
        try await services.metadataStore.addRecentFolder(marker)
        let reopened = try MetadataStore(databaseURL: db)
        let recents = try await reopened.recentFolders(limit: 1000)
        XCTAssertTrue(recents.contains { $0.path == marker.path })
    }
}

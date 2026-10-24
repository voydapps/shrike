//
//  HeaderCacheTests.swift
//  ShrikeCoreTests
//
//  MetadataStore migration v5 (header cache for sorting).
//

import XCTest
import GRDB
@testable import ShrikeCore

final class HeaderCacheTests: XCTestCase {

    func testRoundTrip_keyedByPathAndModificationDate() async throws {
        let tmp = TempDir("header-cache")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let url = tmp.url.appendingPathComponent("x.jpg")
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let info = ImageHeaderInfo(dateCaptured: Date(timeIntervalSince1970: 1_600_000_000),
                                   pixelWidth: 4000, pixelHeight: 3000)
        await store.storeHeaders([url: (date, info)])
        let hit = await store.cachedHeaders(for: [url: date])
        XCTAssertEqual(hit[url], info)
        let stale = await store.cachedHeaders(for: [url: date.addingTimeInterval(1)])
        XCTAssertNil(stale[url])

        // All-nil rows (unreadable files) round-trip too.
        let bad = tmp.url.appendingPathComponent("bad.jpg")
        await store.storeHeaders([bad: (date, ImageHeaderInfo())])
        let badHit = await store.cachedHeaders(for: [bad: date])
        XCTAssertEqual(badHit[bad], ImageHeaderInfo())
    }

    /// Audit MP-12: the oldest header rows go when the table passes its cap,
    /// and recent folders keep only the newest.
    func testHeaderCacheAndRecentFoldersAreBounded() async throws {
        let tmp = TempDir("header-cache-prune")
        defer { tmp.cleanup() }
        let saved = MetadataStore.maxHeaderRows
        MetadataStore.maxHeaderRows = 150
        defer { MetadataStore.maxHeaderRows = saved }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func batch(_ range: Range<Int>) -> [URL: (modified: Date, info: ImageHeaderInfo)] {
            Dictionary(uniqueKeysWithValues: range.map {
                (tmp.url.appendingPathComponent("p\($0).jpg"), (date, ImageHeaderInfo(pixelWidth: $0, pixelHeight: 1)))
            })
        }
        await store.storeHeaders(batch(0..<120))
        await store.storeHeaders(batch(120..<240))
        let counts = try await store.tableCountsForTesting()
        XCTAssertEqual(counts.headers, 150)
        let newest = tmp.url.appendingPathComponent("p239.jpg")
        let kept = await store.cachedHeaders(for: [newest: date])
        XCTAssertNotNil(kept[newest])

        for i in 0..<(MetadataStore.maxRecentFolderRows + 10) {
            try await store.addRecentFolder(tmp.url.appendingPathComponent("f\(i)", isDirectory: true))
        }
        let after = try await store.tableCountsForTesting()
        XCTAssertEqual(after.recents, MetadataStore.maxRecentFolderRows)
        let recent = try await store.recentFolders(limit: 1)
        XCTAssertEqual(recent.first?.lastPathComponent, "f\(MetadataStore.maxRecentFolderRows + 9)")
    }

    /// A database written by the previous build (v1…v4) opens, keeps its
    /// ratings and gains the header cache.
    func testMigrationV5_fromV4Database() async throws {
        let tmp = TempDir("header-cache-migrate")
        defer { tmp.cleanup() }
        let dbURL = tmp.url.appendingPathComponent("v4.sqlite")
        let photo = tmp.url.appendingPathComponent("rated.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: photo)
        do {
            let q = try DatabaseQueue(path: dbURL.path)
            try await q.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                for id in ["v1", "v2-path-key", "v3-drop-file-tags", "v4-case-insensitive-keys"] {
                    try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [id])
                }
                try db.execute(sql: """
                    CREATE TABLE file_metadata (path TEXT PRIMARY KEY NOT NULL,
                      size INTEGER NOT NULL DEFAULT 0, mtime REAL NOT NULL DEFAULT 0,
                      rating INTEGER NOT NULL DEFAULT 0, flagged INTEGER NOT NULL DEFAULT 0,
                      updated_at REAL NOT NULL)
                    """)
                try db.execute(sql: "CREATE INDEX idx_metadata_rating ON file_metadata(rating)")
                try db.execute(sql: "CREATE INDEX idx_metadata_flagged ON file_metadata(flagged)")
                try db.execute(sql: "CREATE TABLE recent_folders (path TEXT PRIMARY KEY, last_opened REAL NOT NULL)")
                try db.execute(sql: "INSERT INTO file_metadata VALUES (?, 3, 1, 5, 1, 100)",
                               arguments: [CanonicalPath.key(photo)])
            }
        }
        let store = try MetadataStore(databaseURL: dbURL, writeFileAttributes: { false })
        let rating = try await store.rating(for: photo)
        XCTAssertEqual(rating, 5)
        let date = Date(timeIntervalSince1970: 42)
        await store.storeHeaders([photo: (date, ImageHeaderInfo(pixelWidth: 1, pixelHeight: 2))])
        let hit = await store.cachedHeaders(for: [photo: date])
        XCTAssertEqual(hit[photo]?.pixelHeight, 2)

        let q = try DatabaseQueue(path: dbURL.path)
        let applied = try await q.read { try String.fetchAll($0, sql: "SELECT identifier FROM grdb_migrations") }
        XCTAssertTrue(applied.contains("v5-header-cache"))
    }
}

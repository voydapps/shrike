//
//  MetadataStoreTests.swift
//  ShrikeCoreTests
//

import XCTest
import GRDB
@testable import ShrikeCore

final class MetadataStoreTests: XCTestCase {

    private func makeStore(_ tmp: TempDir) throws -> MetadataStore {
        let db = tmp.url.appendingPathComponent("meta.sqlite")
        return try MetadataStore(databaseURL: db)
    }

    private func makeFixtureCopy(_ tmp: TempDir, name: String = "img.jpg") throws -> URL {
        let src = try TestFixture.url("small.jpg")
        let dst = tmp.url.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        return dst
    }

    // MARK: - Ratings

    func testRating_defaultZero() async throws {
        let tmp = TempDir("meta-rating-default")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)
        let rating = try await store.rating(for: url)
        XCTAssertEqual(rating, 0)
    }

    func testRating_roundtrip() async throws {
        let tmp = TempDir("meta-rating-rt")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)

        try await store.setRating(4, for: url)
        let rating = try await store.rating(for: url)
        XCTAssertEqual(rating, 4)
    }

    // MARK: - Flag

    func testFlag_roundtrip() async throws {
        let tmp = TempDir("meta-flag")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)

        let initial = try await store.isFlagged(url)
        XCTAssertFalse(initial)
        try await store.setFlag(true, for: url)
        let after = try await store.isFlagged(url)
        XCTAssertTrue(after)
        try await store.setFlag(false, for: url)
        let cleared = try await store.isFlagged(url)
        XCTAssertFalse(cleared)
    }

    // MARK: - Tags

    func testTags_readFinderTagsFromFile() async throws {
        let tmp = TempDir("meta-tags")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)
        let t0 = try await store.tags(for: url)
        XCTAssertEqual(t0, [])
        try (url as NSURL).setResourceValue(["red", "holiday"], forKey: .tagNamesKey)
        let t1 = try await store.tags(for: url)
        XCTAssertEqual(t1, ["holiday", "red"])
    }

    // MARK: - Identity: path key + xattr mirror

    /// Behaviour changed on purpose: user metadata is keyed by path
    /// and mirrored into xattrs, so a rename done outside Shrike (Finder)
    /// keeps the rating via the file's extended attribute. Previously the
    /// rating was lost (asserted 0).
    func testRatingSurvivesFinderRename_viaXattr() async throws {
        let tmp = TempDir("meta-rename")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp, name: "original.jpg")
        try await store.setRating(5, for: url)
        try await store.setFlag(true, for: url)
        let again = try await store.rating(for: url)
        XCTAssertEqual(again, 5)

        let renamed = tmp.url.appendingPathComponent("renamed.jpg")
        try FileManager.default.moveItem(at: url, to: renamed)
        let afterRename = try await store.rating(for: renamed)
        XCTAssertEqual(afterRename, 5, "xattr travels with the file")
        let flagAfter = try await store.isFlagged(renamed)
        XCTAssertTrue(flagAfter)
    }

    func testNoXattrWhenPrefOff() async throws {
        let tmp = TempDir("meta-noxattr")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let url = try makeFixtureCopy(tmp)
        try await store.setRating(4, for: url)
        XCTAssertNil(FileAttributes.rating(at: url))
        let renamed = tmp.url.appendingPathComponent("moved.jpg")
        try FileManager.default.moveItem(at: url, to: renamed)
        let r = try await store.rating(for: renamed)
        XCTAssertEqual(r, 0)
    }

    func testXattrMirrorValues() async throws {
        let tmp = TempDir("meta-xattr")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)
        try await store.setRating(3, for: url)
        try await store.setFlag(true, for: url)
        XCTAssertEqual(FileAttributes.rating(at: url), 3)
        XCTAssertEqual(FileAttributes.flag(at: url), true)
        XCTAssertEqual(FileAttributes.read(FileAttributes.ratingName, at: url), "3")
    }

    func testRatingSurvivesInPlaceSave() async throws {
        let tmp = TempDir("meta-save")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)
        try await store.setRating(4, for: url)
        // Simulate a save: new bytes, new size, new mtime, xattrs gone.
        let tmpFile = tmp.url.appendingPathComponent("new.bin")
        try Data(repeating: 7, count: 1234).write(to: tmpFile)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tmpFile)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 100)],
                                              ofItemAtPath: url.path)
        let r = try await store.rating(for: url)
        XCTAssertEqual(r, 4)
        try await store.rekey(from: url, to: url)
        XCTAssertEqual(FileAttributes.rating(at: url), 4, "rekey re-stamps xattrs")
    }

    func testRekeyMovesEverything() async throws {
        let tmp = TempDir("meta-rekey")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let a = try makeFixtureCopy(tmp, name: "a.jpg")
        try await store.setRating(2, for: a)
        try await store.setFlag(true, for: a)
        let b = tmp.url.appendingPathComponent("sub/b.jpg")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: a, to: b)
        try await store.rekey(from: a, to: b)
        let rb = try await store.rating(for: b)
        let fb = try await store.isFlagged(b)
        XCTAssertEqual(rb, 2)
        XCTAssertTrue(fb)
        let ra = try await store.rating(for: a)
        XCTAssertEqual(ra, 0)
    }

    func testCopyMetadata() async throws {
        let tmp = TempDir("meta-copy")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let a = try makeFixtureCopy(tmp, name: "a.jpg")
        try await store.setRating(5, for: a)
        let b = try makeFixtureCopy(tmp, name: "b.jpg")
        try await store.copyMetadata(from: a, to: b)
        let rb = try await store.rating(for: b)
        let ra = try await store.rating(for: a)
        XCTAssertEqual(rb, 5)
        XCTAssertEqual(ra, 5)
        XCTAssertEqual(FileAttributes.rating(at: b), 5)
    }

    func testSetFlagOnXattrOnlyFileKeepsRating() async throws {
        let tmp = TempDir("meta-seed")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let url = try makeFixtureCopy(tmp)
        FileAttributes.setRating(4, at: url)   // e.g. rated on another Mac
        try await store.setFlag(true, for: url)
        let r = try await store.rating(for: url)
        XCTAssertEqual(r, 4)
    }

    // MARK: - Migration from the v1 (content-hash) schema

    func testMigrationFromV1Schema() async throws {
        let tmp = TempDir("meta-migrate")
        defer { tmp.cleanup() }
        let dbURL = tmp.url.appendingPathComponent("old.sqlite")
        let photo = try makeFixtureCopy(tmp, name: "p.jpg")
        let other = try makeFixtureCopy(tmp, name: "q.jpg")
        do {
            // Build exactly what the old code wrote, including GRDB's
            // migration bookkeeping.
            let q = try DatabaseQueue(path: dbURL.path)
            try await q.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES ('v1')")
                try db.execute(sql: """
                    CREATE TABLE file_metadata (content_hash TEXT PRIMARY KEY, path TEXT NOT NULL,
                      size INTEGER NOT NULL, mtime REAL NOT NULL, rating INTEGER NOT NULL DEFAULT 0,
                      flagged INTEGER NOT NULL DEFAULT 0, updated_at REAL NOT NULL)
                    """)
                try db.execute(sql: """
                    CREATE TABLE file_tags (content_hash TEXT NOT NULL, tag TEXT NOT NULL,
                      PRIMARY KEY (content_hash, tag),
                      FOREIGN KEY (content_hash) REFERENCES file_metadata(content_hash) ON DELETE CASCADE)
                    """)
                try db.execute(sql: "CREATE INDEX idx_metadata_rating ON file_metadata(rating)")
                try db.execute(sql: "CREATE INDEX idx_metadata_flagged ON file_metadata(flagged)")
                try db.execute(sql: "CREATE TABLE recent_folders (path TEXT PRIMARY KEY, last_opened REAL NOT NULL)")
                // Same path, two hashes (file re-saved): old row rated 5,
                // newer row only tagged (rating 0) → rating 5 must survive.
                try db.execute(sql: "INSERT INTO file_metadata VALUES ('h1', ?, 10, 1, 5, 1, 100)",
                               arguments: [photo.path])
                try db.execute(sql: "INSERT INTO file_metadata VALUES ('h2', ?, 20, 2, 0, 0, 200)",
                               arguments: [photo.path])
                try db.execute(sql: "INSERT INTO file_metadata VALUES ('h3', ?, 30, 3, 2, 0, 300)",
                               arguments: [other.path])
                try db.execute(sql: "INSERT INTO file_tags VALUES ('h1', 'old')")
                try db.execute(sql: "INSERT INTO file_tags VALUES ('h2', 'new')")
                try db.execute(sql: "INSERT INTO recent_folders VALUES ('/some/folder', 1)")
            }
        }
        let store = try MetadataStore(databaseURL: dbURL, writeFileAttributes: { false })
        let rp = try await store.rating(for: photo)
        let fp = try await store.isFlagged(photo)
        let rq = try await store.rating(for: other)
        let recents = try await store.recentFolders(limit: 5)
        XCTAssertEqual(rp, 5)
        XCTAssertTrue(fp)
        XCTAssertEqual(rq, 2)
        XCTAssertEqual(recents.map(\.path), ["/some/folder"])
        // Keyed by path now: survives a content change.
        try Data(repeating: 1, count: 99).write(to: photo)
        let rp2 = try await store.rating(for: photo)
        XCTAssertEqual(rp2, 5)
        // v3 dropped the tag table (Finder tags replace it).
        try await store.rekey(from: photo, to: tmp.url.appendingPathComponent("moved.jpg"))
        let rm = try await store.rating(for: tmp.url.appendingPathComponent("moved.jpg"))
        XCTAssertEqual(rm, 5)
        let q = try DatabaseQueue(path: dbURL.path)
        let hasTags = try await q.read { try $0.tableExists("file_tags") }
        XCTAssertFalse(hasTags)
    }

    // MARK: - Batched API (grid)

    func testRecords_batchedReadsAndWrites() async throws {
        let tmp = TempDir("meta-batch")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)
        let a = try makeFixtureCopy(tmp, name: "a.jpg")
        let b = try makeFixtureCopy(tmp, name: "b.jpg")
        let c = try makeFixtureCopy(tmp, name: "c.jpg")
        let d = try makeFixtureCopy(tmp, name: "d.jpg")
        try await store.setRating(3, for: [a, b])
        try await store.setFlag(true, for: [b, c])
        FileAttributes.setRating(2, at: d)            // xattr only, no row
        let recs = await store.records(for: [a, b, c, d, URL(string: "https://x.y/z.jpg")!])
        XCTAssertEqual(recs.count, 4, "non-file URL left out")
        XCTAssertEqual(recs[a], FileRecord(rating: 3, flagged: false))
        XCTAssertEqual(recs[b], FileRecord(rating: 3, flagged: true))
        XCTAssertEqual(recs[c], FileRecord(rating: 0, flagged: true))
        XCTAssertEqual(recs[d], FileRecord(rating: 2, flagged: false))
        XCTAssertEqual(FileAttributes.rating(at: b), 3)
        XCTAssertEqual(FileAttributes.flag(at: c), true)
        let clamp = try makeFixtureCopy(tmp, name: "e.jpg")
        try await store.setRating(9, for: [clamp])
        let r = try await store.rating(for: clamp)
        XCTAssertEqual(r, 5)
    }

    func testRecords_1000URLs_timing() async throws {
        let tmp = TempDir("meta-batch-1000")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"))
        var urls: [URL] = []
        for i in 0..<1000 {
            let u = tmp.url.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            try Data([0xFF, 0xD8]).write(to: u)
            urls.append(u)
        }
        // No rows yet: every URL falls back to its xattrs.
        var t0 = CFAbsoluteTimeGetCurrent()
        let cold = await store.records(for: urls)
        let coldMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        XCTAssertEqual(cold.count, 1000)

        t0 = CFAbsoluteTimeGetCurrent()
        try await store.setRating(4, for: urls)
        let writeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        var best = Double.infinity
        var recs: [URL: FileRecord] = [:]
        for _ in 0..<5 {
            t0 = CFAbsoluteTimeGetCurrent()
            recs = await store.records(for: urls)
            best = min(best, (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        XCTAssertEqual(recs.count, 1000)
        XCTAssertTrue(recs.values.allSatisfy { $0.rating == 4 })
        print(String(format: "[timing] MetadataStore.records(for: 1000) rows=%.2f ms (best of 5), "
                     + "no-rows/xattr=%.2f ms, setRating(1000)=%.2f ms", best, coldMs, writeMs))
        XCTAssertLessThan(best, 250, "loose guard; see printed timing")
    }

    func testTransfer_copyAndMove() async throws {
        let tmp = TempDir("meta-transfer")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let a = try makeFixtureCopy(tmp, name: "a.jpg")
        try await store.setRating(5, for: a)
        let b = try makeFixtureCopy(tmp, name: "b.jpg")
        try await store.transfer(from: a, to: b, mode: .copy)
        let ra = try await store.rating(for: a)
        let rb = try await store.rating(for: b)
        XCTAssertEqual([ra, rb], [5, 5])
        let c = tmp.url.appendingPathComponent("c.jpg")
        try FileManager.default.moveItem(at: b, to: c)
        try await store.transfer(from: b, to: c, mode: .move)
        let rb2 = try await store.rating(for: b)
        let rc = try await store.rating(for: c)
        XCTAssertEqual([rb2, rc], [0, 5])
    }

    // MARK: - Case-insensitive keys

    func testCaseInsensitiveVolume_keysIgnoreCase() async throws {
        let tmp = TempDir("meta-case")
        defer { tmp.cleanup() }
        try XCTSkipUnless(CanonicalPath.isCaseInsensitive(directory: tmp.url.path),
                          "temp volume is case-sensitive")
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("m.sqlite"),
                                      writeFileAttributes: { false })
        let url = try makeFixtureCopy(tmp, name: "Photo.JPG")
        try await store.setRating(3, for: url)
        let other = tmp.url.appendingPathComponent("photo.jpg")
        let r = try await store.rating(for: other)
        XCTAssertEqual(r, 3)
        let recs = await store.records(for: [url, other])
        XCTAssertEqual(recs[other]?.rating, 3)
        XCTAssertEqual(recs[url]?.rating, 3)
        XCTAssertEqual(CanonicalPath.key(url), CanonicalPath.key(other))
        let odd = [url, other, URL(fileURLWithPath: "/x.jpg"), URL(fileURLWithPath: "/tmp/../tmp/x.jpg"),
                   tmp.url.appendingPathComponent("sub/../Z.jpg")]
        XCTAssertEqual(CanonicalPath.keys(odd), odd.map(CanonicalPath.key), "batched = single")
        XCTAssertNotEqual(CanonicalPath.of(url), CanonicalPath.of(other), "of() keeps spelling")
    }

    func testMigrationV4_foldsExistingKeys() async throws {
        let tmp = TempDir("meta-migrate-v4")
        defer { tmp.cleanup() }
        try XCTSkipUnless(CanonicalPath.isCaseInsensitive(directory: tmp.url.path),
                          "temp volume is case-sensitive")
        let dbURL = tmp.url.appendingPathComponent("v3.sqlite")
        let photo = try makeFixtureCopy(tmp, name: "Mixed.JPG")
        let spelled = CanonicalPath.of(photo)
        let lower = (spelled as NSString).deletingLastPathComponent + "/mixed.jpg"
        do {
            let q = try DatabaseQueue(path: dbURL.path)
            try await q.write { db in
                try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
                for id in ["v1", "v2-path-key", "v3-drop-file-tags"] {
                    try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [id])
                }
                try db.execute(sql: """
                    CREATE TABLE file_metadata (path TEXT PRIMARY KEY NOT NULL,
                      size INTEGER NOT NULL DEFAULT 0, mtime REAL NOT NULL DEFAULT 0,
                      rating INTEGER NOT NULL DEFAULT 0, flagged INTEGER NOT NULL DEFAULT 0,
                      updated_at REAL NOT NULL)
                    """)
                try db.execute(sql: "CREATE TABLE recent_folders (path TEXT PRIMARY KEY, last_opened REAL NOT NULL)")
                // Two spellings of one file: older rated 4, newer flagged only.
                try db.execute(sql: "INSERT INTO file_metadata VALUES (?, 1, 1, 4, 0, 100)",
                               arguments: [spelled])
                try db.execute(sql: "INSERT INTO file_metadata VALUES (?, 1, 1, 0, 1, 200)",
                               arguments: [lower])
            }
        }
        let store = try MetadataStore(databaseURL: dbURL, writeFileAttributes: { false })
        let r = try await store.rating(for: photo)
        let f = try await store.isFlagged(photo)
        XCTAssertEqual(r, 4)
        XCTAssertTrue(f)
        let q = try DatabaseQueue(path: dbURL.path)
        let n = try await q.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM file_metadata") }
        XCTAssertEqual(n, 1)
    }

    // MARK: - Persistence is visible

    func testOpenWithFallback_flagsNonPersistent() throws {
        let tmp = TempDir("meta-fallback")
        defer { tmp.cleanup() }
        let blocker = tmp.url.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let bad = blocker.appendingPathComponent("db/meta.sqlite")
        let fb = MetadataStore.openWithFallback(primary: bad,
                                                fallback: tmp.url.appendingPathComponent("fb.sqlite"))
        XCTAssertFalse(fb.isPersistent)
        XCTAssertNotNil(fb.openError)
        let mem = MetadataStore.openWithFallback(primary: bad, fallback: bad)
        XCTAssertFalse(mem.isPersistent)
        let good = MetadataStore.openWithFallback(primary: tmp.url.appendingPathComponent("ok.sqlite"),
                                                  fallback: nil)
        XCTAssertTrue(good.isPersistent)
        XCTAssertNil(good.openError)
    }

    // MARK: - Recent folders

    func testRecentFolders_addAndList() async throws {
        let tmp = TempDir("meta-recents")
        defer { tmp.cleanup() }
        let store = try makeStore(tmp)

        let a = tmp.url.appendingPathComponent("a", isDirectory: true)
        let b = tmp.url.appendingPathComponent("b", isDirectory: true)
        let c = tmp.url.appendingPathComponent("c", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)

        try await store.addRecentFolder(a)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await store.addRecentFolder(b)
        try await Task.sleep(nanoseconds: 5_000_000)
        try await store.addRecentFolder(c)

        let recents = try await store.recentFolders(limit: 10)
        XCTAssertEqual(recents.count, 3)
        XCTAssertEqual(recents[0].lastPathComponent, "c")
        XCTAssertEqual(recents[2].lastPathComponent, "a")

        // Reopening a — it should float to the top.
        try await Task.sleep(nanoseconds: 5_000_000)
        try await store.addRecentFolder(a)
        let recents2 = try await store.recentFolders(limit: 10)
        XCTAssertEqual(recents2[0].lastPathComponent, "a")
    }
}

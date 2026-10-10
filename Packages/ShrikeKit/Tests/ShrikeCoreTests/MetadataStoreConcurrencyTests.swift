//
//  MetadataStoreConcurrencyTests.swift
//  ShrikeCoreTests
//
//  Stress: many batched reads (some in cancelled Tasks) race rating and
//  flag writes while the database folder is deleted under the open store
//  and the store is released. Before the fix, the first read after the
//  folder went away trapped in GRDB 6.29.3 with "unbalanced endReadOnly()"
//  (`DatabaseQueue.asyncRead` ends read-only mode in a `defer` even when
//  `PRAGMA query_only = 1` threw SQLITE_IOERR) and killed the test process.
//

import XCTest
import GRDB
@testable import ShrikeCore

final class MetadataStoreConcurrencyTests: XCTestCase {

    private func makeFiles(_ dir: TempDir, count: Int) throws -> [URL] {
        try (0..<count).map { i in
            let url = dir.url.appendingPathComponent("f\(i).jpg")
            try Data([0xFF, 0xD8, UInt8(i & 0xFF)]).write(to: url)
            return url
        }
    }

    /// The UI-test shape: a viewer rates the photo a few times, the
    /// toolbar / filmstrip / grid keep reading records, some of those
    /// reads are cancelled, then the test folder (holding the database)
    /// is deleted while work is still queued, and the store is dropped.
    func testReadsAndWritesSurviveDatabaseFolderRemovedMidFlight() async throws {
        for round in 0..<12 {
            let dbDir = TempDir("meta-stress-db")
            let fileDir = TempDir("meta-stress-files")
            defer { dbDir.cleanup(); fileDir.cleanup() }
            let urls = try makeFiles(fileDir, count: 6)
            var store: MetadataStore? = try MetadataStore(
                databaseURL: dbDir.url.appendingPathComponent("meta.sqlite"),
                writeFileAttributes: { true })
            let s = try XCTUnwrap(store)
            let removeAt = 10 + round * 3
            let dbFolder = dbDir.url

            await withTaskGroup(of: Void.self) { group in
                var loose: [Task<Void, Never>] = []
                for i in 0..<60 {
                    let url = urls[i % urls.count]
                    group.addTask { _ = await s.records(for: urls) }
                    let t = Task { _ = await s.records(for: urls) }
                    if i % 3 == 0 { t.cancel() }
                    loose.append(t)
                    group.addTask { try? await s.setRating(i % 6, for: [url]) }
                    group.addTask { try? await s.setFlag(i.isMultiple(of: 2), for: url) }
                    group.addTask { _ = try? await s.rating(for: url) }
                    if i == removeAt {
                        group.addTask { try? FileManager.default.removeItem(at: dbFolder) }
                    }
                    if i % 7 == 0 { await Task.yield() }
                }
                // Drop the store while work is still queued on it.
                store = nil
                for t in loose.suffix(10) { t.cancel() }
            }
            XCTAssertNil(store)

            // Every read path, after the folder is gone: an error or the
            // xattr fallback, never a trap.
            dbDir.cleanup()
            let records = await s.records(for: urls)
            XCTAssertEqual(records.count, urls.count, "round \(round)")
            _ = await s.cachedHeaders(for: [urls[0]: Date()])
            _ = try? await s.rating(for: urls[0])
            _ = try? await s.isFlagged(urls[0])
            _ = try? await s.recentFolders(limit: 5)
            _ = await s.records(for: urls)
        }
    }

    /// The narrowest form: one read after the database folder is removed.
    func testReadAfterDatabaseFolderRemovedThrowsInsteadOfTrapping() async throws {
        let dbDir = TempDir("meta-gone-db")
        let fileDir = TempDir("meta-gone-files")
        defer { dbDir.cleanup(); fileDir.cleanup() }
        let url = try makeFiles(fileDir, count: 1)[0]
        let store = try MetadataStore(databaseURL: dbDir.url.appendingPathComponent("meta.sqlite"),
                                      writeFileAttributes: { true })
        try await store.setRating(4, for: url)
        let before = try await store.rating(for: url)
        XCTAssertEqual(before, 4)

        dbDir.cleanup()
        do {
            _ = try await store.recentFolders(limit: 3)
            XCTFail("reading a removed database should throw")
        } catch {
            // SQLITE_IOERR from `PRAGMA query_only = 1`.
        }
        // The rating mirrored into the file's xattr still reads.
        let records = await store.records(for: [url])
        XCTAssertEqual(records[url]?.rating, 4)
    }

    /// Reads stay read-only and transactional after the fix: a write
    /// inside a read fails, and the connection is writable afterwards.
    func testReadAccessIsReadOnlyAndLeavesConnectionWritable() async throws {
        let dbDir = TempDir("meta-ro-db")
        let fileDir = TempDir("meta-ro-files")
        defer { dbDir.cleanup(); fileDir.cleanup() }
        let url = try makeFiles(fileDir, count: 1)[0]
        let store = try MetadataStore(databaseURL: dbDir.url.appendingPathComponent("meta.sqlite"),
                                      writeFileAttributes: { false })
        do {
            try await store.readOnlyAccess { db in
                try db.execute(sql: "INSERT INTO recent_folders (path, last_opened) VALUES ('/x', 1)")
            }
            XCTFail("a write inside a read must fail")
        } catch let error as DatabaseError {
            XCTAssertEqual(error.resultCode, .SQLITE_READONLY)
        }
        let inTransaction = try await store.readOnlyAccess { db in db.isInsideTransaction }
        XCTAssertTrue(inTransaction, "reads run inside a transaction")
        try await store.setRating(2, for: url)
        let rating = try await store.rating(for: url)
        XCTAssertEqual(rating, 2)
        let folders = try await store.recentFolders(limit: 5)
        XCTAssertTrue(folders.isEmpty, "the refused insert left nothing behind")
    }
}

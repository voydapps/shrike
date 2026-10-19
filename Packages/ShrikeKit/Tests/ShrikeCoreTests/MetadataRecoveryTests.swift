import XCTest
import GRDB
@testable import ShrikeCore

final class MetadataRecoveryTests: XCTestCase {
    func testFailedRecoveryKeepsChangesAndSuccessfulRetryMergesAllSessionData() async throws {
        let tmp = TempDir("metadata-recovery")
        defer { tmp.cleanup() }
        let blocker = tmp.url.appendingPathComponent("blocked")
        try Data([1]).write(to: blocker)
        let primary = blocker.appendingPathComponent("metadata.sqlite"), fallback = tmp.url.appendingPathComponent("fallback.sqlite")
        let store = try MetadataStore(databaseURL: fallback, isPersistent: false, openError: "original error",
                                      writeFileAttributes: { false }, recoveryPrimaryURL: primary)
        let image = tmp.url.appendingPathComponent("image.jpg"), recent = tmp.url.appendingPathComponent("recent")
        try await store.setRating(5, for: image); try await store.setFlag(true, for: image)
        try await store.addRecentFolder(recent)
        do { _ = try await store.retryPersistentStore(); XCTFail("blocked primary must fail") } catch {}
        XCTAssertFalse(store.isPersistent)
        let before = try await store.recordsStrict(for: [image])
        XCTAssertEqual(before[image], FileRecord(rating: 5, flagged: true))
        try FileManager.default.removeItem(at: blocker)
        let outcome = try await store.retryPersistentStore()
        XCTAssertEqual(outcome.metadataCount, 1); XCTAssertEqual(outcome.recentFolderCount, 1)
        XCTAssertTrue(store.isPersistent); XCTAssertNil(store.openError)
        let reopened = try MetadataStore(databaseURL: primary, writeFileAttributes: { false })
        let after = try await reopened.recordsStrict(for: [image])
        let recents = try await reopened.recentFolders(limit: 10)
        XCTAssertEqual(after, before); XCTAssertEqual(recents.map(\.path), [recent.path])
        try await store.setRating(2, for: image)
        let actual = try await reopened.rating(for: image)
        XCTAssertEqual(actual, 2, "the same service object must now write the durable database")
    }
    func testRecoveryConflictRulePreservesNewerPrimaryAndExplicitSessionClear() async throws {
        let tmp = TempDir("metadata-recovery-conflict")
        defer { tmp.cleanup() }
        let primary = tmp.url.appendingPathComponent("primary.sqlite"), fallback = tmp.url.appendingPathComponent("fallback.sqlite")
        let durable = try MetadataStore(databaseURL: primary, writeFileAttributes: { false })
        let session = try MetadataStore(databaseURL: fallback, isPersistent: false, writeFileAttributes: { false }, recoveryPrimaryURL: primary)
        let a = tmp.url.appendingPathComponent("a.jpg"), b = tmp.url.appendingPathComponent("b.jpg")
        try await durable.setRatings([a: 5, b: 5]); try await durable.setFlag(true, for: b)
        try await session.setRatings([a: 1, b: 0]); try await session.setFlag(false, for: b)
        let primaryDB = try DatabaseQueue(path: primary.path), fallbackDB = try DatabaseQueue(path: fallback.path)
        try await primaryDB.write { db in try db.execute(sql: "UPDATE file_metadata SET updated_at=100") }
        try await fallbackDB.write { db in
            try db.execute(sql: "UPDATE file_metadata SET updated_at=50")
            try db.execute(sql: "UPDATE file_metadata SET updated_at=200 WHERE path=?", arguments: [CanonicalPath.key(b)])
        }
        _ = try await session.retryPersistentStore()
        let actual = try await session.recordsStrict(for: [a, b])
        XCTAssertEqual(actual[a], FileRecord(rating: 5))
        XCTAssertEqual(actual[b], FileRecord(), "a newer explicit clear must not be treated as missing metadata")
    }
}

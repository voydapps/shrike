import XCTest
import GRDB
@testable import ShrikeCore

final class MetadataFieldMutationTests: XCTestCase {
    private func fixture(_ tmp: TempDir, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url
    }

    func testMixedRatingsRestorePreservesInterveningFlags() async throws {
        let tmp = TempDir("metadata-mixed-ratings")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("metadata.sqlite"),
                                      writeFileAttributes: { false })
        let a = try fixture(tmp, "a.jpg"), b = try fixture(tmp, "b.raw")
        try await store.setRating(1, for: a)
        try await store.setRating(4, for: b)
        try await store.setFlag(true, for: b)
        let forward = try await store.setRatings([a: 5, b: 5])
        XCTAssertEqual(forward.previous, [a: FileRecord(rating: 1), b: FileRecord(rating: 4, flagged: true)])
        XCTAssertEqual(forward.new, [a: FileRecord(rating: 5), b: FileRecord(rating: 5, flagged: true)])
        try await store.setFlags([a: true, b: false])
        let undo = try await store.setRatings(forward.previous.mapValues(\.rating))
        XCTAssertEqual(undo.previous, [a: FileRecord(rating: 5, flagged: true), b: FileRecord(rating: 5)])
        XCTAssertEqual(undo.new, [a: FileRecord(rating: 1, flagged: true), b: FileRecord(rating: 4)])
        let actual = try await store.recordsStrict(for: [a, b])
        XCTAssertEqual(actual, undo.new)
    }

    func testMixedFlagsRestorePreservesInterveningRatings() async throws {
        let tmp = TempDir("metadata-mixed-flags")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("metadata.sqlite"),
                                      writeFileAttributes: { false })
        let a = try fixture(tmp, "a.jpg"), b = try fixture(tmp, "b.raw")
        try await store.setFlag(true, for: b)
        let forward = try await store.setFlags([a: true, b: true])
        XCTAssertEqual(forward.previous, [a: FileRecord(), b: FileRecord(flagged: true)])
        try await store.setRatings([a: 3, b: 4])
        let undo = try await store.setFlags(forward.previous.mapValues(\.flagged))
        XCTAssertEqual(undo.new, [a: FileRecord(rating: 3), b: FileRecord(rating: 4, flagged: true)])
    }

    func testMissingRowsImportAttributesAndOnlyMirrorChangedField() async throws {
        let tmp = TempDir("metadata-import")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("metadata.sqlite"),
                                      writeFileAttributes: { true })
        let a = try fixture(tmp, "a.jpg"), b = try fixture(tmp, "b.jpg"), absent = tmp.url.appendingPathComponent("absent.jpg")
        FileAttributes.setRating(2, at: a)
        FileAttributes.setFlag(true, at: a)
        FileAttributes.setRating(4, at: b)
        let before = try await store.recordsStrict(for: [a, b, absent])
        XCTAssertEqual(before, [a: FileRecord(rating: 2, flagged: true), b: FileRecord(rating: 4), absent: FileRecord()])
        let ratings = try await store.setRatings([a: 8])
        XCTAssertEqual(ratings.previous[a], before[a])
        XCTAssertEqual(ratings.new[a], FileRecord(rating: 5, flagged: true))
        XCTAssertEqual(FileAttributes.rating(at: a), 5)
        XCTAssertEqual(FileAttributes.flag(at: a), true)
        let flags = try await store.setFlags([b: true])
        XCTAssertEqual(flags.previous[b], before[b])
        XCTAssertEqual(flags.new[b], FileRecord(rating: 4, flagged: true))
        XCTAssertEqual(FileAttributes.rating(at: b), 4)
        XCTAssertEqual(FileAttributes.flag(at: b), true)
    }

    func testDatabaseFailureRollsBackWholeMixedRatingAndFlagMutation() async throws {
        let tmp = TempDir("metadata-atomic-failure")
        defer { tmp.cleanup() }
        let databaseURL = tmp.url.appendingPathComponent("metadata.sqlite")
        let store = try MetadataStore(databaseURL: databaseURL, writeFileAttributes: { true })
        let a = try fixture(tmp, "a.jpg"), b = try fixture(tmp, "z.jpg")
        try await store.setRating(1, for: a)
        try await store.setRating(4, for: b)
        try await store.setFlag(true, for: b)
        let before = try await store.recordsStrict(for: [a, b])
        let db = try DatabaseQueue(path: databaseURL.path)
        let failingKey = try MetadataStore.key(for: b)
        try await db.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_last_file BEFORE UPDATE ON file_metadata
                WHEN NEW.path = '\(failingKey.replacingOccurrences(of: "'", with: "''"))'
                BEGIN SELECT RAISE(ABORT, 'injected metadata failure'); END
                """)
        }
        do { _ = try await store.setRatings([a: 3, b: 2]); XCTFail("write must throw") }
        catch is DatabaseError {}
        var after = try await store.recordsStrict(for: [a, b])
        XCTAssertEqual(after, before, "a failure after an earlier update must roll back the entire press")
        XCTAssertEqual(FileAttributes.rating(at: a), 1, "mirrors must not update before commit")
        XCTAssertEqual(FileAttributes.rating(at: b), 4)
        do { _ = try await store.setFlags([a: true, b: false]); XCTFail("write must throw") }
        catch is DatabaseError {}
        after = try await store.recordsStrict(for: [a, b])
        XCTAssertEqual(after, before)
        XCTAssertEqual(FileAttributes.flag(at: a), nil)
        XCTAssertEqual(FileAttributes.flag(at: b), true)
    }

    func testStrictReadThrowsDatabaseErrorInsteadOfInventingUndoBaseline() async throws {
        let tmp = TempDir("metadata-strict-read")
        defer { tmp.cleanup() }
        let databaseURL = tmp.url.appendingPathComponent("metadata.sqlite")
        let store = try MetadataStore(databaseURL: databaseURL, writeFileAttributes: { false })
        let a = try fixture(tmp, "a.jpg")
        FileAttributes.setRating(2, at: a)
        let db = try DatabaseQueue(path: databaseURL.path)
        try await db.write { try $0.execute(sql: "DROP TABLE file_metadata") }
        do { _ = try await store.recordsStrict(for: [a]); XCTFail("failed DB query must throw") }
        catch is DatabaseError {}
        let fallback = await store.records(for: [a])
        XCTAssertEqual(fallback[a], FileRecord(rating: 2), "ordinary display reads retain their tolerant fallback")
    }

    func testInvalidURLRejectsWholeWriteBeforeMutation() async throws {
        let tmp = TempDir("metadata-invalid-url")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("metadata.sqlite"),
                                      writeFileAttributes: { false })
        let a = try fixture(tmp, "a.jpg")
        try await store.setRating(1, for: a)
        let invalid = try XCTUnwrap(URL(string: "https://example.invalid/image.jpg"))
        do { _ = try await store.setRatings([a: 5, invalid: 4]); XCTFail("non-file URL must throw") }
        catch MetadataStoreError.urlNotFileScheme {}
        let after = try await store.recordsStrict(for: [a])
        XCTAssertEqual(after[a], FileRecord(rating: 1))
    }

    func testConflictingAliasesRejectWholeWrite() async throws {
        let tmp = TempDir("metadata-conflicting-aliases")
        defer { tmp.cleanup() }
        let store = try MetadataStore(databaseURL: tmp.url.appendingPathComponent("metadata.sqlite"),
                                      writeFileAttributes: { false })
        let a = try fixture(tmp, "a.jpg")
        let aliasDirectory = tmp.url.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: tmp.url)
        let alias = aliasDirectory.appendingPathComponent("a.jpg")
        XCTAssertEqual(CanonicalPath.key(a), CanonicalPath.key(alias))
        try await store.setRating(1, for: a)
        do { _ = try await store.setRatings([a: 2, alias: 5]); XCTFail("conflicting aliases must throw") }
        catch MetadataStoreError.conflictingValuesForCanonicalPath {}
        let after = try await store.recordsStrict(for: [a])
        XCTAssertEqual(after[a], FileRecord(rating: 1))
    }
}

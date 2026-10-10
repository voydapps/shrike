//
//  MetadataStore.swift
//  ShrikeCore
//
//  Ratings, flags, recent folders. SQLite via GRDB.
//
//  Identity: user metadata is keyed by the file's canonical
//  path (`CanonicalPath.key` — case-folded on case-insensitive volumes).
//  Size and mtime are stored for information but are NOT part of the key,
//  so an in-place save keeps the rating. Renames / moves done by Shrike call
//  `rekey(from:to:)` (or `transfer(…, mode: .move)`); copies call
//  `copyMetadata(from:to:)` (or `transfer(…, mode: .copy)`).
//
//  Rating and flag are also mirrored into extended attributes on the file
//  (`app.shrike.rating` = "0"…"5", `app.shrike.flag`
//  = "1"/"0") so files moved in Finder keep them: when the DB has no row
//  for a path, the xattrs are read instead. Writing xattrs is gated by
//  `Prefs.metadataWriteFileAttributes` (default on).
//
//  Tags are Finder tags on the file (FinderTags in ShrikeIO).
//  The old `file_tags` table is dropped by migration v3; `tags(for:)` now
//  reads the file's Finder tags.
//
//  Persistence: `openWithFallback` never silently swaps in a
//  temp DB — the returned store says `isPersistent == false` and carries
//  `openError`, so the UI can warn that ratings won't survive a relaunch.
//

import Foundation
import GRDB

// MARK: - Errors

public enum MetadataStoreError: Error, Sendable {
    case urlNotFileScheme
    case contentHashUnavailable
}

/// Rating and flag of one file, as the grid shows them.
public struct FileRecord: Sendable, Hashable {
    /// 0…5.
    public var rating: Int
    public var flagged: Bool

    public init(rating: Int = 0, flagged: Bool = false) {
        self.rating = rating
        self.flagged = flagged
    }
}

/// Header values used for sorting, cached per file version.
public struct ImageHeaderInfo: Sendable, Hashable {
    /// EXIF DateTimeOriginal (with its offset when present).
    public var dateCaptured: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(dateCaptured: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.dateCaptured = dateCaptured
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Reads the header only (`CGImageSourceCopyPropertiesAtIndex`, no
    /// decode). Nil when the file can't be opened as an image.
    public static func read(_ url: URL) -> ImageHeaderInfo? {
        guard let info = try? PhotoInfo.readSync(url) else { return nil }
        return ImageHeaderInfo(dateCaptured: info.dateTaken, pixelWidth: info.pixelWidth,
                               pixelHeight: info.pixelHeight)
    }
}

/// How `transfer(from:to:mode:)` treats the source's record.
public enum TransferMode: Sendable, Hashable {
    /// Destination gets a duplicate; the source keeps its own.
    case copy
    /// The record moves to the destination.
    case move
}

// MARK: - Actor

public actor MetadataStore {

    private let writer: DatabaseQueue
    private let writeFileAttributes: @Sendable () -> Bool

    /// Rows per `IN (…)` query in batched reads.
    static let batchChunk = 500

    /// False when this store lives somewhere that won't survive a relaunch
    /// (temp folder or memory fallback). The UI should warn once.
    public nonisolated let isPersistent: Bool
    /// Why the preferred database couldn't be opened, if it couldn't.
    public nonisolated let openError: String?

    /// Opens (or creates) the SQLite database at `databaseURL`. Parent
    /// directory is created if missing — the caller typically passes a
    /// path under `~/Library/Application Support/app.shrike/`.
    public init(
        databaseURL: URL,
        isPersistent: Bool = true,
        openError: String? = nil,
        writeFileAttributes: @escaping @Sendable () -> Bool = { Prefs.metadataWriteFileAttributes }
    ) throws {
        let fm = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)

        var config = Configuration()
        config.foreignKeysEnabled = true
        self.writer = try DatabaseQueue(path: databaseURL.path, configuration: config)
        self.isPersistent = isPersistent
        self.openError = openError
        self.writeFileAttributes = writeFileAttributes

        try Self.runMigrations(on: self.writer)
    }

    /// In-memory store: nothing survives the process. Last-resort fallback.
    public init(
        inMemoryWithError openError: String?,
        writeFileAttributes: @escaping @Sendable () -> Bool = { Prefs.metadataWriteFileAttributes }
    ) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.writer = try DatabaseQueue(configuration: config)
        self.isPersistent = false
        self.openError = openError
        self.writeFileAttributes = writeFileAttributes
        try Self.runMigrations(on: self.writer)
    }

    /// Open `primary`; if that fails, open `fallback` (then memory) and
    /// mark the store non-persistent with the reason. Never crashes.
    public static func openWithFallback(primary: URL, fallback: URL?) -> MetadataStore {
        do {
            return try MetadataStore(databaseURL: primary)
        } catch {
            let reason = "\(error.localizedDescription) (\(primary.path))"
            ShrikeSignposts.decode.event("metadataInitFailed", "\(reason)")
            if let fallback,
               let store = try? MetadataStore(databaseURL: fallback, isPersistent: false,
                                              openError: reason) {
                return store
            }
            // In-memory DatabaseQueue creation only fails on OOM.
            return try! MetadataStore(inMemoryWithError: reason)
        }
    }

    // MARK: - Batched reads (grid)

    /// Rating and flag for every file URL in `urls`, in one DB round trip
    /// per 500 URLs. URLs without a row fall back to the file's xattrs,
    /// then to `FileRecord()` (0 stars, not flagged). Non-file URLs are
    /// left out. Never throws: a DB error reads as "no rows".
    public func records(for urls: [URL]) async -> [URL: FileRecord] {
        let fileURLs = urls.filter(\.isFileURL)
        var byKey: [String: [URL]] = [:]
        byKey.reserveCapacity(fileURLs.count)
        for (url, key) in zip(fileURLs, CanonicalPath.keys(fileURLs)) {
            byKey[key, default: []].append(url)
        }
        let keys = Array(byKey.keys)
        let found: [String: FileRecord] = (try? await readOnlyAccess { db in
            var out: [String: FileRecord] = [:]
            out.reserveCapacity(keys.count)
            var start = 0
            while start < keys.count {
                let chunk = Array(keys[start..<min(start + Self.batchChunk, keys.count)])
                start += Self.batchChunk
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchCursor(
                    db, sql: "SELECT path, rating, flagged FROM file_metadata WHERE path IN (\(marks))",
                    arguments: StatementArguments(chunk))
                while let row = try rows.next() {
                    out[row["path"]] = FileRecord(rating: row["rating"],
                                                  flagged: (row["flagged"] as Int) != 0)
                }
            }
            return out
        }) ?? [:]

        var result: [URL: FileRecord] = [:]
        result.reserveCapacity(urls.count)
        for (key, group) in byKey {
            for url in group {
                if let rec = found[key] {
                    result[url] = rec
                } else {
                    result[url] = FileRecord(rating: FileAttributes.rating(at: url) ?? 0,
                                             flagged: FileAttributes.flag(at: url) ?? false)
                }
            }
        }
        return result
    }

    // MARK: - Header cache (sorting)

    /// Cached header values for `files` (URL → its current modification
    /// date). A row counts only when it was read at that same date, so an
    /// edited file is read again. One DB round trip per 500 files; missing
    /// or stale entries are left out. Never throws.
    public func cachedHeaders(for files: [URL: Date]) async -> [URL: ImageHeaderInfo] {
        var byKey: [String: [(URL, Double)]] = [:]
        let urls = files.keys.filter(\.isFileURL)
        for (url, key) in zip(urls, CanonicalPath.keys(urls)) {
            byKey[key, default: []].append((url, files[url]!.timeIntervalSince1970))
        }
        let keys = Array(byKey.keys)
        let rows: [String: (Double, ImageHeaderInfo)] = (try? await readOnlyAccess { db in
            var out: [String: (Double, ImageHeaderInfo)] = [:]
            var start = 0
            while start < keys.count {
                let chunk = Array(keys[start..<min(start + Self.batchChunk, keys.count)])
                start += Self.batchChunk
                let cursor = try Row.fetchCursor(
                    db, sql: """
                        SELECT path, mtime, captured, width, height FROM header_cache
                        WHERE path IN (\(databaseQuestionMarks(count: chunk.count)))
                        """,
                    arguments: StatementArguments(chunk))
                while let row = try cursor.next() {
                    let captured: Double? = row["captured"]
                    out[row["path"]] = (row["mtime"], ImageHeaderInfo(
                        dateCaptured: captured.map { Date(timeIntervalSince1970: $0) },
                        pixelWidth: row["width"], pixelHeight: row["height"]))
                }
            }
            return out
        }) ?? [:]
        var result: [URL: ImageHeaderInfo] = [:]
        for (key, entries) in byKey {
            guard let (mtime, info) = rows[key] else { continue }
            for (url, wanted) in entries where abs(wanted - mtime) < 0.000_001 {
                result[url] = info
            }
        }
        return result
    }

    /// Stores header values read at each file's modification date (one
    /// transaction). Never throws: it is a cache.
    public func storeHeaders(_ headers: [URL: (modified: Date, info: ImageHeaderInfo)]) async {
        let urls = headers.keys.filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        let rows = zip(urls, CanonicalPath.keys(urls)).map { url, key in
            (key, headers[url]!.modified.timeIntervalSince1970, headers[url]!.info)
        }
        try? await writer.write { db in
            for (key, mtime, info) in rows {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO header_cache (path, mtime, captured, width, height)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [key, mtime, info.dateCaptured?.timeIntervalSince1970,
                                info.pixelWidth, info.pixelHeight])
            }
        }
    }

    // MARK: - Ratings

    public func rating(for url: URL) async throws -> Int {
        let key = try Self.key(for: url)
        let stored = try await readOnlyAccess { db in
            try Int.fetchOne(db, sql: "SELECT rating FROM file_metadata WHERE path = ?",
                             arguments: [key])
        }
        if let stored { return stored }
        return FileAttributes.rating(at: url) ?? 0
    }

    public func setRating(_ rating: Int, for url: URL) async throws {
        try await setRating(rating, for: [url])
    }

    /// Set the same rating (clamped to 0…5) on every URL in one transaction.
    public func setRating(_ stars: Int, for urls: [URL]) async throws {
        let clamped = max(0, min(5, stars))
        let rows = try urls.map { try metadataRow(for: $0, rating: clamped) }
        guard !rows.isEmpty else { return }
        try await writer.write { db in
            for row in rows { try Self.upsertRow(row, in: db) }
        }
        if writeFileAttributes() {
            for url in urls { FileAttributes.setRating(clamped, at: url) }
        }
    }

    // MARK: - Flag

    public func isFlagged(_ url: URL) async throws -> Bool {
        let key = try Self.key(for: url)
        let stored = try await readOnlyAccess { db in
            try Int.fetchOne(db, sql: "SELECT flagged FROM file_metadata WHERE path = ?",
                             arguments: [key])
        }
        if let stored { return stored != 0 }
        return FileAttributes.flag(at: url) ?? false
    }

    public func setFlag(_ flag: Bool, for url: URL) async throws {
        try await setFlag(flag, for: [url])
    }

    /// Set the same flag on every URL in one transaction.
    public func setFlag(_ flagged: Bool, for urls: [URL]) async throws {
        let rows = try urls.map { try metadataRow(for: $0, flagged: flagged) }
        guard !rows.isEmpty else { return }
        try await writer.write { db in
            for row in rows { try Self.upsertRow(row, in: db) }
        }
        if writeFileAttributes() {
            for url in urls { FileAttributes.setFlag(flagged, at: url) }
        }
    }

    // MARK: - Tags (Finder)

    /// The file's Finder tag names, sorted. Kept for existing callers;
    /// new code should use `FinderTags` (ShrikeIO), which also has colours.
    public func tags(for url: URL) async throws -> [String] {
        guard url.isFileURL else { throw MetadataStoreError.urlNotFileScheme }
        let values = try? url.resourceValues(forKeys: [.tagNamesKey])
        return (values?.tagNames ?? []).sorted()
    }

    // MARK: - Identity changes

    /// Copy or move `source`'s record to `destination` (FileOps).
    /// `.move` = `rekey`, `.copy` = `copyMetadata`.
    public func transfer(from source: URL, to destination: URL, mode: TransferMode) async throws {
        switch mode {
        case .move: try await rekey(from: source, to: destination)
        case .copy: try await copyMetadata(from: source, to: destination)
        }
    }

    /// The file at `old` now lives at `new` (rename, move, trash, untrash,
    /// in-place overwrite when `old == new`). Moves the rating and flag;
    /// any stale row already at `new` is replaced. Re-stamps the xattrs on
    /// `new` so they match the DB.
    public func rekey(from old: URL, to new: URL) async throws {
        let oldKey = try Self.key(for: old)
        let newKey = try Self.key(for: new)
        let (size, mtime) = Self.sizeAndMTime(new)
        let now = Date().timeIntervalSince1970
        let values: (Int, Bool)? = try await writer.write { db in
            if oldKey != newKey {
                guard try Bool.fetchOne(db, sql: "SELECT 1 FROM file_metadata WHERE path = ?",
                                        arguments: [oldKey]) ?? false
                else { return nil }
                try db.execute(sql: "DELETE FROM file_metadata WHERE path = ?", arguments: [newKey])
                try db.execute(sql: "UPDATE file_metadata SET path = ? WHERE path = ?",
                               arguments: [newKey, oldKey])
            }
            try db.execute(
                sql: "UPDATE file_metadata SET size = ?, mtime = ?, updated_at = ? WHERE path = ?",
                arguments: [size, mtime, now, newKey])
            guard let row = try Row.fetchOne(
                db, sql: "SELECT rating, flagged FROM file_metadata WHERE path = ?",
                arguments: [newKey]) else { return nil }
            return (row["rating"] as Int, (row["flagged"] as Int) != 0)
        }
        if let values, writeFileAttributes() {
            FileAttributes.setRating(values.0, at: new)
            FileAttributes.setFlag(values.1, at: new)
        }
    }

    /// `destination` is a copy of `source` (Copy, Save As): give it the
    /// same rating and flag. `source` keeps its own.
    public func copyMetadata(from source: URL, to destination: URL) async throws {
        let srcKey = try Self.key(for: source)
        let dstKey = try Self.key(for: destination)
        guard srcKey != dstKey else { return }
        let (size, mtime) = Self.sizeAndMTime(destination)
        let now = Date().timeIntervalSince1970
        let values: (Int, Bool)? = try await writer.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT rating, flagged FROM file_metadata WHERE path = ?",
                arguments: [srcKey]) else { return nil }
            let rating: Int = row["rating"]
            let flagged: Int = row["flagged"]
            try db.execute(sql: "DELETE FROM file_metadata WHERE path = ?", arguments: [dstKey])
            try db.execute(
                sql: """
                    INSERT INTO file_metadata (path, size, mtime, rating, flagged, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [dstKey, size, mtime, rating, flagged, now])
            return (rating, flagged != 0)
        }
        if let values, writeFileAttributes() {
            FileAttributes.setRating(values.0, at: destination)
            FileAttributes.setFlag(values.1, at: destination)
        }
    }

    // MARK: - Recent folders

    public func recentFolders(limit: Int) async throws -> [URL] {
        try await readOnlyAccess { db in
            let paths = try String.fetchAll(
                db,
                sql: "SELECT path FROM recent_folders ORDER BY last_opened DESC LIMIT ?",
                arguments: [limit]
            )
            return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
    }

    public func addRecentFolder(_ url: URL) async throws {
        let path = url.standardizedFileURL.path
        let now = Date().timeIntervalSince1970
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO recent_folders (path, last_opened) VALUES (?, ?) " +
                     "ON CONFLICT(path) DO UPDATE SET last_opened = excluded.last_opened",
                arguments: [path, now]
            )
        }
    }

    // MARK: - Private helpers

    static func key(for url: URL) throws -> String {
        guard url.isFileURL else { throw MetadataStoreError.urlNotFileScheme }
        return CanonicalPath.key(url)
    }

    private static func sizeAndMTime(_ url: URL) -> (Int64, Double) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (Int64(values?.fileSize ?? 0),
                values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
    }

    private struct MetaRow: Sendable {
        let path: String
        /// The file as the caller spelled it (for the xattr seed).
        let url: URL
        let size: Int64
        let mtime: Double
        let rating: Int?
        let flagged: Bool?
    }

    private func metadataRow(
        for url: URL, rating: Int? = nil, flagged: Bool? = nil
    ) throws -> MetaRow {
        let key = try Self.key(for: url)
        let (size, mtime) = Self.sizeAndMTime(url)
        return MetaRow(path: key, url: url, size: size, mtime: mtime,
                       rating: rating, flagged: flagged)
    }

    private static func upsertRow(_ row: MetaRow, in db: Database) throws {
        let now = Date().timeIntervalSince1970
        let exists = try Bool.fetchOne(db, sql: "SELECT 1 FROM file_metadata WHERE path = ?",
                                       arguments: [row.path]) ?? false
        if !exists {
            // Seed from xattrs (file moved in from Finder / another Mac).
            let seedRating = row.rating ?? FileAttributes.rating(at: row.url) ?? 0
            let seedFlag = row.flagged ?? FileAttributes.flag(at: row.url) ?? false
            try db.execute(
                sql: """
                    INSERT INTO file_metadata (path, size, mtime, rating, flagged, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [row.path, row.size, row.mtime, seedRating, seedFlag ? 1 : 0, now])
            return
        }
        var sets = ["size = ?", "mtime = ?", "updated_at = ?"]
        var args: [any DatabaseValueConvertible] = [row.size, row.mtime, now]
        if let r = row.rating { sets.append("rating = ?"); args.append(r) }
        if let f = row.flagged { sets.append("flagged = ?"); args.append(f ? 1 : 0) }
        args.append(row.path)
        try db.execute(
            sql: "UPDATE file_metadata SET \(sets.joined(separator: ", ")) WHERE path = ?",
            arguments: StatementArguments(args))
    }

    // MARK: - Migrations

    private static func runMigrations(on writer: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE file_metadata (
                    content_hash TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    mtime REAL NOT NULL,
                    rating INTEGER NOT NULL DEFAULT 0,
                    flagged INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE file_tags (
                    content_hash TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (content_hash, tag),
                    FOREIGN KEY (content_hash) REFERENCES file_metadata(content_hash) ON DELETE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_metadata_rating ON file_metadata(rating)")
            try db.execute(sql: "CREATE INDEX idx_metadata_flagged ON file_metadata(flagged)")
            try db.execute(sql: """
                CREATE TABLE recent_folders (
                    path TEXT PRIMARY KEY,
                    last_opened REAL NOT NULL
                )
            """)
        }
        // v2: key user metadata by canonical path, not
        // SHA256(path ‖ mtime ‖ size). Several v1 rows can collapse onto
        // one path (the file was re-saved); the newest non-zero rating /
        // flag wins and tags are unioned.
        migrator.registerMigration("v2-path-key") { db in
            // Read everything first, drop the old tables (child first),
            // then create the new ones under their final names. No
            // ALTER TABLE RENAME: GRDB migrations run with legacy rename
            // semantics, which would leave foreign keys pointing at the
            // temporary name.
            let rows = try Row.fetchAll(db, sql: """
                SELECT content_hash, path, size, mtime, rating, flagged, updated_at
                FROM file_metadata ORDER BY updated_at ASC
                """)
            let tagRows = try Row.fetchAll(db, sql: "SELECT content_hash, tag FROM file_tags")
            try db.execute(sql: "DROP TABLE file_tags")
            try db.execute(sql: "DROP TABLE file_metadata")
            try db.execute(sql: """
                CREATE TABLE file_metadata (
                    path TEXT PRIMARY KEY NOT NULL,
                    size INTEGER NOT NULL DEFAULT 0,
                    mtime REAL NOT NULL DEFAULT 0,
                    rating INTEGER NOT NULL DEFAULT 0,
                    flagged INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL
                )
            """)
            try db.execute(sql: """
                CREATE TABLE file_tags (
                    path TEXT NOT NULL,
                    tag TEXT NOT NULL,
                    PRIMARY KEY (path, tag),
                    FOREIGN KEY (path) REFERENCES file_metadata(path)
                        ON DELETE CASCADE ON UPDATE CASCADE
                )
            """)
            try db.execute(sql: "CREATE INDEX idx_metadata_rating ON file_metadata(rating)")
            try db.execute(sql: "CREATE INDEX idx_metadata_flagged ON file_metadata(flagged)")

            var hashToPath: [String: String] = [:]
            for r in rows {
                let hash: String = r["content_hash"]
                let rawPath: String = r["path"]
                let path = CanonicalPath.of(URL(fileURLWithPath: rawPath))
                hashToPath[hash] = path
                try Self.mergeRow(path: path, from: r, in: db)
            }
            for t in tagRows {
                let hash: String = t["content_hash"]
                guard let path = hashToPath[hash] else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO file_tags (path, tag) VALUES (?, ?)",
                               arguments: [path, t["tag"] as String])
            }
        }
        // v3: tags are Finder tags on the file. No app code
        // ever wrote `file_tags` (only tests), so nothing is carried over.
        migrator.registerMigration("v3-drop-file-tags") { db in
            try db.execute(sql: "DROP TABLE IF EXISTS file_tags")
        }
        // v4: keys on case-insensitive volumes become case-folded
        // (`CanonicalPath.key`). Rows that now collide merge: newest
        // non-zero rating / flag wins.
        migrator.registerMigration("v4-case-insensitive-keys") { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT path, size, mtime, rating, flagged, updated_at
                FROM file_metadata ORDER BY updated_at ASC
                """)
            for r in rows {
                let old: String = r["path"]
                let new = CanonicalPath.key(URL(fileURLWithPath: old))
                guard new != old else { continue }
                try db.execute(sql: "DELETE FROM file_metadata WHERE path = ?", arguments: [old])
                try Self.mergeRow(path: new, from: r, in: db)
            }
        }
        // v5: header values for sorting, keyed by
        // canonical path; a row is valid only for the mtime it was read at.
        migrator.registerMigration("v5-header-cache") { db in
            try db.execute(sql: """
                CREATE TABLE header_cache (
                    path TEXT PRIMARY KEY NOT NULL,
                    mtime REAL NOT NULL,
                    captured REAL,
                    width INTEGER,
                    height INTEGER
                )
            """)
        }
        try migrator.migrate(writer)
    }

    /// Insert `r` under `path`; on conflict later rows overwrite, except a
    /// zero never overwrites a non-zero rating / flag. Callers feed rows
    /// oldest first.
    private static func mergeRow(path: String, from r: Row, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO file_metadata (path, size, mtime, rating, flagged, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
              size = excluded.size,
              mtime = excluded.mtime,
              updated_at = excluded.updated_at,
              rating = CASE WHEN excluded.rating != 0 THEN excluded.rating ELSE rating END,
              flagged = CASE WHEN excluded.flagged != 0 THEN excluded.flagged ELSE flagged END
            """,
            arguments: [path, r["size"] as Int64, r["mtime"] as Double,
                        r["rating"] as Int, r["flagged"] as Int, r["updated_at"] as Double])
    }
}

// MARK: - Read access

extension MetadataStore {
    /// Runs `body` read-only inside a deferred transaction on the store's
    /// queue: what GRDB's async `read` does, minus its crash.
    ///
    /// Why not `writer.read { }` (async): in GRDB 6.29.3 (unchanged in
    /// 7.11.1) `DatabaseQueue.asyncRead` calls `endReadOnly()` from a
    /// `defer` even when `beginReadOnly()` threw. `PRAGMA query_only = 1`
    /// throws SQLITE_IOERR once the database file or its folder is removed
    /// while the store is open (a test's tearDown deleting its temp folder;
    /// a user deleting Application Support). The read-only depth then drops
    /// to -1: debug builds trap with "unbalanced endReadOnly()"
    /// (GRDB/Core/Database.swift:770), release builds silently drop the
    /// read-only guard for the rest of the connection's life.
    /// `Database.readOnly` balances itself, so here the error is thrown
    /// to the caller like any other read error.
    ///
    /// Like GRDB 6's async calls, this does not observe Task cancellation:
    /// a started read always finishes.
    ///
    /// Lives in an extension on purpose: extension methods are called
    /// directly, so adding this did not shift the actor's method table.
    /// (Inside the actor body it moved every later method one slot down,
    /// and dependents that an incremental build did not recompile called
    /// `rating(for:)` when they meant `setRating(_:for:)`.)
    func readOnlyAccess<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            writer.asyncUnsafeRead { dbResult in
                continuation.resume(with: dbResult.flatMap { db in
                    Result {
                        try db.readOnly {
                            var value: T?
                            try db.inTransaction(.deferred) {
                                value = try body(db)
                                return .commit
                            }
                            guard let value else {
                                throw DatabaseError(resultCode: .SQLITE_ERROR,
                                                    message: "read finished without a value")
                            }
                            return value
                        }
                    }
                })
            }
        }
    }
}

// MARK: - Extended attributes

/// Rating / flag mirrored on the file itself. Failures (read-only volume,
/// FAT32 without xattr support) are ignored — the DB stays the source of
/// truth for files Shrike knows.
public enum FileAttributes {
    public static let ratingName = "app.shrike.rating"
    public static let flagName = "app.shrike.flag"

    public static func rating(at url: URL) -> Int? {
        guard let s = read(ratingName, at: url), let v = Int(s), (0...5).contains(v) else { return nil }
        return v
    }

    public static func flag(at url: URL) -> Bool? {
        guard let s = read(flagName, at: url) else { return nil }
        return s == "1"
    }

    public static func setRating(_ rating: Int, at url: URL) {
        write(String(max(0, min(5, rating))), name: ratingName, at: url)
    }

    public static func setFlag(_ flag: Bool, at url: URL) {
        write(flag ? "1" : "0", name: flagName, at: url)
    }

    static func read(_ name: String, at url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size > 0, size < 64 else { return nil }
            var buf = [UInt8](repeating: 0, count: size)
            let got = getxattr(path, name, &buf, size, 0, 0)
            guard got == size else { return nil }
            return String(decoding: buf, as: UTF8.self)
        }
    }

    @discardableResult
    static func write(_ value: String, name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let bytes = Array(value.utf8)
            return setxattr(path, name, bytes, bytes.count, 0, 0) == 0
        }
    }
}

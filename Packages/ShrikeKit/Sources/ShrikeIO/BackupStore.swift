//
//  BackupStore.swift
//  ShrikeIO
//
//  Copy-before-overwrite safety net. Every
//  time Shrike is about to overwrite or rewrite a user's file (Save,
//  lossless rotate, batch, revert), the current bytes are copied here
//  first. If the copy fails — or does not verify — the caller must not
//  overwrite.
//
//  Layout:
//      <root>/<yyyy-MM-dd>/<uuid>/<original filename>
//      <root>/<yyyy-MM-dd>/<uuid>/.shrike-backup.json     (BackupRecord)
//
//  Default root: ~/Library/Application Support/app.shrike/Backups
//  (the folder that also holds metadata.sqlite). Tests must inject their
//  own root.
//
//  `FileManager.copyItem` clones on APFS, so a backup is near-instant and
//  takes no extra space until one side changes; every copy is verified
//  (size + SHA-256 of the first and last MiB) before `backup` returns.
//
//  History ("chain") is per file. The oldest record of a file is its
//  *original* — the bytes before Shrike first changed it. Retention
//  (`shrike.backups.retentionDays`) never deletes the original while the
//  file still exists; the 10 GB cap (`shrike.backups.maxBytes`) reaps the
//  oldest non-original records first and never touches a record younger
//  than 24 h.
//

import CryptoKit
import Foundation
import os
import ShrikeCore

/// Why a backup was taken.
public enum BackupReason: String, Codable, Sendable, CaseIterable {
    case save
    case rotate
    case batch
    /// Safety copy of the current file taken just before `restore`.
    case restore
    /// Pre-revert bytes, taken by `revertToOriginal`.
    case revert
    /// The version an Undo Save removed, so Redo can put it back.
    case undo
    /// A file Copy / Move "Replace" is about to trash.
    case replace
}

public struct BackupRecord: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Canonical path of the file that was backed up (see `CanonicalPath`).
    public let originalPath: String
    /// Absolute path of the copy inside the backup root.
    public let backupPath: String
    public let createdAt: Date
    public let reason: BackupReason
    /// Byte size of the copy. `nil` for records written before verification landed.
    public let byteSize: Int64?
    /// Hex SHA-256 over (size ‖ first MiB ‖ last MiB). `nil` for old records.
    public let checksum: String?
    /// Position in the file's chain when taken (0 = original). Breaks
    /// ties between records with the same date. `nil` for old records.
    public let sequence: Int?
    /// What the file looked like right after Shrike wrote it (size and modification time).
    /// Backup chains are keyed by path, so a different photo that later gets the same path
    /// (a camera card after a format) must not inherit the chain: it matches only while the
    /// file still looks like this. `nil` for old records and for records of a file that
    /// Shrike did not write afterwards (Replace); those always match.
    public let writtenSize: Int64?
    public let writtenModified: Int64?   // nanoseconds since 1970
    /// Set when the chain was put aside because the file at its path is a different photo. A chain
    /// put aside is deleted only when retention has run out counted from this moment, never because
    /// "its path does not exist" (that would delete the only copy of an original at once).
    public let detachedAt: Date?
    /// The real path whose chain was put aside (see `detachedAt`). While a file sits there the
    /// original is kept; only when none does, the retention clock from `detachedAt` applies.
    public let detachedFrom: String?
    /// Content hash (`BackupStore.fingerprint`: size, first and last MiB) of the file Shrike wrote.
    /// Used only when the size matches and the date does not (a sync tool, a FAT volume, another
    /// app touched the file): same hash = same file. `nil` for records without one.
    public let writtenChecksum: String?

    public var originalURL: URL { URL(fileURLWithPath: originalPath) }
    public var backupURL: URL { URL(fileURLWithPath: backupPath) }

    public init(id: UUID, originalPath: String, backupPath: String, createdAt: Date,
                reason: BackupReason, byteSize: Int64? = nil, checksum: String? = nil,
                sequence: Int? = nil, writtenSize: Int64? = nil, writtenModified: Int64? = nil,
                detachedAt: Date? = nil, writtenChecksum: String? = nil, detachedFrom: String? = nil) {
        self.detachedFrom = detachedFrom
        self.writtenChecksum = writtenChecksum
        self.detachedAt = detachedAt
        self.writtenSize = writtenSize
        self.writtenModified = writtenModified
        self.id = id
        self.originalPath = originalPath
        self.backupPath = backupPath
        self.createdAt = createdAt
        self.reason = reason
        self.byteSize = byteSize
        self.checksum = checksum
        self.sequence = sequence
    }

    func with(originalPath: String? = nil, backupPath: String? = nil) -> BackupRecord {
        BackupRecord(id: id, originalPath: originalPath ?? self.originalPath,
                     backupPath: backupPath ?? self.backupPath, createdAt: createdAt,
                     reason: reason, byteSize: byteSize, checksum: checksum,
                     sequence: sequence, writtenSize: writtenSize, writtenModified: writtenModified,
                     detachedAt: detachedAt, writtenChecksum: writtenChecksum, detachedFrom: detachedFrom)
    }

    /// The same record with another real path to guard (a put-aside chain follows its photo).
    func withDetachedFrom(_ path: String) -> BackupRecord {
        BackupRecord(id: id, originalPath: originalPath, backupPath: backupPath, createdAt: createdAt,
                     reason: reason, byteSize: byteSize, checksum: checksum, sequence: sequence,
                     writtenSize: writtenSize, writtenModified: writtenModified,
                     detachedAt: detachedAt, writtenChecksum: writtenChecksum, detachedFrom: path)
    }

    /// The record after its chain moved to `path`. `detached` is set EXPLICITLY: an ordinary move
    /// (rename, Undo of a Replace) passes nil and so clears any put-aside mark.
    func moved(to path: String, detached: (at: Date, from: String?)?) -> BackupRecord {
        BackupRecord(id: id, originalPath: path, backupPath: backupPath, createdAt: createdAt,
                     reason: reason, byteSize: byteSize, checksum: checksum, sequence: sequence,
                     writtenSize: writtenSize, writtenModified: writtenModified,
                     detachedAt: detached?.at, writtenChecksum: writtenChecksum, detachedFrom: detached?.from)
    }

    func with(written stamp: (size: Int64, modified: Int64, checksum: String?)) -> BackupRecord {
        BackupRecord(id: id, originalPath: originalPath, backupPath: backupPath, createdAt: createdAt,
                     reason: reason, byteSize: byteSize, checksum: checksum, sequence: sequence,
                     writtenSize: stamp.size, writtenModified: stamp.modified, detachedAt: detachedAt,
                     writtenChecksum: stamp.checksum, detachedFrom: detachedFrom)
    }

    /// Chain order: oldest first; same date → lower sequence first.
    static func chainOrder(_ a: BackupRecord, _ b: BackupRecord) -> Bool {
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return (a.sequence ?? 0) < (b.sequence ?? 0)
    }
}

/// Pencil-badge state of a file.
public enum BackupState: String, Sendable, Hashable {
    /// Shrike never changed this file.
    case none
    /// Shrike changed it; the original is kept.
    case edited
    /// The file was put back to its original (newest record is a revert).
    case reverted
}

public struct BackupAvailability: Sendable {
    public let canRevert: Bool
    public let originalDate: Date?
    public let latestDate: Date?
    public let originalRecord: BackupRecord?
}

/// What one `reap` pass did.
public struct ReapReport: Sendable, Equatable {
    /// Backup folders deleted.
    public var removed: Int
    /// Bytes those folders held.
    public var freedBytes: Int64
    /// Store size after the pass.
    public var totalBytes: Int64
    /// Still over `maxBytes` after the pass (only young or original
    /// records are left).
    public var overCap: Bool
}

/// How full the backup store is. Cheap: it reads the in-memory index.
public struct BackupUsage: Sendable, Equatable {
    public let usedBytes: Int64
    /// The size cap in bytes; 0 = no cap.
    public let capBytes: Int64
    public var isOverCap: Bool { capBytes > 0 && usedBytes > capBytes }
}

public enum BackupError: Error, Sendable, Equatable {
    case sourceMissing
    case copyFailed(underlying: String)
    /// The backup volume is full (the backup-failed alert names the volume).
    case insufficientSpace(volumeName: String)
    case recordWriteFailed(underlying: String)
    case backupMissing
    case restoreFailed(underlying: String)
}

public actor BackupStore {

    /// `~/Library/Application Support` (a per-process temp folder under
    /// XCTest, so `.shared` can never back up into the user's Library).
    private static let applicationSupport: URL = ShrikeDataPaths.applicationSupportBase

    /// `~/Library/Application Support/app.shrike/Backups`.
    public static let defaultRoot: URL = applicationSupport
        .appendingPathComponent("app.shrike", isDirectory: true)
        .appendingPathComponent("Backups", isDirectory: true)

    /// Process-wide store at `defaultRoot`. App code uses this; tests
    /// build their own with a temp root.
    public static let shared = BackupStore()

    static let recordFileName = ".shrike-backup.json"
    /// Bytes hashed at each end of a file when verifying a copy.
    static let verifyWindow = 1 << 20
    /// Records younger than this survive the size cap.
    static let capGrace: TimeInterval = 86_400

    /// Extended attributes that describe the *file*, not its bytes. They
    /// are carried over when a restore swaps in older bytes, so the
    /// rating, flag and Finder tags stay as the user last set them.
    static let carriedAttributes = [
        FileAttributes.ratingName,
        FileAttributes.flagName,
        "com.apple.metadata:_kMDItemUserTags",
    ]

    typealias Copier = @Sendable (_ from: URL, _ to: URL) throws -> Void

    public nonisolated let root: URL
    private let now: @Sendable () -> Date
    private let retentionDays: @Sendable () -> Int
    private let maxBytes: @Sendable () -> Int64
    private let copier: Copier

    private var reapedThisSession = false
    /// Records by chain key (`CanonicalPath`), oldest first. Loaded lazily.
    private var index: [String: [BackupRecord]]?
    /// Real-path key -> keys of the put-aside chains that guard that path (`detachedFrom`). Built once
    /// with the index, so a Batch move of thousands of photos does not scan the store per file.
    private var detachedBy: [String: Set<String>]?
    /// Record id -> key of the chain that holds it. Built with the index and kept in step by insert,
    /// delete and every chain move, so a restore finds a record's chain without scanning the store
    /// (a Batch Undo of thousands of restores stays linear).
    private var recordKeys: [UUID: String]?
    /// Backup folders whose record can't be read, with the folder's day.
    private var orphans: [(entry: URL, day: Date?)] = []

    public init(
        root: URL = BackupStore.defaultRoot,
        retentionDays: @escaping @Sendable () -> Int = { Prefs.backupRetentionDays },
        maxBytes: @escaping @Sendable () -> Int64 = { Prefs.backupMaxBytes },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(root: root, retentionDays: retentionDays, maxBytes: maxBytes,
                  now: now,
                  copier: { try FileManager.default.copyItem(at: $0, to: $1) })
    }

    /// Test seam: `copier` replaces the file copy (to simulate a bad copy).
    init(
        root: URL,
        retentionDays: @escaping @Sendable () -> Int,
        maxBytes: @escaping @Sendable () -> Int64,
        now: @escaping @Sendable () -> Date,
        copier: @escaping Copier
    ) {
        self.root = root
        self.retentionDays = retentionDays
        self.maxBytes = maxBytes
        self.now = now
        self.copier = copier
    }

    // MARK: - Backup

    /// Copy `url` into the store and verify the copy. Throws if the file
    /// is missing or the copy / record can't be written or verified — the
    /// caller must then NOT go on to overwrite the original.
    @discardableResult
    public func backup(_ url: URL, reason: BackupReason) throws -> BackupRecord {
        prepare()
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw BackupError.sourceMissing }

        // First backup of a session also reaps (retention + cap). The UI
        // runs `reap` on its own schedule too; this is the safety net.
        if !reapedThisSession {
            reapedThisSession = true
            _ = reap()
        }

        // A chain that no longer matches the file belongs to another photo: put it aside (it stays
        // in the store until the normal clean-up) so this file starts its own chain.
        if !chainMatches(chain(for: url), file: url) {
            // `backup()` has no channel for a count: the failure is logged.
            if detach(chainAt: url).failed > 0 { Self.log.error("backup: a stale chain could not be fully saved") }
        }

        let id = UUID()
        let date = now()
        let dir = root
            .appendingPathComponent(Self.dayFolderName(for: date), isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        let copyURL = dir.appendingPathComponent(url.lastPathComponent)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try copier(url, copyURL)
        } catch {
            try? fm.removeItem(at: dir)
            if Self.isOutOfSpace(error) {
                throw BackupError.insufficientSpace(volumeName: Self.volumeName(of: root))
            }
            throw BackupError.copyFailed(underlying: "\(error)")
        }

        // Verify before anyone overwrites the original.
        let fp: (size: Int64, sum: String)
        do {
            let src = try Self.fingerprint(url)
            let dst = try Self.fingerprint(copyURL)
            guard src == dst else {
                throw BackupError.copyFailed(
                    underlying: "verification failed (\(src.size) → \(dst.size) bytes)")
            }
            fp = src
        } catch let e as BackupError {
            try? fm.removeItem(at: dir)
            throw e
        } catch {
            try? fm.removeItem(at: dir)
            throw BackupError.copyFailed(underlying: "verification failed: \(error)")
        }

        let record = BackupRecord(
            id: id,
            originalPath: CanonicalPath.of(url),
            backupPath: copyURL.path,
            createdAt: date,
            reason: reason,
            byteSize: fp.size,
            checksum: fp.sum,
            sequence: chain(for: url).last.map { ($0.sequence ?? 0) + 1 } ?? 0
        )
        do {
            try Self.writeRecord(record, in: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw BackupError.recordWriteFailed(underlying: "\(error)")
        }
        insert(record)
        return record
    }

    // MARK: - Written fingerprint

    /// Size and modification time of `url` now (lstat). Nil when it can't be read.
    static func writeStamp(of url: URL) -> (size: Int64, modified: Int64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (Int64(st.st_size), Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }

    /// Call right after Shrike has written `url` (save, rotate, restore). The newest record of
    /// its chain remembers how the file looks now. From then on the chain applies only while the
    /// file still looks like that. Returns false when the record could not be updated on disk
    /// (the in-memory chain is updated anyway).
    @discardableResult
    public func noteWritten(_ url: URL) -> Bool {
        prepare()
        let key = Self.key(for: url)
        checkedMismatch[key] = nil     // the file was just written: forget any "already hashed, different" note
        guard let recs = index?[key], !recs.isEmpty, let basic = Self.writeStamp(of: url) else { return true }
        // Hash what Shrike just wrote (3 MiB at most), so a later date change can be told from a different file.
        let stamp = (size: basic.size, modified: basic.modified, checksum: try? Self.contentHashV2(url))
        // The fingerprint belongs to the CHAIN: every record carries it, so deleting any record
        // (retention, cap) can never lose it.
        var ok = true
        // Newest record FIRST: it is the one the match is decided by, so a pass that stops half way
        // (a failed write, a crash) still leaves it right.
        for (i, rec) in recs.enumerated().reversed() {
            let updated = rec.with(written: stamp)
            index?[key]?[i] = updated
            do { try Self.writeRecord(updated, in: updated.backupURL.deletingLastPathComponent()) } catch { ok = false }
        }
        return ok
    }

    /// True while the file at `url` is the one Shrike last wrote (or nothing says otherwise).
    private func chainMatches(_ chain: [BackupRecord], file url: URL) -> Bool {
        // The NEWEST record decides. A newest record without a stamp (a save that began and did not
        // reach `noteWritten`: a crash, a power loss) means "unknown", so it matches.
        guard let stamped = chain.last,
              let size = stamped.writtenSize, let modified = stamped.writtenModified,
              let now = Self.writeStamp(of: url) else { return true }
        // Other size: a different file.
        guard now.size == size else { return false }
        // Exactly the date Shrike saw: the same file, stat only (the grid path stays cheap).
        if now.modified == modified { return true }
        // A chain without a hash (written before hashes) has only the date tolerance (HFS+ 1 s, FAT 2 s).
        guard let sum = stamped.writtenChecksum else { return abs(now.modified - modified) <= Self.dateTolerance }
        // Same size, other date, a hash is stored: confirm by content, whatever the drift.
        let key = Self.key(for: url)
        if let seen = checkedMismatch[key], seen.size == now.size, seen.modified == now.modified { return false }
        guard let current = try? Self.contentHash(url, like: sum) else { return false }
        if current == sum {
            // Same content: remember the new date so this is paid once.
            for (i, rec) in (index?[key] ?? []).enumerated() {
                let updated = rec.with(written: (size: size, modified: now.modified, checksum: rec.writtenChecksum ?? sum))
                index?[key]?[i] = updated
                do { try Self.writeRecord(updated, in: updated.backupURL.deletingLastPathComponent()) } catch {
                    Self.log.error("re-stamp not saved: \(error.localizedDescription, privacy: .public)")
                }
            }
            return true
        }
        checkedMismatch[key] = now     // do not hash again until the file changes
        return false
    }

    /// Date drift that still counts as the same file: 2 s.
    static let dateTolerance: Int64 = 2_000_000_000
    private var checkedMismatch: [String: (size: Int64, modified: Int64)] = [:]

    /// The chain for `url`, or empty when the file on disk is no longer the one Shrike wrote
    /// (another photo took the path, or another app changed it).
    private func activeChain(for url: URL) -> [BackupRecord] {
        let all = chain(for: url)
        return chainMatches(all, file: url) ? all : []
    }

    // MARK: - Restore / revert

    /// Put the backed-up bytes back at the original path (atomic replace).
    /// The current file, if any, is backed up first (reason `.restore`) so
    /// a restore can itself be undone; that safety record is returned.
    /// Rating, flag and Finder tags on the file are kept.
    @discardableResult
    public func restore(_ record: BackupRecord) throws -> BackupRecord? {
        let (safety, notSaved) = try restoreReporting(record)
        // No channel for a count here (UI callers, `LosslessRotator.undo`): the failure is logged.
        if notSaved > 0 { Self.log.error("restore: the restored photo's history could not be fully saved") }
        return safety
    }

    /// `restore`, plus how many photos' backup information could not be saved (0 or 1): a record of the
    /// chain the heal moved back, or its new stamp, could not be written (in memory the chain is right;
    /// after a relaunch it may be filed at the old place). For callers with a `backupsNotSaved` channel.
    package func restoreReporting(_ record: BackupRecord) throws -> (safety: BackupRecord?, notSaved: Int) {
        prepare()
        // Bytes first. The safety copy of whatever file sits at the path joins THAT file's own chain (or
        // starts a new chain as its record 0), so it is never filed in another photo's chain.
        let safety = try restoreBytes(from: record.backupURL, to: record.originalURL, safetyReason: .restore)
        // Then the chain of the restored record becomes the live chain at the path again, if it was put
        // aside; `rekey` puts the chain that holds the safety copy aside under the path guard.
        guard let failed = healParkedChain(of: record) else { return (safety, 0) }
        let stamped = noteWritten(record.originalURL)
        return (safety, failed > 0 || !stamped ? 1 : 0)
    }

    /// The record's chain was put aside (a Replace victim on the clock, `detachForReplace`; or a chain
    /// guarded by this very path, e.g. the safety copy of an export that an Undo replaced, which a Redo
    /// brings back). Its bytes are at the path again, so its chain goes back to the path: Revert gives the
    /// restored photo's OWN original. Called only after the bytes are back, so a failed restore moves no
    /// chain. Not for chains that followed a rename or Trash move (not put aside) and not for chains that
    /// guard another path. Returns nil when no chain moved, else how many records could not be saved.
    private func healParkedChain(of record: BackupRecord) -> Int? {
        let target = Self.key(for: record.originalURL)
        guard let liveKey = recordKeys?[record.id], liveKey != target,
              let first = index?[liveKey]?.first, first.detachedAt != nil else { return nil }
        if let from = first.detachedFrom, Self.key(for: URL(fileURLWithPath: from)) != target { return nil }
        return rekey(from: URL(fileURLWithPath: first.originalPath), to: record.originalURL)
    }

    /// Batch Undo of a Replace victim whose Trash copy is gone and whose name another file now has: the
    /// victim comes back from `record` at the FREE path `url` (a " 2" name next to the old one; never over
    /// a file), and the record's own chain moves there with the guards that follow it. Bytes first: when
    /// this throws (a file is at `url`, the folder is not writable) no chain has moved. Returns how many
    /// photos' backup information could not be saved (0 or 1).
    package func restore(_ record: BackupRecord, toFreePath url: URL) throws -> Int {
        prepare()
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.restoreFailed(underlying: "a file is at \(url.lastPathComponent)")
        }
        _ = try restoreBytes(from: record.backupURL, to: url, safetyReason: .restore)   // no file there: no safety copy
        var failed = 0
        if let key = recordKeys?[record.id], let first = index?[key]?.first {
            failed += rekey(from: URL(fileURLWithPath: first.originalPath), to: url)
        }
        if !noteWritten(url) { failed += 1 }
        return failed > 0 ? 1 : 0
    }

    /// Store the current bytes (reason `.revert`), then put the
    /// file's original — its oldest record — back atomically. Returns the
    /// pre-revert record (Undo restores it).
    @discardableResult
    public func revertToOriginal(_ url: URL) throws -> BackupRecord {
        prepare()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.sourceMissing
        }
        guard let original = activeChain(for: url).first else { throw BackupError.backupMissing }
        guard let safety = try restoreBytes(from: original.backupURL, to: url,
                                            safetyReason: .revert) else {
            throw BackupError.sourceMissing
        }
        return safety
    }

    private func restoreBytes(from backup: URL, to original: URL,
                              safetyReason: BackupReason) throws -> BackupRecord? {
        let activeWork = ActiveWork.shared.begin(kind: .restore, detail: original.lastPathComponent)
        defer { ActiveWork.shared.end(activeWork) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: backup.path) else { throw BackupError.backupMissing }
        var safety: BackupRecord?
        var carried: [String: Data?] = [:]
        if fm.fileExists(atPath: original.path) {
            safety = try self.backup(original, reason: safetyReason)
            for name in Self.carriedAttributes {
                carried[name] = ExtendedAttribute.read(name, at: original)
            }
        }
        TemporaryFileSweeper.sweep(in: original.deletingLastPathComponent())   // old crash leftovers
        let tmp = original.deletingLastPathComponent().appendingPathComponent(
            TemporaryFileSweeper.hiddenTempName(for: original.lastPathComponent, marker: "shrikerestore"))
        do {
            try fm.copyItem(at: backup, to: tmp)
            if fm.fileExists(atPath: original.path) {
                _ = try fm.replaceItemAt(original, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: original)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw BackupError.restoreFailed(underlying: "\(error)")
        }
        for (name, value) in carried {
            if let value {
                ExtendedAttribute.write(value, name: name, at: original)
            } else {
                ExtendedAttribute.remove(name, at: original)
            }
        }
        if safety != nil { noteWritten(original) }   // the newest record is the safety copy
        return safety
    }

    // MARK: - Lookup

    /// Every record for `url`, newest first.
    public func records(for url: URL) -> [BackupRecord] {
        prepare()
        return chain(for: url).reversed()
    }

    /// Newest record for `url`, if any.
    public func latest(for url: URL) -> BackupRecord? {
        prepare()
        return chain(for: url).last
    }

    /// Live path and backup availability, rather than an unconditional
    /// promise derived from an old badge/index entry.
    public func availability(for url: URL) -> BackupAvailability {
        prepare()
        let records = activeChain(for: url)
        let original = records.first
        let exists = original.map { FileManager.default.isReadableFile(atPath: $0.backupPath) } ?? false
        return BackupAvailability(canRevert: exists && FileManager.default.fileExists(atPath: url.path),
                                  originalDate: exists ? original?.createdAt : nil,
                                  latestDate: records.last?.createdAt, originalRecord: exists ? original : nil)
    }

    /// Every readable record in the store, unordered.
    public func allRecords() -> [BackupRecord] {
        prepare()
        return (index ?? [:]).values.flatMap { $0 }
    }

    /// Pencil-badge state for one file.
    public func state(for url: URL) -> BackupState {
        prepare()
        return state(ofChain: activeChain(for: url), file: url)
    }

    /// Batched `state(for:)` for the grid: one call per visible page.
    public func states(for urls: [URL]) -> [URL: BackupState] {
        prepare()
        var out: [URL: BackupState] = [:]
        out.reserveCapacity(urls.count)
        for url in urls {
            out[url] = state(ofChain: activeChain(for: url), file: url)
        }
        return out
    }

    private func state(ofChain chain: [BackupRecord], file: URL) -> BackupState {
        guard let newest = chain.last, let original = chain.first else { return .none }
        switch newest.reason {
        case .revert:
            return .reverted
        case .restore, .undo:
            // A restore / undo may have put the original bytes back.
            if let sum = original.checksum,
               let current = try? Self.fingerprint(file),
               current.size == original.byteSize, current.sum == sum {
                return .reverted
            }
            return .edited
        case .save, .rotate, .batch:
            return .edited
        case .replace:
            // The newest record is the copy taken before a Replace. A Replace moves the victim's chain
            // away, so a live chain ends with it only when the victim is back at its path (Undo, or a
            // Replace that failed). Edited only when Shrike put it back (the heal stamps the chain) and
            // there is history before it; an unstamped chain (0.2.32 left victims' chains under the new
            // photo on a volume with no Trash) stays as before.
            return chain.count > 1 && newest.writtenSize != nil ? .edited : .none
        }
    }

    /// The file at `old` now lives at `new` (rename / move done by
    /// Shrike): its chain follows it so the original stays protected.
    ///
    /// Returns how many records could not be written to disk (0 = all good). The chain follows
    /// the file in memory either way, but a record that failed still names the old path on
    /// disk, so after the next launch that chain would be lost. The failure is
    /// logged; a caller that can tell the user may do so.
    @discardableResult
    public func rekey(from old: URL, to new: URL) -> Int {
        prepare()
        let oldKey = Self.key(for: old)
        guard oldKey != Self.key(for: new) else { return 0 }
        // First, the put-aside chains that guard the OLD real path now guard the new one, whether or
        // not the photo has a chain of its own at `old`. Only here, never in the private
        // core: `detach(chainAt:)` moves a chain away because the FILE at that path changed, and the
        // other put-aside chains still guard that path.
        let followed = rewriteReferrers(from: oldKey, to: new)
        return followed + rekey(from: old, to: new, detached: nil)
    }

    /// Rewrites `detachedFrom` of every chain that names `oldKey` and saves it. Returns how many
    /// records could not be saved. Cost: one small JSON write per record of each referring chain.
    private func rewriteReferrers(from oldKey: String, to new: URL) -> Int {
        guard let stales = detachedBy?[oldKey], !stales.isEmpty else { return 0 }
        let (failed, followed) = pointGuards(stales, at: new)
        detachedBy?[oldKey] = nil
        if !followed.isEmpty { detachedBy?[Self.key(for: new), default: []].formUnion(followed) }
        return failed
    }

    /// Points the given put-aside chains at `path`; returns the failures and the chains that still exist.
    private func pointGuards(_ keys: Set<String>, at path: URL) -> (failed: Int, followed: Set<String>) {
        let newPath = CanonicalPath.of(path)
        var failed = 0
        var followed = Set<String>()
        for staleKey in keys {
            guard let recs = index?[staleKey], !recs.isEmpty else { continue }   // reaped meanwhile
            for (i, rec) in recs.enumerated() {
                let updated = rec.withDetachedFrom(newPath)
                index?[staleKey]?[i] = updated
                do { try Self.writeRecord(updated, in: updated.backupURL.deletingLastPathComponent()) } catch {
                    failed += 1
                    Self.log.error("detachedFrom not saved: \(error.localizedDescription, privacy: .public)")
                }
            }
            followed.insert(staleKey)
        }
        return (failed, followed)
    }

    /// Puts the chain at `url` aside under a throw-away name with the retention clock and NO path guard:
    /// it is deleted when retention runs out, never kept because some file sits at a path. For chains
    /// that belong to a photo that is gone (a Replace victim, a history without proof of its photo).
    @discardableResult
    package func parkWithClock(chainAt url: URL) -> (aside: URL, failed: Int) {
        prepare()
        let name = ".shrike-stale-\(UUID().uuidString)-\(url.lastPathComponent)"
        let aside = url.deletingLastPathComponent().appendingPathComponent(name)
        checkedMismatch[Self.key(for: url)] = nil
        let failed = rekey(from: url, to: aside, detached: (now(), nil))
        return (aside, failed)
    }

    /// Does the file at `file` look like the photo whose chain is filed at `chainURL`? nil = no proof
    /// either way (no chain, or its newest record has no stamp). No side effects: it never re-stamps
    /// and never touches the caches of the file's own chain.
    package func chainStampMatches(chainAt chainURL: URL, file: URL) -> Bool? {
        prepare()
        guard let newest = chain(for: chainURL).last, let size = newest.writtenSize,
              let modified = newest.writtenModified, let now = Self.writeStamp(of: file) else { return nil }
        guard now.size == size else { return false }
        if now.modified == modified { return true }
        guard let sum = newest.writtenChecksum, let current = try? Self.contentHash(file, like: sum) else { return false }
        return current == sum
    }

    /// For a Replace: the photo at `url` is another photo than the one that takes its place. Its active
    /// chain is put aside as usual, and its OLDER put-aside chains (guards of `url`) are parked under
    /// that chain, so they follow the victim and not whatever photo sits at `url` next.
    /// Not for `backup()`'s stale branch: there the older guards are the same photo's.
    /// Cost: one small JSON write per record of each older guard.
    @discardableResult
    package func detachForReplace(chainAt url: URL) -> (aside: URL, failed: Int) {
        prepare()
        let urlKey = Self.key(for: url)
        let older = detachedBy?[urlKey] ?? []
        // The victim is kept by the retention clock only, not by the file that now sits at
        // its path: otherwise every Replace would keep a full-size copy for as long as any file is there.
        let result = parkWithClock(chainAt: url)
        let (failed, followed) = pointGuards(older, at: result.aside)
        detachedBy?[urlKey]?.subtract(older)
        if !followed.isEmpty { detachedBy?[Self.key(for: result.aside), default: []].formUnion(followed) }
        return (result.aside, result.failed + failed)
    }

    /// Puts the chain at `url` aside under a throw-away name and starts the retention clock.
    /// The chain keeps its original while a file still sits at `url` (see `keepsOriginal`); the clock
    /// only matters once no file is there. A plain `rekey` back to the real path clears the mark.
    @discardableResult
    package func detach(chainAt url: URL) -> (aside: URL, failed: Int) {
        detach(chainAt: url, guarding: url)
    }

    /// Puts the chain at `url` aside, guarded by the path `anchor` (where the photo is believed to
    /// live now) instead of by `url`. Used by recovery when it cannot prove which photo a history
    /// belongs to but the photo is alive at `anchor`.
    @discardableResult
    package func detach(chainAt url: URL, guarding anchor: URL) -> (aside: URL, failed: Int) {
        let name = ".shrike-stale-\(UUID().uuidString)-\(url.lastPathComponent)"
        let aside = url.deletingLastPathComponent().appendingPathComponent(name)
        checkedMismatch[Self.key(for: url)] = nil
        var failed = rekey(from: url, to: aside, detached: (now(), CanonicalPath.of(anchor)))
        let urlKey = Self.key(for: url), anchorKey = Self.key(for: anchor)
        // Other put-aside chains that guarded `url` follow the anchor too: the photo lives there now, and
        // left behind they would fall to the clock.
        if urlKey != anchorKey {
            let others = (detachedBy?[urlKey] ?? []).subtracting([Self.key(for: aside)])
            if !others.isEmpty {
                let moved = pointGuards(others, at: anchor)
                failed += moved.failed
                detachedBy?[urlKey]?.subtract(others)
                detachedBy?[anchorKey, default: []].formUnion(moved.followed)
            }
        }
        detachedBy?[anchorKey, default: []].insert(Self.key(for: aside))
        return (aside, failed)
    }

    @discardableResult
    private func rekey(from old: URL, to new: URL, detached: (at: Date, from: String?)?) -> Int {
        prepare()
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey, let moving = index?[oldKey], !moving.isEmpty else { return 0 }
        // The target path already has a chain: it belongs to another photo. Put it aside, never merge
        // two photos' histories.
        var failed = 0
        if let existing = index?[newKey], !existing.isEmpty { failed += detach(chainAt: new).failed }
        let newPath = CanonicalPath.of(new)
        var moved: [BackupRecord] = []
        for rec in moving {
            let updated = rec.moved(to: newPath, detached: detached)
            do { try Self.writeRecord(updated, in: rec.backupURL.deletingLastPathComponent()) } catch {
                failed += 1
                Self.log.error("rekey: record \(rec.id.uuidString, privacy: .public) not saved: \(error.localizedDescription, privacy: .public)")
            }
            moved.append(updated)
        }
        index?[oldKey] = nil
        index?[newKey, default: []].append(contentsOf: moved)
        for rec in moved { recordKeys?[rec.id] = newKey }
        index?[newKey]?.sort(by: BackupRecord.chainOrder)
        return failed
    }

    private static let log = Logger(subsystem: "app.shrike", category: "backups")

    // MARK: - Size

    /// Bytes held by the store (logical size of every copy; APFS clones
    /// may take less on disk). Editing tab readout and the cap check.
    public func totalBytes() -> Int64 {
        prepare()
        var total: Int64 = 0
        for recs in (index ?? [:]).values {
            for rec in recs { total += Self.size(of: rec) }
        }
        for orphan in orphans { total += Self.directorySize(orphan.entry) }
        return total
    }

    /// Bytes used, the cap, and whether the store is over it (for one line in Settings).
    public func usage() -> BackupUsage {
        BackupUsage(usedBytes: totalBytes(), capBytes: maxBytes())
    }

    // MARK: - Reap

    /// Retention then size cap. Run by the UI 10 s after first paint,
    /// then every 24 h; also once on the first backup of a session.
    /// Deletion is permanent.
    @discardableResult
    public func reap(now date: Date? = nil) -> ReapReport {
        prepare()
        let now = date ?? self.now()
        var report = ReapReport(removed: 0, freedBytes: 0, totalBytes: 0, overCap: false)

        // 1. Retention.
        let (count, freed) = purgeExpired(days: retentionDays(), now: now)
        report.removed += count
        report.freedBytes += freed

        // 2. Size cap.
        var total = totalBytes()
        let cap = maxBytes()
        if cap > 0, total > cap {
            let graceCutoff = now.addingTimeInterval(-Self.capGrace)
            var nonOriginals: [BackupRecord] = []
            var orphanedOriginals: [BackupRecord] = []
            for recs in (index ?? [:]).values {
                guard let first = recs.first else { continue }
                let fileExists = keepsOriginal(first, now: now)
                for (i, rec) in recs.enumerated() where rec.createdAt < graceCutoff {
                    if i == 0 {
                        // Never the original of a file that still exists.
                        if !fileExists { orphanedOriginals.append(rec) }
                    } else {
                        nonOriginals.append(rec)
                    }
                }
            }
            let queue = nonOriginals.sorted(by: BackupRecord.chainOrder)
                + orphanedOriginals.sorted(by: BackupRecord.chainOrder)
            for rec in queue where total > cap {
                let size = Self.size(of: rec)
                if delete(rec) {
                    total -= size
                    report.removed += 1
                    report.freedBytes += size
                }
            }
            report.overCap = total > cap
        }
        report.totalBytes = total
        return report
    }

    /// Deletes EVERY backup copy in the store (the user's "Delete All Backups…").
    /// Only files inside the backup root go; the photos the backups were made from are
    /// never touched. After this, Revert to Original and Undo of a save have nothing to
    /// restore from. Returns how many backups and bytes went.
    @discardableResult
    public func deleteAll() -> (removed: Int, freedBytes: Int64) {
        prepare()
        var removed = 0
        var freed: Int64 = 0
        for recs in Array((index ?? [:]).values) {
            for rec in recs {
                let size = Self.size(of: rec)
                if delete(rec) { removed += 1; freed += size }
            }
        }
        let fm = FileManager.default
        var stillThere: [(entry: URL, day: Date?)] = []
        for orphan in orphans {
            let size = Self.directorySize(orphan.entry)
            if (try? fm.removeItem(at: orphan.entry)) != nil {
                removed += 1; freed += size
                Self.removeIfEmpty(orphan.entry.deletingLastPathComponent())
            } else {
                stillThere.append(orphan)
            }
        }
        orphans = stillThere
        return (removed, freed)
    }

    /// Retention pass only: delete records older than `days` days, except
    /// the original (oldest record) of a file that still exists. Returns
    /// how many were removed. `days < 0` keeps everything.
    @discardableResult
    public func purge(olderThan days: Int = Prefs.backupRetentionDays) -> Int {
        prepare()
        return purgeExpired(days: days, now: now()).removed
    }

    private func purgeExpired(days: Int, now: Date) -> (removed: Int, freed: Int64) {
        guard days >= 0 else { return (0, 0) }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed = 0
        var freed: Int64 = 0
        for recs in (index ?? [:]).values {
            guard let first = recs.first else { continue }
            let fileExists = keepsOriginal(first, now: now)
            for (i, rec) in recs.enumerated() where rec.createdAt < cutoff {
                if i == 0 && fileExists { continue }
                let size = Self.size(of: rec)
                if delete(rec) { removed += 1; freed += size }
            }
        }
        orphans.removeAll { orphan in
            guard let day = orphan.day, day < cutoff else { return false }
            let size = Self.directorySize(orphan.entry)
            guard (try? FileManager.default.removeItem(at: orphan.entry)) != nil else { return false }
            Self.removeIfEmpty(orphan.entry.deletingLastPathComponent())
            removed += 1
            freed += size
            return true
        }
        return (removed, freed)
    }

    /// True when the original of the chain whose first record is `first` must be kept. A chain that
    /// was put aside is kept until retention has run out counted from the moment it was put aside;
    /// any other chain while its file may still exist.
    private func keepsOriginal(_ first: BackupRecord, now: Date, depth: Int = 0) -> Bool {
        guard let detachedAt = first.detachedAt else { return Self.originalMayStillExist(atPath: first.originalPath) }
        // The chain was put aside, but a file still sits at the real path (another app changed it, a
        // Replace put another photo there): keep the original as 0.2.32 did. The store may stay over
        // its cap; `usage().isOverCap` says so.
        if let from = first.detachedFrom {
            if Self.originalMayStillExist(atPath: from) { return true }
            // Parked under a victim's put-aside chain (see `detachForReplace`): kept as long as that chain is.
            if depth < 8, let parent = index?[Self.key(for: URL(fileURLWithPath: from))]?.first,
               parent.detachedAt != nil, keepsOriginal(parent, now: now, depth: depth + 1) { return true }
        }
        // No file there any more: the retention clock counts from the moment the chain was put aside.
        let days = retentionDays()
        return days < 0 || now < detachedAt.addingTimeInterval(Double(days) * 86_400)
    }

    /// Whether the file a chain belongs to may still exist, so its original
    /// must be kept. False only when the file is truly gone: its folder (or
    /// volume) is present and the file is not there. A photo on an unplugged
    /// disk or network share (`/Volumes/<name>` not mounted), and an iCloud
    /// Drive file that macOS evicted (only `.<name>.icloud` is left), count
    /// as existing, so a reap while the disk is away never deletes the
    /// original that Revert to Original needs later.
    static func originalMayStillExist(atPath path: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { return true }
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let placeholder = folder.appendingPathComponent(".\(url.lastPathComponent).icloud")
        if fm.fileExists(atPath: placeholder.path) { return true }
        let parts = folder.pathComponents   // ["/", "Volumes", "Disk", ...]
        if parts.count >= 3, parts[1] == "Volumes" {
            let mount = "/Volumes/" + parts[2]
            if !fm.fileExists(atPath: mount) { return true }   // not mounted
        }
        return false
    }

    // MARK: - Index

    private func prepare() {
        if index == nil { loadIndex() }
    }

    private func chain(for url: URL) -> [BackupRecord] {
        index?[Self.key(for: url)] ?? []
    }

    private func insert(_ rec: BackupRecord) {
        let key = Self.key(for: rec.originalURL)
        index?[key, default: []].append(rec)
        index?[key]?.sort(by: BackupRecord.chainOrder)
        recordKeys?[rec.id] = key
    }

    /// The key of the chain that holds the record `id`, or nil when it is not in the store.
    package func chainKey(ofRecord id: UUID) -> String? {
        prepare()
        return recordKeys?[id]
    }

    /// Remove a record's folder and drop it from the index.
    private func delete(_ rec: BackupRecord) -> Bool {
        let entry = rec.backupURL.deletingLastPathComponent()
        guard (try? FileManager.default.removeItem(at: entry)) != nil else { return false }
        let key = Self.key(for: rec.originalURL)
        index?[key]?.removeAll { $0.id == rec.id }
        if index?[key]?.isEmpty == true { index?[key] = nil }
        Self.removeIfEmpty(entry.deletingLastPathComponent())
        recordKeys?[rec.id] = nil
        return true
    }

    private func loadIndex() {
        let fm = FileManager.default
        var idx: [String: [BackupRecord]] = [:]
        var lost: [(entry: URL, day: Date?)] = []
        for day in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: day.path, isDirectory: &isDir), isDir.boolValue else { continue }
            for entry in (try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil)) ?? [] {
                let json = entry.appendingPathComponent(Self.recordFileName)
                guard let data = try? Data(contentsOf: json),
                      var rec = try? Self.decoder.decode(BackupRecord.self, from: data) else {
                    lost.append((entry, Self.date(fromDayFolder: day.lastPathComponent)))
                    continue
                }
                // The root may have moved (legacy migration, user moved the
                // folder): trust where the record sits, not the stored path.
                let actual = entry.appendingPathComponent(rec.backupURL.lastPathComponent).path
                if actual != rec.backupPath {
                    rec = rec.with(backupPath: actual)
                    try? Self.writeRecord(rec, in: entry)
                }
                idx[Self.key(for: rec.originalURL), default: []].append(rec)
            }
        }
        for key in idx.keys { idx[key]?.sort(by: BackupRecord.chainOrder) }
        index = idx
        var referrers: [String: Set<String>] = [:]
        for (staleKey, recs) in idx {
            if let from = recs.first?.detachedFrom {
                referrers[Self.key(for: URL(fileURLWithPath: from)), default: []].insert(staleKey)
            }
        }
        detachedBy = referrers
        var keys: [UUID: String] = [:]
        for (key, recs) in idx { for rec in recs { keys[rec.id] = key } }
        recordKeys = keys
        orphans = lost
    }

    // MARK: - Helpers

    /// Chain key. Same string for every spelling of one file path
    /// (case-folded on case-insensitive volumes, like MetadataStore).
    static func key(for url: URL) -> String {
        CanonicalPath.key(url)
    }

    /// Version 2 content hash, stored as "2:<hex>": size ‖ first MiB ‖ a middle MiB (only when the
    /// file is longer than two windows) ‖ last MiB. An old hash without the prefix is version 1.
    static func contentHashV2(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let window = Int64(verifyWindow)
        func read(at offset: Int64) throws -> Data {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: verifyWindow) ?? Data()
        }
        let head = try read(at: 0)
        hasher.update(data: head)
        if size > Int64(head.count) {
            if size > 2 * window { hasher.update(data: try read(at: size / 2 - window / 2)) }
            hasher.update(data: try read(at: max(Int64(head.count), size - window)))
        }
        return "2:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The hash of `url` computed the way `stored` was (an old hash is compared the old way).
    static func contentHash(_ url: URL, like stored: String) throws -> String {
        stored.hasPrefix("2:") ? try contentHashV2(url) : try fingerprint(url).sum
    }

    /// Size and SHA-256 over (size ‖ first MiB ‖ last MiB). Cheap on big
    /// files; catches truncation, empty clones and swapped files.
    static func fingerprint(_ url: URL) throws -> (size: Int64, sum: String) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }
        let head = try handle.read(upToCount: verifyWindow) ?? Data()
        hasher.update(data: head)
        if size > Int64(head.count) {
            let tailStart = max(Int64(head.count), size - Int64(verifyWindow))
            try handle.seek(toOffset: UInt64(tailStart))
            hasher.update(data: try handle.read(upToCount: verifyWindow) ?? Data())
        }
        let sum = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (size, sum)
    }

    private static func size(of rec: BackupRecord) -> Int64 {
        if let s = rec.byteSize { return s }
        let v = try? rec.backupURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private static func removeIfEmpty(_ dir: URL) {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: dir.path),
           items.allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: dir)
        }
    }

    private static func writeRecord(_ rec: BackupRecord, in dir: URL) throws {
        let data = try encoder.encode(rec)
        try data.write(to: dir.appendingPathComponent(recordFileName), options: .atomic)
    }

    /// True for "disk full" by error code (Cocoa out-of-space, POSIX ENOSPC / EDQUOT), looking
    /// through underlying errors. Never by the words in the message.
    public static func isOutOfSpace(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return true }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(under)
        }
        return false
    }

    static func volumeName(of url: URL) -> String {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe.deleteLastPathComponent()
        }
        return (try? probe.resourceValues(forKeys: [.volumeLocalizedNameKey]))?
            .volumeLocalizedName ?? "the startup disk"
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func dayFolderName(for date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(fromDayFolder name: String) -> Date? {
        let parts = name.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar(identifier: .gregorian).date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Raw extended attributes

/// Byte-level xattr access, used to carry file-level attributes across a
/// byte restore.
enum ExtendedAttribute {
    static func read(_ name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, 0)
            guard size >= 0 else { return nil }
            var buf = [UInt8](repeating: 0, count: size)
            let got = getxattr(path, name, &buf, size, 0, 0)
            guard got == size else { return nil }
            return Data(buf)
        }
    }

    @discardableResult
    static func write(_ value: Data, name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return value.withUnsafeBytes { raw in
                setxattr(path, name, raw.baseAddress, raw.count, 0, 0) == 0
            }
        }
    }

    static func remove(_ name: String, at url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = removexattr(path, name, 0)
        }
    }
}

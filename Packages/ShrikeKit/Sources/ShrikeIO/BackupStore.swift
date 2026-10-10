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

    public var originalURL: URL { URL(fileURLWithPath: originalPath) }
    public var backupURL: URL { URL(fileURLWithPath: backupPath) }

    public init(id: UUID, originalPath: String, backupPath: String, createdAt: Date,
                reason: BackupReason, byteSize: Int64? = nil, checksum: String? = nil,
                sequence: Int? = nil) {
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
                     sequence: sequence)
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

    // MARK: - Restore / revert

    /// Put the backed-up bytes back at the original path (atomic replace).
    /// The current file, if any, is backed up first (reason `.restore`) so
    /// a restore can itself be undone; that safety record is returned.
    /// Rating, flag and Finder tags on the file are kept.
    @discardableResult
    public func restore(_ record: BackupRecord) throws -> BackupRecord? {
        prepare()
        return try restoreBytes(from: record.backupURL, to: record.originalURL,
                                safetyReason: .restore)
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
        guard let original = chain(for: url).first else { throw BackupError.backupMissing }
        guard let safety = try restoreBytes(from: original.backupURL, to: url,
                                            safetyReason: .revert) else {
            throw BackupError.sourceMissing
        }
        return safety
    }

    private func restoreBytes(from backup: URL, to original: URL,
                              safetyReason: BackupReason) throws -> BackupRecord? {
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
        let tmp = original.deletingLastPathComponent()
            .appendingPathComponent(".\(original.lastPathComponent).shrikerestore.\(UUID().uuidString)")
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

    /// Every readable record in the store, unordered.
    public func allRecords() -> [BackupRecord] {
        prepare()
        return (index ?? [:]).values.flatMap { $0 }
    }

    /// Pencil-badge state for one file.
    public func state(for url: URL) -> BackupState {
        prepare()
        return state(ofChain: chain(for: url), file: url)
    }

    /// Batched `state(for:)` for the grid: one call per visible page.
    public func states(for urls: [URL]) -> [URL: BackupState] {
        prepare()
        var out: [URL: BackupState] = [:]
        out.reserveCapacity(urls.count)
        for url in urls {
            out[url] = state(ofChain: chain(for: url), file: url)
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
            // The file at this path replaced the backed-up one; it is not
            // an edit of it (only left here on a volume without a Trash).
            return .none
        }
    }

    /// The file at `old` now lives at `new` (rename / move done by
    /// Shrike): its chain follows it so the original stays protected.
    public func rekey(from old: URL, to new: URL) {
        prepare()
        let oldKey = Self.key(for: old)
        let newKey = Self.key(for: new)
        guard oldKey != newKey, let moving = index?[oldKey], !moving.isEmpty else { return }
        let newPath = CanonicalPath.of(new)
        var moved: [BackupRecord] = []
        for rec in moving {
            let updated = rec.with(originalPath: newPath)
            try? Self.writeRecord(updated, in: rec.backupURL.deletingLastPathComponent())
            moved.append(updated)
        }
        index?[oldKey] = nil
        index?[newKey, default: []].append(contentsOf: moved)
        index?[newKey]?.sort(by: BackupRecord.chainOrder)
    }

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
                let fileExists = FileManager.default.fileExists(atPath: first.originalPath)
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
            let fileExists = FileManager.default.fileExists(atPath: first.originalPath)
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
    }

    /// Remove a record's folder and drop it from the index.
    private func delete(_ rec: BackupRecord) -> Bool {
        let entry = rec.backupURL.deletingLastPathComponent()
        guard (try? FileManager.default.removeItem(at: entry)) != nil else { return false }
        let key = Self.key(for: rec.originalURL)
        index?[key]?.removeAll { $0.id == rec.id }
        if index?[key]?.isEmpty == true { index?[key] = nil }
        Self.removeIfEmpty(entry.deletingLastPathComponent())
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
        orphans = lost
    }

    // MARK: - Helpers

    /// Chain key. Same string for every spelling of one file path
    /// (case-folded on case-insensitive volumes, like MetadataStore).
    static func key(for url: URL) -> String {
        CanonicalPath.key(url)
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

    static func isOutOfSpace(_ error: any Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { return true }
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

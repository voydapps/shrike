//
//  TemporaryFiles.swift
//  ShrikeIO
//
//  What a crash can leave behind.
//
//  Two kinds of temp file exist:
//
//  * COPIES: the real photo still exists under its own name (save `.shrikeedit.*.tmp`,
//    rotate `.name.shrikerotate.UUID`, restore `.name.shrikerestore.UUID`, copy / cross-volume
//    move `.name.shriketransfer.UUID`). `TemporaryFileSweeper` deletes those once they are
//    an hour old.
//  * THE ONLY COPY: a two-step rename (a case-only rename `.shrike-rename-UUID-name`, or Batch
//    moving a photo out of the way `"<stem> shrike-tmp-XXXXXXXX"`) holds the photo under the
//    temp name for a moment. Those are NEVER deleted. `RenameJournal` writes a small file before
//    the first step and removes it after the last, so a later launch can put the name back, or at
//    least report the photo.
//

import Foundation
import os
import ShrikeCore

// MARK: - Sweeper (copies only)

public enum TemporaryFileSweeper {

    private static let swept = OSAllocatedUnfairLock(initialState: Set<String>())
    private static let copyMarkers = [".shrikerotate.", ".shrikerestore.", ".shriketransfer."]

    /// `.name.<marker>.<uuid><suffix>`, or without the name (`.<marker>.<uuid><suffix>`) when the
    /// full form would pass the 255-byte name limit. The sweeper knows both forms.
    public static func hiddenTempName(for name: String, marker: String, suffix: String = "") -> String {
        let uuid = UUID().uuidString
        let full = ".\(name).\(marker).\(uuid)\(suffix)"
        return full.utf8.count <= 255 ? full : ".\(marker).\(uuid)\(suffix)"
    }

    /// True for a hidden `.name.shrikerotate|shrikerestore|shriketransfer.<UUID>` file.
    static func isCopyTemp(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        for marker in copyMarkers {
            if let range = name.range(of: marker, options: .backwards),
               UUID(uuidString: String(name[range.upperBound...])) != nil { return true }
        }
        return false
    }

    /// True for the save temp `*.shrikeedit.<uuid>.<ext>.tmp`.
    static func isSaveTemp(_ name: String) -> Bool {
        name.hasSuffix(".tmp") && name.contains(".shrikeedit.")
    }

    /// Deletes temp COPIES in `folder` that are older than `age` (younger ones may belong to work in
    /// progress). Once per folder and run. Never touches a photo or an "only copy" temp.
    public static func sweep(in folder: URL, olderThan age: TimeInterval = 3600, now: Date = Date()) {
        // One key per folder however its path is spelled (symlinks, "/./", trailing slash).
        let key = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard swept.withLock({ $0.insert(key).inserted }) else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .attributeModificationDateKey],
            options: []) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard isSaveTemp(name) || isCopyTemp(name) else { continue }
            // A copy keeps its source's modification date, so the file looks old from the moment it is
            // made. The attribute-change date (when the file appeared here) is the honest age: use the
            // newer of the two.
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .attributeModificationDateKey])
            let born = [values?.contentModificationDate, values?.attributeModificationDate].compactMap { $0 }.max()
            if let born, now.timeIntervalSince(born) > age { try? fm.removeItem(at: url) }
        }
    }
}

// MARK: - Journal (the only copy)

public struct RenameJournalEntry: Codable, Sendable, Hashable, Identifiable {
    public struct Move: Codable, Sendable, Hashable {
        /// The name the photo had (and should get back).
        public let original: String
        /// The temporary name it holds while the rename runs.
        public let temporary: String
        /// The name the photo is meant to get at the end (Batch moves a photo aside because another
        /// photo takes its name). nil for entries that have no such name.
        public let final: String?

        public init(original: String, temporary: String, final: String? = nil) {
            self.original = original
            self.temporary = temporary
            self.final = final
        }
    }
    public let id: UUID
    public let created: Date
    public let moves: [Move]
    /// The process that wrote it; an entry of a process that is still running is never touched.
    public let pid: Int32?
}

/// What `FileOps.recoverRenames()` did.
public struct RenameRecovery: Sendable {
    /// Photos that were put back under their old name.
    public var restored: [URL] = []
    /// Photos that stay under a temporary name because their old name is taken again. The UI
    /// should tell the user where they are (`temporary`) and what they were called (`original`).
    public var needsAttention: [(entry: UUID, original: URL, temporary: URL)] = []
    /// Photos whose backup information could not be saved while their bookkeeping moved back.
    public var backupsNotSaved = 0
    /// Histories (backup chains) that could not be given back to a photo because there was no proof
    /// which photo they belong to. They are kept aside by the retention clock; the UI may say so.
    public var historyNotRestored = 0
}

public final class RenameJournal: Sendable {

    /// `~/Library/Application Support/app.shrike/Journal` (a temp folder under XCTest).
    public static let defaultDirectory: URL = ShrikeDataPaths.applicationSupportBase
        .appendingPathComponent("app.shrike", isDirectory: true)
        .appendingPathComponent("Journal", isDirectory: true)

    public static let shared = RenameJournal(directory: defaultDirectory)

    private let directory: URL
    /// When the process with this pid started (nil = unknown / not running). Injected by tests.
    private let startTimeOfPid: @Sendable (Int32) -> Date?

    public convenience init(directory: URL) { self.init(directory: directory, startTimeOfPid: { RenameJournal.startTime(ofPid: $0) }) }

    init(directory: URL, startTimeOfPid: @escaping @Sendable (Int32) -> Date?) {
        self.directory = directory
        self.startTimeOfPid = startTimeOfPid
    }

    private func file(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// Writes the entry BEFORE the first rename. Returns nil when it could not be written
    /// (the rename goes on: the journal is a safety net, not a gate).
    public func begin(moves: [(original: URL, temporary: URL)]) -> UUID? {
        begin(moves: moves.map { (original: $0.original, temporary: $0.temporary, final: nil as URL?) })
    }

    /// Same, and records the name the photo is meant to get at the end (`final`). Recovery uses it to
    /// find the photo again when another photo took its old name.
    public func begin(moves: [(original: URL, temporary: URL, final: URL?)]) -> UUID? {
        let entry = RenameJournalEntry(
            id: UUID(), created: Date(),
            moves: moves.map { .init(original: $0.original.path, temporary: $0.temporary.path, final: $0.final?.path) },
            pid: getpid())
        return write(entry) ? entry.id : nil
    }

    /// Test seam: writes an entry as given (an old date, another process).
    @discardableResult
    func write(_ entry: RenameJournalEntry) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: file(for: entry.id), options: .atomic)
            return true
        } catch { return false }
    }

    /// When this process started (the kernel's value, not "first time asked"), so an entry that a
    /// rename running right now has written is never mistaken for an old one.
    static let processStart: Date = startTime(ofPid: getpid()) ?? .distantPast   // unknown: touch nothing

    /// The kernel's start time of the process `pid`, or nil when there is no such process.
    static func startTime(ofPid pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        guard t.tv_sec != 0 else { return nil }
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }

    /// True when the process that wrote `entry` may still be running. A pid is reused: after a
    /// reboot it can belong to a long-running system process. A process that started AFTER the entry
    /// was written cannot be its writer.
    private func writerMayBeRunning(_ entry: RenameJournalEntry) -> Bool {
        guard let pid = entry.pid, pid != getpid() else { return false }
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let started = startTimeOfPid(pid) else { return true }      // alive, start unknown: be careful
        return started <= entry.created
    }

    /// The photo of entry `id` is about to go somewhere else than the entry says: rewrites the SAME
    /// entry (same id, same date, so its place among the pending entries does not change) with
    /// `moves`, in one atomic file replace. There is no moment without an entry, and never two
    /// entries for one photo. With no entry (`id` nil, or it is gone) it begins one.
    /// Returns the id of the entry that now covers the photo (when the rewrite fails, the old entry
    /// stays, as the journal is a safety net, not a gate).
    public func replace(_ id: UUID?, moves: [(original: URL, temporary: URL, final: URL?)]) -> UUID? {
        guard let id, let old = try? JSONDecoder().decode(RenameJournalEntry.self, from: Data(contentsOf: file(for: id))) else {
            return begin(moves: moves)
        }
        _ = write(RenameJournalEntry(
            id: id, created: old.created,
            moves: moves.map { .init(original: $0.original.path, temporary: $0.temporary.path, final: $0.final?.path) },
            pid: getpid()))
        return id
    }

    /// The last step is done (or rolled back): drop the entry.
    public func end(_ id: UUID?) {
        guard let id else { return }
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Entries that were never ended.
    public func pending() -> [RenameJournalEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(RenameJournalEntry.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created < $1.created }
    }

    /// Entries a launch may handle: written before `startedBefore`, and not by a rename that is
    /// running right now (this process, or another one that is still alive). The WORK is done by
    /// `FileOps.recoverRenames()`, which also moves the backup chain and the metadata; there is no
    /// journal-only recovery, so UI code cannot rename a photo back without its bookkeeping.
    func eligibleEntries(startedBefore: Date) -> [RenameJournalEntry] {
        pending().filter { $0.created < startedBefore && !writerMayBeRunning($0) }
    }

    /// The user has seen the report: forget the entry.
    public func dismiss(_ id: UUID) { end(id) }
}

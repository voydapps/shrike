//
//  FileOps.swift
//  ShrikeIO
//
//  Trash, restore, copy, move and rename for whole `ImageGroup`s (primary
//  + RAW + .xmp/.aae + Live Photo .mov).
//
//  Rules
//  -----
//  * Every operation acts on `group.allURLs`. Keep Both gives every file of
//    a group the same Finder-style " 2" suffix so the pair still matches.
//  * A group is all-or-nothing: if one companion fails, the files already
//    done for that group are put back, and the group is reported failed.
//    Other groups go on.
//  * Replace backs up every file it is about to remove (BackupStore), then
//    moves it to the Trash (or deletes it when the volume has no Trash —
//    the backup is the safety net). Undo puts it back.
//  * Metadata follows the file: `MetadataStore.transfer(… mode: .move)` and
//    `BackupStore.rekey` for trash, restore, move and rename (so Revert to
//    Original keeps working); `transfer(… mode: .copy)` for copy. Finder
//    tags and the rating xattrs are on the file, so they travel with it.
//  * Shrike's own writes are reported through `FolderChangeSuppressing`
//    just before each file operation, so they don't come back as "removed
//    outside Shrike". A window passes its `WindowWatcherScope` (its own and
//    its paired window's watcher); other windows' watchers still report the
//    change. The default (every watcher) is only for callers with no window.
//  * After each operation a `FileOpsChange` is published on `changes()` and
//    as `FileOps.didChangeNotification`, so every window can update its
//    list at once.
//  * Copy / move run as an `AsyncThrowingStream<FileOpProgress, Error>`.
//    Every element carries the receipt so far. Cancelling the consuming
//    task stops after the current group; finished groups stay, and the last
//    element the consumer received is the receipt for Undo (a cancelled
//    consumer does not see a final `wasCancelled` element, and the group
//    that was running when the cancel landed can be missing from it).
//    A caller that needs the exact receipt passes a `TransferStop` and
//    calls `stop()` instead of cancelling: the group in flight finishes,
//    and the final element (`wasCancelled`) lists everything on disk. The
//    stream throws only when nothing can start (destination missing,
//    read-only, not writable).
//

import Foundation
import os
import ShrikeCore

// MARK: - Stop

/// Asks a running copy / move to stop after the group in flight, while the
/// consumer keeps reading (a cancelled consumer would lose the last element).
public final class TransferStop: Sendable {
    private let flag = OSAllocatedUnfairLock(initialState: false)
    public init() {}
    public func stop() { flag.withLock { $0 = true } }
    public var isStopped: Bool { flag.withLock { $0 } }
}

// MARK: - Errors

public enum FileOpsError: Error, Sendable, Hashable {
    /// The file's volume has no Trash (SMB, some USB disks). → the permanent-delete alert,
    /// then `deleteImmediately` if the user agrees.
    case noTrash(volumeName: String, url: URL)
    case permissionDenied(URL)
    case notFound(URL)
    case readOnlyVolume(URL)
    case nameTaken(URL)
    case invalidName(RenameValidation)
    /// The destination (or, for Undo, the original) folder is gone.
    case destinationUnavailable(URL)
    /// Replace refused: the file that would be replaced couldn't be backed up.
    case backupFailed(URL, reason: String)
    /// Anything else. `reason` is the system's one-sentence message.
    case io(URL, reason: String)

    /// The file or folder the error is about.
    public var url: URL {
        switch self {
        case .noTrash(_, let url), .permissionDenied(let url), .notFound(let url),
             .readOnlyVolume(let url), .nameTaken(let url), .destinationUnavailable(let url),
             .backupFailed(let url, _), .io(let url, _):
            return url
        case .invalidName(let validation):
            if case .nameTaken(let url) = validation { return url }
            return URL(fileURLWithPath: "/")
        }
    }
}

// MARK: - Rename validation

/// Result of `FileOps.validate(stem:for:)`. `message` is the line shown to the user.
public enum RenameValidation: Sendable, Hashable {
    case valid
    /// Same name as now: no message, Rename disabled.
    case unchanged
    case empty
    case invalidCharacters
    /// A line break, tab or other control character.
    case controlCharacters
    /// The name starts or ends with a space (Finder hides the difference; scripts break on it).
    case edgeSpace
    /// The name ends with a dot.
    case trailingDot
    /// `rename(_:backToEarlierStem:)` was given a name the photo never had.
    case notAnEarlierName
    case hidden
    case tooLong
    /// A file (or a companion's new name) already exists.
    case nameTaken(URL)

    public var isValid: Bool { self == .valid }

    /// The line shown under the field (nil for `.valid` / `.unchanged`).
    public var message: String? {
        switch self {
        case .valid, .unchanged: return nil
        case .empty: return "Enter a name."
        case .invalidCharacters: return "Names can't contain “/” or “:”."
        case .controlCharacters: return "Names can't contain line breaks or other hidden characters."
        case .edgeSpace: return "Names can't start or end with a space."
        case .trailingDot: return "Names can't end with a period."
        case .notAnEarlierName: return "This photo never had this name."
        case .hidden: return "Names starting with “.” are hidden. Choose another name."
        case .tooLong: return "This name is too long."
        case .nameTaken(let url): return "A file named “\(url.lastPathComponent)” already exists."
        }
    }
}

// MARK: - Receipts and progress

/// Counts the PHOTOS whose backup information could not be saved during one operation.
/// Used inside one actor method at a time, never shared across tasks.
final class LostBackups {
    var photos = 0
}

/// What `renameReporting` did.
public struct RenameResult: Sendable {
    public let group: ImageGroup
    /// The stem the photo had before this rename. `undoRename(_:)` needs nothing else.
    public let earlierStem: String
    /// Photos whose backup information could not be saved (Revert to Original may be missing for
    /// them after the next launch). 0 = all good.
    public let backupsNotSaved: Int
}

/// One file moved to the Trash.
public struct TrashedFile: Sendable, Hashable {
    public let original: URL
    /// Where it is now (`~/.Trash/…`, possibly renamed by the system).
    public let trashed: URL
}

public struct FileOpFailure: Sendable, Hashable {
    public let group: ImageGroup
    public let error: FileOpsError
}

/// What `trash` did, for Undo. `failures` lists groups that stayed put.
public struct TrashReceipt: Sendable, Hashable {
    public struct Item: Sendable, Hashable {
        public let group: ImageGroup
        public let files: [TrashedFile]
    }
    public let items: [Item]
    public let failures: [FileOpFailure]
    /// Photos whose backup information could not be saved by THIS operation.
    /// Read it once per operation: for a copy or move from the LAST `FileOpProgress.receipt`; for
    /// Trash and Put Back from the receipt or result returned. An Undo returns its own count (`undo`);
    /// never add the two, or a photo is counted twice.
    public var backupsNotSaved = 0

    /// Groups that did go to the Trash.
    public var trashedGroups: [ImageGroup] { items.map(\.group) }
}

/// What `restore` put back. `groups` carry the final URLs (" 2" when the
/// original name was taken meanwhile), in receipt order.
public struct RestoreResult: Sendable, Hashable {
    public let groups: [ImageGroup]
    public let failures: [FileOpFailure]
    /// Photos whose backup information could not be saved by THIS operation.
    /// Read it once per operation: for a copy or move from the LAST `FileOpProgress.receipt`; for
    /// Trash and Put Back from the receipt or result returned. An Undo returns its own count (`undo`);
    /// never add the two, or a photo is counted twice.
    public var backupsNotSaved = 0
}

/// A destination file that Replace removed, and how to get it back.
public struct ReplacedFile: Sendable, Hashable {
    public let original: URL
    /// Set when it went to the Trash.
    public let trashed: URL?
    /// Set when BackupStore holds a copy.
    public let backup: BackupRecord?
    /// Replace on a volume with no Trash: the victim's backup chain was moved to this
    /// throw-away name, so the next photo at the path does not inherit it.
    /// Undo moves the chain back.
    var chainMovedTo: URL? = nil
}

/// What a copy or move did, for Undo.
/// Which file is at a path: inode, size and modification time (lstat). Taken
/// right after a copy, so Undo can tell the copy from a different file that
/// now has the same name.
public struct FileStamp: Sendable, Hashable {
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int
    public let modifiedNanoseconds: Int

    public init?(of url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        inode = UInt64(st.st_ino)
        size = Int64(st.st_size)
        modifiedSeconds = Int(st.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int(st.st_mtimespec.tv_nsec)
    }
}

public struct FileOpReceipt: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case copy, move }

    public struct Item: Sendable, Hashable {
        /// The group before the operation.
        public let source: ImageGroup
        /// The new copy (copy) or the moved group (move).
        public let result: ImageGroup
        /// Destination files Replace removed to make room.
        public let replaced: [ReplacedFile]
        /// What each copied file looked like when the copy finished (copy only).
        public var stamps: [URL: FileStamp] = [:]
    }

    public let kind: Kind
    public let destination: URL
    public let items: [Item]
    /// Photos whose backup information could not be saved by THIS operation.
    /// Read it once per operation: for a copy or move from the LAST `FileOpProgress.receipt`; for
    /// Trash and Put Back from the receipt or result returned. An Undo returns its own count (`undo`);
    /// never add the two, or a photo is counted twice.
    public var backupsNotSaved = 0

    public var isEmpty: Bool { items.isEmpty }

    /// Destination files a Replace removed besides the clashing ones: other files with the same
    /// name stem (a RAW or sidecar next to the replaced JPEG), the same files `FileConflict.otherFilesReplaced`
    /// names. Counted over `items`, so a group whose Replace was rolled back, skipped
    /// or cancelled is not in it. On a volume without a Trash they are deleted (backup kept) and
    /// still counted. Read it from the LAST progress receipt, for the toast after the run.
    public var extraFilesTrashed: Int {
        items.reduce(0) { total, item in
            let own = Set(item.source.allURLs.map { $0.lastPathComponent.lowercased() })
            return total + item.replaced.filter { !own.contains($0.original.lastPathComponent.lowercased()) }.count
        }
    }
}

public enum FileOpSkipReason: Sendable, Hashable {
    /// The group is already in the destination folder (toast "… is already in …").
    case alreadyInFolder
    /// Name clash answered with Skip.
    case conflictSkipped
}

public struct FileOpSkip: Sendable, Hashable {
    public let group: ImageGroup
    public let reason: FileOpSkipReason
}

/// One step of a copy / move. The last element has `isFinished == true`.
public struct FileOpProgress: Sendable {
    /// Groups handled so far (done, skipped or failed).
    public let completed: Int
    public let total: Int
    /// Primary file name of the group being handled.
    public let currentName: String?
    public let bytesDone: Int64
    public let bytesTotal: Int64
    /// Everything done so far — valid for Undo even after a cancel.
    public let receipt: FileOpReceipt
    public let skipped: [FileOpSkip]
    public let failures: [FileOpFailure]
    public let isFinished: Bool
    /// The consuming task was cancelled; the remaining groups were not touched.
    public let wasCancelled: Bool

    public var fractionCompleted: Double {
        if bytesTotal > 0 { return Double(bytesDone) / Double(bytesTotal) }
        return total == 0 ? 1 : Double(completed) / Double(total)
    }
}

// MARK: - Conflicts

/// A name clash in the destination.
public struct FileConflict: Sendable, Hashable {
    /// The group being copied / moved.
    public let incoming: ImageGroup
    /// The destination files whose names clash, in `incoming.allURLs` order.
    public let existing: [URL]
    public let destinationFolder: URL
    /// Conflicts still waiting after this one ("Do this for the remaining 7
    /// conflicts" — show the checkbox only when > 0).
    public let remainingConflicts: Int
    /// How many of those `remainingConflicts` would, answered with Replace, also move other
    /// same-name files to the Trash (`otherFilesReplaced` is not empty for them).
    /// Read-only look-ahead made once when the first alert opens, over the destination as
    /// it is then: a later change (two incoming groups with the same stem) can make it differ by
    /// a little from what the run finally removes. Always <= `remainingConflicts`.
    public let remainingWithExtraFiles: Int

    /// For the UI's pure tests.
    package init(incoming: ImageGroup, existing: [URL], destinationFolder: URL, remainingConflicts: Int,
                 remainingWithExtraFiles: Int = 0) {
        self.incoming = incoming
        self.existing = existing
        self.destinationFolder = destinationFolder
        self.remainingConflicts = remainingConflicts
        self.remainingWithExtraFiles = min(max(0, remainingWithExtraFiles), max(0, remainingConflicts))
    }

    /// Files Replace would also move to the Trash: every other image,
    /// sidecar or movie in the destination with the same name stem as a
    /// clashing file (a RAW next to the JPEG being replaced). The conflict
    /// alert names them.
    public var otherFilesReplaced: [URL] {
        let all = FileOps.existingGroupFiles(matching: existing, in: destinationFolder)
        let clashing = Set(existing.map { $0.lastPathComponent.lowercased() })
        return all.filter { !clashing.contains($0.lastPathComponent.lowercased()) }
    }

    /// Every file Replace moves to the Trash besides the one the alert names: the other
    /// clashing files of the group (a RAW and a sidecar that clash too) and
    /// `otherFilesReplaced`. The alert lists them all, so it never says "the existing
    /// file" when more than one goes.
    public var allOtherFilesReplaced: [URL] {
        let primary = existingPrimary?.lastPathComponent.lowercased()
        let clashingOthers = existing.filter { $0.lastPathComponent.lowercased() != primary }
        return clashingOthers + otherFilesReplaced
    }

    /// The existing file that matches the incoming primary, if any.
    public var existingPrimary: URL? {
        existing.first { $0.lastPathComponent.caseInsensitiveCompare(incoming.primary.lastPathComponent) == .orderedSame }
            ?? existing.first
    }
}

public struct ConflictAnswer: Sendable, Hashable {
    public enum Action: Sendable, Hashable {
        /// Move the existing group to the Trash (after a backup), then write.
        case replace
        /// Finder-style " 2" suffix for every file of the incoming group.
        case keepBoth
        /// Leave this group where it is.
        case skip
    }
    public var action: Action
    /// "Do this for the remaining N conflicts".
    public var applyToRemaining: Bool

    public init(_ action: Action, applyToRemaining: Bool = false) {
        self.action = action
        self.applyToRemaining = applyToRemaining
    }

    public static let replace = ConflictAnswer(.replace)
    public static let keepBoth = ConflictAnswer(.keepBoth)
    public static let skip = ConflictAnswer(.skip)
}

/// How a copy / move handles a name clash.
public enum ConflictPolicy: Sendable {
    /// Ask for every clash (the UI shows the name-clash sheet; the closure may hop to
    /// the main actor). An answer with `applyToRemaining` is reused.
    case ask(@Sendable (FileConflict) async -> ConflictAnswer)
    /// Same answer for every clash, no questions.
    case always(ConflictAnswer.Action)
}

// MARK: - Change feed

public struct FileMove: Sendable, Hashable {
    public let from: URL
    public let to: URL
}

/// Published after every operation so lists update at once.
public struct FileOpsChange: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case trash, restore, deleteImmediately, copy, move, rename, undoCopy, undoMove
    }
    public let kind: Kind
    /// Paths that no longer hold a file (trash, delete, undo of a copy, and
    /// destination files Replace removed).
    public let removed: [URL]
    /// Paths that now hold a new file (copy, restore, restored Replace victims).
    public let added: [URL]
    /// Same file, new path (move, rename, undo of a move).
    public let moved: [FileMove]
}

// MARK: - FileOps

public actor FileOps {

    /// Posted on the default center after every operation. `object` is the
    /// `FileOps` instance; `userInfo[FileOps.changeKey]` is the `FileOpsChange`.
    public static let didChangeNotification = Notification.Name("ShrikeFileOpsDidChange")
    public static let changeKey = "change"

    /// How long each watcher ignores a path after Shrike touches it.
    public static let ignoreWindow: Duration = .seconds(1)

    /// BackupReason used for files Replace removes.
    static let replaceBackupReason: BackupReason = .replace

    private let metadata: MetadataStore?
    private let backups: BackupStore?
    private let watchers: (any FolderChangeSuppressing)?
    private let trashItem: @Sendable (URL) throws -> URL
    /// Test seam for the file copy (a partial write, a late "file exists").
    private let copyFile: @Sendable (URL, URL) throws -> Void
    /// Test seam: whether a move is a plain rename (same volume) or a copy + delete.
    private let sameVolume: @Sendable (URL, URL) -> Bool
    /// Test seam: removes the source of a cross-volume move.
    private let removeFile: @Sendable (URL) throws -> Void
    private let broadcaster = ChangeBroadcaster()

    /// - Parameters:
    ///   - metadata: rating / flag store; nil skips metadata transfer.
    ///   - backups: used before Replace removes a file. When nil, Replace
    ///     still trashes (so Undo works) but refuses on a volume with no Trash.
    ///   - watchers: told to ignore Shrike's own writes. Defaults to every
    ///     live `FolderWatcher`; pass nil in tests.
    public init(
        metadata: MetadataStore? = nil,
        backups: BackupStore? = nil,
        watchers: (any FolderChangeSuppressing)? = FolderWatcherRegistry.shared
    ) {
        self.init(metadata: metadata, backups: backups, watchers: watchers,
                  trashItem: FileOps.systemTrash)
    }

    /// Test seam: `trashItem` replaces `FileManager.trashItem` (e.g. to
    /// simulate a volume without a Trash).
    init(
        metadata: MetadataStore?,
        backups: BackupStore?,
        watchers: (any FolderChangeSuppressing)?,
        trashItem: @escaping @Sendable (URL) throws -> URL
    ) {
        self.init(metadata: metadata, backups: backups, watchers: watchers, trashItem: trashItem,
                  copyFile: { try FileManager.default.copyItem(at: $0, to: $1) },
                  sameVolume: FileOps.onSameVolume)
    }

    /// Test seam: `copyFile` replaces the file copy (a partial write, a late "file exists").
    init(
        metadata: MetadataStore?,
        backups: BackupStore?,
        watchers: (any FolderChangeSuppressing)?,
        trashItem: @escaping @Sendable (URL) throws -> URL,
        copyFile: @escaping @Sendable (URL, URL) throws -> Void,
        sameVolume: @escaping @Sendable (URL, URL) -> Bool
    ) {
        self.init(metadata: metadata, backups: backups, watchers: watchers, trashItem: trashItem,
                  copyFile: copyFile, sameVolume: sameVolume,
                  removeFile: { try FileManager.default.removeItem(at: $0) })
    }

    init(
        metadata: MetadataStore?,
        backups: BackupStore?,
        watchers: (any FolderChangeSuppressing)?,
        trashItem: @escaping @Sendable (URL) throws -> URL,
        copyFile: @escaping @Sendable (URL, URL) throws -> Void,
        sameVolume: @escaping @Sendable (URL, URL) -> Bool,
        removeFile: @escaping @Sendable (URL) throws -> Void
    ) {
        self.removeFile = removeFile
        self.metadata = metadata
        self.backups = backups
        self.watchers = watchers
        self.trashItem = trashItem
        self.copyFile = copyFile
        self.sameVolume = sameVolume
    }

    // MARK: Change feed

    /// A new stream of every change this instance makes. Any number of
    /// subscribers; each gets every change from the moment it subscribes.
    public nonisolated func changes() -> AsyncStream<FileOpsChange> {
        broadcaster.subscribe()
    }

    // MARK: - Trash

    /// Moves every file of each group to the Trash. Groups that fail stay
    /// put and are listed in `failures`. Throws only when no group could be
    /// trashed (so a one-item call gets a plain error, e.g. `.noTrash`).
    public func trash(_ groups: [ImageGroup]) async throws -> TrashReceipt {
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Move to Trash")
        defer { ActiveWork.shared.end(work) }
        var items: [TrashReceipt.Item] = []
        var failures: [FileOpFailure] = []
        let lost = LostBackups()
        for group in groups {
            do {
                let files = try trashGroup(group)
                items.append(.init(group: group, files: files))
            } catch {
                failures.append(.init(group: group, error: error))
            }
        }
        if items.isEmpty, let first = failures.first { throw first.error }

        for item in items {
            for file in item.files { await rekey(file.original, file.trashed, lost) }
        }
        publish(.init(kind: .trash,
                      removed: items.flatMap { $0.files.map(\.original) }, added: [], moved: []))
        var receipt = TrashReceipt(items: items, failures: failures)
        receipt.backupsNotSaved = lost.photos
        return receipt
    }

    /// Puts trashed files back at their original paths. When a name was
    /// taken meanwhile, the whole group gets the same " 2" suffix.
    /// Throws only when nothing could be restored.
    public func restore(_ receipt: TrashReceipt) async throws -> RestoreResult {
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Put Back")
        defer { ActiveWork.shared.end(work) }
        var restored: [ImageGroup] = []
        var failures: [FileOpFailure] = []
        var moves: [FileMove] = []
        let lost = LostBackups()
        for item in receipt.items {
            do {
                let (group, done) = try restoreGroup(item)
                restored.append(group)
                moves.append(contentsOf: done)
            } catch {
                failures.append(.init(group: item.group, error: error))
            }
        }
        if restored.isEmpty, let first = failures.first { throw first.error }

        for move in moves { await rekey(move.from, move.to, lost) }
        publish(.init(kind: .restore, removed: [], added: moves.map(\.to), moved: []))
        var result = RestoreResult(groups: restored, failures: failures)
        result.backupsNotSaved = lost.photos
        return result
    }

    /// Deletes every file of `group` for good. Only after the permanent-delete alert ("This
    /// volume doesn't have a Trash. Delete it now?").
    public func deleteImmediately(_ group: ImageGroup) async throws {
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Delete")
        defer { ActiveWork.shared.end(work) }
        let fm = FileManager.default
        let present = group.allURLs.filter { Self.exists($0) }
        guard !present.isEmpty else { throw FileOpsError.notFound(group.primary) }
        suppress(present)
        var removed: [URL] = []
        var firstError: FileOpsError?
        for url in present {
            do {
                try fm.removeItem(at: url)
                removed.append(url)
            } catch {
                if firstError == nil { firstError = Self.map(error, url: url) }
            }
        }
        if !removed.isEmpty {
            publish(.init(kind: .deleteImmediately, removed: removed, added: [], moved: []))
        }
        if let firstError { throw firstError }
    }

    // MARK: - Copy / move

    /// Copies each group (all its files) into `folder`.
    public nonisolated func copy(
        _ groups: [ImageGroup], to folder: URL, conflicts: ConflictPolicy, stop: TransferStop? = nil
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        stream(.copy, groups, folder, conflicts, stop)
    }

    /// Moves each group (all its files) into `folder`. Same-volume moves
    /// are renames; cross-volume moves copy then delete (FileManager).
    public nonisolated func move(
        _ groups: [ImageGroup], to folder: URL, conflicts: ConflictPolicy, stop: TransferStop? = nil
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        stream(.move, groups, folder, conflicts, stop)
    }

    /// Reverts a copy (the copies go to the Trash) or a move (the files go
    /// back to where they were), then puts back what Replace removed.
    /// Best effort over every item; throws the first problem, e.g.
    /// `.destinationUnavailable(originalFolder)` or `.notFound(trashedFile)`.
    /// Returns how many photos' backup information could not be saved by this Undo;
    /// 0 = all good. It is the Undo's own count: do not add it to the receipt's `backupsNotSaved`.
    public func undo(_ receipt: FileOpReceipt) async throws -> Int {
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Undo")
        defer { ActiveWork.shared.end(work) }
        let lost = LostBackups()
        var firstError: FileOpsError?
        var removed: [URL] = []
        var added: [URL] = []
        var moved: [FileMove] = []

        for item in receipt.items.reversed() {
            do {
                switch receipt.kind {
                case .copy:
                    let copies = item.result.allURLs.filter { Self.exists($0) }
                    suppress(copies)
                    for url in copies {
                        if let trashed = try? trashItem(url) {
                            await rekey(url, trashed, lost)
                        } else {
                            // No Trash here, so removing is permanent: only delete the
                            // very file the copy made (same inode, size and time). A
                            // different or edited file with that name stays.
                            guard let stamp = item.stamps[url], FileStamp(of: url) == stamp else {
                                if firstError == nil {
                                    firstError = .io(url, reason: "It changed after it was copied, so it was left in place.")
                                }
                                continue
                            }
                            do { try FileManager.default.removeItem(at: url) } catch {
                                throw Self.map(error, url: url)
                            }
                        }
                        removed.append(url)
                    }
                case .move:
                    let back = try moveBack(item)
                    for m in back { await rekey(m.from, m.to, lost) }
                    moved.append(contentsOf: back)
                }
            } catch let error as FileOpsError {
                if firstError == nil { firstError = error }
                continue
            }
            do {
                added.append(contentsOf: try await putBack(item.replaced, lost))
            } catch let error as FileOpsError {
                if firstError == nil { firstError = error }
            }
        }

        publish(.init(kind: receipt.kind == .copy ? .undoCopy : .undoMove,
                      removed: removed, added: added, moved: moved))
        if let firstError { throw firstError }
        return lost.photos
    }

    // MARK: - Rename

    /// Checks a new stem for `group`. Synchronous and
    /// cheap: call it on every keystroke. The extension is never part of
    /// the input — it can't be changed here.
    public nonisolated func validate(stem: String, for group: ImageGroup) -> RenameValidation {
        Self.validate(stem: stem, for: group)
    }

    /// Renames every file of `group` to `toStem` + its own extension. Any
    /// failure puts the already-renamed files back and throws. A case-only
    /// change is done in two steps. Returns the renamed group. Undo is a
    /// rename back to the old stem.
    public func rename(_ group: ImageGroup, toStem newStem: String) async throws -> ImageGroup {
        try await renameReporting(group, toStem: newStem).group
    }

    /// Puts a group back to a name it HAD before (Undo of a rename, put-back after a failed Batch
    /// rename). The name already exists on disk as a real name, so the shape rules that police what
    /// a user types (a leading ".", a space or period at the end, a line break) do not apply. The
    /// rules the file system itself cannot take still do: an empty name, "/" and NUL; so do
    /// "name taken" and "too long".
    public func rename(_ group: ImageGroup, backToEarlierStem earlierStem: String) async throws -> ImageGroup {
        // Only a name this file really had: typed text can never pass through here.
        guard earlierStems[Self.canonicalPath(group.primary)]?.contains(earlierStem) == true else {
            throw FileOpsError.invalidName(.notAnEarlierName)
        }
        return try await renameCore(group, toStem: earlierStem, relaxed: true).group
    }

    /// Like `rename(_:toStem:)`, and says how many photos' backup information could not be saved
    /// (`backupsNotSaved`: for THIS rename only).
    public func renameReporting(_ group: ImageGroup, toStem newStem: String) async throws -> RenameResult {
        try await renameCore(group, toStem: newStem, relaxed: false)
    }

    /// For Shrike's own renames inside the package (Batch moving a photo aside, putting it back,
    /// Batch Undo): same relaxed rules as `rename(_:backToEarlierStem:)`; `relaxed: false` is the
    /// strict path.
    package func renameReporting(_ group: ImageGroup, toStem newStem: String, relaxed: Bool) async throws -> RenameResult {
        try await renameCore(group, toStem: newStem, relaxed: relaxed, remember: false)
    }

    /// Undo of a rename from its own result: back to `result.earlierStem` with the relaxed rules, no
    /// memory needed.
    public func undoRename(_ result: RenameResult) async throws -> RenameResult {
        try await renameCore(result.group, toStem: result.earlierStem, relaxed: true, remember: false)
    }

    /// The names this instance renamed files away from by hand, by the canonical path of the renamed
    /// primary. A plain `rename` back to exactly that stem is an Undo and takes the relaxed rules,
    /// so the viewer's and browser's Undo need no special call. No size limit: it grows
    /// only with the user's own renames (Batch and recovery do not remember), and no file may be
    /// un-undoable because of a cache size.
    private var earlierStems: [String: Set<String>] = [:]

    private func rememberEarlierStem(_ oldStem: String, for renamedPrimary: URL) {
        let key = Self.canonicalPath(renamedPrimary)
        // A SET: after a -> b -> c, the file at b.jpg came from "a" and, by the first Undo, is
        // also the target of "c" going back; both Undos must stay accepted.
        earlierStems[key, default: []].insert(oldStem)
    }

    private func renameCore(_ group: ImageGroup, toStem newStem: String, relaxed: Bool, remember: Bool = true) async throws -> RenameResult {
        let lost = LostBackups()
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Rename")
        defer { ActiveWork.shared.end(work) }
        let isUndo = earlierStems[Self.canonicalPath(group.primary)]?.contains(newStem) == true
        let validation = Self.validate(stem: newStem, for: group, checkFormat: !(relaxed || isUndo))
        guard validation == .valid else { throw FileOpsError.invalidName(validation) }

        let oldStem = Self.stem(of: group)
        let pairs = group.allURLs.map { url in
            FileMove(from: url, to: url.deletingLastPathComponent()
                .appendingPathComponent(Self.renamed(url.lastPathComponent, oldStem: oldStem, newStem: newStem)))
        }.filter { Self.exists($0.from) }
        guard !pairs.isEmpty else { throw FileOpsError.notFound(group.primary) }

        suppress(pairs.flatMap { [$0.from, $0.to] })
        var done: [FileMove] = []
        for pair in pairs {
            do {
                try Self.moveFile(from: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                for d in done.reversed() { try? Self.moveFile(from: d.to, to: d.from) }
                throw Self.map(error, url: pair.from)
            }
        }
        for pair in done { await rekey(pair.from, pair.to, lost) }
        publish(.init(kind: .rename, removed: [], added: [], moved: done))

        let map = Dictionary(uniqueKeysWithValues: done.map { ($0.from, $0.to) })
        let renamedGroup = Self.mapGroup(group) { map[$0] ?? $0.deletingLastPathComponent()
            .appendingPathComponent(Self.renamed($0.lastPathComponent, oldStem: oldStem, newStem: newStem)) }
        if remember { rememberEarlierStem(oldStem, for: renamedGroup.primary) }
        return RenameResult(group: renamedGroup, earlierStem: oldStem, backupsNotSaved: lost.photos)
    }

    // MARK: - Recovery after a crash

    /// Call once per launch, after the services exist and off the launch path (the slot of the 10 s
    /// backup clean-up). Puts photos that a cut-off rename left under a temporary name back under
    /// their old name AND moves their backup chain, its guards and their metadata with them, with the
    /// same bookkeeping a normal rename does. A photo whose old name is taken again stays
    /// where it is and is listed in `needsAttention` (its chain is filed under the temporary path,
    /// where its file is, so nothing is lost); the journal entry stays until it is solved or
    /// `RenameJournal.shared.dismiss(_:)`. An entry is ended only after its bookkeeping moved, so a
    /// crash between the rename back and the bookkeeping is finished at the next launch.
    public func recoverRenames() async -> RenameRecovery {
        await recoverRenames(journal: .shared, startedBefore: RenameJournal.processStart)
    }

    /// The photo is no longer under `temp`, but its history (backup chain, rating) may still be filed
    /// there. Gives it to the file at `final` or at `original` ONLY when that file has no history of
    /// its own and the chain's stamp proves it is the same photo; otherwise nothing at the candidate is
    /// touched, the chain is put aside under the retention clock and counted in `historyNotRestored`.
    /// A rating with no chain has no proof either, so it stays at the temp path (an orphan row,
    /// harmless). With no stamp there is no proof: when in doubt, do not attach.
    private func settleOrphanedHistory(temp: URL, original: URL, final: URL?, _ lost: LostBackups,
                                       _ report: inout RenameRecovery) async {
        let hasChain: Bool = if let backups { await !backups.records(for: temp).isEmpty } else { false }
        let hasRating: Bool = if let metadata { await Self.hasRow(metadata, temp) } else { false }
        guard hasChain || hasRating else { return }                      // nothing is filed there: done
        var maybeAlive: URL?            // the first candidate whose file may be the photo (proof or no proof)
        for candidate in [final, original].compactMap({ $0 }) where Self.exists(candidate) {
            let stamp: Bool? = if hasChain, let backups { await backups.chainStampMatches(chainAt: temp, file: candidate) } else { nil }
            if stamp == false { continue }                                  // proof of a different photo
            if stamp == true, hasChain, let backups,
               await backups.records(for: candidate).isEmpty,
               await !hasMetadataRow(candidate) {
                await rekey(temp, candidate, lost)                           // proven, and nothing of its own there
                return
            }
            if maybeAlive == nil { maybeAlive = candidate }
        }
        if hasChain, let backups {
            // No proof and the photo may be alive at a candidate (every chain written by 0.2.32 has no
            // stamp): guard the history by that path, so it stays as long as a file is there and follows
            // the path through later renames. Nothing is attached, the candidate's own history, Revert and
            // metadata are untouched. Only when no candidate can be the photo, the clock.
            let parked = if let maybeAlive { await backups.detach(chainAt: temp, guarding: maybeAlive) }
                         else { await backups.parkWithClock(chainAt: temp) }
            if parked.failed > 0 { lost.photos += 1 }
        }
        report.historyNotRestored += 1
    }

    private func hasMetadataRow(_ url: URL) async -> Bool {
        guard let metadata else { return false }
        return await Self.hasRow(metadata, url)
    }

    private static func hasRow(_ metadata: MetadataStore, _ url: URL) async -> Bool {
        guard let record = await metadata.records(for: [url])[url] else { return false }
        return record.rating != 0 || record.flagged
    }

    func recoverRenames(journal: RenameJournal, startedBefore: Date) async -> RenameRecovery {
        let work = ActiveWork.shared.begin(kind: .transfer, detail: "Recovering renames")
        defer { ActiveWork.shared.end(work) }
        let lost = LostBackups()
        var report = RenameRecovery()
        var restoredMoves: [FileMove] = []
        for entry in journal.eligibleEntries(startedBefore: startedBefore) {
            var open = false
            for move in entry.moves {
                let temp = URL(fileURLWithPath: move.temporary), original = URL(fileURLWithPath: move.original)
                if Self.exists(temp) {
                    if !Self.exists(original) {
                        suppress([temp, original])
                        if (try? Self.renameExclusive(from: temp, to: original)) != nil {
                            await rekey(temp, original, lost)      // the same bookkeeping as renameCore
                            report.restored.append(original)
                            restoredMoves.append(FileMove(from: temp, to: original))
                            continue
                        }
                    }
                    report.needsAttention.append((entry.id, original, temp))
                    open = true
                } else if Self.isDirectory(temp.deletingLastPathComponent()) {
                    // Nothing under the temp name. A crash may have come between the rename back and
                    // the bookkeeping, but the file at the old name can also be a DIFFERENT photo (Batch
                    // moves a photo aside because another photo takes its name). History is attached only
                    // with proof.
                    await settleOrphanedHistory(temp: temp, original: original,
                                                final: move.final.map { URL(fileURLWithPath: $0) }, lost, &report)
                } else {
                    open = true                                     // an unplugged disk: keep the entry
                }
            }
            if !open { journal.end(entry.id) }
        }
        publish(.init(kind: .rename, removed: [], added: [], moved: restoredMoves))
        report.backupsNotSaved = lost.photos
        return report
    }

    // MARK: - Trash internals

    private func trashGroup(_ group: ImageGroup) throws(FileOpsError) -> [TrashedFile] {
        let present = group.allURLs.filter { Self.exists($0) }
        guard !present.isEmpty else { throw .notFound(group.primary) }
        if Self.isReadOnlyVolume(present[0]) { throw .readOnlyVolume(present[0]) }

        suppress(present)
        var done: [TrashedFile] = []
        for url in present {
            do {
                let trashed = try trashItem(url)
                done.append(TrashedFile(original: url, trashed: trashed))
            } catch {
                // All or nothing per group: put back what already went.
                for file in done.reversed() {
                    try? FileManager.default.moveItem(at: file.trashed, to: file.original)
                }
                throw Self.map(error, url: url, trashing: true)
            }
        }
        return done
    }

    private func restoreGroup(_ item: TrashReceipt.Item) throws(FileOpsError) -> (ImageGroup, [FileMove]) {
        guard let first = item.files.first else { throw .notFound(item.group.primary) }
        if let gone = item.files.first(where: { !Self.exists($0.trashed) }) {
            throw .notFound(gone.original)
        }
        let folder = first.original.deletingLastPathComponent()
        guard Self.isDirectory(folder) else { throw .destinationUnavailable(folder) }

        let names = item.files.map(\.original.lastPathComponent)
        let stem = Self.stem(of: item.group)
        let targetNames = Self.freeNames(for: names, stem: stem, in: folder)
        let pairs = zip(item.files, targetNames).map {
            FileMove(from: $0.trashed, to: folder.appendingPathComponent($1))
        }
        suppress(pairs.map(\.to))
        var done: [FileMove] = []
        for pair in pairs {
            do {
                try FileManager.default.moveItem(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                for d in done.reversed() { try? FileManager.default.moveItem(at: d.to, to: d.from) }
                throw Self.map(error, url: pair.to)
            }
        }
        let originals = Dictionary(uniqueKeysWithValues: zip(item.files.map(\.original), pairs.map(\.to)))
        let group = Self.mapGroup(item.group) { originals[$0] ?? $0 }
        return (group, done)
    }

    // MARK: - Copy / move internals

    private nonisolated func stream(
        _ kind: FileOpReceipt.Kind, _ groups: [ImageGroup], _ folder: URL, _ policy: ConflictPolicy,
        _ stop: TransferStop?
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        AsyncThrowingStream { continuation in
            // Opened here, before the task starts, so there is no gap; closed when the task ends.
            let work = ActiveWork.shared.begin(
                kind: .transfer, detail: (kind == .copy ? "Copy " : "Move ") + "\(groups.count) photo(s)")
            let task = Task {
                defer { ActiveWork.shared.end(work) }
                do {
                    try await self.transfer(kind, groups, folder, policy, stop) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func transfer(
        _ kind: FileOpReceipt.Kind,
        _ groups: [ImageGroup],
        _ folderIn: URL,
        _ policy: ConflictPolicy,
        _ stop: TransferStop?,
        yield: @Sendable (FileOpProgress) -> Void
    ) async throws {
        let folder = folderIn.standardizedFileURL
        guard Self.isDirectory(folder) else { throw FileOpsError.destinationUnavailable(folderIn) }
        if Self.isReadOnlyVolume(folder) { throw FileOpsError.readOnlyVolume(folderIn) }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw FileOpsError.permissionDenied(folderIn)
        }

        // Pre-pass: sizes and which groups clash (for "remaining N").
        let sizes = groups.map { $0.allURLs.reduce(Int64(0)) { $0 + Self.fileSize($1) } }
        let bytesTotal = sizes.reduce(0, +)
        let destPath = Self.canonicalPath(folder)
        let clashing: [Bool] = groups.map { group in
            Self.canonicalPath(group.primary.deletingLastPathComponent()) != destPath
                && group.allURLs.contains { Self.exists(folder.appendingPathComponent($0.lastPathComponent)) }
        }
        var pendingConflicts = clashing.filter { $0 }.count

        let lost = LostBackups()
        var items: [FileOpReceipt.Item] = []
        var skipped: [FileOpSkip] = []
        var failures: [FileOpFailure] = []
        var bytesDone: Int64 = 0
        var sticky: ConflictAnswer.Action?
        var removedByReplace: [URL] = []
        var cancelled = false
        var extrasAhead: [Int]?
        /// Indexes after `from` of clashing groups that Replace would take extra files for.
        /// One directory listing; nothing is written.
        func lookAheadExtras(after from: Int) -> [Int] {
            // One listing and one index (stem key -> lower-cased names), so the cost is linear in
            // the folder, not clashes x files. Same rule as `existingGroupFiles`.
            var index: [String: [String]] = [:]
            for entry in (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
            where ImageFormat.isFolderScanCandidate(entry) {
                index[Self.groupKey(entry.lastPathComponent), default: []].append(entry.lastPathComponent.lowercased())
            }
            var result: [Int] = []
            for j in groups.indices where j > from && clashing[j] {
                let clashes = groups[j].allURLs.map { folder.appendingPathComponent($0.lastPathComponent) }
                    .filter { Self.exists($0) }
                guard !clashes.isEmpty else { continue }
                let own = Set(clashes.map { $0.lastPathComponent.lowercased() })
                let keys = Set(clashes.map { Self.groupKey($0.lastPathComponent) })
                if keys.contains(where: { key in (index[key] ?? []).contains { !own.contains($0) } }) {
                    result.append(j)
                }
            }
            return result
        }
        func stopRequested() -> Bool { Task.isCancelled || stop?.isStopped == true }

        func progress(_ completed: Int, current: String?, finished: Bool) -> FileOpProgress {
            var receipt = FileOpReceipt(kind: kind, destination: folder, items: items)
            receipt.backupsNotSaved = lost.photos
            return FileOpProgress(
                completed: completed, total: groups.count, currentName: current,
                bytesDone: bytesDone, bytesTotal: bytesTotal,
                receipt: receipt,
                skipped: skipped, failures: failures,
                isFinished: finished, wasCancelled: cancelled)
        }

        yield(progress(0, current: groups.first?.primary.lastPathComponent, finished: false))

        for (index, group) in groups.enumerated() {
            if stopRequested() { cancelled = true; break }
            #if DEBUG
            let debugDelay = Self.debugPerFileDelay.withLock { $0 }
            if debugDelay > 0 {
                try? await Task.sleep(for: .seconds(debugDelay))
                if stopRequested() { cancelled = true; break }
            }
            #endif
            defer { bytesDone += sizes[index] }

            if Self.canonicalPath(group.primary.deletingLastPathComponent()) == destPath {
                skipped.append(.init(group: group, reason: .alreadyInFolder))
                yield(progress(index + 1, current: group.primary.lastPathComponent, finished: false))
                continue
            }

            var targets = group.allURLs.map { folder.appendingPathComponent($0.lastPathComponent) }
            var replaced: [ReplacedFile] = []
            let clashes = targets.filter { Self.exists($0) }

            if !clashes.isEmpty {
                pendingConflicts -= 1
                let action: ConflictAnswer.Action
                if let sticky {
                    action = sticky
                } else {
                    switch policy {
                    case .always(let a):
                        action = a
                    case .ask(let resolve):
                        var withExtras = 0
                        if pendingConflicts > 0 {
                            // Read-only look-ahead for the alert, once per run.
                            if extrasAhead == nil { extrasAhead = lookAheadExtras(after: index) }
                            withExtras = (extrasAhead ?? []).filter { $0 > index }.count
                        }
                        let answer = await resolve(FileConflict(
                            incoming: group, existing: clashes, destinationFolder: folder,
                            remainingConflicts: max(0, pendingConflicts),
                            remainingWithExtraFiles: withExtras))
                        action = answer.action
                        if answer.applyToRemaining { sticky = answer.action }
                    }
                }
                if stopRequested() { cancelled = true; break }

                switch action {
                case .skip:
                    skipped.append(.init(group: group, reason: .conflictSkipped))
                    yield(progress(index + 1, current: group.primary.lastPathComponent, finished: false))
                    continue
                case .keepBoth:
                    let names = Self.freeNames(for: group.allURLs.map(\.lastPathComponent),
                                               stem: Self.stem(of: group), in: folder)
                    targets = names.map { folder.appendingPathComponent($0) }
                case .replace:
                    do {
                        replaced = try await clearForReplace(clashes, in: folder, lost)
                        removedByReplace.append(contentsOf: replaced.map(\.original))
                    } catch let error as FileOpsError {
                        failures.append(.init(group: group, error: error))
                        yield(progress(index + 1, current: group.primary.lastPathComponent, finished: false))
                        continue
                    }
                }
            }

            do {
                let pairs = try transferGroup(kind, group, to: targets)
                for pair in pairs {
                    switch kind {
                    case .copy: await copyMetadata(pair.from, pair.to)
                    case .move: await rekey(pair.from, pair.to, lost)
                    }
                }
                let map = Dictionary(uniqueKeysWithValues: pairs.map { ($0.from, $0.to) })
                var stamps: [URL: FileStamp] = [:]
                if kind == .copy { for pair in pairs { stamps[pair.to] = FileStamp(of: pair.to) } }
                items.append(.init(source: group,
                                   result: Self.mapGroup(group) { map[$0] ?? $0 },
                                   replaced: replaced, stamps: stamps))
            } catch {
                // Nothing of this group landed: give the replaced files back.
                _ = try? await putBack(replaced, lost)
                removedByReplace.removeAll { url in replaced.contains { $0.original == url } }
                failures.append(.init(group: group, error: error))
            }
            yield(progress(index + 1, current: group.primary.lastPathComponent, finished: false))
        }
        let doneCount = items.count + skipped.count + failures.count
        // A stop that lands after the last group changed nothing: not "cancelled".
        if stopRequested(), doneCount < groups.count { cancelled = true }
        yield(progress(doneCount, current: nil, finished: true))

        let pairs = items.flatMap { item in zip(item.source.allURLs, item.result.allURLs).map { FileMove(from: $0, to: $1) } }
        switch kind {
        case .copy:
            publish(.init(kind: .copy, removed: removedByReplace, added: pairs.map(\.to), moved: []))
        case .move:
            publish(.init(kind: .move, removed: removedByReplace, added: [], moved: pairs))
        }
    }

    /// Copies or moves every file of `group` to `targets` (same order as
    /// `allURLs`). All or nothing: on failure the files already handled are
    /// removed (copy) or moved back (move).
    private func transferGroup(
        _ kind: FileOpReceipt.Kind, _ group: ImageGroup, to targets: [URL]
    ) throws(FileOpsError) -> [FileMove] {
        let fm = FileManager.default
        let pairs = zip(group.allURLs, targets)
            .map { FileMove(from: $0, to: $1) }
            .filter { Self.exists($0.from) }
        guard !pairs.isEmpty else { throw .notFound(group.primary) }

        if let first = pairs.first { TemporaryFileSweeper.sweep(in: first.to.deletingLastPathComponent()) }
        var done: [FileMove] = []
        for pair in pairs {
            suppress([pair.from, pair.to])
            do {
                try transferFile(kind, from: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                for d in done.reversed() {
                    switch kind {
                    case .copy: try? fm.removeItem(at: d.to)
                    case .move: try? transferFile(.move, from: d.to, to: d.from)
                    }
                }
                // transferFile has removed its own temp. A file already at the final name is not ours
                // and the source is never touched on failure.
                throw Self.map(error, url: pair.from)
            }
        }
        return done
    }

    /// Copies `from` to `to`, or moves it. A copy and a move across volumes write to a hidden temp
    /// name in the destination folder and rename it into place, exclusively; a
    /// same-volume move is a plain rename. Used by every path that can cross volumes: the transfer,
    /// its rollback and Undo of a move. On failure only the temp file is removed.
    private func transferFile(_ kind: FileOpReceipt.Kind, from: URL, to: URL) throws {
        let fm = FileManager.default
        guard kind == .copy || !sameVolume(from, to.deletingLastPathComponent()) else {
            try fm.moveItem(at: from, to: to)
            return
        }
        let temp = Self.transferTempURL(for: to)
        do {
            suppress([temp])
            try copyFile(from, temp)
            suppress([temp, to])
            try Self.renameExclusive(from: temp, to: to)     // never overwrites
            if kind == .move {
                do { try removeFile(from) } catch {
                    // On a network disk the unlink can succeed and still report an error. Only when the
                    // source is really still there is the move undone; otherwise the new copy is the
                    // only one and it stays.
                    if Self.exists(from) {
                        try? fm.removeItem(at: to)
                        throw error
                    }
                }
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Replace: back up, then trash, every file of the destination group(s)
    /// that clash. On a volume without a Trash the file is deleted, but only
    /// when a backup exists. All or nothing.
    private func clearForReplace(_ clashes: [URL], in folder: URL, _ lost: LostBackups) async throws -> [ReplacedFile] {
        let victims = Self.existingGroupFiles(matching: clashes, in: folder)
        var done: [ReplacedFile] = []
        do {
            for url in victims {
                var record: BackupRecord?
                if let backups {
                    do {
                        record = try await backups.backup(url, reason: Self.replaceBackupReason)
                    } catch {
                        throw FileOpsError.backupFailed(url, reason: "\(error)")
                    }
                }
                suppress([url])
                do {
                    let trashed = try trashItem(url)
                    await rekey(url, trashed, lost)
                    done.append(ReplacedFile(original: url, trashed: trashed, backup: record))
                } catch {
                    let mapped = Self.map(error, url: url, trashing: true)
                    guard case .noTrash = mapped, record != nil else { throw mapped }
                    do { try FileManager.default.removeItem(at: url) } catch {
                        throw Self.map(error, url: url)
                    }
                    // The old photo is gone and no Trash holds it: its backup chain must follow
                    // the old photo, not the path. Otherwise "Revert to Original" on the new
                    // file at this path would bring the replaced photo back (same as
                    // `ImageExporter` step 5b).
                    var detached: URL?
                    if record != nil, let backups {
                        // Put aside with a clock and the real path: its older records are
                        // kept while the new photo sits there. Undo's rekey back clears both marks.
                        let aside = await backups.detachForReplace(chainAt: url)
                        detached = aside.aside
                        if aside.failed > 0 { lost.photos += 1 }
                    }
                    done.append(ReplacedFile(original: url, trashed: nil, backup: record, chainMovedTo: detached))
                }
            }
        } catch let error as FileOpsError {
            _ = try? await putBack(done, lost)
            throw error
        }
        return done
    }

    /// Puts Replace victims back (from the Trash, else from BackupStore).
    /// Returns the restored paths.
    private func putBack(_ replaced: [ReplacedFile], _ lost: LostBackups) async throws -> [URL] {
        var restored: [URL] = []
        var firstError: FileOpsError?
        for file in replaced.reversed() {
            if Self.exists(file.original) {
                if firstError == nil { firstError = .nameTaken(file.original) }
                continue
            }
            suppress([file.original])
            if let trashed = file.trashed, Self.exists(trashed) {
                do {
                    try FileManager.default.moveItem(at: trashed, to: file.original)
                    await rekey(trashed, file.original, lost)
                    restored.append(file.original)
                    continue
                } catch {
                    if file.backup == nil {
                        if firstError == nil { firstError = Self.map(error, url: file.original) }
                        continue
                    }
                }
            }
            if let record = file.backup, let backups {
                do {
                    // The victim's parked chain goes back to its path BEFORE the bytes do, so the safety
                    // copy of whatever replaced it joins that chain instead of starting a new one.
                    if let away = file.chainMovedTo { if await backups.rekey(from: away, to: file.original) > 0 { lost.photos += 1 } }
                    if try await backups.restoreReporting(record).notSaved > 0 { lost.photos += 1 }
                    if let trashed = file.trashed, await backups.rekey(from: trashed, to: file.original) > 0 { lost.photos += 1 }
                    restored.append(file.original)
                } catch {
                    if firstError == nil { firstError = .io(file.original, reason: "\(error)") }
                }
            } else if firstError == nil {
                firstError = .notFound(file.trashed ?? file.original)
            }
        }
        if let firstError { throw firstError }
        return restored
    }

    /// Undo of a move: every file of `item.result` goes back to the source
    /// folder (" 2" suffix for the group if a name was taken meanwhile).
    private func moveBack(_ item: FileOpReceipt.Item) throws(FileOpsError) -> [FileMove] {
        let sourceFolder = item.source.primary.deletingLastPathComponent()
        guard Self.isDirectory(sourceFolder) else { throw .destinationUnavailable(sourceFolder) }
        let present = zip(item.result.allURLs, item.source.allURLs).filter { Self.exists($0.0) }
        guard !present.isEmpty else { throw .notFound(item.result.primary) }
        let names = Self.freeNames(for: present.map(\.1.lastPathComponent),
                                   stem: Self.stem(of: item.source), in: sourceFolder)
        let pairs = zip(present, names).map {
            FileMove(from: $0.0, to: sourceFolder.appendingPathComponent($1))
        }
        suppress(pairs.flatMap { [$0.from, $0.to] })
        var done: [FileMove] = []
        for pair in pairs {
            do {
                try transferFile(.move, from: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                for d in done.reversed() { try? transferFile(.move, from: d.to, to: d.from) }
                throw Self.map(error, url: pair.from)
            }
        }
        return done
    }

    /// `.name.shriketransfer.<uuid>` next to the final name. The extension is the UUID, so no
    /// folder scan or viewer takes it for a photo.
    static func transferTempURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(
            TemporaryFileSweeper.hiddenTempName(for: target.lastPathComponent, marker: "shriketransfer"))
    }

    /// Renames `from` to `to` and fails with EEXIST when `to` exists, in ONE system call
    /// (`renamex_np` with `RENAME_EXCL`), so a file that appears in between is never overwritten.
    /// Where the volume has no such call, falls back to check-then-rename.
    static func renameExclusive(
        from: URL, to: URL,
        syscall: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) },
        betweenCheckAndMove: () -> Void = {}
    ) throws {
        if syscall(from.path, to.path) == 0 { return }
        let code = errno
        if code == ENOTSUP || code == EINVAL {
            if exists(to) { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)) }
            betweenCheckAndMove()
            try FileManager.default.moveItem(at: from, to: to)
            return
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                      userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }

    /// True when `file` and `folder` are on one volume (unknown counts as "different").
    @Sendable static func onSameVolume(_ file: URL, _ folder: URL) -> Bool {
        let a = try? file.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let b = try? folder.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let a, let b else { return false }
        return a.isEqual(b)
    }

    // MARK: - Side effects

    private func suppress(_ urls: [URL]) {
        guard let watchers, !urls.isEmpty else { return }
        watchers.ignore(paths: urls, for: Self.ignoreWindow)
    }

    /// The file moved (trash, untrash, move, move undo, rename, Replace):
    /// its rating / flag record AND its backup chain follow it,
    /// so Revert to Original still finds the true original, and a Replace
    /// victim's chain goes to the Trash with it instead of being merged into
    /// the arriving file's chain.
    private func rekey(_ from: URL, _ to: URL, _ lost: LostBackups) async {
        guard from != to else { return }
        if let metadata { try? await metadata.transfer(from: from, to: to, mode: .move) }
        if let backups, await backups.rekey(from: from, to: to) > 0 { lost.photos += 1 }
    }

    private func copyMetadata(_ from: URL, _ to: URL) async {
        guard let metadata else { return }
        try? await metadata.transfer(from: from, to: to, mode: .copy)
    }

    private func publish(_ change: FileOpsChange) {
        guard !(change.removed.isEmpty && change.added.isEmpty && change.moved.isEmpty) else { return }
        broadcaster.send(change)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                                        userInfo: [Self.changeKey: change])
    }

    // MARK: - Helpers (static, pure or read-only)

    /// The rules for the SHAPE of a name, in the order they are checked. nil = the shape is fine.
    /// Also used by Batch on the filled template, so preview and run agree.
    public static func nameProblem(_ stem: String) -> RenameValidation? {
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if stem.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.value == 0x2028 || $0.value == 0x2029 }) {
            return .controlCharacters
        }
        if stem.contains("/") || stem.contains(":") { return .invalidCharacters }
        if stem.hasPrefix(".") { return .hidden }
        if stem.first?.isWhitespace == true || stem.last?.isWhitespace == true { return .edgeSpace }
        if stem.hasSuffix(".") { return .trailingDot }
        return nil
    }

    static func validate(stem: String, for group: ImageGroup, checkFormat: Bool = true) -> RenameValidation {
        if checkFormat {
            if let problem = nameProblem(stem) { return problem }
        } else {
            // Relaxed (Shrike's own rename back to a real earlier name): only what the file system
            // cannot take is refused.
            if stem.isEmpty { return .empty }
            // ":" is allowed here: a real name may contain it (Finder shows "/"), and a rename back
            // to it must work.
            if stem.contains("/") { return .invalidCharacters }
            if stem.unicodeScalars.contains(where: { $0.value == 0 }) { return .controlCharacters }
        }
        let oldStem = Self.stem(of: group)
        if stem == oldStem { return .unchanged }

        for url in group.allURLs {
            let newName = renamed(url.lastPathComponent, oldStem: oldStem, newStem: stem)
            if newName.utf8.count > 255 { return .tooLong }
        }
        for url in group.allURLs {
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(renamed(url.lastPathComponent, oldStem: oldStem, newStem: stem))
            // A case-only change finds the file itself on a case-insensitive volume.
            if exists(target), !sameFile(target, url) { return .nameTaken(target) }
        }
        return .valid
    }

    /// Where the files of `group` will be after `rename(group, toStem:)` (same order as `allURLs`).
    public static func renamedURLs(of group: ImageGroup, toStem newStem: String) -> [URL] {
        let oldStem = stem(of: group)
        return group.allURLs.map {
            $0.deletingLastPathComponent().appendingPathComponent(renamed($0.lastPathComponent, oldStem: oldStem, newStem: newStem))
        }
    }

    /// The group's stem: the primary's name without its extension.
    static func stem(of group: ImageGroup) -> String {
        group.primary.deletingPathExtension().lastPathComponent
    }

    /// `name` with `oldStem` swapped for `newStem`, keeping everything
    /// after it (".JPG", ".CR3.xmp"). A name that doesn't start with the
    /// stem keeps its own extension.
    static func renamed(_ name: String, oldStem: String, newStem: String) -> String {
        let lowerName = name.lowercased()
        let lowerStem = oldStem.lowercased()
        if lowerName.hasPrefix(lowerStem + ".") || lowerName == lowerStem {
            return newStem + String(name.dropFirst(oldStem.count))
        }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? newStem : newStem + "." + ext
    }

    /// Names for `names` inside `folder` that are all free: unchanged if
    /// none is taken, else the smallest Finder suffix " n" (n ≥ 2, or one
    /// more than a trailing " n" already in the stem) free for all of them.
    static func freeNames(for names: [String], stem: String, in folder: URL) -> [String] {
        freeNames(for: names, stem: stem, in: folder) { exists($0) }
    }

    /// Same Finder " n" rule, with the caller deciding what is taken (Batch
    /// also counts names claimed by earlier items of the same run).
    public static func freeNames(for names: [String], stem: String, in folder: URL,
                                 isTaken: (URL) -> Bool) -> [String] {
        let exists = isTaken
        if !names.contains(where: { exists(folder.appendingPathComponent($0)) }) { return names }
        var base = stem
        var n = 2
        if let space = stem.lastIndex(of: " "),
           let number = Int(stem[stem.index(after: space)...]), number >= 1,
           stem[stem.index(after: space)...].allSatisfy(\.isASCII) {
            base = String(stem[..<space])
            n = number + 1
        }
        while true {
            let candidate = "\(base) \(n)"
            let renamedNames = names.map { renamed($0, oldStem: stem, newStem: candidate) }
            if !renamedNames.contains(where: { exists(folder.appendingPathComponent($0)) }) {
                return renamedNames
            }
            n += 1
        }
    }

    /// The name stem that ties files of one shot together (case-insensitive; `IMG_1.CR3.xmp` -> `img_1`).
    static func groupKey(_ name: String) -> String {
        var n = (name as NSString).deletingPathExtension
        let inner = (n as NSString).pathExtension
        if !inner.isEmpty, ImageFormat.isSupported(extension: inner) {
            n = (n as NSString).deletingPathExtension   // IMG_1.CR3.xmp
        }
        return n.lowercased()
    }

    /// Destination files that belong to the same shot as any clash: every
    /// image / sidecar / movie in `folder` whose stem matches a clashing
    /// file's stem (case-insensitive). Clashes come first.
    static func existingGroupFiles(matching clashes: [URL], in folder: URL) -> [URL] {
        let key = groupKey
        let keys = Set(clashes.map { key($0.lastPathComponent) })
        var result = clashes
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = entry.lastPathComponent
            guard ImageFormat.isFolderScanCandidate(entry), keys.contains(key(name)),
                  !result.contains(where: { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            result.append(folder.appendingPathComponent(name))
        }
        return result
    }

    static func mapGroup(_ group: ImageGroup, _ transform: (URL) -> URL) -> ImageGroup {
        ImageGroup(
            primary: transform(group.primary),
            companions: group.companions.map { .init(url: transform($0.url), kind: $0.kind) },
            primaryIsRAW: group.primaryIsRAW)
    }

    /// Move that also handles a case-only rename on a case-insensitive
    /// volume (two steps through a temporary name).
    static func moveFile(from: URL, to: URL,
                         syscall: (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_EXCL)) }) throws {
        if from.path != to.path, from.path.lowercased() == to.path.lowercased(), sameFile(from, to) {
            let temp = from.deletingLastPathComponent()
                .appendingPathComponent(".shrike-rename-\(UUID().uuidString)-\(from.lastPathComponent)")
            try twoStepRename(from: from, to: to, temp: temp)
            return
        }
        // Never over a file that appeared after the name was checked.
        try renameExclusive(from: from, to: to, syscall: syscall)
    }

    /// The photo is held under a hidden temp name between the two steps. A crash there must not lose
    /// its name: the journal lets a later launch put it back. The entry is dropped only
    /// when the photo is under a real name again: after success, or after a successful rollback.
    /// If the second step and the rollback both fail it stays (the one stranded case).
    static func twoStepRename(from: URL, to: URL, temp: URL, journal: RenameJournal = .shared,
                              move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws {
        let id = journal.begin(moves: [(original: from, temporary: temp, final: to as URL?)])
        do { try move(from, temp) } catch { journal.end(id); throw error }
        do { try move(temp, to) } catch {
            do { try move(temp, from) } catch { throw error }   // stranded: keep the journal entry
            journal.end(id)
            throw error
        }
        journal.end(id)
    }

    /// lstat-based: a dangling symlink still "exists" (it has a name).
    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    static func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let kb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let ka, let kb { return ka.isEqual(kb) }
        return canonicalPath(a) == canonicalPath(b)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func volumeName(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeNameKey])
        return values?.volumeLocalizedName ?? values?.volumeName ?? "this volume"
    }

    /// Test opt-in for the real Trash. Under XCTest `systemTrash` refuses, so a
    /// test that forgets the `trashItem:` seam fails loudly instead of putting
    /// files into the developer's own Trash. Nothing sets this today.
    nonisolated(unsafe) static var allowSystemTrashInTests = false

    @Sendable static func systemTrash(_ url: URL) throws -> URL {
        if ShrikeDataPaths.isRunningTests && !allowSystemTrashInTests {
            preconditionFailure("FileOps.systemTrash called under XCTest for \(url.lastPathComponent): "
                + "pass a fake trash through FileOps(…, trashItem:) so no test touches the real ~/.Trash")
        }
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }

    /// Maps a Foundation / POSIX error to `FileOpsError`.
    static func map(_ error: any Error, url: URL, trashing: Bool = false) -> FileOpsError {
        if let own = error as? FileOpsError { return own }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFeatureUnsupportedError where trashing:
                return .noTrash(volumeName: volumeName(of: url), url: url)
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return .notFound(url)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
                return .permissionDenied(url)
            case NSFileWriteVolumeReadOnlyError:
                return .readOnlyVolume(url)
            case NSFileWriteFileExistsError:
                return .nameTaken(url)
            default:
                if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
                   underlying.domain == NSPOSIXErrorDomain {
                    return map(underlying, url: url, trashing: trashing)
                }
            }
        }
        if ns.domain == NSPOSIXErrorDomain {
            switch Int32(ns.code) {
            case ENOENT: return .notFound(url)
            case EACCES, EPERM: return .permissionDenied(url)
            case EROFS: return .readOnlyVolume(url)
            case EEXIST: return .nameTaken(url)
            default: break
            }
        }
        return .io(url, reason: ns.localizedDescription)
    }
}

// MARK: - Broadcaster

/// Fan-out of `FileOpsChange` to any number of `AsyncStream`s.
private final class ChangeBroadcaster: Sendable {
    private let continuations =
        OSAllocatedUnfairLock<[UUID: AsyncStream<FileOpsChange>.Continuation]>(initialState: [:])

    func subscribe() -> AsyncStream<FileOpsChange> {
        let (stream, continuation) = AsyncStream<FileOpsChange>.makeStream(bufferingPolicy: .unbounded)
        let id = UUID()
        continuations.withLock { $0[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            _ = self?.continuations.withLock { $0.removeValue(forKey: id) }
        }
        return stream
    }

    func send(_ change: FileOpsChange) {
        for continuation in continuations.withLock({ Array($0.values) }) {
            continuation.yield(change)
        }
    }

    deinit {
        for continuation in continuations.withLock({ Array($0.values) }) { continuation.finish() }
    }
}

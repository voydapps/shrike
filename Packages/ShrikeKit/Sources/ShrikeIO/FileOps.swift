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
//  * Shrike's own writes are reported to every `FolderWatcher` (through
//    `FolderChangeSuppressing`) just before each file operation, so they
//    don't come back as "removed outside Shrike".
//  * After each operation a `FileOpsChange` is published on `changes()` and
//    as `FileOps.didChangeNotification`, so every window can update its
//    list at once.
//  * Copy / move run as an `AsyncThrowingStream<FileOpProgress, Error>`.
//    Every element carries the receipt so far. Cancelling the consuming
//    task stops after the current group; finished groups stay, and the last
//    element the consumer received is the receipt for Undo (a cancelled
//    consumer does not see a final `wasCancelled` element). The stream
//    throws only when nothing can start (destination missing, read-only,
//    not writable).
//

import Foundation
import os
import ShrikeCore

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
    /// The destination (or, for Undo, the original) folder is gone. → A2.
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
        case .hidden: return "Names starting with “.” are hidden. Choose another name."
        case .tooLong: return "This name is too long."
        case .nameTaken(let url): return "A file named “\(url.lastPathComponent)” already exists."
        }
    }
}

// MARK: - Receipts and progress

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

    /// Groups that did go to the Trash.
    public var trashedGroups: [ImageGroup] { items.map(\.group) }
}

/// What `restore` put back. `groups` carry the final URLs (" 2" when the
/// original name was taken meanwhile), in receipt order.
public struct RestoreResult: Sendable, Hashable {
    public let groups: [ImageGroup]
    public let failures: [FileOpFailure]
}

/// A destination file that Replace removed, and how to get it back.
public struct ReplacedFile: Sendable, Hashable {
    public let original: URL
    /// Set when it went to the Trash.
    public let trashed: URL?
    /// Set when BackupStore holds a copy.
    public let backup: BackupRecord?
}

/// What a copy or move did, for Undo.
public struct FileOpReceipt: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case copy, move }

    public struct Item: Sendable, Hashable {
        /// The group before the operation.
        public let source: ImageGroup
        /// The new copy (copy) or the moved group (move).
        public let result: ImageGroup
        /// Destination files Replace removed to make room.
        public let replaced: [ReplacedFile]
    }

    public let kind: Kind
    public let destination: URL
    public let items: [Item]

    public var isEmpty: Bool { items.isEmpty }
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
        self.metadata = metadata
        self.backups = backups
        self.watchers = watchers
        self.trashItem = trashItem
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
        var items: [TrashReceipt.Item] = []
        var failures: [FileOpFailure] = []
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
            for file in item.files { await rekey(file.original, file.trashed) }
        }
        publish(.init(kind: .trash,
                      removed: items.flatMap { $0.files.map(\.original) }, added: [], moved: []))
        return TrashReceipt(items: items, failures: failures)
    }

    /// Puts trashed files back at their original paths. When a name was
    /// taken meanwhile, the whole group gets the same " 2" suffix.
    /// Throws only when nothing could be restored.
    public func restore(_ receipt: TrashReceipt) async throws -> RestoreResult {
        var restored: [ImageGroup] = []
        var failures: [FileOpFailure] = []
        var moves: [FileMove] = []
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

        for move in moves { await rekey(move.from, move.to) }
        publish(.init(kind: .restore, removed: [], added: moves.map(\.to), moved: []))
        return RestoreResult(groups: restored, failures: failures)
    }

    /// Deletes every file of `group` for good. Only after the permanent-delete alert ("This
    /// volume doesn't have a Trash. Delete it now?").
    public func deleteImmediately(_ group: ImageGroup) async throws {
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
        _ groups: [ImageGroup], to folder: URL, conflicts: ConflictPolicy
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        stream(.copy, groups, folder, conflicts)
    }

    /// Moves each group (all its files) into `folder`. Same-volume moves
    /// are renames; cross-volume moves copy then delete (FileManager).
    public nonisolated func move(
        _ groups: [ImageGroup], to folder: URL, conflicts: ConflictPolicy
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        stream(.move, groups, folder, conflicts)
    }

    /// Reverts a copy (the copies go to the Trash) or a move (the files go
    /// back to where they were), then puts back what Replace removed.
    /// Best effort over every item; throws the first problem, e.g.
    /// `.destinationUnavailable(originalFolder)` or `.notFound(trashedFile)`.
    public func undo(_ receipt: FileOpReceipt) async throws {
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
                            await rekey(url, trashed)
                        } else {
                            // No Trash here: the copy is a duplicate, so removing it is safe.
                            do { try FileManager.default.removeItem(at: url) } catch {
                                throw Self.map(error, url: url)
                            }
                        }
                        removed.append(url)
                    }
                case .move:
                    let back = try moveBack(item)
                    for m in back { await rekey(m.from, m.to) }
                    moved.append(contentsOf: back)
                }
            } catch let error as FileOpsError {
                if firstError == nil { firstError = error }
                continue
            }
            do {
                added.append(contentsOf: try await putBack(item.replaced))
            } catch let error as FileOpsError {
                if firstError == nil { firstError = error }
            }
        }

        publish(.init(kind: receipt.kind == .copy ? .undoCopy : .undoMove,
                      removed: removed, added: added, moved: moved))
        if let firstError { throw firstError }
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
        let validation = Self.validate(stem: newStem, for: group)
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
        for pair in done { await rekey(pair.from, pair.to) }
        publish(.init(kind: .rename, removed: [], added: [], moved: done))

        let map = Dictionary(uniqueKeysWithValues: done.map { ($0.from, $0.to) })
        return Self.mapGroup(group) { map[$0] ?? $0.deletingLastPathComponent()
            .appendingPathComponent(Self.renamed($0.lastPathComponent, oldStem: oldStem, newStem: newStem)) }
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
        _ kind: FileOpReceipt.Kind, _ groups: [ImageGroup], _ folder: URL, _ policy: ConflictPolicy
    ) -> AsyncThrowingStream<FileOpProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.transfer(kind, groups, folder, policy) { continuation.yield($0) }
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

        var items: [FileOpReceipt.Item] = []
        var skipped: [FileOpSkip] = []
        var failures: [FileOpFailure] = []
        var bytesDone: Int64 = 0
        var sticky: ConflictAnswer.Action?
        var removedByReplace: [URL] = []
        var cancelled = false

        func progress(_ completed: Int, current: String?, finished: Bool) -> FileOpProgress {
            FileOpProgress(
                completed: completed, total: groups.count, currentName: current,
                bytesDone: bytesDone, bytesTotal: bytesTotal,
                receipt: FileOpReceipt(kind: kind, destination: folder, items: items),
                skipped: skipped, failures: failures,
                isFinished: finished, wasCancelled: cancelled)
        }

        yield(progress(0, current: groups.first?.primary.lastPathComponent, finished: false))

        for (index, group) in groups.enumerated() {
            if Task.isCancelled { cancelled = true; break }
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
                        let answer = await resolve(FileConflict(
                            incoming: group, existing: clashes, destinationFolder: folder,
                            remainingConflicts: max(0, pendingConflicts)))
                        action = answer.action
                        if answer.applyToRemaining { sticky = answer.action }
                    }
                }
                if Task.isCancelled { cancelled = true; break }

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
                        replaced = try await clearForReplace(clashes, in: folder)
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
                    case .move: await rekey(pair.from, pair.to)
                    }
                }
                let map = Dictionary(uniqueKeysWithValues: pairs.map { ($0.from, $0.to) })
                items.append(.init(source: group,
                                   result: Self.mapGroup(group) { map[$0] ?? $0 },
                                   replaced: replaced))
            } catch {
                // Nothing of this group landed: give the replaced files back.
                _ = try? await putBack(replaced)
                removedByReplace.removeAll { url in replaced.contains { $0.original == url } }
                failures.append(.init(group: group, error: error))
            }
            yield(progress(index + 1, current: group.primary.lastPathComponent, finished: false))
        }
        if Task.isCancelled { cancelled = true }

        let doneCount = items.count + skipped.count + failures.count
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

        var done: [FileMove] = []
        for pair in pairs {
            suppress([pair.from, pair.to])
            do {
                switch kind {
                case .copy: try fm.copyItem(at: pair.from, to: pair.to)
                case .move: try fm.moveItem(at: pair.from, to: pair.to)
                }
                done.append(pair)
            } catch {
                for d in done.reversed() {
                    switch kind {
                    case .copy: try? fm.removeItem(at: d.to)
                    case .move: try? fm.moveItem(at: d.to, to: d.from)
                    }
                }
                if kind == .copy { try? fm.removeItem(at: pair.to) }   // partial copy
                throw Self.map(error, url: pair.from)
            }
        }
        return done
    }

    /// Replace: back up, then trash, every file of the destination group(s)
    /// that clash. On a volume without a Trash the file is deleted, but only
    /// when a backup exists. All or nothing.
    private func clearForReplace(_ clashes: [URL], in folder: URL) async throws -> [ReplacedFile] {
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
                    await rekey(url, trashed)
                    done.append(ReplacedFile(original: url, trashed: trashed, backup: record))
                } catch {
                    let mapped = Self.map(error, url: url, trashing: true)
                    guard case .noTrash = mapped, record != nil else { throw mapped }
                    do { try FileManager.default.removeItem(at: url) } catch {
                        throw Self.map(error, url: url)
                    }
                    done.append(ReplacedFile(original: url, trashed: nil, backup: record))
                }
            }
        } catch let error as FileOpsError {
            _ = try? await putBack(done)
            throw error
        }
        return done
    }

    /// Puts Replace victims back (from the Trash, else from BackupStore).
    /// Returns the restored paths.
    private func putBack(_ replaced: [ReplacedFile]) async throws -> [URL] {
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
                    await rekey(trashed, file.original)
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
                    try await backups.restore(record)
                    if let trashed = file.trashed { await backups.rekey(from: trashed, to: file.original) }
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
                try FileManager.default.moveItem(at: pair.from, to: pair.to)
                done.append(pair)
            } catch {
                for d in done.reversed() { try? FileManager.default.moveItem(at: d.to, to: d.from) }
                throw Self.map(error, url: pair.from)
            }
        }
        return done
    }

    // MARK: - Side effects

    private func suppress(_ urls: [URL]) {
        guard let watchers, !urls.isEmpty else { return }
        watchers.ignore(paths: urls, for: Self.ignoreWindow)
    }

    /// The file moved (trash, untrash, move, move undo, rename, Replace):
    /// its rating / flag record AND its backup chain follow it (A.7 point 5),
    /// so Revert to Original still finds the true original, and a Replace
    /// victim's chain goes to the Trash with it instead of being merged into
    /// the arriving file's chain.
    private func rekey(_ from: URL, _ to: URL) async {
        guard from != to else { return }
        if let metadata { try? await metadata.transfer(from: from, to: to, mode: .move) }
        await backups?.rekey(from: from, to: to)
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

    static func validate(stem: String, for group: ImageGroup) -> RenameValidation {
        if stem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .empty }
        if stem.contains("/") || stem.contains(":") { return .invalidCharacters }
        if stem.hasPrefix(".") { return .hidden }
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

    /// Destination files that belong to the same shot as any clash: every
    /// image / sidecar / movie in `folder` whose stem matches a clashing
    /// file's stem (case-insensitive). Clashes come first.
    static func existingGroupFiles(matching clashes: [URL], in folder: URL) -> [URL] {
        func key(_ name: String) -> String {
            var n = (name as NSString).deletingPathExtension
            let inner = (n as NSString).pathExtension
            if !inner.isEmpty, ImageFormat.isSupported(extension: inner) {
                n = (n as NSString).deletingPathExtension   // IMG_1.CR3.xmp
            }
            return n.lowercased()
        }
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
    static func moveFile(from: URL, to: URL) throws {
        let fm = FileManager.default
        if from.path != to.path, from.path.lowercased() == to.path.lowercased(), sameFile(from, to) {
            let temp = from.deletingLastPathComponent()
                .appendingPathComponent(".shrike-rename-\(UUID().uuidString)-\(from.lastPathComponent)")
            try fm.moveItem(at: from, to: temp)
            do { try fm.moveItem(at: temp, to: to) } catch {
                try? fm.moveItem(at: temp, to: from)
                throw error
            }
            return
        }
        try fm.moveItem(at: from, to: to)
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

    @Sendable static func systemTrash(_ url: URL) throws -> URL {
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

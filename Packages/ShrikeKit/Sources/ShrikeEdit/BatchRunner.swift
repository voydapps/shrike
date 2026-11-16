//
//  BatchRunner.swift
//  ShrikeEdit
//
//  Convert, resize, rotate, rename and
//  edit-recipe apply over many items.
//
//  - `preview` resolves every output name and every clash before anything
//    runs (the Batch window's PREVIEW list).
//  - `run` streams progress; cancelling the consuming task stops the batch
//    (no new items start; ImageExporter writes temp + atomic rename, so an
//    interrupted item leaves no partial file).
//  - `undo` reverts a finished in-place run (renames, rotates, recipe
//    applies). Convert / Resize into a folder create new files: no undo.
//
//  Built on the existing pieces, never beside them: `ImageExporter` writes
//  every re-encoded file, `ExportFormat.inPlaceFormat` / `SaveTarget`
//  decide what can be written in place, `FileOps` renames (companions
//  keep the shared stem) and trashes Replace victims, `LosslessRotator`
//  rotates in place, `BackupStore` keeps the originals.
//

import CoreGraphics
import Foundation
import ImageIO
import os
import ShrikeCore
import ShrikeIO

// MARK: - Plan

public struct ConvertOptions: Sendable, Hashable, Codable {
    public var format: ExportFormat
    /// 0.60…1.00 (JPEG / HEIC only).
    public var quality: Double
    public var keepMetadata: Bool
    public var removeLocation: Bool

    public init(format: ExportFormat, quality: Double = 0.85,
                keepMetadata: Bool = true, removeLocation: Bool = false) {
        self.format = format
        self.quality = min(max(quality, 0.60), 1.0)
        self.keepMetadata = keepMetadata
        self.removeLocation = removeLocation
    }
}

public struct ResizeOptions: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        case longEdge, width, height, percent
    }
    public var mode: Mode
    /// Pixels, or percent for `.percent`.
    public var value: Int
    public var dontEnlarge: Bool

    public init(mode: Mode, value: Int, dontEnlarge: Bool = true) {
        self.mode = mode
        self.value = value
        self.dontEnlarge = dontEnlarge
    }

    /// Output size for a (display-oriented) source size. Aspect is kept.
    public func targetSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, value > 0 else { return size }
        let scale: Double
        switch mode {
        case .longEdge: scale = Double(value) / Double(max(size.width, size.height))
        case .width: scale = Double(value) / Double(size.width)
        case .height: scale = Double(value) / Double(size.height)
        case .percent: scale = Double(value) / 100
        }
        let s = dontEnlarge ? min(scale, 1) : scale
        return CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
    }
}

public enum BatchOutput: Sendable, Hashable {
    /// New files in this folder; originals untouched.
    case folder(URL)
    /// Change the files themselves (originals go to BackupStore first).
    case inPlace
}

public struct BatchPlan: Sendable {
    var resumePhases: [ImageGroup: Set<BatchPhase>] = [:]
    var retryDestinations: [ImageGroup: URL] = [:]
    var previousChanges: BatchResult?
    /// A retry: the files of every photo of the earlier run(s) (`retryPlan`). One of them is never a
    /// Replace victim, even when it is not in this queue.
    var runSources: Set<String> = []
    /// Counter order = list order.
    public var items: [ImageGroup]
    public var convert: ConvertOptions?
    public var resize: ResizeOptions?
    /// Quarter turns clockwise: 1 = Right 90°, 2 = 180°, 3 or -1 = Left 90°.
    public var rotate: Int?
    public var rename: RenameTemplate?
    /// Edit operations applied to every item ("apply these edits to all").
    /// A value snapshot: take it with `await recipe.operations` from the
    /// `EditRecipe` actor.
    public var recipe: [EditOperation]?
    public var output: BatchOutput
    /// What to do when an output name is already used on disk. Clashes
    /// between items of the same batch always get Finder " 2" suffixes.
    public var onConflict: ConflictAnswer.Action
    /// The user confirmed that a photo whose output file is the photo
    /// itself (output folder = its own folder, same name and format) may be
    /// re-encoded in place. Without it such a name is a clash like any
    /// other and gets a Finder " 2" suffix, so no original is overwritten
    /// by accident. Only the photo's own file qualifies, never another
    /// queued photo.
    public var overwritesOriginals: Bool = false

    public init(items: [ImageGroup], convert: ConvertOptions? = nil, resize: ResizeOptions? = nil,
                rotate: Int? = nil, rename: RenameTemplate? = nil, recipe: [EditOperation]? = nil,
                output: BatchOutput, onConflict: ConflictAnswer.Action = .keepBoth) {
        self.items = items
        self.convert = convert
        self.resize = resize
        self.rotate = rotate
        self.rename = rename
        self.recipe = recipe
        self.output = output
        self.onConflict = onConflict
    }

    var quarters: Int { ((rotate ?? 0) % 4 + 4) % 4 }
    var hasRecipe: Bool { !(recipe?.isEmpty ?? true) }
    /// Pixels are re-encoded (Convert, Resize, or a recipe).
    var reencodes: Bool { convert != nil || resize != nil || hasRecipe }
    /// The job reads pixels (re-encode or lossless rotate). A rename-only job does not.
    var needsPixels: Bool { reencodes || quarters != 0 }

    /// Validation line, or nil when the plan can run.
    public var validationError: BatchValidationError? {
        if !reencodes && quarters == 0 && rename == nil { return .noOperation }
        if let resize, resize.value <= 0 { return .invalidResizeValue }
        if convert != nil || resize != nil {
            guard case .folder(let folder) = output else { return .outputFolderRequired }
            var isDir: ObjCBool = false
            if !FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir) || !isDir.boolValue {
                // Created on run when its parent exists (default "<source>/Shrike Export").
                if !FileManager.default.fileExists(atPath: folder.deletingLastPathComponent().path) {
                    return .outputFolderRequired
                }
            }
        }
        return nil
    }
}

public enum BatchValidationError: Error, Sendable, Hashable {
    case noOperation
    case invalidResizeValue
    case outputFolderRequired

    public var message: String {
        switch self {
        case .noOperation: return "Choose at least one operation."
        case .invalidResizeValue: return "Resize size must be greater than zero."
        case .outputFolderRequired: return "Choose an output folder."
        }
    }
}

// MARK: - Results

public enum BatchSkipReason: Sendable, Hashable {
    case unreadable
    case diskFull
    case nameExists
    case cannotRotateLosslessly
    case cancelled
    /// An in-place recipe on a type Shrike can't write
    /// back (RAW, multi-frame, …).
    case cannotSaveInPlace
    /// The rename template rendered an empty name.
    case emptyName
    /// The filled template is not a usable name (for example it ends with a period).
    case invalidName(RenameValidation)

    /// Review Remaining picks these up on its own (the user did not choose
    /// to skip them). The other skips are on purpose; the user may select them.
    public var isRetriedAutomatically: Bool {
        self == .cancelled || self == .unreadable || self == .diskFull
    }

    /// The text shown to the user.
    public var message: String {
        switch self {
        case .unreadable: return "Shrike can't read this file."
        case .diskFull: return "Not enough disk space."
        case .nameExists: return "A file with this name exists — skipped."
        case .cannotRotateLosslessly: return "This file type can't be rotated without re-encoding — skipped."
        case .cancelled: return "Canceled."
        case .cannotSaveInPlace: return "Shrike can't save this file type in place — skipped."
        case .emptyName: return "The new name would be empty — skipped."
        case .invalidName(let why):
            switch why {
            case .empty: return "The new name would be empty — skipped."
            case .trailingDot: return "The new name would end with a period — skipped."
            case .hidden: return "The new name would start with “.” — skipped."
            case .edgeSpace: return "The new name would start or end with a space — skipped."
            case .invalidCharacters: return "The new name would contain “/” or “:” — skipped."
            case .controlCharacters: return "The new name would contain hidden characters — skipped."
            default: return "The new name is not allowed — skipped."
            }
        }
    }
}

public struct BatchPreviewRow: Sendable, Hashable {
    public let source: ImageGroup
    public let outputName: String
    public let destination: URL
    /// Output pixel size when known (nil for rename-only rows).
    public let outputSize: CGSize?
    /// The name is used on disk or by an earlier item ("Name already used").
    public let nameClash: Bool
    /// Known before running (e.g. rotate on WebP, unreadable file).
    public let skip: BatchSkipReason?
    /// The output file is the original itself (runs only with `overwritesOriginals`).
    public var overwritesOriginal: Bool = false
}

public enum BatchItemOutcome: Sendable {
    case done(URL)
    case skipped(BatchSkipReason)
    case failed(any Error)
}

public enum BatchPhase: String, Sendable, Hashable { case rotate, rename, export }

/// A replaced destination remains recoverable even when automatic rollback
/// fails (for example, its volume disconnected). Keep the actual receipt.
public struct BatchRecoveryRequiredError: LocalizedError, Sendable {
    public let record: BackupRecord
    public let operationError: any Error
    public let recoveryError: any Error
    public var errorDescription: String? {
        "Rename failed: \(operationError.localizedDescription) The replaced file could not be restored: \(recoveryError.localizedDescription) Its backup is retained; restore it with Undo when the destination is available."
    }
}

/// Batch Undo could not put one or more Replace victims of a Batch rename back at their names. Nothing was
/// written over another file. A victim whose Trash copy is gone and whose name another file now has comes
/// back under a free " 2" name (`restoredAs`; that alone is not a failure: Undo then returns normally, as
/// Put Back's " 2" names do, and the new names are reported only when Undo throws anyway). A victim that
/// is not back is in one of two places: still in the Trash (Put Back failed, e.g. its folder is gone), or,
/// when it could not be written under a new name either (the folder is not writable), only in Shrike's
/// backups, which keep it for the "Keep older backups for" period in Settings > Editing. Batch Undo runs
/// once, so the text promises no later Undo. `BatchRunner.undo` throws this after it has done everything else.
public struct BatchVictimNotRestoredError: LocalizedError, Sendable {
    /// File names of the victims still in the Trash, in run order.
    public let inTrash: [String]
    /// File names of the victims left only in Shrike's backups, in run order.
    public let inBackups: [String]
    /// Victims that came back under a new name (old file name, new file name), in run order.
    public let restoredAs: [(old: String, new: String)]
    /// The first other problem Undo met (often why a name is taken: a rename back that failed).
    public let alsoFailed: (any Error)?
    /// How many victims are NOT back.
    public var count: Int { inTrash.count + inBackups.count }
    public var errorDescription: String? {
        let base = Self.text(inTrash: inTrash, inBackups: inBackups, restoredAs: restoredAs)
        guard let alsoFailed else { return base }
        return base + " " + alsoFailed.localizedDescription
    }

    /// Where a copy is kept: no period is promised, the storage limit can remove one sooner.
    static let keptIn = "Shrike's backups for a while (Settings → Editing)"

    /// The toast texts in two pieces: what was not put back, and the
    /// photos that came back under a new name (dropped first when the toast is
    /// too long). `name` shortens a file name (the UI passes
    /// `FileNameFit.short(_, limit: 20)`).
    package static func pieces(inTrash: [String], inBackups: [String], restoredAs: [(old: String, new: String)] = [],
                               name: (String) -> String = { $0 }) -> (main: String, restoredAs: String?) {
        var parts: [String] = []
        let n = inTrash.count + inBackups.count
        let first = name((inTrash + inBackups).first ?? "")
        if n == 1 {
            parts.append(inTrash.isEmpty
                ? "“\(first)” was not put back: another file has its name, and a new name could not be saved. A copy is kept in \(keptIn)."
                : "“\(first)” could not be put back. It is still in the Trash.")
        } else if n > 1 {
            parts.append("\(n) replaced photos were not put back, including “\(first)”.")
            if inBackups.isEmpty {
                parts.append("They are still in the Trash.")
            } else if inTrash.isEmpty {
                parts.append("Their names are taken and new names could not be saved. Copies are kept in \(keptIn).")
            } else {
                parts.append(inTrash.count == 1 ? "1 is still in the Trash." : "\(inTrash.count) are still in the Trash.")
                parts.append(inBackups.count == 1
                    ? "1 could not be saved under a new name; a copy is kept in \(keptIn)."
                    : "\(inBackups.count) could not be saved under new names; copies are kept in \(keptIn).")
            }
        }
        var back: String?
        if let one = restoredAs.first {
            back = restoredAs.count == 1
                ? "“\(name(one.old))” is back as “\(name(one.new))”."
                : "\(restoredAs.count) other photos are back under new names."
        }
        return (parts.joined(separator: " "), back)
    }

    static func text(inTrash: [String], inBackups: [String], restoredAs: [(old: String, new: String)] = []) -> String {
        let p = pieces(inTrash: inTrash, inBackups: inBackups, restoredAs: restoredAs)
        return [p.main, p.restoredAs].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// What a Batch Undo that did not throw reports: the
/// backups it lost track of, and the replaced photos that came back under a
/// new name because their old name was taken.
public struct BatchUndoReport: Sendable {
    public let backupsNotSaved: Int
    public let restoredAs: [(old: String, new: String)]
    package init(backupsNotSaved: Int, restoredAs: [(old: String, new: String)] = []) {
        self.backupsNotSaved = backupsNotSaved
        self.restoredAs = restoredAs
    }
}

public struct BatchItemResult: Sendable {
    public let source: ImageGroup
    public let outcome: BatchItemOutcome
    public let completedPhases: [BatchPhase]
    public let finalURL: URL?
    public let destinationURL: URL?
    /// The first resolved job name, including outcomes that never wrote a
    /// file. Recovery keeps this naming identity while applying its current
    /// output folder/conflict policy. This is provenance, not an actual file
    /// location; use finalURL / .done for the item that exists on disk.
    public let plannedDestinationURL: URL?
    public let failurePhase: BatchPhase?
    public let recoveryRequired: BackupRecord?
    /// The " 2" name the photo ended with because a rename of this run that was
    /// stopped or failed could not give it its old name back (another photo has it now). nil for
    /// every other row. Set only by the rename clean-up (`moveToSecondName`).
    public let putBackAs: URL?
    public var isPartial: Bool { recoveryRequired != nil || (!completedPhases.isEmpty && !isDone) }
    public init(source: ImageGroup, outcome: BatchItemOutcome, completedPhases: [BatchPhase] = [],
                finalURL: URL? = nil, destinationURL: URL? = nil, failurePhase: BatchPhase? = nil,
                recoveryRequired: BackupRecord? = nil, plannedDestinationURL: URL? = nil, putBackAs: URL? = nil) {
        self.putBackAs = putBackAs
        self.source = source; self.outcome = outcome; self.completedPhases = completedPhases
        if let finalURL { self.finalURL = finalURL }
        else if case .done(let url) = outcome { self.finalURL = url }
        else { self.finalURL = source.primary }
        self.destinationURL = destinationURL; self.failurePhase = failurePhase
        self.recoveryRequired = recoveryRequired
        self.plannedDestinationURL = plannedDestinationURL ?? destinationURL
    }
}

public struct BatchResult: Sendable {
    public internal(set) var items: [BatchItemResult] = []
    /// In-place renames, in run order (undo renames back).
    public internal(set) var renames: [(before: ImageGroup, after: ImageGroup)] = []
    public internal(set) var rotations: [LosslessRotateResult] = []
    /// In-place recipe applies: the `.batch` backup of each original.
    public internal(set) var replacedOriginals: [BackupRecord] = []
    /// What the Trash move of each Replace victim of a Batch RENAME returned. Undo puts the victim back
    /// with `FileOps.restore`, which also moves its chain, guards and rating. (Not Codable:
    /// the result holds tuples, so no old saved results exist.)
    public internal(set) var replacedVictims: [TrashReceipt] = []
    /// Photos whose backup information could not be saved during the renames and Trash moves of the
    /// run. 0 = all good.
    public internal(set) var backupsNotSaved = 0

    public var doneCount: Int { items.filter { if case .done = $0.outcome { return true }; return false }.count }
    public var skippedCount: Int { items.count - doneCount }
    /// A file Shrike could not read counts as failed, not as a skip.
    public var failedCount: Int {
        items.filter {
            switch $0.outcome {
            case .failed, .skipped(.unreadable): return true
            default: return $0.isPartial
            }
        }.count
    }
    /// Skipped on purpose and not picked up by Review Remaining on its own.
    public var hasIntentionalSkips: Bool {
        items.contains { if case .skipped(let why) = $0.outcome { return !why.isRetriedAutomatically && !$0.isPartial }; return false }
    }
    public var cancelledCount: Int { items.filter { if case .skipped(.cancelled) = $0.outcome { return true }; return false }.count }

    // For the summary of a rename-only run (they mean nothing for other jobs).
    // newNameCount + oldNameCount + putBackAsCount == items.count, except a row whose photo the
    // clean-up could not move at all (it stays under a temporary name, its row says so, the next
    // launch repairs it): that row is in none of the three.
    /// D: photos that have their new name (= `doneCount`).
    public var newNameCount: Int { doneCount }
    /// W: photos that got a " 2" name because their old name was taken (`putBackAs` set).
    public var putBackAsCount: Int { items.filter { $0.putBackAs != nil }.count }
    /// K: photos that are not done and are still at their old name: canceled, skipped, or failed
    /// and put back. Failed and skipped ones are inside this count; the summary shows them on their
    /// own line too.
    public var oldNameCount: Int {
        items.filter { item in
            !item.isDone && item.putBackAs == nil
                && item.finalURL.map { CanonicalPath.key($0) == CanonicalPath.key(item.source.primary) } ?? true
        }.count
    }
    /// Only in-place work can be undone.
    public var canUndo: Bool { !renames.isEmpty || !rotations.isEmpty || !replacedOriginals.isEmpty }
}

public struct BatchProgress: Sendable {
    public let completed: Int
    public let total: Int
    public let currentName: String?
    /// The item that just finished (nil on the first event).
    public let item: BatchItemResult?
    /// Set on the last event only.
    public let result: BatchResult?
    public let phase: BatchPhase?
    public init(completed: Int, total: Int, currentName: String?, item: BatchItemResult?, result: BatchResult?, phase: BatchPhase? = nil) {
        self.completed = completed; self.total = total; self.currentName = currentName
        self.item = item; self.result = result; self.phase = phase
    }
}

// MARK: - Runner

public struct BatchRunner: Sendable {

    private let fileOps: FileOps
    private let backups: BackupStore
    private let metadata: MetadataStore?
    private let phaseCheckpoint: (@Sendable (BatchPhase, URL) async throws -> Void)?
    public enum RenameCheckpoint: Sendable { case beforeMove, beforeRollback }
    private let renameCheckpoint: (@Sendable (RenameCheckpoint, URL) async throws -> Void)?
    /// Test seam: runs before each move that sets a photo aside (`beforeStage`) and before each
    /// move of the clean-up after a Stop or an error (`beforeCleanup`), with the photo's original
    /// primary; and before each rename step of Undo (`beforeUndoStep`), with the file it moves. A
    /// throw makes that move fail. Only tests set it.
    enum CleanupCheckpoint: Sendable { case beforeStage, beforeCleanup, beforeUndoStep }
    var cleanupCheckpoint: (@Sendable (CleanupCheckpoint, URL) async throws -> Void)?

    public init(fileOps: FileOps, backups: BackupStore = .shared, metadata: MetadataStore? = nil,
                phaseCheckpoint: (@Sendable (BatchPhase, URL) async throws -> Void)? = nil,
                renameCheckpoint: (@Sendable (RenameCheckpoint, URL) async throws -> Void)? = nil) {
        self.fileOps = fileOps
        self.backups = backups
        self.metadata = metadata
        self.phaseCheckpoint = phaseCheckpoint
        self.renameCheckpoint = renameCheckpoint
    }

    /// Worker count: `max(2, min(activeProcessorCount − 1, 6))`.
    public static var workerCount: Int {
        max(2, min(ProcessInfo.processInfo.activeProcessorCount - 1, 6))
    }

    // MARK: Preview

    /// Every output name and clash, first `limit` rows (200, then
    /// "and N more"). Nothing is written.
    public func preview(_ plan: BatchPlan, limit: Int = 200) async -> [BatchPreviewRow] {
        let items = Array(plan.items.prefix(max(0, limit)))
        return Self.resolve(plan, items: items).map(\.row)
    }

    /// Everything one preview refresh needs, from ONE read of each photo's header.
    public struct Analysis: Sendable {
        /// The first `limit` preview rows.
        public let rows: [BatchPreviewRow]
        /// Every photo whose header can't be read (all of the plan, not only the rows).
        public let unreadable: Set<URL>
        /// The unreadable photos this run will SKIP. Empty for a job that only renames: it needs
        /// no pixels, so it renames them too.
        public let skippedUnreadable: Set<URL>
        /// The photos skipped because the filled rename template gives a name Shrike cannot use
        /// (`.invalidName` and `.emptyName`). The whole plan, like `skippedUnreadable`.
        public let skippedInvalidName: Set<URL>
        /// Photos that a folder output would overwrite (empty for other plans).
        public let overwritten: [ImageGroup]
        /// Display size of every readable photo.
        public let sizes: [URL: CGSize]
        /// The existing files a Replace run would trash first, for the whole plan (read only; empty
        /// unless the plan renames or answers clashes with Replace). Preview only: a run resolves again.
        public var replaceTargets: Set<URL> = []
    }

    /// Rows, unreadable set, overwrite list and sizes with each header read once. Runs on the
    /// caller's thread: call it off the main thread. Stops early (partial result) when cancelled.
    public func analyze(_ plan: BatchPlan, limit: Int = 200) -> Analysis {
        analyze(plan, limit: limit) { Header($0) }
    }

    func analyze(_ plan: BatchPlan, limit: Int, header read: (URL) -> Header?) -> Analysis {
        var headers: [URL: Header] = [:]
        var unreadable = Set<URL>()
        for item in plan.items {
            if Task.isCancelled { break }
            if let h = read(item.primary) { headers[item.primary] = h } else { unreadable.insert(item.primary) }
        }
        let lookup: (URL) -> Header? = { headers[$0] }
        // With a rename template the whole plan is resolved once: the name skips are counted for the
        // whole queue, and the rows are its first `limit` entries (the counter of a row depends only on
        // the photos before it, so they equal a resolve of the prefix).
        // With Replace too, so the files outside the queue it replaces are known for the whole queue.
        let resolvedAll = plan.rename != nil || plan.onConflict == .replace
            ? Self.resolve(plan, items: plan.items, header: lookup) : nil
        let rows = (resolvedAll.map { Array($0.prefix(max(0, limit))) }
                    ?? Self.resolve(plan, items: Array(plan.items.prefix(max(0, limit))), header: lookup)).map(\.row)
        var invalidName = Set<URL>()
        for r in resolvedAll ?? [] {
            switch r.row.skip {
            case .invalidName?, .emptyName?: invalidName.insert(r.row.source.primary)
            default: break
            }
        }
        var overwritten: [ImageGroup] = []
        if plan.reencodes, case .folder = plan.output {
            var confirmed = plan
            confirmed.overwritesOriginals = true
            overwritten = Self.resolve(confirmed, items: plan.items, header: lookup)
                .filter(\.row.overwritesOriginal).map(\.row.source)
        }
        return Analysis(rows: rows, unreadable: unreadable,
                        skippedUnreadable: plan.needsPixels ? unreadable : [],
                        skippedInvalidName: invalidName,
                        overwritten: overwritten, sizes: headers.mapValues(\.displaySize),
                        replaceTargets: Set((resolvedAll ?? []).compactMap(\.replaceTarget)))
    }

    /// How many photos of the plan Shrike can't read (their header won't
    /// open). All of them are checked, not only the preview's first 200: a
    /// header read is cheap and the run skips every one.
    public func unreadableCount(in plan: BatchPlan) -> Int {
        plan.items.reduce(0) { Task.isCancelled || Header($1.primary) != nil ? $0 : $0 + 1 }
    }

    /// The photos of the plan Shrike can't read (all of them are checked).
    public func unreadablePhotos(in plan: BatchPlan) -> Set<URL> {
        var bad = Set<URL>()
        for item in plan.items where !Task.isCancelled && Header(item.primary) == nil { bad.insert(item.primary) }
        return bad
    }

    /// How many photos would be re-encoded over their own file if the user
    /// confirms (`overwritesOriginals`): the output folder is the photo's
    /// folder and the output keeps its name and format. The Batch window
    /// shows the in-place wording and asks before running when this is > 0.
    public func originalsOverwritten(by plan: BatchPlan) -> Int {
        groupsOverwritten(by: plan).count
    }

    /// The photos behind `originalsOverwritten(by:)`.
    public func groupsOverwritten(by plan: BatchPlan) -> [ImageGroup] {
        guard plan.reencodes, case .folder = plan.output else { return [] }
        var confirmed = plan
        confirmed.overwritesOriginals = true
        return Self.resolve(confirmed, items: plan.items).filter(\.row.overwritesOriginal).map(\.row.source)
    }

    /// Continue only unfinished items/phases. Receipt history follows the
    /// retry so Undo still reverses a rotate committed in the earlier run.
    public func retryPlan(for result: BatchResult, original: BatchPlan, includingIntentionalSkips: Bool = false,
                          selectedIntentionalSkips: Set<URL> = []) -> BatchPlan {
        var plan = original
        // Where the run set photos aside and left them: a recorded move straight from a photo's own
        // name to where its row says it is now can only be the move aside (a " 2" name is reached from
        // the temporary name, a planned name makes the row done). From the record, never from the text
        // of a file name.
        let movedAside = Set(result.renames.map { CanonicalPath.key($0.before.primary) + "\n" + CanonicalPath.key($0.after.primary) })
        let unfinished = result.items.filter { item in
            // A photo still under a temporary name has an open journal entry: the next launch's
            // recovery owns it, and its row names the file. Never retried.
            if !item.isDone, let at = item.finalURL,
               movedAside.contains(CanonicalPath.key(item.source.primary) + "\n" + CanonicalPath.key(at)) { return false }
            switch item.outcome {
            case .done: return false
            case .failed: return true
            case .skipped(let reason): return includingIntentionalSkips || selectedIntentionalSkips.contains(item.source.primary)
                || reason.isRetriedAutomatically || item.isPartial
            }
        }
        // Results arrive in worker-completion order. Recovery is still the
        // same job: retain its original relative item/counter order.
        let bySource = Dictionary(unfinished.map { ($0.source, $0) }, uniquingKeysWith: { first, _ in first })
        let retry = original.items.compactMap { bySource[$0] }
        // A photo that a stopped or failed rename could not give its old name back is no longer
        // at its source path, and another photo of the run may be: it is addressed where it IS now,
        // never by its old path, and goes on to its planned name.
        func current(_ item: BatchItemResult) -> ImageGroup {
            guard !item.isDone, let at = item.finalURL, CanonicalPath.key(at) != CanonicalPath.key(item.source.primary)
            else { return item.source }
            let urls = FileOps.renamedURLs(of: item.source, toStem: at.deletingPathExtension().lastPathComponent)
            return ImageGroup(primary: urls[0],
                              companions: zip(item.source.companions, urls.dropFirst()).map { .init(url: $1, kind: $0.kind) },
                              primaryIsRAW: item.source.primaryIsRAW)
        }
        plan.items = retry.map(current)
        plan.resumePhases = Dictionary(uniqueKeysWithValues: retry.map {
            (current($0), (original.resumePhases[$0.source] ?? []).union($0.completedPhases))
        })
        plan.retryDestinations = Dictionary(uniqueKeysWithValues: retry.compactMap { item in
            (original.retryDestinations[item.source] ?? item.plannedDestinationURL ?? item.destinationURL)
                .map { (current(item), $0) }
        })
        plan.previousChanges = result
        plan.runSources = original.runSources.union(result.items.flatMap { $0.source.allURLs.map { CanonicalPath.key($0) } })
        // And where the renamed photos are NOW, every file of the group: a finished photo's companion
        // under its new name is never a Replace victim either.
        for item in result.items where item.isDone && item.completedPhases.contains(.rename) {
            guard let at = item.finalURL else { continue }
            for url in FileOps.renamedURLs(of: item.source, toStem: at.deletingPathExtension().lastPathComponent) {
                plan.runSources.insert(CanonicalPath.key(url))
            }
        }
        return plan
    }

    // MARK: Run

    public func run(_ plan: BatchPlan) -> AsyncThrowingStream<BatchProgress, any Error> {
        run(plan, stop: BatchStop())
    }

    /// Like `run(_:)`, with a Stop button: `stop.stop()` starts no new
    /// items and cancels the ones in flight, and the stream still ends
    /// with the last event carrying `result` ("Canceled." rows included,
    /// finished in-place work undoable). Ending the stream instead also
    /// stops the work, but that last event is lost.
    public func run(_ plan: BatchPlan, stop: BatchStop) -> AsyncThrowingStream<BatchProgress, any Error> {
        AsyncThrowingStream { continuation in
            stop.prepareRun()
            // Covers the whole run, also while its window is hidden ("Keep Running").
            let activeWork = ActiveWork.shared.begin(kind: .batchRun, detail: "Batch, \(plan.items.count) photo(s)")
            let work = Task {
                let resizeScope = ResizeTool.beginBatchProcessing()
                defer { resizeScope.finish(); stop.markSettled(); ActiveWork.shared.end(activeWork) }
                do {
                    let result = try await self.execute(plan) { continuation.yield($0) }
                    // execute has joined every child. Concurrent batches and
                    // actual edit renders still hold their own context scopes.
                    resizeScope.finish()
                    continuation.yield(BatchProgress(completed: result.items.count, total: plan.items.count,
                                                     currentName: nil, item: nil, result: result))
                    continuation.finish()
                } catch {
                    resizeScope.finish()
                    continuation.finish(throwing: error)
                }
            }
            stop.attach(work)
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    // MARK: Undo

    /// Reverts a finished in-place run: renames back (last first),
    /// lossless rotates undone, recipe applies restored from BackupStore.
    /// Returns how many photos' backup information could not be saved; 0 = all good.
    public func undo(_ result: BatchResult) async throws -> BatchUndoReport {
        var firstError: (any Error)?
        var notSaved = 0
        // Undo walks a set-aside photo back through its temporary name. While it is there, a journal
        // entry covers it, as in the forward run, and a failed step never leaves it there.
        let reserved = Set(result.renames.flatMap { $0.before.allURLs.map { CanonicalPath.key($0) } })
        var setAsideFrom: [String: ImageGroup] = [:]         // temporary name -> the name it was set aside from
        // A step that set a photo aside, read from the step itself (its new stem is its old stem plus
        // the marker and 8 characters), never from the text of a name alone.
        for step in result.renames {
            let before = Self.stem(of: step.before), after = Self.stem(of: step.after)
            if after.hasPrefix(before + Self.temporaryMarker), after.count == before.count + Self.temporaryMarker.count + 8 {
                setAsideFrom[CanonicalPath.key(step.after.primary)] = step.before
            }
        }
        var underTemp: [String: UUID?] = [:]                 // photos Undo itself put under a temporary name
        var secondNames: [(old: String, new: String)] = []
        for rename in result.renames.reversed() {
            let putThereByUndo = underTemp.removeValue(forKey: CanonicalPath.key(rename.after.primary))
            // Leaving a real name for a temporary one: the entry names the name it leaves, so a kill
            // before the bookkeeping moved puts it back there with its history.
            let target = setAsideFrom[CanonicalPath.key(rename.before.primary)]
            let entry: UUID? = target == nil ? nil : RenameJournal.shared.begin(moves: zip(rename.after.allURLs, rename.before.allURLs).map {
                (original: $0, temporary: $1, final: nil as URL?)
            })
            do {
                try await cleanupCheckpoint?(.beforeUndoStep, rename.after.primary)
                let back = try await fileOps.renameReporting(rename.after, toStem: Self.stem(of: rename.before), relaxed: true)
                notSaved += back.backupsNotSaved
                if let target {
                    // Under the temporary name with its history: from here on a kill completes the Undo.
                    underTemp[CanonicalPath.key(back.group.primary)] = RenameJournal.shared.replace(entry, moves:
                        zip(target.allURLs, back.group.allURLs).map { (original: $0, temporary: $1, final: nil as URL?) })
                }
                if let putThereByUndo { RenameJournal.shared.end(putThereByUndo) }   // a real name again
            } catch {
                RenameJournal.shared.end(entry)                    // it never left its real name
                if let putThereByUndo {
                    // Undo left it under the temporary name and its name cannot be had: a " 2" name.
                    let restore = zip(rename.before.allURLs, rename.after.allURLs).map { (original: $0, temporary: $1, final: nil as URL?) }
                    if let moved = try? await moveToSecondName(rename.after, nextTo: rename.before, journal: putThereByUndo,
                                                               restore: restore, reserved: reserved) {
                        notSaved += moved.backupsNotSaved
                        secondNames.append((rename.before.primary.lastPathComponent, moved.group.primary.lastPathComponent))
                        continue
                    }
                }
                firstError = firstError ?? error
            }
        }
        if !result.rotations.isEmpty {
            let rotator = LosslessRotator(backupStore: backups)
            for rotation in result.rotations.reversed() {
                do { notSaved += try await rotator.undo(rotation) } catch { firstError = firstError ?? error }
            }
        }
        // Replace victims of a Batch rename come back from the Trash with their chain, guards and
        // rating (the renamed photos are already back at their old names, so the names are free).
        var restoredPaths = Set<String>()
        // Victims of a Batch RENAME (Trash receipt). A file at such a victim's name is not
        // the exported file Undo means to replace: it is another photo, and it is never written over.
        let renameVictimPaths = Set(result.replacedVictims.flatMap { $0.items.flatMap(\.files).map { CanonicalPath.of($0.original) } })
        var inTrash: [String] = [], inBackups: [String] = []
        var restoredAs: [(old: String, new: String)] = secondNames   // also set-aside photos that got a " 2" name
        // Victims whose Trash copy is gone while another file has their name: original path -> where their
        // history is filed (the Trash path) and their stem, for a restore under a free name below.
        var displaced: [String: (trashed: URL, stem: String)] = [:]
        for receipt in result.replacedVictims {
            var notBack = Set(receipt.items.map(\.group))
            do {
                let back = try await fileOps.restore(receipt)
                notSaved += back.backupsNotSaved
                notBack = Set(back.failures.map(\.group))
            } catch {}        // reported below, with where the victim is now
            for item in receipt.items {
                // By the ORIGINAL paths of what came back (a victim whose name was taken again got a " 2"
                // name: its bytes must not also be written at the old path).
                guard notBack.contains(item.group) else { restoredPaths.insert(CanonicalPath.of(item.group.primary)); continue }
                // Put Back failed. While the Trash copy exists the victim stays there with its history and
                // nothing is written. Only when it is really gone (the Trash was emptied) do the
                // chain and rating move to the original path, and the bytes come from the backup below.
                if item.files.contains(where: { FileManager.default.fileExists(atPath: $0.trashed.path) }) {
                    restoredPaths.insert(CanonicalPath.of(item.group.primary))
                    inTrash.append(item.group.primary.lastPathComponent)
                } else {
                    for file in item.files where FileManager.default.fileExists(atPath: file.original.path) {
                        displaced[CanonicalPath.of(file.original)] = (file.trashed, Self.stem(of: item.group))
                    }
                    await settleTrashHistory(of: item.files.filter { !FileManager.default.fileExists(atPath: $0.original.path) })
                }
            }
        }
        for record in result.replacedOriginals {
            if restoredPaths.contains(record.originalPath) { continue }       // already back, or left in the Trash
            if renameVictimPaths.contains(record.originalPath), FileManager.default.fileExists(atPath: record.originalPath) {
                // Another photo sits at the victim's name (its rename back failed, say): nothing is written
                // there. The victim comes back from its backup under a free " 2" name next to it,
                // with its chain and rating; that photo, its chain and its rating are not touched.
                if let aside = displaced[record.originalPath] {
                    let folder = record.originalURL.deletingLastPathComponent()
                    let name = FileOps.freeNames(for: [record.originalURL.lastPathComponent], stem: aside.stem, in: folder) {
                        FileManager.default.fileExists(atPath: $0.path)
                    }[0]
                    let target = folder.appendingPathComponent(name)
                    do {
                        notSaved += try await backups.restore(record, toFreePath: target)
                        try? await metadata?.transfer(from: aside.trashed, to: target, mode: .move)
                        restoredAs.append((record.originalURL.lastPathComponent, name))
                        continue
                    } catch {
                        await backups.parkWithClock(chainAt: aside.trashed)      // only its backup is left
                    }
                }
                inBackups.append(record.originalURL.lastPathComponent)
                continue
            }
            do { notSaved += try await backups.restoreReporting(record).notSaved } catch { firstError = firstError ?? error }
        }
        // The channel for "these victims were not put back": the error Undo throws after doing the rest.
        if !inTrash.isEmpty || !inBackups.isEmpty || (!restoredAs.isEmpty && firstError != nil) {
            firstError = BatchVictimNotRestoredError(inTrash: inTrash, inBackups: inBackups, restoredAs: restoredAs,
                                                     alsoFailed: firstError)
        }
        if let firstError { throw firstError }
        return BatchUndoReport(backupsNotSaved: notSaved, restoredAs: restoredAs)
    }

    /// The history (chain, rating) of a Replace victim whose Trash copy is really gone moves to the
    /// victim's original path, but only while that path is free. A victim that is still in the Trash keeps
    /// its history there. When another photo sits at the original path, the victim's chain is put on the
    /// clock instead (its rating stays under the Trash key): moving it would displace that photo's own
    /// chain.
    private func settleTrashHistory(of files: [TrashedFile]) async {
        for file in files where !FileManager.default.fileExists(atPath: file.trashed.path) {
            if FileManager.default.fileExists(atPath: file.original.path) {
                await backups.parkWithClock(chainAt: file.trashed)
            } else {
                await backups.rekey(from: file.trashed, to: file.original)
                try? await metadata?.transfer(from: file.trashed, to: file.original, mode: .move)
            }
        }
    }

    /// In-run rollback of a Replace victim that is in the Trash and whose name is free. While its Trash
    /// copy exists it comes back FROM the Trash with its chain and rating, and no bytes are written (no
    /// duplicate). Only when the Trash copy is gone does its history move to the free name FIRST and the
    /// bytes then come from the backup, so the victim's chain is live at its path.
    private func rollBackVictim(_ receipt: TrashReceipt, record: BackupRecord, result: inout BatchResult) async throws {
        if receipt.items.flatMap(\.files).contains(where: { FileManager.default.fileExists(atPath: $0.trashed.path) }) {
            let back = try await fileOps.restore(receipt)
            result.backupsNotSaved += back.backupsNotSaved
            if let failure = back.failures.first { throw failure.error }
        } else {
            await settleTrashHistory(of: receipt.items.flatMap(\.files))
            result.backupsNotSaved += try await backups.restoreReporting(record).notSaved
        }
    }

    // MARK: - Resolution (shared by preview and run)

    struct Resolved: Sendable {
        let row: BatchPreviewRow
        /// Existing file to Trash first (Replace).
        let replaceTarget: URL?
        let format: ExportFormat?
        let pixelCount: Int
    }

    static func resolve(_ plan: BatchPlan, items: [ImageGroup]) -> [Resolved] {
        resolve(plan, items: items, header: { Header($0) })
    }

    static func resolve(_ plan: BatchPlan, items: [ImageGroup], header read: (URL) -> Header?) -> [Resolved] {
        // Each header is read once here. A job that needs pixels skips an unreadable photo; a
        // job that only renames does not.
        let headers = items.map { read($0.primary) }
        let skipsUnreadable = plan.needsPixels
        let stems: [String]
        if items.allSatisfy({ plan.retryDestinations[$0] != nil }) {
            // Every real recovery result carries its first resolved name.
            // Do not re-read mutable metadata to create a different name.
            stems = items.map { plan.retryDestinations[$0]!.deletingPathExtension().lastPathComponent }
        } else if let template = plan.rename {
            // The counter must not count a photo that will be skipped: number only the others.
            let readable = items.indices.filter { !(skipsUnreadable && headers[$0] == nil) }
            func filledStems(for indices: [Int]) -> [String] {
                template.plan(for: indices.map { items[$0].primary }).map { ($0.newName as NSString).deletingPathExtension }
            }
            var all = items.map { stem(of: $0) }
            // A photo whose filled name is not usable is skipped and takes no counter number either, so
            // preview and run show no gap. Whether a name is usable is decided with a
            // probe fill: counter digits are always valid, so the verdict does not depend on the counter
            // value (no circular case).
            let probe = filledStems(for: readable)
            var counted: [Int] = []
            for (n, i) in readable.enumerated() {
                all[i] = probe[n]                                  // a skipped photo keeps its probe name
                if FileOps.nameProblem(probe[n]) == nil { counted.append(i) }
            }
            let real = filledStems(for: counted)
            for (n, i) in counted.enumerated() { all[i] = real[n] }
            stems = all
        } else {
            stems = items.map { stem(of: $0) }
        }
        var claimed = Set<String>()
        var out: [Resolved] = []
        out.reserveCapacity(items.count)
        let sources = Set(items.flatMap { $0.allURLs.map { CanonicalPath.key($0) } })

        for (i, group) in items.enumerated() {
            let src = group.primary
            let header = headers[i]
            var skip: BatchSkipReason? = (header == nil && skipsUnreadable) ? .unreadable : nil
            let folder: URL
            var format: ExportFormat?
            var ext = src.pathExtension
            let inPlace: Bool
            if plan.reencodes, case .folder(let f) = plan.output {
                folder = f
                inPlace = false
                format = plan.convert?.format ?? ExportFormat.inPlaceFormat(for: src) ?? .jpeg
                ext = format?.fileExtension ?? ext
            } else {
                folder = src.deletingLastPathComponent()
                inPlace = true
                if plan.reencodes {
                    format = ExportFormat.inPlaceFormat(for: src)
                    if format == nil, skip == nil { skip = .cannotSaveInPlace }
                } else if plan.quarters != 0, !LosslessRotator.isSupported(src), skip == nil {
                    skip = .cannotRotateLosslessly
                }
            }
            var stem = plan.retryDestinations[group]?.deletingPathExtension().lastPathComponent ?? stems[i]
            if stem.isEmpty, skip == nil { skip = .emptyName }
            // The filled template must be a usable name: the same shape rules as the Rename sheet,
            // so the preview and the run agree. Names that are not from a template stay as they are.
            if skip == nil, plan.rename != nil, plan.retryDestinations[group] == nil,
               let problem = FileOps.nameProblem(stem) {
                // A name of spaces only is empty too: preview and run agree.
                skip = problem == .empty ? .emptyName : .invalidName(problem)
            }
            if stem.isEmpty { stem = Self.stem(of: group) }

            var name = ext.isEmpty ? stem : "\(stem).\(ext)"
            var dest = folder.appendingPathComponent(name)
            var clash = false
            var replaceTarget: URL?
            var overwritesOriginal = false
            let unchanged = inPlace && name == src.lastPathComponent
            if !unchanged {
                let key = CanonicalPath.key(dest)
                // Writing into a folder, a queued photo's file is free only
                // when it is this item's own file and the user confirmed it.
                // Any other queued file is a name in use, like all others.
                overwritesOriginal = !inPlace && key == CanonicalPath.key(src)
                let allowed = overwritesOriginal && plan.overwritesOriginals
                let isSource = sources.contains(key)
                let onDisk = FileManager.default.fileExists(atPath: dest.path) && !(inPlace && isSource) && !allowed
                if claimed.contains(key) || onDisk {
                    clash = true
                    // Replace must never trash a photo of this batch, nor one of the run a retry continues.
                    let protected = (isSource && !inPlace) || plan.runSources.contains(key)
                    if claimed.contains(key) || plan.onConflict == .keepBoth || (protected && plan.onConflict == .replace) {
                        let isTaken: (URL) -> Bool = { url in
                            let k = CanonicalPath.key(url)
                            return claimed.contains(k)
                                || (FileManager.default.fileExists(atPath: url.path) && !(inPlace && sources.contains(k)))
                        }
                        name = FileOps.freeNames(for: [name], stem: stem, in: folder, isTaken: isTaken)[0]
                        dest = folder.appendingPathComponent(name)
                        overwritesOriginal = false
                    } else if plan.onConflict == .skip {
                        if skip == nil { skip = .nameExists }
                    } else {
                        replaceTarget = dest
                    }
                }
                claimed.insert(CanonicalPath.key(dest))
            }

            var size: CGSize?
            if let header {
                var s = header.displaySize
                if plan.quarters % 2 == 1 { s = CGSize(width: s.height, height: s.width) }
                if let resize = plan.resize { s = resize.targetSize(for: s) }
                size = s
            }
            out.append(Resolved(
                row: BatchPreviewRow(source: group, outputName: name, destination: dest,
                                     outputSize: size, nameClash: clash, skip: skip,
                                     overwritesOriginal: overwritesOriginal && skip == nil),
                replaceTarget: skip == nil ? replaceTarget : nil,
                format: format,
                pixelCount: header.map { Int($0.displaySize.width * $0.displaySize.height) } ?? 0))
        }
        return out
    }

    // MARK: - Execution

    /// Record resolution at the execution boundary, so early skips, active
    /// cancellation and never-started work retain the same provenance as
    /// successful/partially completed items. Existing actual-file fields and
    /// recovery receipts are copied without inventing a successful write.
    private static func recordingResolution(_ item: BatchItemResult, resolved: Resolved,
                                            plan: BatchPlan) -> BatchItemResult {
        let phases = (plan.resumePhases[item.source] ?? []).union(item.completedPhases)
        return BatchItemResult(source: item.source, outcome: item.outcome,
            completedPhases: [BatchPhase.rotate, .export, .rename].filter { phases.contains($0) },
            finalURL: item.finalURL, destinationURL: item.destinationURL,
            failurePhase: item.failurePhase, recoveryRequired: item.recoveryRequired,
            plannedDestinationURL: plan.retryDestinations[item.source] ?? item.plannedDestinationURL ?? resolved.row.destination,
            putBackAs: item.putBackAs)
    }

    private func execute(_ plan: BatchPlan,
                         emit: @escaping @Sendable (BatchProgress) -> Void) async throws -> BatchResult {
        if let error = plan.validationError { throw error }
        let resolved = Self.resolve(plan, items: plan.items)
        let total = resolved.count
        var result = BatchResult()
        if let previous = plan.previousChanges {
            result.backupsNotSaved = previous.backupsNotSaved
            result.renames = previous.renames; result.rotations = previous.rotations
            result.replacedOriginals = previous.replacedOriginals
            result.replacedVictims = previous.replacedVictims
        }
        emit(BatchProgress(completed: 0, total: total, currentName: resolved.first?.row.source.primary.lastPathComponent,
                           item: nil, result: nil))

        if case .folder(let folder) = plan.output, plan.reencodes {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        // Renames alone run in order (they're quick and names depend on
        // earlier items); everything else runs on the worker pool.
        if !plan.reencodes && plan.quarters == 0 {
            let staged = await stageBlockers(resolved, result: &result)
            let reserved = staged.isEmpty ? [] : Self.namesInPlay(resolved)
            var aside: [Aside] = []
            for r in resolved {
                let item = Self.recordingResolution(await renameItem(r, plan: plan, result: &result, staged: staged[r.row.source],
                                                                     reserved: reserved, aside: &aside), resolved: r, plan: plan)
                result.items.append(item)
                emit(BatchProgress(completed: result.items.count, total: total,
                                   currentName: r.row.source.primary.lastPathComponent, item: item, result: nil))
            }
            let settled = await settleAside(aside, reserved: reserved, result: &result)
            for (k, r) in resolved.enumerated() {
                if let item = settled[r.row.source] { result.items[k] = Self.recordingResolution(item, resolved: r, plan: plan) }
            }
            return result
        }

        let postRename = plan.rename != nil && (!plan.reencodes || { if case .inPlace = plan.output { return true }; return false }())
        var notDone = 0   // running count: re-filtering every item was O(n^2)
        try await withThrowingTaskGroup(of: (BatchItemResult, Change).self) { group in
            var next = 0
            func startNext() {
                guard next < resolved.count else { return }
                let r = resolved[next]
                next += 1
                group.addTask {
                    if Task.isCancelled {
                        return (Self.recordingResolution(BatchItemResult(source: r.row.source, outcome: .skipped(.cancelled)),
                                                         resolved: r, plan: plan), .none)
                    }
                    // ImageExporter admits the entire pixel pipeline by
                    // bytes before entering a decode lane. No count gate
                    // or nested reservation can deadlock its workers.
                    let (item, change) = await self.processItem(r, plan: plan)
                    return (Self.recordingResolution(item, resolved: r, plan: plan), change)
                }
            }
            for _ in 0..<Self.workerCount { startNext() }
            while let (item, change) = try await group.next() {
                result.items.append(item)
                if !item.isDone { notDone += 1 }
                switch change {
                case .none: break
                case .rotated(let rotation): result.rotations.append(rotation)
                case .replaced(let record, let notSaved):
                    result.replacedOriginals.append(record)
                    result.backupsNotSaved += notSaved
                }
                let settled = postRename ? notDone : result.items.count
                emit(BatchProgress(completed: settled, total: total,
                    currentName: item.source.primary.lastPathComponent, item: item, result: nil, phase: plan.reencodes ? .export : .rotate))
                if !Task.isCancelled { startNext() }
            }
        }
        // Items never started because of a Stop.
        let finished = Set(result.items.map(\.source))
        for r in resolved where !finished.contains(r.row.source) {
            result.items.append(Self.recordingResolution(
                BatchItemResult(source: r.row.source, outcome: .skipped(.cancelled)), resolved: r, plan: plan))
        }
        // In-place rename after a lossless rotate (Rotate + Rename).
        if postRename {
            var renamed = BatchResult()
            var settled = result.items.filter { !$0.isDone }.count
            var doneIndex: [ImageGroup: Int] = [:]
            for (i, item) in result.items.enumerated() where item.isDone && doneIndex[item.source] == nil { doneIndex[item.source] = i }
            let toRename = resolved.filter { doneIndex[$0.row.source] != nil }
            let staged = await stageBlockers(toRename, result: &renamed)
            // ALL photos: one whose rotate failed still wants its planned name.
            let reserved = staged.isEmpty ? [] : Self.namesInPlay(resolved)
            var aside: [Aside] = []
            var priors: [Int: BatchItemResult] = [:]
            func merged(_ prior: BatchItemResult, _ next: BatchItemResult, _ r: Resolved) -> BatchItemResult {
                Self.recordingResolution(BatchItemResult(source: next.source, outcome: next.outcome,
                    completedPhases: Array(Set(prior.completedPhases + next.completedPhases)), finalURL: next.finalURL,
                    destinationURL: r.row.destination, failurePhase: next.isDone ? nil : .rename,
                    recoveryRequired: next.recoveryRequired, plannedDestinationURL: prior.plannedDestinationURL,
                    putBackAs: next.putBackAs), resolved: r, plan: plan)
            }
            for r in resolved {
                guard let index = doneIndex[r.row.source] else { continue }
                let prior = result.items[index]
                priors[index] = prior
                let next = await renameItem(r, plan: plan, result: &renamed, staged: staged[r.row.source],
                                            reserved: reserved, aside: &aside)
                result.items[index] = merged(prior, next, r)
                settled += 1
                emit(BatchProgress(completed: settled, total: total, currentName: next.finalURL?.lastPathComponent,
                                   item: result.items[index], result: nil, phase: .rename))
            }
            let afterStop = await settleAside(aside, reserved: reserved, result: &renamed)
            for r in toRename {
                if let next = afterStop[r.row.source], let index = doneIndex[r.row.source], let prior = priors[index] {
                    result.items[index] = merged(prior, next, r)
                }
            }
            result.renames.append(contentsOf: renamed.renames)
            result.replacedOriginals.append(contentsOf: renamed.replacedOriginals)
            result.replacedVictims.append(contentsOf: renamed.replacedVictims)
        }
        return result
    }

    private enum Change: Sendable {
        case none
        case rotated(LosslessRotateResult)
        case replaced(BackupRecord, notSaved: Int)
    }

    /// A photo moved aside under a temporary name, and the journal entry that protects it meanwhile.
    struct Staged: Sendable {
        let moved: ImageGroup
        let journal: UUID?
    }

    /// A photo that was moved aside could not be put back under its name (its old name is taken, or
    /// the move failed). `nowCalled` is where it is: a free " 2" name next to its old one, or, only
    /// when even that move failed, the temporary name.
    struct StagedRenameError: LocalizedError, Sendable {
        let nowCalled: String
        let underlying: String
        var errorDescription: String? {
            ["The rename did not finish and the photo could not get its old name back. It is now called “\(nowCalled)”.", underlying]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    /// A moved-aside photo whose rename a Stop cancelled: settled with the others after the loop.
    struct Aside: Sendable {
        let resolved: Resolved
        let staged: Staged
    }

    /// Every name the queue's photos have now or are planned to get. A " 2" name given in a clean-up
    /// never takes one of them, even when it is free at that moment.
    private static func namesInPlay(_ resolved: [Resolved]) -> Set<String> {
        var names = Set<String>()
        for r in resolved {
            for url in r.row.source.allURLs { names.insert(CanonicalPath.key(url)) }
            if r.row.skip == nil { names.formUnion(targetKeys(of: r)) }
        }
        return names
    }

    private static func anyExists(_ urls: [URL]) -> Bool {
        urls.contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Names a rename of `r` would give to the files of its group.
    private static func targetKeys(of r: Resolved) -> [String] {
        let group = r.row.source
        let oldStem = stem(of: group)
        let newStem = (r.row.outputName as NSString).deletingPathExtension
        return group.allURLs.map { url in
            let name = url.lastPathComponent
            let lower = name.lowercased(), lowerStem = oldStem.lowercased()
            let renamed = lower.hasPrefix(lowerStem + ".") || lower == lowerStem
                ? newStem + String(name.dropFirst(oldStem.count))
                : (((name as NSString).pathExtension.isEmpty) ? newStem : newStem + "." + (name as NSString).pathExtension)
            return CanonicalPath.key(url.deletingLastPathComponent().appendingPathComponent(renamed))
        }
    }

    /// When a new name is the current name of another photo that is
    /// also being renamed (1→2, 2→3 or a swap), the second photo must get
    /// out of the way first. Phase 1 gives every such photo a temporary
    /// name; the normal rename then runs in list order and finds its name
    /// free (phase 2). Both steps go into `result.renames`, so Undo, which
    /// walks them backwards, never meets a taken name either. Returns the
    /// moved-aside group by original group.
    private func stageBlockers(_ resolved: [Resolved], result: inout BatchResult) async -> [ImageGroup: Staged] {
        let movers = resolved.filter {
            $0.row.skip == nil && $0.row.outputName != $0.row.source.primary.lastPathComponent
        }
        guard movers.count > 1 else { return [:] }
        var owner: [String: Int] = [:]
        for (i, r) in movers.enumerated() {
            for url in r.row.source.allURLs { owner[CanonicalPath.key(url)] = i }
        }
        var blockers = Set<Int>()
        for (i, r) in movers.enumerated() {
            for key in Self.targetKeys(of: r) {
                if let j = owner[key], j != i { blockers.insert(j) }
            }
        }
        var staged: [ImageGroup: Staged] = [:]
        for j in blockers.sorted() {
            if Task.isCancelled { break }
            let group = movers[j].row.source
            do { try await cleanupCheckpoint?(.beforeStage, group.primary) } catch { continue }
            let tempStem = "\(Self.stem(of: group))\(Self.temporaryMarker)\(UUID().uuidString.prefix(8))"
            // Until this photo is back under a real name, it is only known by the temp name. Note
            // that in the journal first, so a crash here can be repaired at the next launch.
            let temps = FileOps.renamedURLs(of: group, toStem: tempStem)
            let finals = FileOps.renamedURLs(of: group, toStem: (movers[j].row.outputName as NSString).deletingPathExtension)
            let journalID = RenameJournal.shared.begin(
                moves: (0..<group.allURLs.count).map { (original: group.allURLs[$0], temporary: temps[$0], final: finals[$0] as URL?) })
            do {
                let reported = try await fileOps.renameReporting(group, toStem: tempStem, relaxed: true)
                let moved = reported.group
                result.backupsNotSaved += reported.backupsNotSaved
                result.renames.append((group, moved))
                staged[group] = Staged(moved: moved, journal: journalID)
            } catch {
                RenameJournal.shared.end(journalID)
                continue   // stays put; whoever needs its name fails safely
            }
        }
        return staged
    }

    /// Renames `r`; a photo that was moved aside (`staged`) is renamed from there. If this rename
    /// fails, the photo is given back its old name at once (`giveBack`); if a Stop cancelled it, it
    /// goes to `aside` and `settleAside` decides after the loop, with all the others.
    private func renameItem(_ r: Resolved, plan: BatchPlan, result: inout BatchResult,
                            staged: Staged?, reserved: Set<String>, aside: inout [Aside]) async -> BatchItemResult {
        let item = await renameItemCore(r, plan: plan, result: &result, from: staged?.moved ?? r.row.source)
        guard let staged else { return item }
        guard !item.isDone else {
            RenameJournal.shared.end(staged.journal)   // it left the temp name for its final one
            return item
        }
        if case .skipped(.cancelled) = item.outcome {
            aside.append(Aside(resolved: r, staged: staged))
            return item
        }
        return await giveBack(r, staged, item: item, reserved: reserved, result: &result)
    }

    /// After a Stop, the photos still under a temporary name. Each gets exactly one move, so the
    /// clean-up is as short as the old put-back. A photo whose old name a finished rename of this run
    /// took moves on to its PLANNED name. That name is free: it was the old name of a photo that was
    /// also moved aside (every such photo was), or a free name. Then the photo whose old name that
    /// was must move on too, and so on: this closes each open swap or shift, and nothing else.
    /// Every other photo goes back to its old name. A photo that can do neither ends under a free
    /// " 2" name (`giveBack`). Returns the new result of each photo, by its group.
    private func settleAside(_ aside: [Aside], reserved: Set<String>,
                             result: inout BatchResult) async -> [ImageGroup: BatchItemResult] {
        var settled: [ImageGroup: BatchItemResult] = [:]
        guard !aside.isEmpty else { return settled }
        var byOldName: [String: Int] = [:]
        for (i, a) in aside.enumerated() {
            for url in a.resolved.row.source.allURLs { byOldName[CanonicalPath.key(url)] = i }
        }
        var tried = Set<Int>()
        var queue = aside.indices.filter { Self.anyExists(aside[$0].resolved.row.source.allURLs) }
        while let i = queue.popLast() {
            // With Replace, the planned name holds a file that is not of this batch: the clean-up
            // never trashes anything, so that photo is given back instead.
            guard tried.insert(i).inserted, aside[i].resolved.replaceTarget == nil else { continue }
            let r = aside[i].resolved, staged = aside[i].staged
            do {
                try await cleanupCheckpoint?(.beforeCleanup, r.row.source.primary)
                let moved = try await fileOps.renameReporting(
                    staged.moved, toStem: (r.row.outputName as NSString).deletingPathExtension, relaxed: false)
                result.backupsNotSaved += moved.backupsNotSaved
                result.renames.append((staged.moved, moved.group))
                RenameJournal.shared.end(staged.journal)
                settled[r.row.source] = BatchItemResult(source: r.row.source, outcome: .done(moved.group.primary),
                                                        completedPhases: [.rename], finalURL: moved.group.primary,
                                                        destinationURL: r.row.destination)
                for key in Self.targetKeys(of: r) {
                    if let j = byOldName[key], !tried.contains(j) { queue.append(j) }
                }
            } catch {}   // given back below
        }
        for a in aside where settled[a.resolved.row.source] == nil {
            settled[a.resolved.row.source] = await giveBack(
                a.resolved, a.staged, item: BatchItemResult(source: a.resolved.row.source, outcome: .skipped(.cancelled)),
                reserved: reserved, result: &result)
        }
        return settled
    }

    /// Puts a moved-aside photo back under its old name and returns `item`. When that name is taken
    /// (a finished rename of this run has it) or the move fails, the photo gets the first free " 2"
    /// name next to it, never one in `reserved`, and fails with `StagedRenameError` naming it.
    /// Only when that move fails too does it stay under the temporary name, with its journal entry,
    /// so the next launch can still repair it.
    private func giveBack(_ r: Resolved, _ staged: Staged, item: BatchItemResult, reserved: Set<String>,
                          result: inout BatchResult) async -> BatchItemResult {
        let source = r.row.source
        var why: String = if case .failed(let error) = item.outcome { error.localizedDescription } else { "" }
        if !Self.anyExists(source.allURLs) {
            do {
                try await cleanupCheckpoint?(.beforeCleanup, source.primary)
                let back = try await fileOps.renameReporting(staged.moved, toStem: Self.stem(of: source), relaxed: true)
                result.backupsNotSaved += back.backupsNotSaved
                result.renames.append((staged.moved, back.group))
                RenameJournal.shared.end(staged.journal)
                return item
            } catch {
                if why.isEmpty { why = error.localizedDescription }
            }
        }
        var now = staged.moved.primary
        var putBackAs: URL?
        do {
            // The entry as `stageBlockers` wrote it, for when this move fails.
            let planned = FileOps.renamedURLs(of: source, toStem: (r.row.outputName as NSString).deletingPathExtension)
            let restore = (0..<min(source.allURLs.count, staged.moved.allURLs.count)).map {
                (original: source.allURLs[$0], temporary: staged.moved.allURLs[$0], final: planned[$0] as URL?)
            }
            let moved = try await moveToSecondName(staged.moved, nextTo: source, journal: staged.journal,
                                                   restore: restore, reserved: reserved)
            result.backupsNotSaved += moved.backupsNotSaved
            result.renames.append((staged.moved, moved.group))
            now = moved.group.primary
            putBackAs = now
        } catch {
            if why.isEmpty { why = error.localizedDescription }
        }
        return BatchItemResult(source: source,
                               outcome: .failed(StagedRenameError(nowCalled: now.lastPathComponent, underlying: why)),
                               finalURL: now, destinationURL: r.row.destination, failurePhase: .rename, putBackAs: putBackAs)
    }

    /// Moves `temp` (a photo under a temporary name) to the first free " 2" name next to `old`, never
    /// one in `reserved`. First the photo's journal entry `journal` is rewritten so that its final is
    /// that name (one rewrite of the same entry, so there is never a moment without one): a kill
    /// between the move and its bookkeeping is repaired at the next launch. The entry is
    /// ended once the photo has the name; if the move fails, the entry is put back to `restore`, its
    /// moves before this call, so it never names a " 2" file that does not exist.
    private func moveToSecondName(_ temp: ImageGroup, nextTo old: ImageGroup, journal: UUID?,
                                  restore: [(original: URL, temporary: URL, final: URL?)],
                                  reserved: Set<String>) async throws -> RenameResult {
        let second = FileOps.freeNames(for: old.allURLs.map(\.lastPathComponent), stem: Self.stem(of: old),
                                       in: old.primary.deletingLastPathComponent()) {
            reserved.contains(CanonicalPath.key($0)) || FileManager.default.fileExists(atPath: $0.path)
        }
        let secondStem = (second[0] as NSString).deletingPathExtension
        let finals = FileOps.renamedURLs(of: temp, toStem: secondStem)
        let entry = RenameJournal.shared.replace(journal, moves: (0..<min(old.allURLs.count, temp.allURLs.count)).map {
            (original: old.allURLs[$0], temporary: temp.allURLs[$0], final: finals[$0] as URL?)
        })
        do {
            try await cleanupCheckpoint?(.beforeCleanup, old.primary)
            let moved = try await fileOps.renameReporting(temp, toStem: secondStem, relaxed: true)
            RenameJournal.shared.end(entry)
            return moved
        } catch {
            _ = RenameJournal.shared.replace(entry, moves: restore)
            throw error
        }
    }

    /// The temporary names Batch gives photos it sets aside contain this (`stageBlockers`).
    static let temporaryMarker = " shrike-tmp-"
    static func isTemporary(_ group: ImageGroup) -> Bool { stem(of: group).contains(temporaryMarker) }

    private func renameItemCore(_ r: Resolved, plan: BatchPlan, result: inout BatchResult,
                                from current: ImageGroup) async -> BatchItemResult {
        let group = r.row.source
        if Task.isCancelled {
            // A photo that already has its planned name and was not moved
            // aside has nothing to do: done, as in an unstopped run.
            // A moved-aside photo stays cancelled so the
            // clean-up after the loop settles it.
            if current == group, r.row.skip == nil, r.row.outputName == group.primary.lastPathComponent {
                return BatchItemResult(source: group, outcome: .done(group.primary))
            }
            return BatchItemResult(source: group, outcome: .skipped(.cancelled))
        }
        if let skip = r.row.skip { return BatchItemResult(source: group, outcome: .skipped(skip)) }
        if r.row.outputName == group.primary.lastPathComponent {
            return BatchItemResult(source: group, outcome: .done(group.primary))
        }
        var replaced: BackupRecord?
        var victimReceipt: TrashReceipt?
        do {
            try await phaseCheckpoint?(.rename, group.primary)
            try Task.checkCancellation()
            // Renaming begins its commit only after a recoverable victim
            // copy exists. Failure rolls the destination path back.
            if let victim = r.replaceTarget {
                replaced = try await backups.backup(victim, reason: .replace)
                try Task.checkCancellation()
                // A volume with no Trash throws `.noTrash` here: the item fails and nothing is deleted
                // (as in 0.2.32).
                let receipt = try await fileOps.trash([ImageGroup(primary: victim)])
                result.backupsNotSaved += receipt.backupsNotSaved
                victimReceipt = receipt
            } else { try Task.checkCancellation() }
            try await renameCheckpoint?(.beforeMove, group.primary)
            let newStem = (r.row.outputName as NSString).deletingPathExtension
            let reported = try await fileOps.renameReporting(current, toStem: newStem, relaxed: false)
            let renamed = reported.group
            result.backupsNotSaved += reported.backupsNotSaved
            result.renames.append((current, renamed))
            if let replaced {
                result.replacedOriginals.append(replaced)
                if let victimReceipt { result.replacedVictims.append(victimReceipt) }
            }
            return BatchItemResult(source: group, outcome: .done(renamed.primary), completedPhases: [.rename],
                                   finalURL: renamed.primary, destinationURL: r.row.destination)
        } catch let operationError {
            if let replaced, !FileManager.default.fileExists(atPath: replaced.originalPath) {
                do {
                    try await renameCheckpoint?(.beforeRollback, replaced.originalURL)
                    if let victimReceipt {
                        try await rollBackVictim(victimReceipt, record: replaced, result: &result)
                    } else {
                        result.backupsNotSaved += try await backups.restoreReporting(replaced).notSaved   // the Trash move itself failed (as 0.2.32)
                    }
                } catch let recoveryError {
                    result.replacedOriginals.append(replaced)
                    if let victimReceipt { result.replacedVictims.append(victimReceipt) }
                    let failure = BatchRecoveryRequiredError(record: replaced, operationError: operationError,
                                                             recoveryError: recoveryError)
                    return BatchItemResult(source: group, outcome: .failed(failure), destinationURL: r.row.destination,
                                           failurePhase: .rename, recoveryRequired: replaced)
                }
            } else if let replaced, let victimReceipt {
                // Another file took the victim's name meanwhile: nothing is written there. The victim stays
                // in the Trash with its chain, and its receipt is kept so Batch Undo can put it back under
                // a free name.
                result.replacedOriginals.append(replaced)
                result.replacedVictims.append(victimReceipt)
            }
            return BatchItemResult(source: group, outcome: Self.outcome(for: operationError), destinationURL: r.row.destination, failurePhase: .rename)
        }
    }

    private func processItem(_ r: Resolved, plan: BatchPlan) async -> (BatchItemResult, Change) {
        let group = r.row.source
        let src = group.primary
        if let skip = r.row.skip { return (BatchItemResult(source: group, outcome: .skipped(skip)), .none) }
        do {
            // Lossless in-place rotate (no re-encode).
            if !plan.reencodes {
                if plan.resumePhases[group]?.contains(.rotate) == true {
                    return (BatchItemResult(source: group, outcome: .done(src), completedPhases: [.rotate], destinationURL: r.row.destination), .none)
                }
                try await phaseCheckpoint?(.rotate, src)
                try Task.checkCancellation()
                let rotation = try await LosslessRotator(backupStore: backups).rotate(url: src, quarters: plan.quarters)
                return (BatchItemResult(source: group, outcome: .done(src), completedPhases: [.rotate], destinationURL: r.row.destination), .rotated(rotation))
            }
            if plan.resumePhases[group]?.contains(.export) == true {
                return (BatchItemResult(source: group, outcome: .done(src), completedPhases: [.export], destinationURL: r.row.destination), .none)
            }
            var ops: [EditOperation] = plan.recipe ?? []
            if plan.quarters != 0 { ops.append(.rotate90(quarters: plan.quarters)) }
            if let resize = plan.resize, let size = r.row.outputSize {
                ops.append(.resize(ResizeSpec(width: Int(size.width), height: Int(size.height),
                                              interpolation: .lanczos, preventUpscale: resize.dontEnlarge)))
            }
            let format = r.format ?? .jpeg
            try await phaseCheckpoint?(.export, src)
            let convert = plan.convert
            let quality = convert?.quality ?? ImageExporter.defaultQuality
            if Task.isCancelled { return (BatchItemResult(source: group, outcome: .skipped(.cancelled)), .none) }

            if case .folder = plan.output {
                let exported = try await ImageExporter(backupStore: backups, metadataStore: metadata).exportReporting(
                    recipe: EditRecipe(operations: ops), from: src, to: r.row.destination, format: format,
                    quality: quality, preserveEXIF: convert?.keepMetadata ?? true,
                    stripGPS: convert?.removeLocation ?? false,
                    backupReason: r.row.overwritesOriginal ? .batch : .replace, resourceCategory: .batchWork)
                return (BatchItemResult(source: group, outcome: .done(r.row.destination), completedPhases: [.export],
                                        destinationURL: r.row.destination), exported.record.map { Change.replaced($0, notSaved: exported.backupsNotSaved) } ?? .none)
            }
            let exported = try await ImageExporter(backupStore: backups, metadataStore: metadata).exportReporting(
                recipe: EditRecipe(operations: ops), from: src, to: src, format: format, quality: quality,
                backupReason: .batch, resourceCategory: .batchWork)
            return (BatchItemResult(source: group, outcome: .done(src), completedPhases: [.export], destinationURL: r.row.destination),
                    exported.record.map { Change.replaced($0, notSaved: exported.backupsNotSaved) } ?? .none)
        } catch {
            return (BatchItemResult(source: group, outcome: Self.outcome(for: error), destinationURL: r.row.destination,
                                    failurePhase: plan.reencodes ? .export : .rotate), .none)
        }
    }

    // MARK: - Helpers

    static func outcome(for error: any Error) -> BatchItemOutcome {
        if error is CancellationError { return .skipped(.cancelled) }
        if let e = error as? ExportError, case .sourceUnreadable = e { return .skipped(.unreadable) }
        // "Disk full" is decided by error code, never by words in the message: a folder called
        // "Workspace" must not look like a full disk.
        if let e = error as? BackupError, case .insufficientSpace = e { return .skipped(.diskFull) }
        if let e = error as? ExportError {
            if case .diskFull = e { return .skipped(.diskFull) }
            // Export and rotate flatten a backup error into text; its case name is ours, not free text.
            if case .backupFailed(let text) = e, text.hasPrefix("insufficientSpace(") { return .skipped(.diskFull) }
        }
        if let e = error as? LosslessRotateError, case .backupFailed(let text) = e, text.hasPrefix("insufficientSpace(") {
            return .skipped(.diskFull)
        }
        if BackupStore.isOutOfSpace(error) { return .skipped(.diskFull) }
        if let e = error as? FileOpsError, case .nameTaken = e { return .skipped(.nameExists) }
        return .failed(error)
    }

    static func stem(of group: ImageGroup) -> String {
        group.primary.deletingPathExtension().lastPathComponent
    }

    /// Display-oriented pixel size from the header (no decode).
    struct Header {
        let displaySize: CGSize
        init?(_ url: URL) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int
            else { return nil }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            displaySize = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
    }
}

extension BatchItemResult {
    var isDone: Bool { if case .done = outcome { return true }; return false }
}

/// The Batch window's Stop, for `BatchRunner.run(_:stop:)`.
/// Safe to call from any thread, before or during the run.
public final class BatchStop: Sendable {
    private struct State: Sendable {
        var stopped = false
        var settled = false
        var work: Task<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isStopped: Bool { state.withLock { $0.stopped } }
    public var isSettled: Bool { state.withLock { $0.settled } }

    public func stop() {
        let work = state.withLock { s -> Task<Void, Never>? in
            s.stopped = true
            return s.work
        }
        work?.cancel()
    }

    func attach(_ work: Task<Void, Never>) {
        let stopped = state.withLock { s -> Bool in
            if !s.settled { s.work = work }
            return s.stopped
        }
        if stopped { work.cancel() }
    }
    fileprivate func prepareRun() { state.withLock { $0.settled = false } }
    fileprivate func markSettled() { state.withLock { $0.settled = true; $0.work = nil } }
}

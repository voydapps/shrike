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
        case .cancelled: return "Cancelled."
        case .cannotSaveInPlace: return "Shrike can't save this file type in place — skipped."
        case .emptyName: return "The new name would be empty — skipped."
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
    public var isPartial: Bool { recoveryRequired != nil || (!completedPhases.isEmpty && !isDone) }
    public init(source: ImageGroup, outcome: BatchItemOutcome, completedPhases: [BatchPhase] = [],
                finalURL: URL? = nil, destinationURL: URL? = nil, failurePhase: BatchPhase? = nil,
                recoveryRequired: BackupRecord? = nil, plannedDestinationURL: URL? = nil) {
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
        let unfinished = result.items.filter { item in
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
        plan.items = retry.map(\.source)
        plan.resumePhases = Dictionary(uniqueKeysWithValues: retry.map {
            ($0.source, (original.resumePhases[$0.source] ?? []).union($0.completedPhases))
        })
        plan.retryDestinations = Dictionary(uniqueKeysWithValues: retry.compactMap { item in
            (original.retryDestinations[item.source] ?? item.plannedDestinationURL ?? item.destinationURL)
                .map { (item.source, $0) }
        })
        plan.previousChanges = result
        return plan
    }

    // MARK: Run

    public func run(_ plan: BatchPlan) -> AsyncThrowingStream<BatchProgress, any Error> {
        run(plan, stop: BatchStop())
    }

    /// Like `run(_:)`, with a Stop button: `stop.stop()` starts no new
    /// items and cancels the ones in flight, and the stream still ends
    /// with the last event carrying `result` ("Cancelled." rows included,
    /// finished in-place work undoable). Ending the stream instead also
    /// stops the work, but that last event is lost.
    public func run(_ plan: BatchPlan, stop: BatchStop) -> AsyncThrowingStream<BatchProgress, any Error> {
        AsyncThrowingStream { continuation in
            stop.prepareRun()
            let work = Task {
                let resizeScope = ResizeTool.beginBatchProcessing()
                defer { resizeScope.finish(); stop.markSettled() }
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
    public func undo(_ result: BatchResult) async throws {
        var firstError: (any Error)?
        for rename in result.renames.reversed() {
            do { _ = try await fileOps.rename(rename.after, toStem: Self.stem(of: rename.before)) }
            catch { firstError = firstError ?? error }
        }
        if !result.rotations.isEmpty {
            let rotator = LosslessRotator(backupStore: backups)
            for rotation in result.rotations.reversed() {
                do { try await rotator.undo(rotation) } catch { firstError = firstError ?? error }
            }
        }
        for record in result.replacedOriginals {
            do { try await backups.restore(record) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
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
        let stems: [String]
        if items.allSatisfy({ plan.retryDestinations[$0] != nil }) {
            // Every real recovery result carries its first resolved name.
            // Do not re-read mutable metadata to create a different name.
            stems = items.map { plan.retryDestinations[$0]!.deletingPathExtension().lastPathComponent }
        } else if let template = plan.rename {
            stems = template.plan(for: items.map(\.primary)).map { ($0.newName as NSString).deletingPathExtension }
        } else {
            stems = items.map { stem(of: $0) }
        }
        var claimed = Set<String>()
        var out: [Resolved] = []
        out.reserveCapacity(items.count)
        let sources = Set(items.flatMap { $0.allURLs.map { CanonicalPath.key($0) } })

        for (i, group) in items.enumerated() {
            let src = group.primary
            let header = Header(src)
            var skip: BatchSkipReason? = header == nil ? .unreadable : nil
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
                    // Replace must never trash a photo of this batch.
                    let protected = isSource && !inPlace
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
            plannedDestinationURL: plan.retryDestinations[item.source] ?? item.plannedDestinationURL ?? resolved.row.destination)
    }

    private func execute(_ plan: BatchPlan,
                         emit: @escaping @Sendable (BatchProgress) -> Void) async throws -> BatchResult {
        if let error = plan.validationError { throw error }
        let resolved = Self.resolve(plan, items: plan.items)
        let total = resolved.count
        var result = BatchResult()
        if let previous = plan.previousChanges {
            result.renames = previous.renames; result.rotations = previous.rotations
            result.replacedOriginals = previous.replacedOriginals
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
            for r in resolved {
                let item = Self.recordingResolution(await renameItem(r, plan: plan, result: &result, staged: staged[r.row.source]), resolved: r, plan: plan)
                result.items.append(item)
                emit(BatchProgress(completed: result.items.count, total: total,
                                   currentName: r.row.source.primary.lastPathComponent, item: item, result: nil))
            }
            return result
        }

        let postRename = plan.rename != nil && (!plan.reencodes || { if case .inPlace = plan.output { return true }; return false }())
        var notDone = 0   // running count: re-filtering every item was O(n^2) (audit MP-13)
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
                case .replaced(let record): result.replacedOriginals.append(record)
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
            let staged = await stageBlockers(resolved.filter { doneIndex[$0.row.source] != nil }, result: &renamed)
            for r in resolved {
                guard let index = doneIndex[r.row.source] else { continue }
                let prior = result.items[index]
                let next = await renameItem(r, plan: plan, result: &renamed, staged: staged[r.row.source])
                result.items[index] = Self.recordingResolution(BatchItemResult(source: next.source, outcome: next.outcome,
                    completedPhases: Array(Set(prior.completedPhases + next.completedPhases)), finalURL: next.finalURL,
                    destinationURL: r.row.destination, failurePhase: next.isDone ? nil : .rename,
                    recoveryRequired: next.recoveryRequired, plannedDestinationURL: prior.plannedDestinationURL), resolved: r, plan: plan)
                settled += 1
                emit(BatchProgress(completed: settled, total: total, currentName: next.finalURL?.lastPathComponent,
                                   item: result.items[index], result: nil, phase: .rename))
            }
            result.renames.append(contentsOf: renamed.renames)
            result.replacedOriginals.append(contentsOf: renamed.replacedOriginals)
        }
        return result
    }

    private enum Change: Sendable {
        case none
        case rotated(LosslessRotateResult)
        case replaced(BackupRecord)
    }

    /// A photo that was moved aside could not be put back under its name.
    struct StagedRenameError: LocalizedError, Sendable {
        let tempName: String
        let underlying: String
        var errorDescription: String? {
            "The rename did not finish and the photo could not get its old name back. It is now called “\(tempName)”. \(underlying)"
        }
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

    /// COR-3. When a new name is the current name of another photo that is
    /// also being renamed (1→2, 2→3 or a swap), the second photo must get
    /// out of the way first. Phase 1 gives every such photo a temporary
    /// name; the normal rename then runs in list order and finds its name
    /// free (phase 2). Both steps go into `result.renames`, so Undo, which
    /// walks them backwards, never meets a taken name either. Returns the
    /// moved-aside group by original group.
    private func stageBlockers(_ resolved: [Resolved], result: inout BatchResult) async -> [ImageGroup: ImageGroup] {
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
        var staged: [ImageGroup: ImageGroup] = [:]
        for j in blockers.sorted() {
            if Task.isCancelled { break }
            let group = movers[j].row.source
            let tempStem = "\(Self.stem(of: group)) shrike-tmp-\(UUID().uuidString.prefix(8))"
            do {
                let moved = try await fileOps.rename(group, toStem: tempStem)
                result.renames.append((group, moved))
                staged[group] = moved
            } catch { continue }   // stays put; whoever needs its name fails safely
        }
        return staged
    }

    /// Renames `r`; a photo that was moved aside (`staged`) is renamed from
    /// there, and put back under its old name if this rename does not happen.
    private func renameItem(_ r: Resolved, plan: BatchPlan, result: inout BatchResult,
                            staged: ImageGroup? = nil) async -> BatchItemResult {
        let item = await renameItemCore(r, plan: plan, result: &result, from: staged ?? r.row.source)
        guard let staged, !item.isDone else { return item }
        do {
            let back = try await fileOps.rename(staged, toStem: Self.stem(of: r.row.source))
            result.renames.append((staged, back))
            return item
        } catch {
            return BatchItemResult(source: r.row.source,
                                   outcome: .failed(StagedRenameError(tempName: staged.primary.lastPathComponent,
                                                                      underlying: error.localizedDescription)),
                                   destinationURL: r.row.destination, failurePhase: .rename)
        }
    }

    private func renameItemCore(_ r: Resolved, plan: BatchPlan, result: inout BatchResult,
                                from current: ImageGroup) async -> BatchItemResult {
        let group = r.row.source
        if Task.isCancelled { return BatchItemResult(source: group, outcome: .skipped(.cancelled)) }
        if let skip = r.row.skip { return BatchItemResult(source: group, outcome: .skipped(skip)) }
        if r.row.outputName == group.primary.lastPathComponent {
            return BatchItemResult(source: group, outcome: .done(group.primary))
        }
        var replaced: BackupRecord?
        do {
            try await phaseCheckpoint?(.rename, group.primary)
            try Task.checkCancellation()
            // Renaming begins its commit only after a recoverable victim
            // copy exists. Failure rolls the destination path back.
            if let victim = r.replaceTarget {
                replaced = try await backups.backup(victim, reason: .replace)
                try Task.checkCancellation()
                _ = try await fileOps.trash([ImageGroup(primary: victim)])
            } else { try Task.checkCancellation() }
            try await renameCheckpoint?(.beforeMove, group.primary)
            let newStem = (r.row.outputName as NSString).deletingPathExtension
            let renamed = try await fileOps.rename(current, toStem: newStem)
            result.renames.append((current, renamed))
            if let replaced { result.replacedOriginals.append(replaced) }
            return BatchItemResult(source: group, outcome: .done(renamed.primary), completedPhases: [.rename],
                                   finalURL: renamed.primary, destinationURL: r.row.destination)
        } catch let operationError {
            if let replaced, !FileManager.default.fileExists(atPath: replaced.originalPath) {
                do {
                    try await renameCheckpoint?(.beforeRollback, replaced.originalURL)
                    _ = try await backups.restore(replaced)
                } catch let recoveryError {
                    result.replacedOriginals.append(replaced)
                    let failure = BatchRecoveryRequiredError(record: replaced, operationError: operationError,
                                                             recoveryError: recoveryError)
                    return BatchItemResult(source: group, outcome: .failed(failure), destinationURL: r.row.destination,
                                           failurePhase: .rename, recoveryRequired: replaced)
                }
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
                let record = try await ImageExporter(backupStore: backups, metadataStore: metadata).export(
                    recipe: EditRecipe(operations: ops), from: src, to: r.row.destination, format: format,
                    quality: quality, preserveEXIF: convert?.keepMetadata ?? true,
                    stripGPS: convert?.removeLocation ?? false,
                    backupReason: r.row.overwritesOriginal ? .batch : .replace, resourceCategory: .batchWork)
                return (BatchItemResult(source: group, outcome: .done(r.row.destination), completedPhases: [.export],
                                        destinationURL: r.row.destination), record.map(Change.replaced) ?? .none)
            }
            let record = try await ImageExporter(backupStore: backups, metadataStore: metadata).export(
                recipe: EditRecipe(operations: ops), from: src, to: src, format: format, quality: quality,
                backupReason: .batch, resourceCategory: .batchWork)
            return (BatchItemResult(source: group, outcome: .done(src), completedPhases: [.export], destinationURL: r.row.destination),
                    record.map(Change.replaced) ?? .none)
        } catch {
            return (BatchItemResult(source: group, outcome: Self.outcome(for: error), destinationURL: r.row.destination,
                                    failurePhase: plan.reencodes ? .export : .rotate), .none)
        }
    }

    // MARK: - Helpers

    static func outcome(for error: any Error) -> BatchItemOutcome {
        if error is CancellationError { return .skipped(.cancelled) }
        if let e = error as? ExportError, case .sourceUnreadable = e { return .skipped(.unreadable) }
        if let e = error as? BackupError, "\(e)".localizedCaseInsensitiveContains("space") { return .skipped(.diskFull) }
        if (error as NSError).domain == NSCocoaErrorDomain, (error as NSError).code == NSFileWriteOutOfSpaceError {
            return .skipped(.diskFull)
        }
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

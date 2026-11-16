//
//  BatchModel.swift
//  ShrikeUI
//
//  State of the Batch window: the queue, the form, the live
//  preview, the presets and the run. Every rule about names, clashes,
//  skips, validation and presets lives in the engine (`BatchRunner`,
//  `BatchPlan`, `RenameTemplate`, `BatchPresetStore`); this model only
//  turns the form into a `BatchPlan` and shows what the engine says.
//  Disk reads (preview, validation, image sizes) run off the main thread.
//

import AppKit
import Combine
import ImageIO
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// One queue row (the counter follows the queue order).
public struct BatchQueueItem: Identifiable, Hashable, Sendable {
    public let group: ImageGroup
    public var id: URL { group.primary }
    public var name: String { group.primary.lastPathComponent }
}

/// Rotate choices (Right 90° / Left 90° / 180°).
public enum BatchRotation: Int, CaseIterable, Sendable, Hashable {
    case right = 1
    case half = 2
    case left = 3

    /// Quarter turns clockwise, as `BatchPlan.rotate` takes them.
    public var quarters: Int { rawValue }

    public var title: String {
        switch self {
        case .right: return "Right 90°"
        case .left: return "Left 90°"
        case .half: return "180°"
        }
    }

    /// Popup order: Right, Left, 180.
    public static let menuOrder: [BatchRotation] = [.right, .left, .half]

    public init?(quarters: Int) {
        self.init(rawValue: ((quarters % 4) + 4) % 4)
    }
}

/// The form, one value so a change is one preview.
public struct BatchForm: Equatable, Sendable {
    public var convertOn = true
    public var format: ExportFormat = .jpeg
    /// 60…100.
    public var quality = 85
    public var keepMetadata = true
    public var removeLocation = false

    public var resizeOn = true
    public var resizeMode: ResizeOptions.Mode = .longEdge
    public var resizeValue = 2048
    public var dontEnlarge = true

    public var rotateOn = false
    public var rotation: BatchRotation = .right

    public var renameOn = false
    public var template = "{yyyy-MM-dd}_{counter:000}"
    public var counterStart = 1
    public var nameCase: NameCase = .keep

    /// nil = the default "<first item's folder>/Shrike Export".
    public var outputFolder: URL?
    public var onConflict: ConflictAnswer.Action = .keepBoth

    public init() {}

    /// New files go to the Output folder (Convert or Resize on).
    public var writesToFolder: Bool { convertOn || resizeOn }
}

@MainActor
public final class BatchModel: ObservableObject {

    public enum Phase: Equatable, Sendable { case form, running, done }

    /// One skipped item on the Done view.
    public struct SkippedRow: Hashable, Sendable {
        public let name: String
        public let reason: String
        public let source: URL
        /// A skip the user can include in Review Remaining by ticking it
        /// (not "Canceled.", unreadable or disk full: those retry by themselves).
        public var isIntentionalSkip = false
    }

    // MARK: Copy (new lines marked)

    public enum Copy {
        public static let defaultOutputFolderName = "Shrike Export"
        public static let inPlaceRotate = "Changes the original files. Undo works while Shrike still has the backup."
        /// Rename only, in place (`renamesOnlyInPlace`): no pixels change, no pixel backup.
        public static func inPlace(_ count: Int) -> String {
            count == 1 ? "Only the name changes. Undo Batch can put the old name back."
                       : "Only the names change. Undo Batch can put the old names back."
        }
        /// The queue is empty.
        public static let emptyQueue = "Add photos to the queue."
        /// An item failed for a reason the batch runner has no line for.
        public static let failed = "Shrike couldn't write this file."
        /// The run could not start.
        public static let couldNotStart = "Shrike couldn't start the batch."
        public static let customPreset = "Custom"
        public static let emptyTemplate = "Enter a name template."
        public static let unclosedBrace = "Missing “}” in the name."

        public static func images(_ n: Int) -> String { n == 1 ? "1 photo" : "\(n.formatted(.number)) photos" }
        /// The window title is one name; the count is the subtitle.
        public static let windowTitle = "Batch"
        public static func subtitle(_ n: Int) -> String { images(n) }
        /// "Example: 2026-11-10_001.jpg"; nil for a missing or empty name.
        public static func exampleLine(outputName: String?) -> String? {
            guard let name = outputName, !name.isEmpty else { return nil }
            return "Example: \(name)"
        }
        /// The Output row when the plan changes the originals.
        public static let inPlaceNotice = "Replaces the originals. You can undo while Shrike keeps the backup."
        /// Under the folder field.
        public static let folderNote = "Your originals are not changed."

        /// Which form the Output row takes. `inPlaceText` is the model's
        /// own line (nil when nothing changes in place).
        public enum OutputForm: Equatable {
            /// The orange notice box with this text.
            case notice(String)
            /// The folder field with the note under it.
            case folder(note: String)
            /// The notice box above the folder field (the folder is a source's own folder).
            case folderNotice(String)
            case none
        }

        /// `changesOriginals` is `BatchModel.changesOriginals` (the same
        /// predicate the confirm question uses): a folder output that lands
        /// on a photo's own file shows the notice above the folder field, so
        /// the user can still choose another folder.
        public static func outputForm(inPlaceText: String?, writesToFolder: Bool,
                                      changesOriginals: Bool = false) -> OutputForm {
            if let inPlaceText { return .notice(inPlaceText) }
            guard writesToFolder else { return .none }
            return changesOriginals ? .folderNotice(inPlaceNotice) : .folder(note: folderNote)
        }

        /// `Run 12 Photos…` when the job changes originals (the dots tell
        /// that a question follows); else the plain title.
        public static func runTitle(_ n: Int, changesOriginals: Bool) -> String {
            let base = runButton(n)
            return changesOriginals && n > 0 ? base + "…" : base
        }

        /// The footer's Run title: `Retry 3 Remaining Photos` while reviewing
        /// the remaining ones, else `runTitle`. Also the accessibility label.
        public static func footerRunTitle(reviewingRemaining: Bool, queueCount: Int, processable: Int,
                                          changesOriginals: Bool) -> String {
            if reviewingRemaining { return "Retry \(queueCount) Remaining \(queueCount == 1 ? "Photo" : "Photos")" }
            return runTitle(processable, changesOriginals: changesOriginals)
        }

        /// Never "Run 0 Photos": with nothing to process it reads "Run".
        public static func runButton(_ n: Int) -> String { n == 0 ? "Run" : n == 1 ? "Run 1 Photo" : "Run \(n) Photos" }
        /// The summary line for photos skipped for their name.
        public static func invalidNameLine(_ n: Int) -> String? {
            guard n > 0 else { return nil }
            return n == 1 ? "1 photo would get a name Shrike can't use and will be skipped."
                          : "\(n) photos would get a name Shrike can't use and will be skipped."
        }
        public static func andMore(_ n: Int) -> String { "and \(n) more" }
        public static func unknownToken(_ token: String) -> String { "Unknown name part {\(token)}. Choose one from Insert Field…" }
        public static func progress(_ done: Int, _ total: Int) -> String { "\(done.formatted(.number)) of \(total.formatted(.number))" }
        /// No count: the sheet does not refresh while the run goes on, and a
        /// frozen "6 of 300" behind a window showing 12 was wrong.
        public static let stopAlertInfo = "Completed changes are kept; no new photos are started."
    }

    // MARK: Published state

    @Published public private(set) var queue: [BatchQueueItem] = [] {
        // Any photo leaving the queue (Remove, Remove All, a new queue) makes the
        // note untrue: the kept copy may be the one that went.
        didSet { if queue.count < oldValue.count, !droppingDuplicates { droppedDuplicateCount = 0 } }
    }
    /// Photos left out because they are the same file as one already chosen (a
    /// second folder path, or a link). Adds up while photos are added.
    @Published public private(set) var droppedDuplicateCount = 0
    private var droppingDuplicates = false
    /// The window closed: the note does not come back with the next window.
    public func forgetDroppedDuplicates() { droppedDuplicateCount = 0 }
    /// The note under "N photos chosen"; nil with none left out.
    nonisolated static func duplicatesNote(_ count: Int) -> String? {
        switch count {
        case ..<1: nil
        case 1: "1 duplicate was left out. It is the same photo as one already chosen."
        default: "\(count) duplicates were left out. They are the same photos as ones already chosen."
        }
    }
    @Published public var selection: Set<URL> = []
    /// Display-oriented pixel sizes, read off main after items arrive.
    @Published public private(set) var sizes: [URL: CGSize] = [:]
    @Published public var form = BatchForm() {
        // The confirm question names the plan; no form change while it is up.
        didSet {
            guard !restoringForm, form != oldValue else { return }
            if isConfirming { restoringForm = true; form = oldValue; restoringForm = false; return }
            schedulePreview()
        }
    }

    @Published public private(set) var previewRows: [BatchPreviewRow] = []

    /// Queued photos the preview already knows Shrike can't read (they are skipped at run time).
    /// Counted over the whole queue, not only the preview's first rows.
    @Published public private(set) var unreadablePhotos: Set<URL> = []
    public var unreadableCount: Int { unreadablePhotos.count }
    /// Photos skipped because the filled rename template gives a name Shrike cannot use (whole queue,
    /// from the preview's single pass).
    @Published public private(set) var invalidNamePhotos: Set<URL> = []
    public var invalidNameCount: Int { invalidNamePhotos.count }
    /// Queued photos the run can process: the counts in the Run button, the summary and the
    /// "Change N original photos?" question leave out the unreadable ones (they are skipped).
    public var processableCount: Int { max(0, queue.count - unreadableCount - invalidNameCount) }
    public var unreadableLine: String? {
        let n = unreadableCount
        guard n > 0 else { return nil }
        return n == 1 ? "1 photo can't be read and will be skipped." : "\(n) photos can't be read and will be skipped."
    }
    /// One more "What will happen" line for photos skipped for their new name.
    public var invalidNameLine: String? { Copy.invalidNameLine(invalidNameCount) }

    /// Every queued photo is skipped and at least one for its name: the
    /// template is the cause, so its field shows the name-problem text in red.
    public var nameTemplateLine: String? {
        guard !queue.isEmpty, invalidNameCount > 0, processableCount == 0 else { return nil }
        return BatchPreviewRowLook.templateText(firstNameSkip: previewRows.lazy.compactMap(\.skip).first {
            if case .invalidName = $0 { return true }
            if case .emptyName = $0 { return true }
            return false
        })
    }

    /// The footer validation line is an error (red), not a hint.
    public var validationIsError: Bool { templateError != nil }

    /// Where each template message goes:
    /// the name-problem text sits directly under the template field and the field
    /// gets the red outline; the footer keeps the other lines. Pure.
    public struct TemplateFeedback: Equatable, Sendable {
        public var underField: String?
        public var footer: String?
        public var footerIsError: Bool
        public var fieldOutlineRed: Bool

        public static func decide(templateError: String?, queueIsEmpty: Bool,
                                  nameTemplateLine: String?, validationMessage: String?) -> TemplateFeedback {
            if let templateError {
                return TemplateFeedback(underField: nil, footer: templateError, footerIsError: true, fieldOutlineRed: true)
            }
            let footer = queueIsEmpty ? Copy.emptyQueue : validationMessage
            return TemplateFeedback(underField: nameTemplateLine, footer: footer, footerIsError: false,
                                    fieldOutlineRed: nameTemplateLine != nil)
        }
    }

    public var templateFeedback: TemplateFeedback {
        TemplateFeedback.decide(templateError: templateError, queueIsEmpty: queue.isEmpty,
                                nameTemplateLine: nameTemplateLine, validationMessage: validationMessage)
    }

    /// Queue items past the first `previewLimit` ("and N more").
    @Published public private(set) var moreCount = 0
    /// The engine's validation line ("Choose at least one operation.").
    @Published public private(set) var validationMessage: String?
    /// The template parse error ("Unknown token {foo}.").
    @Published public private(set) var templateError: String?
    /// True once the preview for the current form has arrived.
    @Published public private(set) var isPreviewCurrent = false
    @Published public private(set) var conversionDisclosures: [String] = []
    /// Photos the run would re-encode over their own file (output folder =
    /// the photo's folder, same name and format). 0 = originals stay unchanged.
    @Published public private(set) var overwriteCount = 0
    /// The photos behind `overwriteCount`, found once per preview refresh off the main thread
    /// so the "Change N originals?" question never reads headers on the main thread.
    private var overwrittenGroups: [ImageGroup] = []
    @Published public private(set) var presets: [BatchPreset] = BatchPresetStore.builtIns
    @Published public private(set) var phase: Phase = .form

    @Published public private(set) var completed = 0
    @Published public private(set) var total = 0
    @Published public private(set) var currentName: String?
    @Published public private(set) var etaText: String?
    @Published public private(set) var isStopping = false

    @Published public private(set) var result: BatchResult?
    @Published public private(set) var summary = ""
    /// The last line of the result summary when the
    /// batch lost track of some backups (`BatchResult.backupsNotSaved`).
    public var backupNotice: String? {
        guard let result else { return nil }
        return BackupNotice.sentence(notSaved: result.backupsNotSaved, of: result.doneCount, leadNamesPhotos: false)
    }
    /// The run was taken back (Undo Batch or Edit > Undo). The Done screen says so and no
    /// longer offers Undo Batch or the files that were taken back.
    @Published public private(set) var isUndone = false
    public func markUndone() {
        guard phase == .done, result != nil, !isUndone else { return }
        isUndone = true
        summary = "The changes were taken back."
    }
    @Published public private(set) var skippedRows: [SkippedRow] = []
    @Published public var selectedResultRows: Set<URL> = []

    // MARK: Collaborators

    public static let previewLimit = 200
    public static let previewDebounce: Duration = .milliseconds(150)

    let runner: BatchRunner
    let presetStore: BatchPresetStore

    /// Progress (completed, total) for the Dock badge.
    var onProgress: ((Int, Int) -> Void)?
    /// The run ended (Done view up, or back to the form on an error).
    var onFinished: ((BatchResult?, BatchPlan?) -> Void)?

    private var previewTask: Task<Void, Never>?
    private var previewGeneration = 0
    private var sizeTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var stopper: BatchStop?
    private var startedAt: ContinuousClock.Instant?
    /// The plan of the last run (Done view actions, undo name).
    public private(set) var lastPlan: BatchPlan?
    private var remainingPlan: BatchPlan?
    @Published public private(set) var reviewingRemaining = false
    @Published public private(set) var scopeDescription = BatchScope.pickedByHand
    public func setOriginScope(_ text: String) { scopeDescription = text }
    /// The output folder under the "What will happen" sentence (one line,
    /// truncated at the start in the view). nil: no folder chosen, in place, every photo
    /// skipped (no sentence), or the Resume branch (its sentence keeps the path).
    public var outputPathLine: String? {
        guard form.writesToFolder, !reviewingRemaining, processableCount > 0, let outputFolder else { return nil }
        return UserFacingPath.string(outputFolder)
    }

    /// Leading and trailing spaces and line breaks of the template are trimmed
    /// before it is parsed; the field keeps what the user typed. The name checks then run on
    /// the filled names.
    nonisolated static func templateForRun(_ typed: String) -> String {
        typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var consequenceSummary: String {
        let recovery = "You can undo completed changes while their recovery data is available."
        if reviewingRemaining, let plan = makePlan().plan {
            let n = plan.items.count
            let lead = "Resume unfinished steps for \(n) \(n == 1 ? "photo" : "photos"). Completed steps will not run again."
            switch plan.output {
            case .folder(let destination):
                if overwriteCount > 0 { return lead + " " + overwriteSentence + " " + recovery }
                let originals = n == 1 ? "Original stays unchanged." : "Originals stay unchanged."
                return lead + " Destination: \(UserFacingPath.string(destination)). " + originals
                    + (plan.onConflict == .replace ? " Existing outputs: Replace." : "")
            case .inPlace:
                return lead + " Remaining work may change \(n == 1 ? "the original file" : "original files"). " + recovery
            }
        }
        let n = processableCount
        // The chosen folder is its own line under the sentence (`outputPathLine`).
        let destination = outputFolder == nil ? "the output folder" : "the folder below"
        if form.writesToFolder, overwriteCount > 0 {
            return "Create \(n) \(n == 1 ? "photo" : "photos") in \(destination). " + overwriteSentence + " " + recovery
        }
        if form.writesToFolder {
            let originals = n == 1 ? "Original stays unchanged." : "Originals stay unchanged."
            return "Create \(n) new \(n == 1 ? "photo" : "photos") in \(destination). " + originals
                + (form.onConflict == .replace ? " Existing outputs: Replace." : "")
        }
        let verb = form.rotateOn && form.renameOn ? "Rotate and rename" : (form.rotateOn ? "Rotate" : "Rename")
        return "\(verb) \(n) original \(n == 1 ? "file" : "files"). " + recovery
    }
    /// The "What will happen" block: the summary, then
    /// the unreadable line, then the bad-name line. When every queued photo
    /// is skipped the summary is left out ("Create 0 new photos" says nothing true).
    public var whatWillHappenLines: [String] {
        Self.whatWillHappen(summary: consequenceSummary, queued: queue.count, processable: processableCount,
                            reviewing: reviewingRemaining,
                            skipLines: validationLine == nil ? [unreadableLine, invalidNameLine].compactMap { $0 } : [])
    }

    /// The heading "What will happen" shows only with something under it
    /// (every photo skipped and a validation line up leaves the block empty).
    public var showsWhatWillHappenHeading: Bool {
        Self.showsWhatWillHappenHeading(lines: whatWillHappenLines, disclosures: conversionDisclosures)
    }

    nonisolated static func showsWhatWillHappenHeading(lines: [String], disclosures: [String]) -> Bool {
        !lines.isEmpty || !disclosures.isEmpty
    }

    nonisolated static func whatWillHappen(summary: String, queued: Int, processable: Int, reviewing: Bool,
                                           skipLines: [String]) -> [String] {
        let allSkipped = !reviewing && queued > 0 && processable == 0
        return (allSkipped ? [] : [summary]) + skipLines
    }

    /// Same words as the in-place Rotate/Rename line.
    var overwriteSentence: String {
        overwriteCount == 1 ? "1 original file changes in place; recovery data is kept when available."
            : "\(overwriteCount) original files change in place; recovery data is kept when available."
    }
    public var resultTitle: String {
        guard let result else { return "Batch" }
        if isUndone { return "Batch undone" }
        // A rename clean-up that finished every photo leaves cancelledCount at 0.
        if isStoppedResult { return "Batch stopped" }
        if result.doneCount == 0 && Self.failedCount(result, announcedSkips: announcedUnreadable) > 0 { return "No photos completed" }
        return Self.hasIssues(result, announcedSkips: announcedUnreadable) ? "Batch finished with issues" : "Batch complete"
    }
    /// The run was stopped (Stop pressed, or photos left unprocessed).
    var isStoppedResult: Bool {
        guard let result else { return false }
        return stopRequested || result.cancelledCount > 0
    }

    /// The icon beside the result title, for both result views
    /// (`resultIcon(isUndone:isStopped:hasReasons:doneCount:)` picks it).
    /// Undone first, then stopped (a stopped run never gets the complete or
    /// the issues icon). Then the list of photos with a reason: none means
    /// complete; reasons with nothing done mean none completed; else issues.
    /// `resultTitle` checks undone and stopped the same way, but its last
    /// steps read the result's own counts, not that list.
    enum ResultIcon: Equatable {
        case complete, stopped, undone, noneCompleted, issues
        var symbolName: String {
            switch self {
            case .complete: return "checkmark.circle.fill"
            case .stopped: return "stop.circle"
            case .undone: return "arrow.uturn.backward.circle"
            case .noneCompleted: return "xmark.circle"
            case .issues: return "exclamationmark.triangle"
            }
        }
        /// Green for `complete`; secondary label colour otherwise.
        var isGreen: Bool { self == .complete }
    }

    /// Pure. `hasReasons`: the result lists photos with a reason (skipped
    /// or failed); without that list a run that was not stopped is complete.
    nonisolated static func resultIcon(isUndone: Bool, isStopped: Bool, hasReasons: Bool,
                                       doneCount: Int) -> ResultIcon {
        if isUndone { return .undone }
        if isStopped { return .stopped }
        guard hasReasons else { return .complete }
        return doneCount == 0 ? .noneCompleted : .issues
    }

    var resultIcon: ResultIcon {
        Self.resultIcon(isUndone: isUndone, isStopped: isStoppedResult, hasReasons: !skippedRows.isEmpty,
                        doneCount: result?.doneCount ?? 0)
    }

    /// Photos the preview announced as unreadable (skipped) when the run started.
    var announcedUnreadable: Set<URL> = []
    /// The Done view's hint about selecting skips is only useful when some
    /// skip was on purpose (not "Canceled." or an unreadable file).
    public var hasIntentionalSkips: Bool { result?.hasIntentionalSkips ?? false }
    public var canReviewRemaining: Bool {
        guard let result, let lastPlan else { return false }
        return !remainingItems(result: result, plan: lastPlan, includingIntentionalSkips: false).isEmpty
    }
    /// The runner's retry list without the photos the preview announced as skipped:
    /// an unreadable photo alone is no reason for "Review Remaining…".
    private func remainingItems(result: BatchResult, plan: BatchPlan, includingIntentionalSkips: Bool) -> [ImageGroup] {
        runner.retryPlan(for: result, original: plan, includingIntentionalSkips: includingIntentionalSkips,
                         selectedIntentionalSkips: selectedResultRows).items
            .filter { !announcedUnreadable.contains($0.primary) }
    }
    public func reviewRemaining(includingIntentionalSkips: Bool = false) {
        guard phase == .done, let result, let lastPlan else { return }
        var plan = runner.retryPlan(for: result, original: lastPlan, includingIntentionalSkips: includingIntentionalSkips, selectedIntentionalSkips: selectedResultRows)
        plan.items = remainingItems(result: result, plan: lastPlan, includingIntentionalSkips: includingIntentionalSkips)
        guard !plan.items.isEmpty else { return }
        remainingPlan = plan; reviewingRemaining = true
        queue = plan.items.map { BatchQueueItem(group: $0) }; selection = []
        phase = .form; schedulePreview()
    }
    public func cancelRemainingReview() {
        guard reviewingRemaining, !isConfirming else { return }
        queue = lastPlan?.items.map { BatchQueueItem(group: $0) } ?? []
        remainingPlan = nil; reviewingRemaining = false; phase = .done
    }
    public func runAnother() {
        guard phase == .done || reviewingRemaining, !isConfirming else { return }
        remainingPlan = nil; reviewingRemaining = false
        queue = []; selection = []; result = nil; skippedRows = []; summary = ""; isUndone = false; phase = .form
        schedulePreview()
    }

    /// The settings of the last run, as one `BatchPreset` (JSON). A new
    /// window starts from them, so a Custom setup is not lost.
    static let lastFormKey = "shrike.batch.lastForm"
    private let defaults: UserDefaults

    public init(runner: BatchRunner, presetStore: BatchPresetStore = BatchPresetStore(),
                defaults: UserDefaults = ShrikeDefaults.store) {
        self.runner = runner
        self.presetStore = presetStore
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.lastFormKey),
           let saved = try? JSONDecoder().decode(BatchPreset.self, from: data) {
            apply(saved)
        }
        Task { [weak self] in await self?.reloadPresets() }
    }

    // MARK: Queue

    /// Adds groups not already queued (by plain path, no disk call), in
    /// order. The same photo reached through a symbolic link is dropped by
    /// the preview, off the main thread, before Run turns on.
    public func add(_ groups: [ImageGroup]) {
        guard !reviewingRemaining, !isConfirming else { return }
        var known = Set(queue.map { $0.group.primary.standardizedFileURL.path })
        var fresh: [BatchQueueItem] = []
        for group in groups where known.insert(group.primary.standardizedFileURL.path).inserted {
            fresh.append(BatchQueueItem(group: group))
        }
        guard !fresh.isEmpty, phase != .running else { return }
        scopeDescription = BatchScope.pickedByHand
        if reviewingRemaining { remainingPlan = nil; reviewingRemaining = false }
        queue += fresh
        schedulePreview()      // the preview's single header pass also gives the sizes
    }

    /// Drag to reorder (the order is the counter order).
    public func move(from source: IndexSet, to destination: Int) {
        guard !reviewingRemaining, !isConfirming else { return }
        let moving = source.sorted().map { queue[$0] }
        var rest = queue
        for index in source.sorted(by: >) { rest.remove(at: index) }
        let insertAt = destination - source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(insertAt, rest.count)))
        guard rest != queue else { return }
        queue = rest
        schedulePreview()
    }

    /// The − button and Delete.
    /// Switching to or from Percent resets the number (2048 % or 50 px
    /// would never be meant).
    public func setResizeMode(_ mode: ResizeOptions.Mode) {
        guard mode != form.resizeMode else { return }
        var f = form
        if mode == .percent { f.resizeValue = 50 } else if f.resizeMode == .percent { f.resizeValue = 2048 }
        f.resizeMode = mode
        form = f
    }

    public func removeSelected() {
        guard !reviewingRemaining, !isConfirming else { return }
        guard !selection.isEmpty else { return }
        scopeDescription = BatchScope.pickedByHand
        queue.removeAll { selection.contains($0.id) }
        selection = []
        schedulePreview()
    }

    /// The live line under the name template, built from the first
    /// queued photo's new name. Nothing when there is no rename, no photo, an
    /// error in the template, or the first photo is skipped (it has no new name).
    public var exampleLine: String? {
        Self.exampleLine(renameOn: form.renameOn, templateError: templateError,
                         first: previewRows.first.map { ($0.outputName, $0.skip != nil) })
    }

    /// The rule of `exampleLine`, apart from the model: nothing when rename is off, the template
    /// has an error, the queue is empty, or the first photo is skipped (it has no new name).
    static func exampleLine(renameOn: Bool, templateError: String?,
                            first: (outputName: String, skipped: Bool)?) -> String? {
        guard renameOn, templateError == nil, let first else { return nil }
        return Copy.exampleLine(outputName: first.skipped ? nil : first.outputName)
    }

    public var title: String { Copy.windowTitle }
    public var subtitle: String { Copy.subtitle(queue.count) }

    /// The default Output folder: "<first item's folder>/Shrike Export".
    public var defaultOutputFolder: URL? {
        queue.first.map {
            $0.group.primary.deletingLastPathComponent()
                .appendingPathComponent(Copy.defaultOutputFolderName, isDirectory: true)
        }
    }

    public var outputFolder: URL? { form.outputFolder ?? defaultOutputFolder }

    /// The Output row's text when files change in place, else nil.
    public var inPlaceText: String? {
        guard !form.writesToFolder else { return nil }
        if form.rotateOn { return Copy.inPlaceRotate }
        guard renamesOnlyInPlace else { return nil }
        // The confirm sheet's count (`originalsAtRisk`): a photo with a bad name is not renamed.
        let renamed = Self.originalsAtRisk(inPlace: true, items: queue.map(\.group), overwritten: [],
                                           unreadable: unreadablePhotos, invalidName: invalidNamePhotos).count
        return Copy.inPlace(renamed > 0 ? renamed : queue.count)
    }

    /// One rule for the Output notice and the confirm text: an in-place job
    /// that only renames changes no pixels (rotate is the only other in-place step).
    public var renamesOnlyInPlace: Bool { !form.writesToFolder && form.renameOn && !form.rotateOn }

    private func readSizes(of urls: [URL]) {
        let previous = sizeTask
        sizeTask = Task { [weak self] in
            await previous?.value
            let read = await Self.headerSizes(urls)
            self?.sizes.merge(read) { _, new in new }
        }
    }

    @concurrent
    nonisolated static func headerSizes(_ urls: [URL]) async -> [URL: CGSize] {
        var out: [URL: CGSize] = [:]
        for url in urls {
            if Task.isCancelled { break }
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { continue }
            let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
            out[url] = orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
        }
        return out
    }

    // MARK: Form → plan

    /// The plan for the current form, or the template error.
    public func makePlan() -> (plan: BatchPlan?, templateError: String?) {
        if var retry = remainingPlan {
            // Only output location/conflict policy may change during recovery.
            // Preserve original counter ordinals, outstanding phases and receipts.
            if form.writesToFolder, let outputFolder { retry.output = .folder(outputFolder) }
            retry.onConflict = form.onConflict
            return (retry, nil)
        }
        var rename: RenameTemplate?
        if form.renameOn {
            do {
                rename = try RenameTemplate(parsing: Self.templateForRun(form.template), counterStart: form.counterStart,
                                            nameCase: form.nameCase)
            } catch let error as RenameTemplateError {
                return (nil, Self.message(for: error))
            } catch {
                return (nil, Copy.emptyTemplate)
            }
        }
        let convert = form.convertOn
            ? ConvertOptions(format: form.format, quality: Double(form.quality) / 100,
                             keepMetadata: form.keepMetadata, removeLocation: form.removeLocation)
            : nil
        let resize = form.resizeOn
            ? ResizeOptions(mode: form.resizeMode, value: form.resizeValue, dontEnlarge: form.dontEnlarge)
            : nil
        let output: BatchOutput
        if form.writesToFolder, let folder = outputFolder {
            output = .folder(folder)
        } else {
            output = .inPlace
        }
        let plan = BatchPlan(items: queue.map(\.group), convert: convert, resize: resize,
                             rotate: form.rotateOn ? form.rotation.quarters : nil, rename: rename,
                             output: output, onConflict: form.onConflict)
        return (plan, nil)
    }

    static func message(for error: RenameTemplateError) -> String {
        switch error {
        case .unknownToken(let name, _): return Copy.unknownToken(name)
        case .invalidArgument(let token, let argument, _): return Copy.unknownToken("\(token):\(argument)")
        case .unclosedBrace: return Copy.unclosedBrace
        case .empty: return Copy.emptyTemplate
        }
    }

    /// The line under the form: template error first, then the queue,
    /// then the engine's validation.
    public var validationLine: String? { templateFeedback.footer }

    public var canRun: Bool {
        phase == .form && !queue.isEmpty && templateError == nil && validationMessage == nil && isPreviewCurrent
            // Every photo would be skipped, whatever the cause: nothing to run.
            // A file repaired on disk is read again by `refreshSkippedPhotos()`.
            && processableCount > 0
    }

    /// The preview only reads files when the queue or the form changes, so a
    /// photo repaired on disk stays "can't be read" (and Run off) until it is
    /// read again. The Batch window calls this when it becomes key; nothing
    /// is read unless a photo is skipped as unreadable.
    public func refreshSkippedPhotos() {
        guard phase == .form, !isConfirming, !queue.isEmpty, !unreadablePhotos.isEmpty else { return }
        schedulePreview()
    }

    // MARK: Preview (150 ms debounce, off main)

    func schedulePreview() {
        conversionDisclosures = []
        overwriteCount = 0
        // The replaced list stays with the shown rows until the new preview lands
        // (clearing it here hid `Replaces “…”.` for the 150 ms debounce).
        overwrittenGroups = []
        previewTask?.cancel()
        previewGeneration += 1
        pendingRun = nil          // a newer form change cancels a queued ⌘Return
        let generation = previewGeneration
        isPreviewCurrent = false
        let built = makePlan()
        templateError = built.templateError
        guard let plan = built.plan, !queue.isEmpty else {
            previewRows = []
            replacedOutsidePaths = []
            unreadablePhotos = []
            invalidNamePhotos = []
            moreCount = 0
            validationMessage = nil
            // No preview runs without a plan, so read the sizes of photos that have none yet.
            readSizes(of: queue.map(\.group.primary).filter { sizes[$0] == nil })
            return
        }
        let runner = self.runner
        let primaries = queue.map(\.group.primary)
        let canonical = self.canonical
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDebounce)
            if Task.isCancelled { return }
            let linked = await Task.detached(priority: .userInitiated) {
                Self.linkedDuplicates(primaries, canonical: canonical)
            }.value
            if !linked.isEmpty {
                guard let self, !Task.isCancelled, generation == self.previewGeneration,
                      !self.isConfirming, !self.reviewingRemaining, self.phase == .form else { return }
                let before = self.queue.count
                self.droppingDuplicates = true
                self.queue.removeAll { linked.contains($0.group.primary) }
                self.droppingDuplicates = false
                self.droppedDuplicateCount += before - self.queue.count
                self.selection.subtract(linked)
                let pending = self.pendingRun
                self.schedulePreview()
                self.pendingRun = pending
                return
            }
            // Show the names a confirmed run would use.
            var confirmed = plan
            confirmed.overwritesOriginals = true
            let evaluated = await Self.evaluate(confirmed, runner: runner, limit: Self.previewLimit)
            // The files outside the queue a Replace trashes (off the main thread).
            // For the whole queue, from the same analysis (no disk call here).
            let others = Self.otherFilesReplacedPaths(targets: evaluated.analysis.replaceTargets, queued: plan.items,
                                                      replaces: plan.onConflict == .replace)
            guard let self, !Task.isCancelled, generation == self.previewGeneration else { return }
            // Only the photos the run will skip: a rename-only job renames unreadable ones too.
            self.sizes.merge(evaluated.analysis.sizes) { _, new in new }   // same header pass: no second read
            self.unreadablePhotos = evaluated.analysis.skippedUnreadable
            self.invalidNamePhotos = evaluated.analysis.skippedInvalidName
            self.conversionDisclosures = evaluated.disclosures
            self.overwrittenGroups = evaluated.analysis.overwritten
            self.overwriteCount = evaluated.analysis.overwritten.count
            self.previewRows = evaluated.analysis.rows
            self.replacedOutsidePaths = others
            self.previewConflictPolicy = plan.onConflict
            self.moreCount = max(0, plan.items.count - Self.previewLimit)
            self.validationMessage = evaluated.validation?.message
            self.isPreviewCurrent = true
            if let pending = self.pendingRun {
                self.pendingRun = nil
                if ContinuousClock.now < pending { self.requestRun() }
            }
        }
    }

    /// Resolves a folder path through symbolic links (disk calls; run off
    /// the main thread). Test seam.
    var canonical: @Sendable (URL) -> String = { GroupList.canonical($0) }

    /// The later copies of photos queued twice through different folder
    /// paths that lead to the same folder, and the links to a file that is
    /// queued too (whatever the order: the real file is the one kept).
    /// One `canonical` call per distinct folder and per file link (one
    /// link check per photo); none when every photo shares one folder path and none is a link.
    nonisolated static func linkedDuplicates(
        _ primaries: [URL], canonical: (URL) -> String,
        isLink: (URL) -> Bool = { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
    ) -> Set<URL> {
        let folders = Set(primaries.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        let links = Set(primaries.filter(isLink))
        guard folders.count > 1 || !links.isEmpty else { return [] }
        var resolved: [String: String] = [:]
        var seen: Set<String> = []
        var later: Set<URL> = []
        // Real files first, then links: a link to a queued photo goes and the
        // photo stays, whichever was added first (a rename must rename the photo).
        for url in primaries where !links.contains(url) {
            let parent = url.deletingLastPathComponent()
            let key = parent.standardizedFileURL.path
            let folder = resolved[key] ?? canonical(parent)
            resolved[key] = folder
            if !seen.insert(folder + "/" + url.lastPathComponent).inserted { later.insert(url) }
        }
        for url in primaries where links.contains(url) {
            if !seen.insert(canonical(url)).inserted { later.insert(url) }
        }
        return later
    }

    /// ⌘Return right after typing in a field: committing the
    /// value starts a new preview, so Run is off for a moment. The run waits for
    /// that preview (at most 2 s); a later form change cancels it.
    private var pendingRun: ContinuousClock.Instant?

    func requestRunWhenCurrent() {
        guard !isConfirming else { return }
        if canRun { requestRun(); return }
        guard phase == .form, !isPreviewCurrent, previewTask != nil else { return }
        pendingRun = .now + .seconds(2)
    }

    struct Evaluation: Sendable {
        let analysis: BatchRunner.Analysis
        let validation: BatchValidationError?
        let disclosures: [String]
    }

    /// One pass off the main thread; every header is read once.
    @concurrent
    nonisolated static func evaluate(_ plan: BatchPlan, runner: BatchRunner, limit: Int) async -> Evaluation {
        let analysis = runner.analyze(plan, limit: limit)
        var disclosures = Set<String>()
        if plan.convert != nil || plan.resize != nil || !(plan.recipe?.isEmpty ?? true) {
            for group in plan.items {
                if Task.isCancelled { break }
                // A photo the run skips gets no notice (its header failed: that is why it is skipped).
                if analysis.skippedUnreadable.contains(group.primary) { continue }
                var ops = plan.recipe ?? []
                if let rotate = plan.rotate, rotate % 4 != 0 { ops.append(.rotate90(quarters: rotate)) }
                if let resize = plan.resize, let size = analysis.sizes[group.primary] {
                    let target = resize.targetSize(for: size)
                    ops.append(.resize(ResizeSpec(width: Int(target.width), height: Int(target.height), interpolation: .lanczos, preventUpscale: resize.dontEnlarge)))
                }
                let capability = ImageExporter.capability(for: group.primary, operations: ops, format: plan.convert?.format)
                if let disclosure = capability.conversionDisclosure,
                   includesDisclosure(disclosure, output: plan.output) { disclosures.insert(disclosure) }
            }
        }
        return Evaluation(analysis: analysis, validation: plan.validationError, disclosures: disclosures.sorted())
    }

    /// The "could not be verified … keep the original unchanged" notice is
    /// only true when the job changes originals; other notices (HDR to SDR)
    /// hold for an export too.
    nonisolated static func includesDisclosure(_ text: String, output: BatchOutput) -> Bool {
        if case .inPlace = output { return true }
        return text != EditSaveCapability.unverifiedPrecision
    }

    /// Waits for the pending preview (tests).
    func waitForPreview() async { await previewTask?.value }
    func waitForSizes() async { await sizeTask?.value }

    // MARK: Presets

    public func reloadPresets() async {
        presets = await presetStore.list()
    }

    /// The preset the form matches, or nil ("Custom").
    public var matchedPreset: BatchPreset? {
        let mine = Self.signature(preset(named: ""))
        return presets.first { Self.signature($0) == mine }
    }

    public var presetTitle: String { matchedPreset?.name ?? Copy.customPreset }

    /// True for the preset the form matches: the Preset menu puts a check
    /// mark on it. "Custom" forms check nothing.
    public func isCurrent(_ preset: BatchPreset) -> Bool {
        matchedPreset?.name == preset.name
    }

    /// Saved (deletable) preset the form matches.
    public var deletablePresetName: String? {
        guard let name = matchedPreset?.name, !BatchPresetStore.isBuiltIn(name) else { return nil }
        return name
    }

    public func apply(_ preset: BatchPreset) {
        guard !reviewingRemaining, !isConfirming else { return }
        var f = form
        f.convertOn = preset.convert != nil
        if let c = preset.convert {
            f.format = c.format
            f.quality = Int((c.quality * 100).rounded())
            f.keepMetadata = c.keepMetadata
            f.removeLocation = c.removeLocation
        }
        f.resizeOn = preset.resize != nil
        if let r = preset.resize {
            f.resizeMode = r.mode
            f.resizeValue = r.value
            f.dontEnlarge = r.dontEnlarge
        }
        let rotation = preset.rotate.flatMap(BatchRotation.init(quarters:))
        f.rotateOn = rotation != nil
        if let rotation { f.rotation = rotation }
        f.renameOn = preset.renameTemplate != nil
        if let template = preset.renameTemplate {
            f.template = template
            f.counterStart = preset.renameStart
            f.nameCase = preset.renameCase ?? .keep
        }
        if let path = preset.outputFolderPath { f.outputFolder = URL(fileURLWithPath: path, isDirectory: true) }
        form = f
    }

    /// The form as a preset called `name`.
    public func preset(named name: String) -> BatchPreset {
        BatchPreset(
            name: name,
            convert: form.convertOn
                ? ConvertOptions(format: form.format, quality: Double(form.quality) / 100,
                                 keepMetadata: form.keepMetadata, removeLocation: form.removeLocation)
                : nil,
            resize: form.resizeOn
                ? ResizeOptions(mode: form.resizeMode, value: form.resizeValue, dontEnlarge: form.dontEnlarge)
                : nil,
            rotate: form.rotateOn ? form.rotation.quarters : nil,
            renameTemplate: form.renameOn ? form.template : nil,
            renameStart: form.renameOn ? form.counterStart : 1,
            renameCase: form.renameOn ? form.nameCase : nil,
            outputFolderPath: form.outputFolder?.path)
    }

    /// Fields that decide a match: no name, whole-percent quality, and
    /// the output folder only when the preset names one.
    private static func signature(_ p: BatchPreset) -> BatchPreset {
        var s = p
        s.name = ""
        s.outputFolderPath = nil
        if var c = s.convert {
            c.quality = (c.quality * 100).rounded() / 100
            s.convert = c
        }
        if s.renameTemplate == nil {
            s.renameStart = 1
            s.renameCase = nil
        } else if s.renameCase == nil {
            s.renameCase = .keep
        }
        return s
    }

    public func savePreset(named name: String) async throws {
        try await presetStore.save(preset(named: name))
        await reloadPresets()
    }

    public func deletePreset(named name: String) async throws {
        try await presetStore.delete(named: name)
        await reloadPresets()
    }

    // MARK: Run

    /// "Converting 42 images" / "Renaming 3 images".
    public var runningTitle: String {
        let n = Copy.images(total)
        switch Self.verb(for: lastPlan) {
        case "converted": return "Converting \(n)"
        case "resized": return "Resizing \(n)"
        case "rotated": return "Rotating \(n)"
        default: return "Renaming \(n)"
        }
    }

    /// What the bar shows: the same `completed` and `total` as the counter text.
    public var progressFraction: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }

    #if DEBUG
    func setEtaTextForTesting(_ text: String?) { etaText = text }
    #endif

    public var progressLine: String {
        let base = Copy.progress(completed, total)
        guard let etaText else { return base }
        return "\(base) · \(etaText)"
    }

    /// Remembers the form for the next Batch window. The output folder is
    /// not kept (a new window offers its own default).
    func rememberForm() {
        var saved = preset(named: "")
        saved.outputFolderPath = nil
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.lastFormKey) }
    }

    // MARK: Confirm before changing originals

    /// Shows the "Change N original photos?" alert; true = Change Original(s).
    /// The Batch window sets it. Without one, a run that changes originals
    /// is not started.
    var confirmChangeOriginals: (@MainActor (_ title: String, _ information: String) async -> Bool)?
    /// The question's destructive button, for the same count as its title
    /// (set by `requestRun` before it asks).
    private(set) var confirmButtonTitle = ConfirmCopy.confirm(2)
    public private(set) var isConfirming = false
    private var restoringForm = false
    /// The plan the open question named (its preview generation and photos).
    /// The confirmed run starts only from it, and only while nothing changed.
    private var confirmed: (generation: Int, plan: BatchPlan)?

    /// The photos of `plan` whose original files the run may change: all of
    /// them for an in-place plan, and for a folder plan those whose output
    /// file is the photo's own file (the runner compares case-folded paths).
    func originalsAtRisk(_ plan: BatchPlan) -> [ImageGroup] {
        let inPlace: Bool
        switch plan.output {
        case .inPlace: inPlace = true
        case .folder: inPlace = false
        }
        return Self.originalsAtRisk(inPlace: inPlace, items: plan.items, overwritten: overwrittenGroups,
                                    unreadable: unreadablePhotos, invalidName: invalidNamePhotos)
    }

    /// The one rule for "this run changes originals" (pure): every readable,
    /// nameable photo of an in-place plan; for a folder plan the photos whose
    /// output file is their own file (the preview's `overwritten`).
    nonisolated static func originalsAtRisk(inPlace: Bool, items: [ImageGroup], overwritten: [ImageGroup],
                                            unreadable: Set<URL>, invalidName: Set<URL>) -> [ImageGroup] {
        (inPlace ? items : overwritten).filter { !unreadable.contains($0.primary) && !invalidName.contains($0.primary) }
    }

    /// True when Run would change original files: drives the Output row's
    /// notice, the dots of the Run title and (through `originalsAtRisk`)
    /// the confirm question, so the three always agree.
    public var changesOriginals: Bool {
        // In place = Rename or Rotate without Convert/Resize (`inPlaceText`);
        // with no operation chosen nothing changes (no dots, no notice).
        // A folder output needs a folder (none only with an empty queue).
        let inPlace: Bool
        if inPlaceText != nil { inPlace = true }
        else if form.writesToFolder, outputFolder != nil { inPlace = false }
        else { return false }
        return !Self.originalsAtRisk(inPlace: inPlace, items: queue.map(\.group), overwritten: overwrittenGroups,
                                     unreadable: unreadablePhotos, invalidName: invalidNamePhotos).isEmpty
    }

    public enum ConfirmCopy {
        public static func title(_ groups: [ImageGroup]) -> String {
            groups.count == 1 ? "Change the original photo “\(groups[0].displayName)”?"
                              : "Change \(groups.count) original photos?"
        }
        /// `renameOnly`: an in-place rename changes no pixels and makes no
        /// pixel backup, so it says what is true: Undo Batch puts the names back.
        public static func information(_ count: Int, renameOnly: Bool = false) -> String {
            if renameOnly {
                return Copy.inPlace(count)
            }
            return count == 1 ? "Shrike keeps a backup of the original, and Undo or Revert can restore it."
                              : "Shrike keeps a backup of each original, and Undo or Revert can restore them."
        }
        /// The destructive button; singular for one photo, like the title.
        public static func confirm(_ count: Int) -> String { count == 1 ? "Change Original" : "Change Originals" }

        /// A rename with Replace that also replaces files
        /// outside the queue says so. nil when there are none.
        public static func otherFilesReplaced(_ n: Int) -> String? {
            guard n > 0 else { return nil }
            return n == 1 ? "1 other file will be replaced and moved to the Trash."
                          : "\(n) other files will be replaced and moved to the Trash."
        }

        /// The confirm text with the other-files sentence when there are any.
        public static func information(_ count: Int, renameOnly: Bool = false, otherFilesReplaced others: Int) -> String {
            [information(count, renameOnly: renameOnly), otherFilesReplaced(others)].compactMap { $0 }.joined(separator: " ")
        }

        /// The result summary's line for those files. nil when there were none.
        public static func otherFilesWereReplaced(_ n: Int) -> String? {
            guard n > 0 else { return nil }
            return n == 1 ? "1 other file was replaced." : "\(n) other files were replaced."
        }
    }

    /// Pure, disk-free: the paths of the files a Replace run trashes that
    /// are not queued photos. `targets` is the analysis' whole-plan list
    nonisolated static func otherFilesReplacedPaths(targets: Set<URL>, queued: [ImageGroup],
                                                    replaces: Bool) -> Set<String> {
        guard replaces else { return [] }
        let queuedPaths = Set(queued.flatMap(\.allURLs).map { $0.standardizedFileURL.path })
        return Set(targets.map { $0.standardizedFileURL.path }).subtracting(queuedPaths)
    }

    /// Files outside the queue a Replace run trashes (found with the preview, off the main thread).
    var otherFilesReplaced: Int { replacedOutsidePaths.count }
    /// Their paths, set with `previewRows` (a row names the file it replaces).
    private(set) var replacedOutsidePaths: Set<String> = []
    /// The "If a file exists" answer the shown preview rows were made with.
    private(set) var previewConflictPolicy: ConflictAnswer.Action = .keepBoth

    /// The clash words of a preview row (with Replace the
    /// row must not say `Name already used`).
    func clashText(for row: BatchPreviewRow) -> String? {
        BatchPreviewRowLook.clashText(row, policy: previewConflictPolicy,
                                      replacesOutsideFile: replacedOutsidePaths.contains(row.destination.standardizedFileURL.path))
    }

    /// Run button / Return: asks first when the run would change originals,
    /// then starts with the user's answer. Without `confirmChangeOriginals`
    /// such a run does not start (never silently).
    public func requestRun() {
        guard canRun, !isConfirming, let plan = makePlan().plan else { return }
        let atRisk = originalsAtRisk(plan)
        guard !atRisk.isEmpty else { start(overwritingOriginals: false); return }
        guard let confirm = confirmChangeOriginals else { return }
        isConfirming = true
        confirmed = (previewGeneration, plan)
        let others = otherFilesReplaced
        confirmButtonTitle = ConfirmCopy.confirm(atRisk.count)
        let title = ConfirmCopy.title(atRisk), info = ConfirmCopy.information(atRisk.count,
            renameOnly: renamesOnlyInPlace, otherFilesReplaced: others)
        Task { @MainActor [weak self] in
            let ok = await confirm(title, info)
            guard let self else { return }
            // Already started in the answer itself: never a second run (a
            // short batch may have finished before this task resumed).
            if self.startedOnConfirm { self.startedOnConfirm = false; self.isConfirming = false; return }
            if ok { self.startConfirmedPlan() }
            self.isConfirming = false
            self.confirmed = nil
        }
    }

    private var startedOnConfirm = false

    /// `Change Original(s)` was pressed: starts the confirmed run now, inside
    /// the alert's completion, so the batch is `.running` before any other
    /// event (⌘Q) is handled. Only while the question is open; once.
    public func startConfirmedRun() {
        guard isConfirming, !startedOnConfirm else { return }
        startedOnConfirm = startConfirmedPlan()
    }

    /// Starts the plan the question named, only if the preview generation and
    /// the photos are unchanged; otherwise the form stays (Run asks again).
    @discardableResult
    private func startConfirmedPlan() -> Bool {
        guard let confirmed, canRun, confirmed.generation == previewGeneration,
              let now = makePlan().plan, now.items.map(\.primary) == confirmed.plan.items.map(\.primary)
        else { return false }
        start(overwritingOriginals: true, plan: now)
        return true
    }

    /// Starts without asking. An output that would land on a photo's own
    /// file gets a Finder " 2" name instead, so no original is overwritten.
    public func run() {
        guard canRun, !isConfirming else { return }
        start(overwritingOriginals: false)
    }

    private func start(overwritingOriginals: Bool, plan confirmedPlan: BatchPlan? = nil) {
        guard var plan = confirmedPlan ?? makePlan().plan else { return }
        plan.overwritesOriginals = overwritingOriginals
        rememberForm()
        lastPlan = plan
        // The photos the preview already announced as skipped stay "skipped" in the result.
        announcedUnreadable = unreadablePhotos
        result = nil
        let stop = BatchStop()
        stopper = stop
        droppedDuplicateCount = 0
        phase = .running
        completed = 0
        total = plan.items.count
        etaText = nil
        isStopping = false
        stopRequested = false
        doneAtStop = 0
        doneSoFar = 0
        currentName = plan.items.first?.primary.lastPathComponent
        runQueue = plan.items
        finishedSources = []
        startedAt = .now
        let runner = self.runner
        runTask = Task { [weak self] in
            var final: BatchResult?
            var failure: (any Error)?
            do {
                for try await progress in runner.run(plan, stop: stop) {
                    if let r = progress.result { final = r }
                    self?.progressed(progress)
                }
            } catch {
                failure = error
            }
            self?.finished(final, error: failure, plan: plan)
        }
    }

    /// Stop: no new items; in-flight ones are cancelled. The Done view
    /// still comes, with "Canceled." rows.
    public func stop() {
        guard phase == .running, !isStopping else { return }
        isStopping = true
        // The title follows the user's Stop, not the cancelled rows.
        stopRequested = true
        doneAtStop = doneSoFar
        stopper?.stop()
    }

    /// The user pressed Stop in this run (cleared when a run starts and on `resetToForm`).
    public private(set) var stopRequested = false
    /// Photos done when Stop was pressed (from `onProgress`), and done so far.
    private(set) var doneAtStop = 0
    private var doneSoFar = 0
    #if DEBUG
    /// Look checks only: `-ShrikeDebugBatchStopAt <n>` presses Stop (the real path) after n photos.
    private static let debugStopAt: Int? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-ShrikeDebugBatchStopAt"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }()
    #endif

    /// Waits for the run to end (tests, and a Stop from the close alert).
    public func waitForRun() async { await runTask?.value }

    /// The plan's photos in order, and the ones that have finished (workers
    /// finish out of order, so the runner's "item that just finished" is not
    /// the photo being worked on).
    private var runQueue: [ImageGroup] = []
    private var finishedSources: Set<ImageGroup> = []

    /// The first photo in plan order that is not finished; `fallback` when all are.
    static func workingName(queue: [ImageGroup], finished: Set<ImageGroup>, fallback: String?) -> String? {
        queue.first { !finished.contains($0) }?.primary.lastPathComponent ?? fallback
    }

    private func progressed(_ progress: BatchProgress) {
        completed = progress.completed
        total = progress.total
        if let item = progress.item {
            finishedSources.insert(item.source)
            if case .done = item.outcome { doneSoFar += 1 }
        }
        #if DEBUG
        if let at = Self.debugStopAt, progress.completed >= at { stop() }
        #endif
        // Name, counter and bar come from this one step: the name is the next
        // photo still to do, never an earlier one that already finished.
        currentName = Self.workingName(queue: runQueue, finished: finishedSources,
                                       fallback: progress.currentName ?? currentName)
        etaText = Self.eta(completed: completed, total: total,
                           elapsed: startedAt.map { ContinuousClock.now - $0 })
        onProgress?(completed, total)
    }

    private func finished(_ final: BatchResult?, error: (any Error)?, plan: BatchPlan) {
        stopper = nil
        isStopping = false
        guard let final else {
            phase = .form
            validationMessage = (error as? BatchValidationError)?.message ?? Copy.couldNotStart
            onFinished?(nil, plan)
            return
        }
        result = final
        isUndone = false
        summary = Self.summary(final, verb: Self.verb(for: plan), announcedSkips: announcedUnreadable)
        if let line = ConfirmCopy.otherFilesWereReplaced(final.replacedVictims.count) {
            summary = summary.isEmpty ? line : summary + " · " + line
        }
        // A stopped in-place rename says which names the photos have now;
        // the "N other files were replaced." line stays as its last line.
        if stopRequested, Self.isRenameOnly(plan) {
            summary = Self.stoppedRenameSummary(Self.stoppedRenameLines(
                total: final.items.count, newNames: final.newNameCount, oldNames: final.oldNameCount,
                putBack: final.items.compactMap { item in item.putBackAs.map { (item.source.primary.lastPathComponent, $0.lastPathComponent) } },
                issuesLine: Self.issuesLine(final, announcedSkips: announcedUnreadable),
                finishedAfterStop: final.newNameCount > doneAtStop
            ), otherFilesReplaced: final.replacedVictims.count)
        }
        skippedRows = final.items.compactMap { item in
            switch item.outcome {
            case .done: return nil
            case .skipped(let reason):
                return SkippedRow(name: item.source.primary.lastPathComponent, reason: (item.completedPhases.isEmpty ? "" : item.completedPhases.map(\.rawValue).joined(separator: "; ") + "; ") + reason.message, source: item.source.primary,
                                  isIntentionalSkip: !reason.isRetriedAutomatically && !item.isPartial)
            case .failed(let error):
                let phases = item.completedPhases.map { $0 == .rotate ? "Rotated" : ($0 == .rename ? "Renamed" : "Exported") }.joined(separator: "; ")
                let prefix = phases.isEmpty ? "" : phases + "; "
                return SkippedRow(name: item.source.primary.lastPathComponent, reason: prefix + (item.failurePhase?.rawValue ?? "write") + " failed: " + error.localizedDescription, source: item.source.primary)
            }
        }
        // The result lists rows in finish order; show them in queue order.
        skippedRows = Self.inQueueOrder(skippedRows, plan: plan)
        phase = .done
        onFinished?(final, plan)
    }

    /// Result rows in the order of the plan's queue (workers finish out of
    /// order); rows the plan doesn't know keep their relative order at the end.
    static func inQueueOrder(_ rows: [SkippedRow], plan: BatchPlan) -> [SkippedRow] {
        let position = Dictionary(plan.items.enumerated().map { ($0.element.primary, $0.offset) },
                                  uniquingKeysWith: { first, _ in first })
        return rows.enumerated().sorted { a, b in
            let pa = position[a.element.source] ?? Int.max, pb = position[b.element.source] ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    /// Back to the form after Done, with the same queue and settings
    /// (a second ⌥⌘B while the Done view is up).
    public func resetToForm() {
        guard phase == .done else { return }
        phase = .form
        stopRequested = false
        result = nil
        isUndone = false
        summary = ""
        skippedRows = []
        completed = 0
        total = 0
        schedulePreview()
    }

    /// Clears the queue for new items (a second ⌥⌘B after a finished run).
    public func replaceQueue(with groups: [ImageGroup]) {
        guard !reviewingRemaining, !isConfirming else { return }
        queue = []
        selection = []
        add(groups)
        schedulePreview()
    }

    // MARK: Text

    /// The verb for the Done line: Convert > Resize > Rotate > Rename.
    static func verb(for plan: BatchPlan?) -> String {
        guard let plan else { return "converted" }
        if plan.convert != nil { return "converted" }
        if plan.resize != nil { return "resized" }
        if plan.rotate.map({ $0 % 4 != 0 }) ?? false { return "rotated" }
        return "renamed"
    }

    /// "Done. 40 images converted, 2 skipped."
    /// A file the preview already announced as "skipped" (unreadable when the run started).
    /// The result counts it as skipped too, not as a failure. A file that
    /// became unreadable during the run, or one the preview did not flag, is still a failure.
    nonisolated static func isAnnouncedSkip(_ item: BatchItemResult, announced: Set<URL>) -> Bool {
        if case .skipped(.unreadable) = item.outcome { return announced.contains(item.source.primary) }
        return false
    }

    /// Failed items as the Done view counts them: `BatchResult.failedCount` without the announced skips.
    nonisolated static func failedCount(_ result: BatchResult, announcedSkips: Set<URL>) -> Int {
        result.items.filter {
            switch $0.outcome {
            case .failed: return true
            case .skipped(.unreadable): return !isAnnouncedSkip($0, announced: announcedSkips)
            default: return $0.isPartial
            }
        }.count
    }

    /// The Done title says "issues" for anything but announced skips.
    nonisolated static func hasIssues(_ result: BatchResult, announcedSkips: Set<URL>) -> Bool {
        result.items.contains { item in
            if case .done = item.outcome { return false }
            return !isAnnouncedSkip(item, announced: announcedSkips)
        }
    }

    nonisolated static func summary(_ result: BatchResult, verb: String, announcedSkips: Set<URL> = []) -> String {
        let partial = result.items.filter(\.isPartial).count
        let failed = result.items.filter {
            switch $0.outcome {
            case .failed: return !$0.isPartial
            case .skipped(.unreadable): return !$0.isPartial && !isAnnouncedSkip($0, announced: announcedSkips)
            default: return false
            }
        }.count
        let skipped = result.items.filter {
            if case .skipped(let why) = $0.outcome {
                return !$0.isPartial && why != .cancelled && (why != .unreadable || isAnnouncedSkip($0, announced: announcedSkips))
            }
            return false
        }.count
        return [(result.doneCount, "completed"), (partial, "partially changed"), (failed, "failed"),
                (skipped, "skipped"), (result.cancelledCount, "not processed")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")

    }

    /// Failed and skipped photos "as today", without the done and not-processed parts.
    nonisolated static func issuesLine(_ result: BatchResult, announcedSkips: Set<URL> = []) -> String? {
        let parts = summary(result, verb: "", announcedSkips: announcedSkips).components(separatedBy: " · ")
            .filter { !$0.hasSuffix(" completed") && !$0.hasSuffix(" not processed") && !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// A rename into the originals and nothing else (the verb alone falls back to "renamed").
    static func isRenameOnly(_ plan: BatchPlan) -> Bool {
        guard case .inPlace = plan.output else { return false }
        return verb(for: plan) == "renamed"
    }

    /// The stopped-rename lines, then `N other files were replaced.` as the last line.
    nonisolated static func stoppedRenameSummary(_ lines: [String], otherFilesReplaced n: Int) -> String {
        (lines + [ConfirmCopy.otherFilesWereReplaced(n)].compactMap { $0 }).joined(separator: "\n")
    }

    /// A stopped rename-only run. T photos; D have their new name, K their old
    /// one, W got a " 2" name (`putBack`: old name → name now). The three counts come from
    /// `BatchResult`; a row still under a temporary name is in none of them.
    nonisolated static func stoppedRenameLines(total t: Int, newNames d: Int, oldNames k: Int,
                                               putBack: [(old: String, now: String)],
                                               issuesLine: String?, finishedAfterStop: Bool) -> [String] {
        var lines: [String] = []
        let photos = t == 1 ? "photo" : "photos"
        if d == 0 {
            if k == t {
                lines.append(t == 1 ? "No photo was renamed. It kept its old name." : "No photo was renamed. All \(t) kept their old names.")
            } else if k == 0 {
                lines.append("No photo was renamed.")
            } else {
                // Some rows are not at their old name (a " 2" name or a temporary one).
                lines.append("No photo was renamed. " + (k == 1 ? "1 kept its old name." : "\(k) kept their old names."))
            }
        } else {
            var first = d == 1 ? "1 of \(t) \(photos) has its new name." : "\(d) of \(t) \(photos) have their new names."
            if d == t, t == 1 { first = "1 of 1 photo has its new name." }
            if k == 1 { first += " The other photo kept its old name." }
            else if k > 1 { first += " The other \(k) kept their old names." }
            lines.append(first)
        }
        if let issuesLine { lines.append(issuesLine) }
        // Only when the counts say nothing is left under a temporary name.
        if finishedAfterStop, d + k + putBack.count == t {
            lines.append("Shrike finished the photos whose names it was swapping, so none is left under a temporary name.")
        }
        if let line = putBackLine(putBack) { lines.append(line) }
        return lines
    }

    /// The " 2" names (W > 0). Names through `FileNameFit.short(_, limit: 20)`.
    nonisolated static func putBackLine(_ putBack: [(old: String, now: String)]) -> String? {
        guard let first = putBack.first else { return nil }
        let old = FileNameFit.short(first.old, limit: 20), now = FileNameFit.short(first.now, limit: 20)
        if putBack.count == 1 {
            return "“\(old)” could not get its old name back, because another photo has it now. It is called “\(now)”."
        }
        return "\(putBack.count) photos could not get their old names back, because other photos have those names now. For example, “\(old)” is called “\(now)”."
    }

    /// "about 47 s left" / "about 3 min left"; nil until one item is
    /// done and a second has passed.
    static func eta(completed: Int, total: Int, elapsed: Duration?) -> String? {
        guard let elapsed, completed > 0, completed < total else { return nil }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds >= 1 else { return nil }
        let left = seconds / Double(completed) * Double(total - completed)
        if left < 60 { return "about \(max(1, Int(left.rounded(.up)))) s left" }
        return "about \(Int((left / 60).rounded(.up))) min left"
    }

    /// Copy Log: the summary, then one line per item.
    public var logText: String {
        guard let result else { return "" }
        var lines = [summary, ""]
        for item in result.items {
            let name = item.source.primary.lastPathComponent
            switch item.outcome {
            case .done(let url):
                lines.append(url == item.source.primary ? "\(name): done" : "\(name) → \(url.path)")
            case .skipped(let reason):
                lines.append("\(name): \(reason.message)")
            case .failed(let error):
                lines.append("\(name): \(item.completedPhases.map(\.rawValue).joined(separator: ", ")); \(item.failurePhase?.rawValue ?? "write") failed: \(error.localizedDescription); current: \(item.finalURL?.path ?? item.source.primary.path)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Files the run made or changed (Show in Finder).
    public var doneURLs: [URL] {
        if isUndone { return [] }
        return result?.items.compactMap { if case .done(let url) = $0.outcome { return url }; return $0.isPartial ? $0.finalURL : nil } ?? []
    }

    /// Folders to open in Shrike: the Output folder, or the folders of
    /// the files changed in place.
    public var doneFolders: [URL] {
        if let plan = lastPlan, case .folder(let folder) = plan.output, plan.convert != nil || plan.resize != nil {
            return doneURLs.isEmpty ? [] : [folder]
        }
        var seen = Set<String>()
        return doneURLs.map { $0.deletingLastPathComponent() }.filter { seen.insert($0.path).inserted }
    }

    /// The folder named under the Done summary: the Output folder, or the
    /// one folder changed in place. Nil when nothing was done or the run
    /// changed files in several folders.
    public var resultFolder: URL? {
        let folders = doneFolders
        return folders.count == 1 ? folders[0] : nil
    }

    /// `resultFolder` as the Done view writes it ("~/Pictures/Shrike Export",
    /// "/tmp/out" — never "/private/tmp/out").
    public var resultFolderText: String? {
        resultFolder.map(UserFacingPath.string)
    }

    /// "Batch Rename" / "Batch Rotate" / "Batch Rotate and Rename", or nil
    /// when the run left nothing to undo in place.
    public var undoActionName: String? {
        guard !isUndone, let plan = lastPlan, let result, result.canUndo else { return nil }
        if result.items.contains(where: { $0.recoveryRequired != nil }) { return "Batch Changes" }
        if case .folder = plan.output, plan.convert != nil || plan.resize != nil { return result.replacedOriginals.isEmpty ? nil : "Batch Changes" }
        let rotated = !result.rotations.isEmpty
        let renamed = !result.renames.isEmpty
        switch (rotated, renamed) {
        case (true, true): return "Batch Rotate and Rename"
        case (true, false): return "Batch Rotate"
        case (false, true): return "Batch Rename"
        case (false, false): return result.replacedOriginals.isEmpty ? nil : "Batch Changes"
        }
    }
}

/// The grey line under "N photos chosen". Pure.
public enum BatchScope {
    /// Add Photos…, a drop, Remove from Queue, or added to an open Batch.
    public static let pickedByHand = "Picked by hand"

    /// `“X”` with curly quotes; a missing name reads `this folder`, no quotes.
    static func quoted(_ folderName: String?) -> String {
        guard let folderName, !folderName.isEmpty else { return "this folder" }
        return "“\(folderName)”"
    }

    /// Browser: some photos selected, or nothing selected (all shown in the grid).
    public static func browser(selectedAny: Bool, folderName: String?) -> String {
        (selectedAny ? "Selected in " : "All shown in ") + quoted(folderName)
    }

    /// Viewer: the shown photo.
    public static func viewer(folderName: String?) -> String {
        "Shown in " + quoted(folderName)
    }
}

/// How a Batch preview row looks for a photo the run will skip.
/// Pure.
public enum BatchPreviewRowLook {

    /// What a row whose name is taken says,
    /// per "If a file exists" answer. nil = no words (and no warning sign).
    /// - Replace: `Replaces “IMG_2.jpg”.` when it trashes a file outside
    ///   the queue; a name an earlier row took gets a free name: no words.
    /// - Keep Both: no words; the name column already shows the " 2" name.
    /// - Skip: `Skipped. A file with this name exists.`
    public static func clashText(_ row: BatchPreviewRow, policy: ConflictAnswer.Action,
                                 replacesOutsideFile: Bool) -> String? {
        if case .nameExists? = row.skip { return "Skipped. A file with this name exists." }
        guard row.nameClash, row.skip == nil else { return nil }
        switch policy {
        case .replace: return replacesOutsideFile ? "Replaces “\(row.destination.lastPathComponent)”." : nil
        case .keepBoth: return nil
        case .skip: return "Skipped. A file with this name exists."
        }
    }

    /// The reason text of a skipped-look row (grey, warning icon, no arrow and
    /// no new name); nil = the normal arrow row. An unreadable photo gets
    /// `Skipped. ` in front; the name texts already end with `— skipped.`.
    public static func skipText(_ skip: BatchSkipReason?) -> String? {
        switch skip {
        case .unreadable?: return "Skipped. " + BatchSkipReason.unreadable.message
        case .emptyName?, .invalidName?: return skip?.message
        default: return nil
        }
    }

    /// `broken.jpg. Skipped. Shrike can't read this file.`
    public static func accessibilityLabel(name: String, skipText: String) -> String {
        "\(name). \(skipText)"
    }

    /// The name-problem text for the template field when the name is the cause.
    /// The filled name is empty (the field itself is not).
    static let emptyNameText = "The new name would be empty. Change the template."

    static func templateText(firstNameSkip: BatchSkipReason?) -> String {
        switch firstNameSkip {
        case .invalidName(let why)?: return why.message ?? emptyNameText
        default: return emptyNameText
        }
    }
}

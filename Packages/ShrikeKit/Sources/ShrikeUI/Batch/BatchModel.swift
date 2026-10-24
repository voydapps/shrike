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
        /// (not "Cancelled.", unreadable or disk full: those retry by themselves).
        public var isIntentionalSkip = false
    }

    // MARK: Copy (new lines marked)

    public enum Copy {
        public static let defaultOutputFolderName = "Shrike Export"
        public static let inPlaceRotate = "Changes the original files. Undo works while Shrike still has the backup."
        public static let inPlace = "In place"
        public static let nameClash = "Name already used"
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
        public static func title(_ n: Int) -> String { "Batch — \(images(n))" }
        public static func runButton(_ n: Int) -> String { n == 1 ? "Run 1 Photo" : "Run \(n) Photos" }
        public static func andMore(_ n: Int) -> String { "and \(n) more" }
        public static func unknownToken(_ token: String) -> String { "Unknown name part {\(token)}. Choose one from Insert Field…" }
        public static func progress(_ done: Int, _ total: Int) -> String { "\(done.formatted(.number)) of \(total.formatted(.number))" }
        public static func stopAlertInfo(_ done: Int, _ total: Int) -> String {
            "Completed: \(done) of \(images(total)). Completed changes are kept; no new photos are started."
        }
    }

    // MARK: Published state

    @Published public private(set) var queue: [BatchQueueItem] = []
    @Published public var selection: Set<URL> = []
    /// Display-oriented pixel sizes, read off main after items arrive.
    @Published public private(set) var sizes: [URL: CGSize] = [:]
    @Published public var form = BatchForm() {
        didSet { if form != oldValue { schedulePreview() } }
    }

    @Published public private(set) var previewRows: [BatchPreviewRow] = []

    /// Queued photos the preview already knows Shrike can't read (they are skipped at run time).
    /// Counted over the whole queue, not only the preview's first rows.
    @Published public private(set) var unreadableCount = 0
    public var unreadableLine: String? {
        let n = unreadableCount
        guard n > 0 else { return nil }
        return n == 1 ? "1 photo can't be read and will be skipped." : "\(n) photos can't be read and will be skipped."
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
    @Published public private(set) var presets: [BatchPreset] = BatchPresetStore.builtIns
    @Published public private(set) var phase: Phase = .form

    @Published public private(set) var completed = 0
    @Published public private(set) var total = 0
    @Published public private(set) var currentName: String?
    @Published public private(set) var etaText: String?
    @Published public private(set) var isStopping = false

    @Published public private(set) var result: BatchResult?
    @Published public private(set) var summary = ""
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
    @Published public private(set) var scopeDescription = "Custom selection"
    public func setOriginScope(_ text: String) { scopeDescription = text }
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
        let n = queue.count
        if form.writesToFolder, overwriteCount > 0 {
            return "Create \(n) \(n == 1 ? "photo" : "photos") in \(outputFolder.map(UserFacingPath.string) ?? "the output folder"). "
                + overwriteSentence + " " + recovery
        }
        if form.writesToFolder {
            let destination = outputFolder.map(UserFacingPath.string) ?? "the output folder"
            let originals = n == 1 ? "Original stays unchanged." : "Originals stay unchanged."
            return "Create \(n) new \(n == 1 ? "photo" : "photos") in \(destination). " + originals
                + (form.onConflict == .replace ? " Existing outputs: Replace." : "")
        }
        let verb = form.rotateOn && form.renameOn ? "Rotate and rename" : (form.rotateOn ? "Rotate" : "Rename")
        return "\(verb) \(n) original \(n == 1 ? "file" : "files"). " + recovery
    }
    /// Same words as the in-place Rotate/Rename line.
    var overwriteSentence: String {
        overwriteCount == 1 ? "1 original file changes in place; recovery data is kept when available."
            : "\(overwriteCount) original files change in place; recovery data is kept when available."
    }
    public var resultTitle: String {
        guard let result else { return "Batch" }
        if result.cancelledCount > 0 { return "Batch stopped" }
        if result.doneCount == 0 && result.failedCount > 0 { return "No photos completed" }
        return skippedRows.isEmpty ? "Batch complete" : "Batch finished with issues"
    }
    /// The Done view's hint about selecting skips is only useful when some
    /// skip was on purpose (not "Cancelled." or an unreadable file).
    public var hasIntentionalSkips: Bool { result?.hasIntentionalSkips ?? false }
    public var canReviewRemaining: Bool {
        guard let result, let lastPlan else { return false }
        return !runner.retryPlan(for: result, original: lastPlan, selectedIntentionalSkips: selectedResultRows).items.isEmpty
    }
    public func reviewRemaining(includingIntentionalSkips: Bool = false) {
        guard phase == .done, let result, let lastPlan else { return }
        let plan = runner.retryPlan(for: result, original: lastPlan, includingIntentionalSkips: includingIntentionalSkips, selectedIntentionalSkips: selectedResultRows)
        guard !plan.items.isEmpty else { return }
        remainingPlan = plan; reviewingRemaining = true
        queue = plan.items.map { BatchQueueItem(group: $0) }; selection = []
        phase = .form; schedulePreview()
    }
    public func cancelRemainingReview() {
        guard reviewingRemaining else { return }
        queue = lastPlan?.items.map { BatchQueueItem(group: $0) } ?? []
        remainingPlan = nil; reviewingRemaining = false; phase = .done
    }
    public func runAnother() {
        guard phase == .done || reviewingRemaining else { return }
        remainingPlan = nil; reviewingRemaining = false
        queue = []; selection = []; result = nil; skippedRows = []; summary = ""; phase = .form
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

    /// Adds groups not already queued (by path), in order.
    public func add(_ groups: [ImageGroup]) {
        guard !reviewingRemaining else { return }
        var known = Set(queue.map { GroupList.canonical($0.group.primary) })
        var fresh: [BatchQueueItem] = []
        for group in groups where known.insert(GroupList.canonical(group.primary)).inserted {
            fresh.append(BatchQueueItem(group: group))
        }
        guard !fresh.isEmpty, phase != .running else { return }
        scopeDescription = "Custom selection"
        if reviewingRemaining { remainingPlan = nil; reviewingRemaining = false }
        queue += fresh
        readSizes(of: fresh.map(\.group.primary))
        schedulePreview()
    }

    /// Drag to reorder (the order is the counter order).
    public func move(from source: IndexSet, to destination: Int) {
        guard !reviewingRemaining else { return }
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
        guard !reviewingRemaining else { return }
        guard !selection.isEmpty else { return }
        scopeDescription = "Custom selection"
        queue.removeAll { selection.contains($0.id) }
        selection = []
        schedulePreview()
    }

    public var title: String { Copy.title(queue.count) }

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
        return form.renameOn ? Copy.inPlace : nil
    }

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
                rename = try RenameTemplate(parsing: form.template, counterStart: form.counterStart,
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
    public var validationLine: String? {
        if let templateError { return templateError }
        if queue.isEmpty { return Copy.emptyQueue }
        return validationMessage
    }

    public var canRun: Bool {
        phase == .form && !queue.isEmpty && templateError == nil && validationMessage == nil && isPreviewCurrent
    }

    // MARK: Preview (150 ms debounce, off main)

    func schedulePreview() {
        conversionDisclosures = []
        overwriteCount = 0
        previewTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        isPreviewCurrent = false
        let built = makePlan()
        templateError = built.templateError
        guard let plan = built.plan, !queue.isEmpty else {
            previewRows = []
            unreadableCount = 0
            moreCount = 0
            validationMessage = nil
            return
        }
        let runner = self.runner
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.previewDebounce)
            if Task.isCancelled { return }
            // Show the names a confirmed run would use.
            var confirmed = plan
            confirmed.overwritesOriginals = true
            let (rows, validation, disclosures, overwrites) = await Self.evaluate(confirmed, runner: runner)
            let unreadable = await Self.countUnreadable(confirmed, runner: runner)
            guard let self, !Task.isCancelled, generation == self.previewGeneration else { return }
            self.unreadableCount = unreadable
            self.conversionDisclosures = disclosures
            self.overwriteCount = overwrites
            self.previewRows = rows
            self.moreCount = max(0, plan.items.count - Self.previewLimit)
            self.validationMessage = validation?.message
            self.isPreviewCurrent = true
        }
    }

    @concurrent
    nonisolated static func countUnreadable(_ plan: BatchPlan, runner: BatchRunner) async -> Int {
        runner.unreadableCount(in: plan)
    }

    @concurrent
    nonisolated static func evaluate(_ plan: BatchPlan, runner: BatchRunner) async
        -> ([BatchPreviewRow], BatchValidationError?, [String], Int) {
        let rows = await runner.preview(plan, limit: previewLimit)
        let overwrites = runner.originalsOverwritten(by: plan)
        var disclosures = Set<String>()
        if plan.convert != nil || plan.resize != nil || !(plan.recipe?.isEmpty ?? true) {
            let sizes = await headerSizes(plan.items.map(\.primary))
            for group in plan.items {
                if Task.isCancelled { break }
                var ops = plan.recipe ?? []
                if let rotate = plan.rotate, rotate % 4 != 0 { ops.append(.rotate90(quarters: rotate)) }
                if let resize = plan.resize, let size = sizes[group.primary] {
                    let target = resize.targetSize(for: size)
                    ops.append(.resize(ResizeSpec(width: Int(target.width), height: Int(target.height), interpolation: .lanczos, preventUpscale: resize.dontEnlarge)))
                }
                let capability = ImageExporter.capability(for: group.primary, operations: ops, format: plan.convert?.format)
                if let disclosure = capability.conversionDisclosure { disclosures.insert(disclosure) }
            }
        }
        return (rows, plan.validationError, disclosures.sorted(), overwrites)
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
        guard !reviewingRemaining else { return }
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

    /// Shows the "Change N original photos?" alert; true = Change Originals.
    /// The Batch window sets it. Without one, a run that changes originals
    /// is not started.
    var confirmChangeOriginals: (@MainActor (_ title: String, _ information: String) async -> Bool)?
    private var isConfirming = false

    /// The photos of `plan` whose original files the run may change: all of
    /// them for an in-place plan, and for a folder plan those whose output
    /// file is the photo's own file (the runner compares case-folded paths).
    func originalsAtRisk(_ plan: BatchPlan) -> [ImageGroup] {
        switch plan.output {
        case .inPlace: return plan.items
        case .folder: return overwriteCount > 0 ? runner.groupsOverwritten(by: plan) : []
        }
    }

    public enum ConfirmCopy {
        public static func title(_ groups: [ImageGroup]) -> String {
            groups.count == 1 ? "Change the original photo “\(groups[0].displayName)”?"
                              : "Change \(groups.count) original photos?"
        }
        public static func information(_ count: Int) -> String {
            count == 1 ? "Shrike keeps a backup of the original, and Undo or Revert can restore it."
                       : "Shrike keeps a backup of each original, and Undo or Revert can restore them."
        }
        public static let confirm = "Change Originals"
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
        let title = ConfirmCopy.title(atRisk), info = ConfirmCopy.information(atRisk.count)
        Task { @MainActor [weak self] in
            let ok = await confirm(title, info)
            guard let self else { return }
            self.isConfirming = false
            if ok, self.canRun { self.start(overwritingOriginals: true) }
        }
    }

    /// Starts without asking. An output that would land on a photo's own
    /// file gets a Finder " 2" name instead, so no original is overwritten.
    public func run() {
        guard canRun else { return }
        start(overwritingOriginals: false)
    }

    private func start(overwritingOriginals: Bool) {
        let built = makePlan()
        guard var plan = built.plan else { return }
        plan.overwritesOriginals = overwritingOriginals
        rememberForm()
        lastPlan = plan
        result = nil
        let stop = BatchStop()
        stopper = stop
        phase = .running
        completed = 0
        total = plan.items.count
        etaText = nil
        isStopping = false
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
    /// still comes, with "Cancelled." rows.
    public func stop() {
        guard phase == .running, !isStopping else { return }
        isStopping = true
        stopper?.stop()
    }

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
        if let item = progress.item { finishedSources.insert(item.source) }
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
        summary = Self.summary(final, verb: Self.verb(for: plan))
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
        // The result lists rows in finish order; show them in queue order (audit on-screen L2).
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
        result = nil
        summary = ""
        skippedRows = []
        completed = 0
        total = 0
        schedulePreview()
    }

    /// Clears the queue for new items (a second ⌥⌘B after a finished run).
    public func replaceQueue(with groups: [ImageGroup]) {
        guard !reviewingRemaining else { return }
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
    static func summary(_ result: BatchResult, verb: String) -> String {
        let partial = result.items.filter(\.isPartial).count
        let failed = result.items.filter {
            switch $0.outcome {
            case .failed, .skipped(.unreadable): return !$0.isPartial
            default: return false
            }
        }.count
        let skipped = result.items.filter { if case .skipped(let why) = $0.outcome { return why != .cancelled && why != .unreadable && !$0.isPartial }; return false }.count
        return [(result.doneCount, "completed"), (partial, "partially changed"), (failed, "failed"),
                (skipped, "skipped"), (result.cancelledCount, "not processed")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")

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
        result?.items.compactMap { if case .done(let url) = $0.outcome { return url }; return $0.isPartial ? $0.finalURL : nil } ?? []
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
        guard let plan = lastPlan, let result, result.canUndo else { return nil }
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

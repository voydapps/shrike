//
//  EditModeController.swift
//  ShrikeUI
//
//  Orchestrates the edit-mode session from enter to exit.
//
//  Lifecycle:
//    1. `enter(image:url:)` stashes the source image + URL, creates a
//       fresh `EditRecipe`, flips `isActive` on, and returns ownership
//       of the toolbar / parameter-panel / status-strip views to the
//       window layer for mounting.
//    2. `selectTool(_:)` switches the right-rail panel, wiring its
//       callbacks back into the controller. Tool-agnostic toolbar stays
//       put; only the panel swaps.
//    3. Each panel drives the controller via closures. Continuous events
//       route through `EditRenderer.render(recipe:from:qualityHint: .draft)`
//       and push the result into `MetalImageView.setPlaceholderImage(_:)`
//       (which is the non-animated quick swap, perfect for live preview).
//       Committed events either `append` or `replaceLast` on the recipe
//       then do a `.full` render.
//    4. `attemptExit(reason:)` checks `EditRecipe.isDirty` and routes
//       through `EditExitModal` if needed. The result (save / saveAs /
//       discard / cancel) flows back through the window's dispatch so
//       `⌘S` / `⌘⇧S` / Done / Esc / ⌘W / ⌘Q all share one path.
//

import AppKit
import ShrikeCore
import ShrikeEdit

/// How the user is trying to leave edit mode. Drives the modal copy
/// and — for `.windowClose` / `.appQuit` — whether a Cancel should
/// veto the close/quit.
@MainActor
public enum EditExitReason: Sendable, Equatable {
    case userToggled     // Esc, Done, `E`
    case windowClose     // ⌘W
    case appQuit         // ⌘Q
    case navigation      // another photo or folder (Go menu, filmstrip, keys)
}

/// Outcome the controller reports back to the window after the exit
/// modal resolves. The window uses this to decide whether to actually
/// close / quit / leave edit mode.
@MainActor
public enum EditExitOutcome: Sendable, Equatable {
    case exited
    case cancelled
    case needsSave
    case needsSaveAs
}

@MainActor
public final class EditModeController {

    // MARK: - Owned views

    let parameterPanel = EditParameterPanel()
    let cropOverlay = CropOverlayView()

    /// The window the session runs in (sheets hang here). Set by the
    /// content view on entry.
    weak var hostWindow: NSWindow?

    /// What the edit toolbar / capsule shows.
    private(set) var chromeState = EditChromeState()

    /// Fires whenever `chromeState` changes.
    var onChromeStateChanged: ((EditChromeState) -> Void)?

    // MARK: - Session state

    public private(set) var isActive: Bool = false
    /// Nil until a tool is picked.
    public private(set) var currentTool: EditTool?
    public private(set) var sourceURL: URL?
    public private(set) var originalImage: CGImage?

    /// The live recipe. `nil` until `enter(…)`; reset on exit.
    public var recipe: EditRecipe?

    private let renderer = EditRenderer()

    /// Last known pixel size of the source — used by panels + overlay.
    private var sourcePixelSize: CGSize = .zero

    /// Last tool-panel snapshot so re-entering a tool mid-session
    /// (switching back to Crop from Rotate) can seed it with the prior
    /// state. For now we just re-construct fresh panels; this property
    /// is a seam for later.
    private var lastColorParams = ColorAdjustParams.identity

    /// Synchronous mirror of "recipe has any ops or undo history" — used
    /// by the (non-edit-mode) Reset button on the edit rail
    /// so the button can disable without an actor hop. Kept in
    /// sync by `refreshPendingEditsMirror()` after any recipe mutation.
    /// Outside an active session this is always false.
    public private(set) var hasPendingEdits: Bool = false

    /// Fires when `hasPendingEdits` flips so the rail can refresh the
    /// Reset button's enabled state without polling.
    var onPendingEditsChanged: ((Bool) -> Void)?

    /// The currently-installed tool panel, typed loosely so `selectTool`
    /// can switch freely.
    private var installedTool: NSView?

    // MARK: - Renderer output wiring

    /// Delegate-like closure the window supplies; receives every image
    /// the controller wants painted onto the MetalImageView. The window
    /// owns the image view so we don't reach into it directly.
    var onPresentImage: ((CGImage) -> Void)?

    /// Fires when the user clicks Done / presses Esc / runs through Save
    /// — the window uses it to swap chrome back to viewer mode.
    /// The Bool is true when the pre-edit image should come back on
    /// screen (discard, Save As a copy), false after a save in place.
    var onExitedEditMode: ((Bool) -> Void)?

    /// Fires with a resolved exit outcome after the modal (if any).
    var onExitOutcome: ((EditExitOutcome) -> Void)?

    /// Closure requesting a save pass from the window. The window owns
    /// the `ImageExporter` + window sheet, so it resolves quality + RAW
    /// redirect itself.
    var onSaveRequested:   (() -> Void)?
    var onSaveAsRequested: (() -> Void)?

    /// Fires when the user requests a lossless JPEG rotate from inside
    /// edit mode (e.g. ⌘R) — the window routes to the lossless rotator
    /// with recipe-path fallthrough.
    var onLosslessRotate: ((Int) -> Void)?

    // MARK: - Init

    public init() {
        wireCropOverlay()
    }

    /// One entry point for the edit toolbar and the capsule.
    func perform(_ action: EditChromeAction) {
        switch action {
        case .cancel: attemptExit(reason: .userToggled)
        case .selectTool(let tool): selectTool(tool)
        case .undo: performUndo()
        case .redo: performRedo()
        case .reset: revertPendingEdits()
        case .done: done()
        }
    }

    /// Done (button or Return): apply the current tool the
    /// way its own Apply would, then save by the ⌘S rules (in place, or a
    /// copy for RAW) — or just leave when nothing changed.
    public func done() {
        guard isActive, let recipe else { return }
        let pendingCrop = currentTool == .crop ? pendingCropRect() : nil
        endCoalescing()
        if let crop = pendingCrop { appendGeometry(.crop(crop)) }
        let queued = mutationTail
        Task { [weak self] in
            guard let self else { return }
            await queued?.value
            await self.renderTail?.value
            if await recipe.operations.isEmpty {
                self.finalizeExit()
                self.onExitOutcome?(.exited)
            } else if let save = self.onSaveRequested {
                save()
            } else {
                self.onExitOutcome?(.needsSave)
            }
        }
    }

    /// The crop the overlay shows, normalised, or nil when it still
    /// covers the whole image (nothing to apply).
    func pendingCropRect() -> CropRect? {
        guard let crop = overlayCropRect() else { return nil }
        // Within half an image pixel of the whole image: nothing to apply.
        let w = max(Double(currentPixelSize.width), 1), h = max(Double(currentPixelSize.height), 1)
        if crop.originX * w < 0.5, crop.originY * h < 0.5,
           (1 - crop.width) * w < 0.5, (1 - crop.height) * h < 0.5 {
            return nil
        }
        return crop
    }

    /// The overlay's rect relative to the image as drawn (top-left
    /// origin). The drawn image is the image as it enters a new crop
    /// (every earlier geometry op applied), so the crop lands where the
    /// frame was drawn whatever came before it.
    func overlayCropRect() -> CropRect? {
        let f = cropOverlay._imageFrame, r = cropOverlay._cropRect.intersection(cropOverlay._imageFrame)
        guard f.width > 0, f.height > 0, r.width > 0, r.height > 0 else { return nil }
        let crop = CropRect(originX: Double((r.minX - f.minX) / f.width),
                            originY: Double((r.minY - f.minY) / f.height),
                            width: Double(r.width / f.width),
                            height: Double(r.height / f.height))
        return crop.isValid ? crop : nil
    }

    private func publishChrome(_ change: (inout EditChromeState) -> Void) {
        var next = chromeState
        change(&next)
        guard next != chromeState else { return }
        chromeState = next
        onChromeStateChanged?(next)
    }

    private func wireCropOverlay() {
        cropOverlay.isHidden = true
        cropOverlay.onRectChanged = { [weak self] _ in
            // The panel reads the rect lazily at Apply — no per-move
            // dispatch needed here.
            _ = self
        }
    }

    // MARK: - Lifecycle

    /// Enter edit mode with a concrete source. Builds a fresh recipe,
    /// records the original image, sets up the chrome, and lands on
    /// `tool`, or on no tool (the "Choose a Tool" panel, no
    /// crop frame) when it is nil.
    public func enter(image: CGImage, url: URL?, landOn tool: EditTool?) {
        guard !isActive else { return }
        isActive = true
        originalImage = image
        sourceURL = url
        sourcePixelSize = CGSize(width: image.width, height: image.height)
        currentPixelSize = sourcePixelSize
        effectiveColor = .identity
        effectiveLevels = .identity
        levelsHistogramCache = nil
        undoNames = [:]
        operationCount = 0
        undoneCount = 0
        pendingLevelsStatus = nil
        lastWrittenDrag = nil
        coalescing = nil
        recipe = EditRecipe()
        currentTool = nil
        publishChrome { $0 = EditChromeState(tool: tool) }
        refreshToolbarButtons()
        if let tool {
            selectTool(tool)
        } else {
            parameterPanel.install(ChooseToolPanel())
            installedTool = nil
            cropOverlay.isHidden = true
            Culling.announce(Self.noToolAnnouncement)
        }
    }

    /// VoiceOver on a no-tool entry.
    static let noToolAnnouncement = "Editing. Choose a tool."

    /// Switch tool within an active session.
    public func selectTool(_ tool: EditTool) {
        guard isActive else { return }
        // A tool switch ends a slider drag.
        endCoalescing()
        currentTool = tool
        publishChrome { $0.tool = tool }
        installPanel(for: tool)
        // Crop overlay is on-canvas; only the crop tool needs it.
        cropOverlay.isHidden = (tool != .crop)
    }

    /// The user asked to leave edit mode.
    public func attemptExit(reason: EditExitReason) {
        guard isActive else {
            onExitOutcome?(.exited)
            return
        }
        guard let recipe else {
            finalizeExit()
            onExitOutcome?(.exited)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            // Undone-only history is not a change worth an alert.
            let dirty = await !recipe.operations.isEmpty
            if !dirty {
                self.finalizeExit()
                self.onExitOutcome?(.exited)
                return
            }
            guard let window = self.hostWindow ?? self.parameterPanel.window else {
                // No window — treat as exited, the caller will decide
                // what to do with the dirty recipe.
                self.finalizeExit()
                self.onExitOutcome?(.exited)
                return
            }
            // Save for files written in place, Save As…
            // for RAW and other types Shrike can't change.
            let url = self.sourceURL
            let writable = url.map { ExportFormat.inPlaceFormat(for: $0) != nil } ?? false
            EditExitModal.show(on: window, fileName: url?.lastPathComponent ?? "Untitled",
                               writable: writable) { choice in
                switch choice {
                case .save:    self.onExitOutcome?(.needsSave)
                case .saveAs:  self.onExitOutcome?(.needsSaveAs)
                case .discard:
                    self.finalizeExit()
                    self.onExitOutcome?(.exited)
                case .cancel:
                    self.onExitOutcome?(.cancelled)
                }
            }
        }
    }

    /// Called after save completes (or on discard) — tears down the
    /// session state. Safe to call when not active.
    public func finalizeExit(keepDisplay: Bool = false) {
        guard isActive else { return }
        isActive = false
        endCoalescing()
        mutationTail = nil
        renderTail = nil
        recipe = nil
        originalImage = nil
        levelsHistogramCache = nil
        levelsHistogramTask?.cancel()
        levelsHistogramTask = nil
        undoNames = [:]
        operationCount = 0
        undoneCount = 0
        sourceURL = nil
        sourcePixelSize = .zero
        parameterPanel.install(nil)
        installedTool = nil
        currentTool = nil
        cropOverlay.isHidden = true
        publishChrome { $0 = EditChromeState() }
        updatePendingEditsMirror(false)
        onExitedEditMode?(!keepDisplay)
    }

    /// Public helper used by the window on a forced undo/redo dispatch
    /// (menu item, ⌘Z while panel doesn't have focus).
    public func performUndo() {
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            _ = await recipe.undo()
        }
    }

    public func performRedo() {
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            _ = await recipe.redo()
        }
    }

    /// Revert every pending edit — wipes the whole recipe, clears the
    /// redo stack, and re-renders. Shown on the
    /// windowed edit rail as the Reset button. Safe no-op when the
    /// recipe is absent or already empty.
    public func revertPendingEdits() {
        guard recipe != nil else {
            updatePendingEditsMirror(false)
            return
        }
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            await recipe.reset()
        }
    }

    /// Update the synchronous `hasPendingEdits` mirror + broadcast. Call
    /// after any recipe mutation from MainActor code.
    internal func updatePendingEditsMirror(_ flag: Bool) {
        guard hasPendingEdits != flag else { return }
        hasPendingEdits = flag
        onPendingEditsChanged?(flag)
    }

    /// Reset the active tool's parameters to identity — does NOT
    /// touch the recipe. Scoped per-tool because each panel owns its
    /// own "reset" concept.
    public func resetCurrentTool() {
        if let crop = installedTool as? CropPanel {
            crop.setDimensions(width: Int(currentPixelSize.width),
                               height: Int(currentPixelSize.height))
            cropOverlay.resetToFull()
        } else if let rot = installedTool as? RotatePanel {
            rot.setAngle(0)
        } else if let colour = installedTool as? ColorAdjustPanel {
            colour.setParams(.identity)
        }
        // Resize panel has no "reset" beyond clearing fields — handled
        // by the tool itself if the user chooses.
    }

    /// Append a snapped 90° rotate to the recipe (`[` / `]`).
    /// Collapses the parameter panel back to the tool it was on.
    public func appendSnapped90(quarters: Int) {
        appendGeometry(.rotate90(quarters: quarters))
    }

    // MARK: - Recipe writes

    enum RenderPass { case draft, full }
    enum CoalesceKind: Equatable { case color, freeRotate, levels }

    /// The slider drag in progress: which kind, and its id.
    private var coalescing: (kind: CoalesceKind, drag: Int)?
    private var dragCounter = 0
    /// The drag whose op is the recipe's last op (set by the serial
    /// writes; any other write clears it).
    private var lastWrittenDrag: Int?
    private var coalesceIdleTask: Task<Void, Never>?
    /// A drag ends 500 ms after its last frame.
    static let coalesceIdle: TimeInterval = 0.5

    /// Recipe writes run one after another, in call order.
    private var mutationTail: Task<Void, Never>?
    /// The newest render (renders overlap so the renderer can drop
    /// stale ones).
    private var renderTail: Task<Void, Never>?

    /// Size of the image as drawn now (every op applied, full render).
    private(set) var currentPixelSize: CGSize = .zero
    /// The Color panel's values as the recipe draws them.
    private(set) var effectiveColor = ColorAdjustParams.identity

    /// Ends the running drag: the next slider frame starts a new undo
    /// step. Tool switch, Apply, undo, redo and Reset call it.
    func endCoalescing() {
        coalescing = nil
        coalesceIdleTask?.cancel()
        coalesceIdleTask = nil
    }

    private func enqueue(render: RenderPass?, syncPanels: Bool = false,
                         _ body: @escaping @MainActor (EditRecipe) async -> Void) {
        guard let recipe else { return }
        let previous = mutationTail
        mutationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.recipe === recipe else { return }
            await body(recipe)
            await self.afterWrite(recipe: recipe, render: render, syncPanels: syncPanels)
        }
    }

    private func afterWrite(recipe: EditRecipe, render: RenderPass?, syncPanels: Bool) async {
        let ops = await recipe.snapshot()
        effectiveColor = EditRecipe.effectiveColorAdjust(ops)
        effectiveLevels = EditRecipe.effectiveLevels(ops)
        if syncPanels { syncPanelsFromRecipe(ops) }
        if let levels = installedTool as? LevelsPanel {
            if let status = pendingLevelsStatus {
                levels.showStatus(status)
            }
            refreshLevelsHistogram(ops: ops)
        }
        pendingLevelsStatus = nil
        if let render {
            renderTail = Task { @MainActor [weak self] in
                guard let self else { return }
                if render == .draft { await self.renderDraft() } else { await self.renderFull() }
            }
        }
        await refreshStatusCountsAsync()
    }

    /// Crop / Rotate / Resize Apply: always a new undo step.
    private func appendGeometry(_ op: EditOperation) {
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            await recipe.append(op)
            await self?.nameLastStep(recipe, nil)
        }
    }

    /// A slider frame: the first frame of a drag appends, later frames of
    /// the same drag replace that op (never another op). A frame that
    /// changes nothing adds no undo step.
    private func writeCoalesced(_ op: EditOperation, kind: CoalesceKind,
                                render: RenderPass, endsDrag: Bool = false) {
        if coalescing?.kind != kind {
            dragCounter += 1
            coalescing = (kind, dragCounter)
        }
        let drag = coalescing?.drag ?? dragCounter
        coalesceIdleTask?.cancel()
        if endsDrag {
            coalescing = nil
        } else {
            coalesceIdleTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.coalesceIdle * 1_000_000_000))
                guard !Task.isCancelled, let self, self.coalescing?.drag == drag else { return }
                self.coalescing = nil
            }
        }
        enqueue(render: render) { [weak self] recipe in
            guard let self else { return }
            let ops = await recipe.snapshot()
            if self.lastWrittenDrag == drag, let last = ops.last, Self.kind(of: last) == kind {
                await recipe.replaceLast(op)
                return
            }
            if Self.isNoChange(op, ops: ops) { return }
            await recipe.append(op)
            await self.nameLastStep(recipe, nil)
            self.lastWrittenDrag = drag
        }
    }

    private static func kind(of op: EditOperation) -> CoalesceKind? {
        switch op {
        case .colorAdjust: return .color
        case .rotate: return .freeRotate
        case .levels: return .levels
        default: return nil
        }
    }

    private static func isNoChange(_ op: EditOperation, ops: [EditOperation]) -> Bool {
        switch op {
        case .colorAdjust(let p): return p == EditRecipe.effectiveColorAdjust(ops)
        case .rotate(let degrees): return abs(degrees) < 0.0001
        case .levels(let p): return p == EditRecipe.effectiveLevels(ops)
        default: return false
        }
    }

    /// After undo / redo / Reset / Apply the panels show what the
    /// recipe draws.
    private func syncPanelsFromRecipe(_ ops: [EditOperation]) {
        lastColorParams = EditRecipe.effectiveColorAdjust(ops)
        if let colour = installedTool as? ColorAdjustPanel {
            colour.setParams(lastColorParams)
        } else if let rot = installedTool as? RotatePanel {
            if case .rotate(let d) = ops.last { rot.setAngle(d) } else { rot.setAngle(0) }
        } else if let levels = installedTool as? LevelsPanel {
            // Undo / redo / Reset: the handles show what the recipe
            // draws, and the status line clears.
            levels.setParams(EditRecipe.effectiveLevels(ops))
            levels.showStatus(nil)
        }
    }

    /// Test seam: the tool panel on screen.
    var _installedToolForTesting: NSView? { installedTool }

    /// Test seam: waits for every queued write and the render after it.
    func settleForTesting() async {
        while true {
            let m = mutationTail, r = renderTail
            await m?.value
            await r?.value
            if m == mutationTail, r == renderTail { return }
        }
    }

    // MARK: - Save helpers

    /// Decide which export format to use for a given source URL. Asks
    /// `ExportFormat.inPlaceFormat(for:)` (ShrikeEdit); when the
    /// file can't be overwritten safely (RAW, GIF, PSD, multi-frame…) the
    /// save is redirected to a JPEG sibling — see `destinationURL(for:)`.
    /// Returns `nil` when the URL is missing (synthetic source).
    static func exportFormat(for url: URL?) -> ExportFormat? {
        guard let url else { return nil }
        return ExportFormat.inPlaceFormat(for: url) ?? .jpeg
    }

    /// Where ⌘S writes: the original when it can be overwritten safely,
    /// otherwise `<stem>-edited.jpg` next to it.
    static func destinationURL(for url: URL) -> URL {
        if ExportFormat.inPlaceFormat(for: url) == nil {
            return ExportFormat.editedSiblingURL(for: url, format: .jpeg)
        }
        return url
    }

    static func urlIsRAW(_ url: URL?) -> Bool {
        guard let url else { return false }
        return ImageFormat.isCameraRAW(url)
    }

    // MARK: - Panel installation

    private func toolDisplayName(_ tool: EditTool) -> String {
        switch tool {
        case .crop:   return "Crop"
        case .rotate: return "Rotate"
        case .resize: return "Resize"
        case .color:  return "Color Adjust"
        case .levels: return "Levels"
        }
    }

    private func installPanel(for tool: EditTool) {
        switch tool {
        case .crop:   installCropPanel()
        case .rotate: installRotatePanel()
        case .resize: installResizePanel()
        case .color:  installColorPanel()
        case .levels: installLevelsPanel()
        }
    }

    private func installCropPanel() {
        let panel = CropPanel()
        panel.setDimensions(width: Int(currentPixelSize.width),
                            height: Int(currentPixelSize.height))
        panel.onApply = { [weak self] in
            self?.applyCurrentCrop()
        }
        panel.onReset = { [weak self] in
            self?.cropOverlay.resetToFull()
        }
        panel.onAspectChanged = { [weak self] aspect in
            let ratio: Double?
            if aspect == .original, let s = self?.currentPixelSize,
               s.width > 0, s.height > 0 {
                ratio = Double(s.width) / Double(s.height)
            } else {
                ratio = aspect.ratio
            }
            self?.cropOverlay.aspectRatio = ratio
        }
        panel.onShowThirdsChanged = { [weak self] flag in
            self?.cropOverlay.showThirds = flag
        }
        panel.onShowGoldenChanged = { [weak self] flag in
            self?.cropOverlay.showGolden = flag
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installRotatePanel() {
        let panel = RotatePanel()
        panel.setAutoCrop(Prefs.editAutoCropOnFreeRotate)
        panel.onQuickRotate = { [weak self] quarters in
            self?.appendSnapped90(quarters: quarters)
        }
        panel.onAngleChanged = { [weak self] degrees in
            self?.previewFreeRotate(degrees: degrees)
        }
        panel.onAngleCommitted = { [weak self] degrees in
            self?.commitFreeRotate(degrees: degrees)
        }
        panel.onReset = { [weak self] in
            // Drop the last .rotate(degrees:) if the tail matches.
            self?.undoLastFreeRotate()
        }
        panel.onApply = { [weak self] in
            // Apply just collapses — the commit already landed on the
            // recipe via the idle-commit path. It ends the drag.
            self?.endCoalescing()
            self?.refreshToolbarButtons()
        }
        panel.onAutoCropChanged = { flag in
            Prefs.editAutoCropOnFreeRotate = flag
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installResizePanel() {
        let panel = ResizePanel()
        panel.sourcePixelSize = currentPixelSize
        panel.onApply = { [weak self] spec in
            self?.applyResize(spec: spec)
        }
        panel.onSpecChanged = { [weak self] _ in
            // Live preview deferred — a resize preview requires a full
            // render at the target size, which is cheap for small
            // destinations and expensive for no-ops. Previews are on
            // Apply only.
            _ = self
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installColorPanel() {
        let panel = ColorAdjustPanel()
        panel.setParams(effectiveColor)
        panel.onParamsChanged = { [weak self] params in
            self?.previewColorAdjust(params: params)
        }
        panel.onParamsCommitted = { [weak self] params in
            self?.commitColorAdjust(params: params)
        }
        panel.onEditEnded = { [weak self] params in
            self?.commitColorAdjust(params: params, endsDrag: true)
        }
        panel.onResetAll = { [weak self] in
            self?.lastColorParams = .identity
        }
        panel.onApply = { [weak self] in
            self?.endCoalescing()
            self?.refreshToolbarButtons()
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installLevelsPanel() {
        let panel = LevelsPanel()
        panel.setParams(effectiveLevels)
        panel.onParamsChanged = { [weak self] params in
            self?.writeCoalesced(.levels(params), kind: .levels, render: .draft)
        }
        panel.onParamsCommitted = { [weak self] params in
            self?.writeCoalesced(.levels(params), kind: .levels, render: .full)
        }
        panel.onEditEnded = { [weak self] params in
            // Drag end, a field commit, Reset: one undo step.
            self?.writeCoalesced(.levels(params), kind: .levels, render: .full, endsDrag: true)
        }
        panel.onAuto = { [weak self] kind in
            self?.applyLevelsAuto(kind)
        }
        parameterPanel.install(panel)
        installedTool = panel
        if let recipe {
            Task { [weak self] in
                let ops = await recipe.snapshot()
                guard let self, self.recipe === recipe else { return }
                self.refreshLevelsHistogram(ops: ops)
            }
        }
    }

    // MARK: - Levels

    /// The Levels values the recipe draws now.
    private(set) var effectiveLevels = LevelsParams.identity

    /// Histogram of the image as it enters Levels, keyed by the ops that
    /// make that image (a Levels change never changes it).
    private var levelsHistogramCache: (key: [EditOperation], data: HistogramData)?
    private var levelsHistogramTask: Task<Void, Never>?
    /// Status text the next write shows on the Levels panel.
    private var pendingLevelsStatus: String?

    /// Undo names by op index ("Auto Contrast"), for Edit ▸ Undo's title.
    /// Every append sets its index, so a stale name never shows.
    private var undoNames: [Int: String] = [:]
    /// Mirrors of the recipe's op / redo counts (set after every write).
    private(set) var operationCount = 0
    private(set) var undoneCount = 0

    /// Edit ▸ Undo title in edit mode: "Undo Auto Contrast" or "Undo".
    var undoMenuTitle: String {
        guard operationCount > 0, let name = undoNames[operationCount - 1] else { return "Undo" }
        return "Undo \(name)"
    }

    /// Edit ▸ Redo title in edit mode: "Redo Auto Color" or "Redo".
    var redoMenuTitle: String {
        guard undoneCount > 0, let name = undoNames[operationCount] else { return "Redo" }
        return "Redo \(name)"
    }

    private func nameLastStep(_ recipe: EditRecipe, _ name: String?) async {
        let index = await recipe.operations.count - 1
        guard index >= 0 else { return }
        undoNames[index] = name
    }

    /// Auto Contrast / Auto Color: switch to Levels (as the rail
    /// does), read the histogram of the image as it enters Levels, and
    /// replace the recipe's Levels values with the result as one undo
    /// step — or, when the result is what the recipe already draws,
    /// write nothing and say why on the status line.
    public func applyLevelsAuto(_ kind: LevelsAutoKind) {
        guard isActive, recipe != nil else { return }
        if currentTool != .levels { selectTool(.levels) }
        endCoalescing()
        if kind == .contrast { (installedTool as? LevelsPanel)?.setChannel(.rgb) }
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            guard let self else { return }
            let ops = await recipe.snapshot()
            let histogram = await self.levelsInputHistogram(ops: ops)
            guard self.recipe === recipe else { return }
            let result = kind == .contrast
                ? LevelsParams.autoContrast(from: histogram, clip: 0.001)
                : LevelsParams.autoColor(from: histogram, clip: 0.001)
            let current = EditRecipe.effectiveLevels(ops)
            if result == current {
                self.pendingLevelsStatus = result.isIdentity
                    ? LevelsStatus.alreadyFullRange : LevelsStatus.alreadyApplied
                return
            }
            self.lastWrittenDrag = nil
            await recipe.append(.levels(result))
            await self.nameLastStep(recipe, kind.title)
            self.pendingLevelsStatus = LevelsStatus.applied(kind)
        }
    }

    /// The input histogram for `ops` (cached; waits for it when needed).
    private func levelsInputHistogram(ops: [EditOperation]) async -> HistogramData {
        let key = EditRecipe.levelsInputOperations(ops)
        if let cache = levelsHistogramCache, cache.key == key { return cache.data }
        guard let original = originalImage else { return .empty }
        let data = await Self.computeLevelsInputHistogram(renderer: renderer, ops: key, original: original)
        if originalImage === original { levelsHistogramCache = (key, data) }
        return data
    }

    nonisolated private static func computeLevelsInputHistogram(
        renderer: EditRenderer, ops: [EditOperation], original: CGImage
    ) async -> HistogramData {
        let input = await renderer.renderLevelsInput(recipe: EditRecipe(operations: ops), from: original)
        return await Histogram.compute(from: input)
    }

    /// Feeds the Levels panel's histogram (the image as it enters Levels).
    private func refreshLevelsHistogram(ops: [EditOperation]) {
        guard let panel = installedTool as? LevelsPanel else { return }
        let key = EditRecipe.levelsInputOperations(ops)
        if let cache = levelsHistogramCache, cache.key == key {
            panel.setHistogram(cache.data)
            return
        }
        levelsHistogramTask?.cancel()
        levelsHistogramTask = Task { [weak self] in
            guard let self else { return }
            let data = await self.levelsInputHistogram(ops: ops)
            guard !Task.isCancelled, let panel = self.installedTool as? LevelsPanel else { return }
            panel.setHistogram(data)
        }
    }

    /// Test seam: waits for the Levels histogram in flight.
    func settleLevelsHistogramForTesting() async {
        await levelsHistogramTask?.value
    }

    // MARK: - Tool actions

    private func applyCurrentCrop() {
        guard recipe != nil, let crop = pendingCropRect() else { return }
        appendGeometry(.crop(crop))
    }

    private func previewFreeRotate(degrees: Double) {
        writeCoalesced(.rotate(degrees: degrees), kind: .freeRotate, render: .draft)
    }

    private func commitFreeRotate(degrees: Double) {
        writeCoalesced(.rotate(degrees: degrees), kind: .freeRotate, render: .full)
    }

    private func undoLastFreeRotate() {
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            let ops = await recipe.snapshot()
            if case .rotate = ops.last {
                self?.lastWrittenDrag = nil
                _ = await recipe.undo()
            }
        }
    }

    private func applyResize(spec: ResizeSpec) {
        appendGeometry(.resize(spec))
    }

    private func previewColorAdjust(params: ColorAdjustParams) {
        lastColorParams = params
        writeCoalesced(.colorAdjust(params), kind: .color, render: .draft)
    }

    private func commitColorAdjust(params: ColorAdjustParams, endsDrag: Bool = false) {
        lastColorParams = params
        writeCoalesced(.colorAdjust(params), kind: .color, render: .full, endsDrag: endsDrag)
    }

    // MARK: - Render dispatch

    /// Test seam: stands in for the renderer (a slow render, for the
    /// discard-while-rendering race). Nil in the app.
    var renderOverrideForTesting: ((EditRecipe, CGImage, RenderQualityHint) async -> CGImage?)?

    private func render(_ recipe: EditRecipe, _ original: CGImage,
                        _ hint: RenderQualityHint) async -> CGImage? {
        if let override = renderOverrideForTesting { return await override(recipe, original, hint) }
        return await renderer.render(recipe: recipe, from: original, qualityHint: hint)
    }

    /// True while the session that started a render is still the one on
    /// screen. A render finishing after a discard (or after the session
    /// was left and a new one entered) must not paint over the viewer.
    private func isSameSession(_ recipe: EditRecipe, _ original: CGImage) -> Bool {
        isActive && self.recipe === recipe && originalImage === original
    }

    private func renderDraft() async {
        guard let recipe, let original = originalImage else { return }
        if let result = await render(recipe, original, .draft),
           isSameSession(recipe, original) {
            onPresentImage?(result)
        }
    }

    private func renderFull() async {
        guard let recipe, let original = originalImage else { return }
        if let result = await render(recipe, original, .full),
           isSameSession(recipe, original) {
            let size = CGSize(width: result.width, height: result.height)
            let changed = size != currentPixelSize
            currentPixelSize = size
            onPresentImage?(result)
            if changed {
                // A new shape (crop, 90° rotate, resize): the frame starts
                // on the whole image, and W × H follow (rotate swaps them).
                cropOverlay.imagePixelSize = size
                cropOverlay.resetToFull()
                (installedTool as? CropPanel)?.setDimensions(width: result.width, height: result.height)
                (installedTool as? ResizePanel)?.sourcePixelSize = size
            }
        }
    }

    // MARK: - Toolbar / status sync

    private func refreshStatusCountsAsync() async {
        guard let recipe else {
            updatePendingEditsMirror(false)
            return
        }
        let ops = await recipe.operations.count
        let redos = await recipe.undoneOperations.count
        operationCount = ops
        undoneCount = redos
        publishChrome {
            $0.canUndo = ops > 0
            $0.canRedo = redos > 0
            $0.hasEdits = ops > 0
        }
        updatePendingEditsMirror(ops > 0 || redos > 0)
    }

    private func refreshToolbarButtons() {
        guard recipe != nil else { return }
        Task { [weak self] in
            await self?.refreshStatusCountsAsync()
        }
    }
}

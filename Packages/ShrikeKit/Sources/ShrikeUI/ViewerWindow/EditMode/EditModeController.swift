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
//    2. `selectTool(_:)` switches the right-side panel, wiring its
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

    var resources: ImageResourceBudget = .shared
    var resourceOwner = ImageResourceOwner()
    var loadedOriginalLease: ImageResourceLease?
    private var originalLease: ImageResourceLease?
    private var renderedLease: ImageResourceLease?
    private let renderer = EditRenderer()
    private var capabilityTask: Task<Void, Never>?
    private var capabilityGeneration: UInt64 = 0
    private var pendingEditRevision: UInt64 = 0
    /// Nil in production; holds a real header capability response for ownership regressions.
    var capabilityResolverForTesting: ((URL, [EditOperation]) async -> EditSaveCapability)?
    var isSaving: Bool { chromeState.isSaving }
    var isTransitioning: Bool { chromeState.isTransitioning }
    private(set) var isAwaitingDepartureSave = false
    /// The viewer owns the photo-departure gate; tools share that boundary.
    var canStartToolTransition: () -> Bool = { true }
    private var toolTransitionTask: Task<Void, Never>?
    private var exitPreparationTask: Task<Void, Never>?
    /// The completion belongs to the originating request, never the next session's handler.
    private final class ExitRequest {
        private var completion: ((EditExitOutcome) -> Void)?
        init(completion: @escaping (EditExitOutcome) -> Void) { self.completion = completion }
        func takeCompletion() -> ((EditExitOutcome) -> Void)? {
            defer { completion = nil }
            return completion
        }
    }
    private var exitRequest: ExitRequest?
    private var toolCheckpointTask: Task<SessionCheckpoint?, Never>?
    private var sessionCheckpointTask: Task<EditRecipe.Checkpoint, Never>?
    private var toolEntryVersion: UInt64 = 0
    private var mutationVersion: UInt64 = 0
    private var decisionGeneration: UInt64 = 0
    private var cancelDecision: (() -> Void)?
    private var decisionAlert: NSAlert?
    private var departureDraft: DepartureDraft?
    private var disabledForDecision: [(NSControl, Bool)] = []

    private struct SessionCheckpoint {
        let history: EditRecipe.Checkpoint
        let names: [Int: String]
        let size: CGSize
    }
    struct DepartureToken: Sendable {
        fileprivate let session: EditRecipe
        fileprivate let generation: UInt64
    }
    var departureToken: DepartureToken? {
        recipe.map { DepartureToken(session: $0, generation: decisionGeneration) }
    }
    private func owns(_ token: DepartureToken) -> Bool {
        isActive && recipe === token.session && decisionGeneration == token.generation
    }
    private struct DepartureDraft {
        let token: DepartureToken
        let checkpoint: SessionCheckpoint
        let crop: CropRect?
        let resize: ResizePanel.Draft?
        let fineRotation: (drag: Int, degrees: Double, finalized: Bool)?
    }

    private func setTransitioning(_ value: Bool) {
        guard isTransitioning != value else { return }
        if value {
            func disable(_ root: NSView) {
                if let control = root as? NSControl {
                    disabledForDecision.append((control, control.isEnabled))
                    control.isEnabled = false
                }
                root.subviews.forEach(disable)
            }
            disable(parameterPanel)
        } else {
            for (control, enabled) in disabledForDecision { control.isEnabled = enabled }
            disabledForDecision = []
        }
        cropOverlay.acceptsGeometryInput = !value && !isSaving
        publishChrome { $0.isTransitioning = value }
    }

    private func checkpoint(_ session: EditRecipe) async -> SessionCheckpoint {
        let history = await session.checkpoint()
        return SessionCheckpoint(history: history, names: undoNames, size: currentPixelSize)
    }

    private func beginToolInterval() {
        guard let session = recipe else { return }
        toolEntryVersion = mutationVersion
        let previous = mutationTail
        let size = currentPixelSize
        let capture = Task { @MainActor [weak self] () -> SessionCheckpoint? in
            await previous?.value
            guard let self, self.isActive, self.recipe === session else { return nil }
            let history = await session.checkpoint()
            guard self.isActive, self.recipe === session, !Task.isCancelled else { return nil }
            return SessionCheckpoint(history: history, names: self.undoNames, size: size)
        }
        toolCheckpointTask = capture
        // New panel writes must follow the snapshot, including immediate typing.
        mutationTail = Task { _ = await capture.value }
    }

    private func installSelectedTool(_ tool: EditTool) {
        currentTool = tool
        publishChrome { $0.tool = tool }
        installPanel(for: tool)
        cropOverlay.isHidden = tool != .crop
        beginToolInterval()
        refreshPendingToolEdits()
    }

    private func focusSelectedTool() {
        guard let window = hostWindow else { return }
        func firstControl(_ root: NSView) -> NSView? {
            if let control = root as? NSControl, control.isEnabled, !control.isHidden, control.acceptsFirstResponder { return control }
            return root.subviews.lazy.compactMap { firstControl($0) }.first
        }
        if let panel = installedTool, let control = firstControl(panel), control.window === window {
            window.makeFirstResponder(control)
        }
    }

    private func pendingResizeSpec(projected: Bool = false) -> ResizeSpec? {
        guard let panel = installedTool as? ResizePanel,
              let spec = projected ? panel.projectedSpec : panel.pendingSpec,
              let size = EditRenderer.outputPixelSize(from: currentPixelSize, operations: [.resize(spec)]),
              size != currentPixelSize else { return nil }
        return spec
    }

    private func hasStagedGeometry() -> Bool {
        (currentTool == .crop && pendingCropRect() != nil)
            || (currentTool == .resize && pendingResizeSpec() != nil)
    }

    /// Explicit Crop/Resize Apply already accepted its recipe operations. Tool
    /// Discard removes only geometry still staged against the current output;
    /// restoring a visit checkpoint would also undo Apply, Undo, Redo or Reset.
    private func discardPendingGeometry() {
        cropOverlay.imagePixelSize = currentPixelSize
        cropOverlay.resetToFull()
        (installedTool as? CropPanel)?.setDimensions(width: Int(currentPixelSize.width),
                                                    height: Int(currentPixelSize.height))
        (installedTool as? ResizePanel)?.acceptAppliedSize(currentPixelSize)
        refreshPendingToolEdits()
    }

    private func restore(_ checkpoint: SessionCheckpoint, session: EditRecipe) async {
        endCoalescing()
        lastWrittenDrag = nil
        renderRevision &+= 1
        await session.restore(checkpoint.history)
        guard isActive, recipe === session, !Task.isCancelled else { return }
        undoNames = checkpoint.names
        currentPixelSize = checkpoint.size
        cropOverlay.imagePixelSize = checkpoint.size
        cropOverlay.resetToFull()
        (installedTool as? ResizePanel)?.acceptAppliedSize(checkpoint.size)
        await afterWrite(recipe: session, render: .full, syncPanels: true, revision: renderRevision)
        guard isActive, recipe === session, !Task.isCancelled else { return }
        await settleMutations()
    }

    /// Cancelled photo departures restore the user's unconsumed geometry,
    /// not an extra recipe operation hidden behind an unchanged panel.
    func restoreCancelledDeparture(for token: DepartureToken) async {
        guard owns(token), let draft = departureDraft, owns(draft.token) else { return }
        setTransitioning(true)
        departureDraft = nil
        await restore(draft.checkpoint, session: token.session)
        guard owns(token), !Task.isCancelled else { return }
        if let crop = draft.crop {
            cropOverlay.setRectFromImageSpace(CGRect(x: crop.originX * currentPixelSize.width,
                y: crop.originY * currentPixelSize.height, width: crop.width * currentPixelSize.width,
                height: crop.height * currentPixelSize.height))
        }
        if let resize = draft.resize { (installedTool as? ResizePanel)?.restoreDraft(resize) }
        fineRotation = draft.fineRotation
        lastWrittenDrag = draft.fineRotation?.drag
        isAwaitingDepartureSave = false
        setTransitioning(false)
    }

    func acceptsDepartureSave(_ token: DepartureToken?) -> Bool {
        if let token { return owns(token) && isAwaitingDepartureSave }
        return !isTransitioning && !isAwaitingDepartureSave
    }

    /// Called synchronously immediately before the window claims Saving.
    /// No event/actor hop can edit the recipe between these two states.
    func handOffDepartureToSave(_ token: DepartureToken?) -> Bool {
        guard acceptsDepartureSave(token) else { return false }
        isAwaitingDepartureSave = false
        setTransitioning(false)
        return true
    }

    /// Transfer the save lock back to the same unresolved departure BEFORE
    /// publishing Saving(false). A stale exporter cannot unlock a new session.
    func finishSaving(for session: EditRecipe, departure token: DepartureToken?) {
        guard recipe === session, isActive else { return }
        if let token {
            guard owns(token) else { return }
            if let draft = departureDraft, owns(draft.token) { setTransitioning(true) }
        }
        setSaving(false)
    }
    private var disabledForSave: [(NSControl, Bool)] = []
    func setSaving(_ saving: Bool) {
        guard chromeState.isSaving != saving else { return }
        if saving {
            func disable(_ root: NSView) {
                if let control = root as? NSControl { disabledForSave.append((control, control.isEnabled)); control.isEnabled = false }
                root.subviews.forEach(disable)
            }
            disable(parameterPanel)
        } else {
            if isTransitioning {
                // Controls stay disabled. Preserve the pre-save enabled states
                // for the decision lock to restore after rollback finishes.
                disabledForDecision = disabledForSave
            } else {
                for (control, enabled) in disabledForSave { control.isEnabled = enabled }
            }
            disabledForSave = []
        }
        cropOverlay.acceptsGeometryInput = !saving && !isTransitioning
        publishChrome { $0.isSaving = saving }
    }
    /// Caption-only projection. It does not consume draft edits, focus, history or pixels.
    private func refreshPendingToolEdits() {
        guard isActive, let session = recipe else { return }
        let pending: EditOperation?
        if currentTool == .crop {
            if let draft = (installedTool as? CropPanel)?.dimensionDraft,
               let rect = cropRectForDimensions(width: draft.width, height: draft.height, side: draft.side) {
                pending = meaningfulCrop(CropRect(originX: rect.minX / currentPixelSize.width,
                    originY: rect.minY / currentPixelSize.height, width: rect.width / currentPixelSize.width,
                    height: rect.height / currentPixelSize.height)).map(EditOperation.crop)
            } else { pending = pendingCropRect().map(EditOperation.crop) }
        } else if currentTool == .resize {
            pending = pendingResizeSpec(projected: true).map(EditOperation.resize)
        } else if currentTool == .levels {
            pending = (installedTool as? LevelsPanel)?.projectedParams.map(EditOperation.levels)
        } else { pending = nil }
        pendingEditRevision &+= 1
        let revision = pendingEditRevision, panel = panelGeneration, source = sourceURL
        capabilityGeneration &+= 1
        capabilityTask?.cancel()
        publishChrome { $0.hasPendingToolEdits = pending != nil }
        // Chrome layout may synchronously replace/reset a panel or its geometry.
        guard isActive, recipe === session, pendingEditRevision == revision,
              panelGeneration == panel, sourceURL == source else { return }
        let writes = mutationTail
        capabilityTask = Task { @MainActor [weak self] in
            await writes?.value
            guard !Task.isCancelled else { return }
            let operations = await session.snapshot()
            guard let self, !Task.isCancelled, self.isActive, self.recipe === session,
                  self.sourceURL == source, self.panelGeneration == panel,
                  self.pendingEditRevision == revision else { return }
            await self.updateSaveCapability(operations: operations + (pending.map { [$0] } ?? []),
                                            session: session, projectionRevision: revision)
        }
    }

    private func updateSaveCapability(operations: [EditOperation], session: EditRecipe,
                                      projectionRevision: UInt64? = nil) async {
        guard isActive, recipe === session, let sourceURL,
              projectionRevision == nil || projectionRevision == pendingEditRevision else { return }
        capabilityGeneration &+= 1
        let generation = capabilityGeneration
        let capability: EditSaveCapability
        let target: SaveTargetDecision
        if let resolver = capabilityResolverForTesting {
            capability = await resolver(sourceURL, operations)
            target = SaveTarget.evaluate(sourceURL)
        } else {
            (capability, target) = await Task.detached(priority: .utility) {
                (ImageExporter.capability(for: sourceURL, operations: operations), SaveTarget.evaluate(sourceURL))
            }.value
        }
        guard !Task.isCancelled, isActive, recipe === session, self.sourceURL == sourceURL,
              generation == capabilityGeneration,
              projectionRevision == nil || projectionRevision == pendingEditRevision else { return }
        publishChrome {
            let sourceRequiresCopy: Bool
            if case .inPlace = target { sourceRequiresCopy = false } else { sourceRequiresCopy = true }
            $0.requiresCopy = capability.requiresCopy || sourceRequiresCopy
            $0.savePolicy = target.reason?.message(for: sourceURL) ?? capability.conversionDisclosure ?? (sourceURL.pathExtension.lowercased() == "jpg" || sourceURL.pathExtension.lowercased() == "jpeg"
                ? "JPEG edits are re-encoded at your save quality. The original backup is kept."
                : "Changes will replace this file. An original backup is kept.")
        }
    }

    /// Last known pixel size of the source — used by panels + overlay.
    private var sourcePixelSize: CGSize = .zero

    /// Last tool-panel snapshot so re-entering a tool mid-session
    /// (switching back to Crop from Rotate) can seed it with the prior
    /// state. For now we just re-construct fresh panels; this property
    /// is a seam for later.
    private var lastColorParams = ColorAdjustParams.identity

    /// Whether the edit bar is the full-screen capsule (the empty panel says "bottom").
    var chooseToolInFullScreen: () -> Bool = { false }

    /// Synchronous mirror of "recipe has any ops or undo history" — used
    /// by the (non-edit-mode) Reset button in the edit bar
    /// so the button can disable without an actor hop. Kept in
    /// sync by `refreshPendingEditsMirror()` after any recipe mutation.
    /// Outside an active session this is always false.
    public private(set) var hasPendingEdits: Bool = false

    /// Fires when `hasPendingEdits` flips so the bar can refresh the
    /// Reset button's enabled state without polling.
    var onPendingEditsChanged: ((Bool) -> Void)?

    /// The currently-installed tool panel, typed loosely so `selectTool`
    /// can switch freely.
    private var installedTool: NSView?
    private var panelGeneration: UInt64 = 0

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
        guard !isSaving, !isTransitioning else { return }
        switch action {
        case .cancel: attemptExit(reason: .userToggled)
        case .selectTool(let tool): selectTool(tool)
        case .undo: performUndo()
        case .redo: performRedo()
        case .reset: revertPendingEdits()
        case .done: done()
        case .saveCopy: onSaveAsRequested?()
        }
    }

    /// Done (button or Return): apply the current tool the
    /// way its own Apply would, then save by the ⌘S rules (in place, or a
    /// copy for RAW) — or just leave when nothing changed.
    public func done() {
        guard isActive, !isSaving, !isTransitioning, let recipe else { return }
        Task { [weak self] in
            guard let self, self.recipe === recipe,
                  await self.prepareForSave(), self.recipe === recipe else { return }
            let initial = await self.sessionCheckpointTask?.value
            let changed = if let initial { await recipe.hasContentChanges(since: initial) }
                else { !EditRecipe.effectiveOperations(await recipe.snapshot()).isEmpty }
            guard self.isActive, self.recipe === recipe, !self.isSaving, !self.isTransitioning else { return }
            if !changed {
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
    func pendingCropRect() -> CropRect? { meaningfulCrop(overlayCropRect()) }

    private func meaningfulCrop(_ candidate: CropRect?) -> CropRect? {
        guard let crop = candidate else { return nil }
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
        cropOverlay.onRectChanged = { [weak self] rect in
            guard rect.width > 0, rect.height > 0 else { return }
            (self?.installedTool as? CropPanel)?.setDimensions(width: Int(rect.width.rounded()), height: Int(rect.height.rounded()))
            self?.refreshPendingToolEdits()
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
        originalLease = loadedOriginalLease ?? resources.retain(image: image, owner: resourceOwner, category: .editOriginal)
        loadedOriginalLease = nil
        sourceURL = url
        sourcePixelSize = CGSize(width: image.width, height: image.height)
        currentPixelSize = sourcePixelSize
        cropOverlay.imagePixelSize = sourcePixelSize
        effectiveColor = .identity
        effectiveLevels = .identity
        levelsHistogramCache = nil
        undoNames = [:]
        operationCount = 0
        undoneCount = 0
        pendingLevelsStatus = nil
        lastWrittenDrag = nil
        coalescing = nil
        let newRecipe = EditRecipe()
        recipe = newRecipe
        let initial = Task { await newRecipe.checkpoint() }
        sessionCheckpointTask = initial
        mutationTail = Task { _ = await initial.value }
        currentTool = nil
        publishChrome { $0 = EditChromeState(tool: tool) }
        refreshToolbarButtons()
        if let tool {
            selectTool(tool)
        } else {
            parameterPanel.install(ChooseToolPanel(inFullScreen: chooseToolInFullScreen(), onSelect: { [weak self] in self?.selectTool($0) }))
            installedTool = nil
            cropOverlay.isHidden = true
            Culling.announce(Self.noToolAnnouncement)
        }
        refreshPendingToolEdits()
    }

    /// VoiceOver on a no-tool entry.
    static let noToolAnnouncement = "Editing. Choose a tool."

    /// Switch tool within an active session.
    public func selectTool(_ tool: EditTool) {
        selectTool(tool, completion: nil)
    }

    private func selectTool(_ tool: EditTool, completion: ((Bool) -> Void)?) {
        guard isActive, !isSaving, !isTransitioning, canStartToolTransition(), exitPreparationTask == nil, currentTool != tool else {
            onChromeStateChanged?(chromeState)
            completion?(currentTool == tool && !isTransitioning)
            return
        }
        weak let focus = (hostWindow?.firstResponder as? NSTextView)?.delegate as? NSView
        guard commitFocusedField() else {
            onChromeStateChanged?(chromeState)
            completion?(false)
            return
        }
        let outgoingFineRotation = fineRotation
        endCoalescing()
        guard let outgoing = currentTool, let session = recipe else {
            installSelectedTool(tool)
            completion?(true)
            return
        }
        // No actor work or staged draft has changed: keep the familiar
        // synchronous clean-tool selection path.
        if mutationVersion == toolEntryVersion, !hasStagedGeometry() {
            installSelectedTool(tool)
            completion?(true)
            return
        }
        decisionGeneration &+= 1
        let generation = decisionGeneration
        setTransitioning(true)
        // The picker is optimistic; render the actual outgoing selection now.
        onChromeStateChanged?(chromeState)
        toolTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.decisionGeneration == generation {
                    self.toolTransitionTask = nil
                    self.setTransitioning(false)
                    self.onChromeStateChanged?(self.chromeState)
                }
            }
            guard let baseline = await self.toolCheckpointTask?.value else { return }
            await self.settleMutations()
            guard self.validDecision(session, generation: generation), self.currentTool == outgoing else { return }
            // Crop/Resize have explicit Apply: their current recipe is accepted
            // even when it differs from tool entry. Other live-preview tools
            // still decide about the entire current visit.
            let explicitGeometry = outgoing == .crop || outgoing == .resize
            let changed = if explicitGeometry { false } else { await session.hasContentChanges(since: baseline.history) }
            guard self.validDecision(session, generation: generation) else { return }
            if changed || self.hasStagedGeometry() {
                let choice = await self.askToolDecision(outgoing: outgoing, destination: tool)
                guard self.validDecision(session, generation: generation) else { return }
                switch choice {
                case .cancel:
                    self.fineRotation = outgoingFineRotation
                    self.setTransitioning(false)
                    if let focus { self.hostWindow?.makeFirstResponder(focus) }
                    completion?(false)
                    return
                case .discard:
                    if explicitGeometry { self.discardPendingGeometry() }
                    else { await self.restore(baseline, session: session) }
                case .keep:
                    self.resolvePendingGeometry()
                    await self.settleMutations()
                }
            }
            guard self.validDecision(session, generation: generation) else { return }
            self.installSelectedTool(tool)
            self.setTransitioning(false)
            self.focusSelectedTool()
            completion?(true)
        }
    }

    private func validDecision(_ session: EditRecipe, generation: UInt64) -> Bool {
        isActive && recipe === session && decisionGeneration == generation && !Task.isCancelled
    }

    private func askToolDecision(outgoing: EditTool, destination: EditTool) async -> EditToolTransitionModal.Choice {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer: @MainActor (EditToolTransitionModal.Choice) -> Void = { [weak self] choice in
                guard !answered else { return }
                answered = true
                self?.cancelDecision = nil
                self?.decisionAlert = nil
                continuation.resume(returning: choice)
            }
            cancelDecision = { answer(.cancel) }
            let alert = EditToolTransitionModal.show(on: hostWindow ?? parameterPanel.window,
                content: .init(outgoing: outgoing, destination: destination), completion: answer)
            if !answered { decisionAlert = alert }
        }
    }

    /// The user asked to leave edit mode through the viewer's default handler.
    public func attemptExit(reason: EditExitReason) {
        guard !isSaving, !isTransitioning, exitPreparationTask == nil else { return }
        attemptExit(reason: reason, completion: onExitOutcome ?? { _ in })
    }

    /// Explicit callers own their completion; they never replace a later session's handler.
    func attemptExit(reason: EditExitReason, completion: @escaping (EditExitOutcome) -> Void) {
        guard !isSaving, !isTransitioning, exitPreparationTask == nil else {
            completion(.cancelled); return
        }
        guard isActive, let session = recipe else { completion(.exited); return }
        guard commitFocusedField() else { completion(.cancelled); return }
        let request = ExitRequest(completion: completion)
        exitRequest = request
        decisionGeneration &+= 1
        let generation = decisionGeneration
        let token = DepartureToken(session: session, generation: generation)
        let departingFineRotation = fineRotation
        endCoalescing()
        setTransitioning(true)
        exitPreparationTask = Task { @MainActor [weak self] in
            guard let self else { request.takeCompletion()?(.cancelled); return }
            defer {
                if self.decisionGeneration == generation {
                    self.exitPreparationTask = nil
                    if !self.isAwaitingDepartureSave { self.setTransitioning(false) }
                }
                self.finishExitRequest(request, outcome: .cancelled)
            }
            await self.settlePendingChanges()
            guard self.validDecision(session, generation: generation) else { return }
            let checkpoint = await self.checkpoint(session)
            guard self.validDecision(session, generation: generation) else { return }
            self.departureDraft = DepartureDraft(token: token, checkpoint: checkpoint,
                crop: self.currentTool == .crop ? self.pendingCropRect() : nil,
                resize: (self.installedTool as? ResizePanel)?.draft,
                fineRotation: departingFineRotation)
            guard await self.prepareForSave(allowDecision: true), self.validDecision(session, generation: generation) else { return }
            let initial = await self.sessionCheckpointTask?.value
            let changed = if let initial { await session.hasContentChanges(since: initial) }
                else { !EditRecipe.effectiveOperations(await session.snapshot()).isEmpty }
            guard self.validDecision(session, generation: generation) else { return }
            if !changed {
                let completion = self.takeExitCompletion(request)
                self.finalizeExit(); completion?(.exited); return
            }
            await self.updateSaveCapability(operations: await session.snapshot(), session: session)
            guard self.validDecision(session, generation: generation) else { return }
            guard let window = self.hostWindow ?? self.parameterPanel.window else {
                await self.restoreCancelledDeparture(for: token)
                self.finishExitRequest(request, outcome: .cancelled)
                return
            }
            let content = EditExitModal.content(fileName: self.sourceURL?.lastPathComponent ?? "Untitled",
                writable: !self.chromeState.requiresCopy, reason: reason, savePolicy: self.chromeState.savePolicy)
            let choice = await self.askExitDecision(on: window, content: content)
            guard self.validDecision(session, generation: generation) else { return }
            switch choice {
            case .save:
                self.isAwaitingDepartureSave = true
                self.finishExitRequest(request, outcome: .needsSave)
            case .saveAs:
                self.isAwaitingDepartureSave = true
                self.finishExitRequest(request, outcome: .needsSaveAs)
            case .discard:
                let completion = self.takeExitCompletion(request)
                self.finalizeExit(); completion?(.exited)
            case .cancel:
                await self.restoreCancelledDeparture(for: token)
                self.finishExitRequest(request, outcome: .cancelled)
            }
        }
    }

    private func takeExitCompletion(_ request: ExitRequest) -> ((EditExitOutcome) -> Void)? {
        if exitRequest === request { exitRequest = nil }
        return request.takeCompletion()
    }

    private func finishExitRequest(_ request: ExitRequest, outcome: EditExitOutcome) {
        takeExitCompletion(request)?(outcome)
    }

    private func askExitDecision(on window: NSWindow, content: EditExitModal.Content) async -> EditExitModal.Choice {
        await withCheckedContinuation { continuation in
            var answered = false
            let answer: @MainActor (EditExitModal.Choice) -> Void = { [weak self] choice in
                guard !answered else { return }
                answered = true
                self?.cancelDecision = nil; self?.decisionAlert = nil
                continuation.resume(returning: choice)
            }
            cancelDecision = { answer(.cancel) }
            let alert = EditExitModal.show(on: window, content: content, completion: answer)
            if !answered { decisionAlert = alert }
        }
    }

    /// Called after save completes (or on discard) — tears down the
    /// session state. Safe to call when not active.
    public func finalizeExit(keepDisplay: Bool = false, notify: Bool = true) {
        guard isActive else { return }
        let cancelledCompletion = exitRequest.flatMap { takeExitCompletion($0) }
        isActive = false
        decisionGeneration &+= 1
        toolTransitionTask?.cancel(); toolTransitionTask = nil
        exitPreparationTask?.cancel(); exitPreparationTask = nil
        toolCheckpointTask?.cancel(); toolCheckpointTask = nil
        sessionCheckpointTask?.cancel(); sessionCheckpointTask = nil
        if let alert = decisionAlert, let parent = alert.window.sheetParent { parent.endSheet(alert.window, returnCode: .abort) }
        cancelDecision?(); cancelDecision = nil; decisionAlert = nil
        departureDraft = nil
        isAwaitingDepartureSave = false
        disabledForDecision = []
        disabledForSave = []
        endCoalescing()
        capabilityTask?.cancel()
        capabilityTask = nil
        mutationTail?.cancel()
        mutationTail = nil
        renderTail?.cancel()
        renderTail = nil
        recipe = nil
        originalImage = nil
        originalLease = nil; renderedLease = nil; loadedOriginalLease = nil
        levelsHistogramCache = nil
        levelsHistogramTask?.cancel()
        levelsHistogramTask = nil
        undoNames = [:]
        operationCount = 0
        undoneCount = 0
        sourceURL = nil
        sourcePixelSize = .zero
        fineRotationSegment = nil
        fineRotationSegments.removeAll(keepingCapacity: false)
        parameterPanel.install(nil)
        installedTool = nil
        currentTool = nil
        panelGeneration &+= 1
        cropOverlay.isHidden = true
        publishChrome { $0 = EditChromeState() }
        updatePendingEditsMirror(false)
        if notify { onExitedEditMode?(!keepDisplay) }
        cancelledCompletion?(.cancelled)
    }

    /// A closed window must release session buffers without restoring its
    /// pre-edit photo or changing chrome on a window that is gone.
    func releaseAfterClose() {
        finalizeExit(notify: false)
        onExitOutcome = nil
        onPresentImage = nil
        onSaveRequested = nil
        onSaveAsRequested = nil
    }

    private func cancelDeferredPanelWork() {
        (installedTool as? ColorAdjustPanel)?.cancelPendingCommit()
        (installedTool as? RotatePanel)?.cancelPendingCommit()
    }

    private func commitFocusedField() -> Bool {
        guard let window = hostWindow ?? parameterPanel.window else { return true }
        let editor = window.firstResponder as? NSTextView
        let field = editor?.delegate as? NSTextField
        let session = recipe, tool = currentTool, panel = installedTool, generation = panelGeneration
        func stillOwned() -> Bool {
            recipe === session && currentTool == tool && installedTool === panel && panelGeneration == generation
        }
        if let numeric = field as? PanelTextField, numeric.commitsOnFocusLoss {
            guard numeric.completeEditing(in: window).mayContinue else { return false }
        } else {
            let originalCell = field?.cell, originalDelegate = field?.delegate
            let originalTarget = field?.target, originalAction = field?.action
            guard window.makeFirstResponder(nil), stillOwned() else { return false }
            // Opt-out panels (including Levels) retain their existing explicit
            // flush. Native end-edit consumers already dispatched during resignation.
            if let field {
                guard field.window === window, field.cell === originalCell,
                      field.delegate === originalDelegate, field.target === originalTarget,
                      field.action == originalAction else { return false }
                if field.cell?.sendsActionOnEndEditing != true, let action = originalAction {
                    _ = field.sendAction(action, to: originalTarget)
                }
            }
        }
        return stillOwned()
    }

    private func resolvePendingGeometry() {
        if currentTool == .crop, let crop = pendingCropRect() {
            appendGeometry(.crop(crop))
        } else if currentTool == .resize, let spec = pendingResizeSpec() {
            appendGeometry(.resize(spec))
        }
    }

    /// Shared by Done, direct Save, Save As, and dirty-exit checks.
    /// Geometry is consumed synchronously before awaiting the serial writes.
    @discardableResult
    func prepareForSave(allowDecision: Bool = false) async -> Bool {
        guard !isTransitioning || allowDecision else { return false }
        guard isActive, let session = recipe else { return false }
        guard commitFocusedField() else { return false }
        endCoalescing()
        resolvePendingGeometry()
        await settlePendingChanges()
        return isActive && recipe === session && !Task.isCancelled
    }

    /// Public helper used by the window on a forced undo/redo dispatch
    /// (menu item, ⌘Z while panel doesn't have focus).
    public func performUndo() {
        guard !isSaving, !isTransitioning else { return }
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            _ = await recipe.undo()
        }
    }

    public func performRedo() {
        guard !isSaving, !isTransitioning else { return }
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            _ = await recipe.redo()
        }
    }

    /// Revert every pending edit — wipes the whole recipe, clears the
    /// redo stack, and re-renders. Shown on the
    /// edit bar as the Reset button. Safe no-op when the
    /// recipe is absent or already empty.
    public func revertPendingEdits() {
        guard !isSaving, !isTransitioning else { return }
        guard recipe != nil else {
            updatePendingEditsMirror(false)
            return
        }
        guard commitFocusedField() else { return }
        // Reset intentionally discards the pending typed target as well
        // as recipe operations. Later typing still survives its render.
        (installedTool as? ResizePanel)?.acceptAppliedSize(currentPixelSize)
        cropOverlay.resetToFull()
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
        guard !isSaving, !isTransitioning else { return }
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
        guard !isTransitioning, quarters % 4 != 0 else { return }
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
    /// The panel's delayed full render belongs to its preview even after the
    /// generic coalescer has expired. Tool/Undo/geometry boundaries clear it.
    private var fineRotation: (drag: Int, degrees: Double, finalized: Bool)?
    /// Parameter ownership outlives idle/Undo grouping, but never a kept visit.
    private var fineRotationSegment: EditRecipe.GeometryOwner?
    private var fineRotationSegments: Set<EditRecipe.GeometryOwner> = []
    private var coalesceIdleTask: Task<Void, Never>?
    /// A drag ends 500 ms after its last frame.
    static let coalesceIdle: TimeInterval = 0.5
    /// Read-only task ownership for deterministic idle-order regression tests.
    var coalesceIdleForTesting: Task<Void, Never>? { coalesceIdleTask }

    /// Recipe writes run one after another, in call order.
    private var mutationTail: Task<Void, Never>?
    /// The newest render (renders overlap so the renderer can drop
    /// stale ones).
    private var renderTail: Task<Void, Never>?
    private var renderRevision: UInt64 = 0

    /// Logical image size, including geometry whose render is still pending.
    private(set) var currentPixelSize: CGSize = .zero
    /// The Color panel's values as the recipe draws them.
    private(set) var effectiveColor = ColorAdjustParams.identity

    /// Ends the running drag: the next slider frame starts a new undo
    /// step. Tool switch, Apply, undo, redo and Reset call it.
    func endCoalescing() {
        cancelDeferredPanelWork()
        fineRotation = nil
        coalescing = nil
        coalesceIdleTask?.cancel()
        coalesceIdleTask = nil
    }

    private func enqueue(render: RenderPass?, syncPanels: Bool = false,
                         _ body: @escaping @MainActor (EditRecipe) async -> Void) {
        guard let recipe else { return }
        mutationVersion &+= 1
        renderRevision &+= 1
        let revision = renderRevision
        let previous = mutationTail
        mutationTail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.recipe === recipe else { return }
            await body(recipe)
            await self.afterWrite(recipe: recipe, render: render, syncPanels: syncPanels, revision: revision)
        }
    }

    private func afterWrite(recipe: EditRecipe, render: RenderPass?, syncPanels: Bool, revision: UInt64) async {
        let ops = await recipe.snapshot()
        guard isActive, self.recipe === recipe, !Task.isCancelled else { return }
        if revision == renderRevision,
           let size = EditRenderer.outputPixelSize(from: sourcePixelSize, operations: ops) {
            if size != currentPixelSize {
                currentPixelSize = size
                cropOverlay.imagePixelSize = size
                cropOverlay.resetToFull()
                (installedTool as? CropPanel)?.setDimensions(width: Int(size.width), height: Int(size.height))
                (installedTool as? ResizePanel)?.sourcePixelSize = size
            }
        }
        refreshPendingToolEdits()
        effectiveColor = EditRecipe.effectiveColorAdjust(ops)
        effectiveLevels = EditRecipe.effectiveLevels(ops)
        let panelScope = panelGeneration
        let ownedRotation = syncPanels ? await recipe.ownedFreeRotation() : nil
        // The owner lookup can outlive this panel or the entire edit session.
        guard isActive, self.recipe === recipe, !Task.isCancelled, panelScope == panelGeneration else { return }
        if syncPanels, revision == renderRevision {
            syncPanelsFromRecipe(ops, ownedRotation: ownedRotation)
        }
        if let levels = installedTool as? LevelsPanel {
            if let status = pendingLevelsStatus {
                levels.showStatus(status)
            }
            refreshLevelsHistogram(ops: ops)
        }
        pendingLevelsStatus = nil
        if let render {
            renderTail = Task { @MainActor [weak self] in
                guard let self, self.renderRevision == revision else { return }
                if render == .draft { await self.renderDraft(revision: revision) } else { await self.renderFull(revision: revision) }
            }
        }
        await refreshStatusCountsAsync()
    }

    /// Crop / Rotate / Resize Apply: always a new undo step.
    private func appendGeometry(_ op: EditOperation) {
        guard !isSaving else { return }
        endCoalescing()
        fineRotationSegment = nil
        // Geometry controls refer to the recipe's logical output, even
        // while an expensive render still displays its preceding image.
        var size = currentPixelSize
        switch op {
        case .crop(let crop):
            let x = max(0, min((crop.originX * size.width).rounded(), size.width - 1))
            let y = max(0, min((crop.originY * size.height).rounded(), size.height - 1))
            size = CGSize(width: max(1, min((crop.width * size.width).rounded(), size.width - x)),
                          height: max(1, min((crop.height * size.height).rounded(), size.height - y)))
        case .resize(let spec):
            size = CGSize(width: spec.preventUpscale ? min(CGFloat(spec.width), size.width) : CGFloat(spec.width),
                          height: spec.preventUpscale ? min(CGFloat(spec.height), size.height) : CGFloat(spec.height))
        case .rotate90(let quarters):
            if quarters % 2 != 0 { size = CGSize(width: size.height, height: size.width) }
        default: break
        }
        currentPixelSize = size
        cropOverlay.imagePixelSize = size
        cropOverlay.resetToFull()
        (installedTool as? CropPanel)?.setDimensions(width: Int(size.width), height: Int(size.height))
        (installedTool as? ResizePanel)?.acceptAppliedSize(size)
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            self?.lastWrittenDrag = nil
            await recipe.append(op)
            await self?.nameLastStep(recipe, nil)
        }
    }

    /// A slider frame: the first frame of a drag appends, later frames of
    /// the same drag replace that op (never another op). A frame that
    /// changes nothing adds no undo step.
    @discardableResult
    private func writeCoalesced(_ op: EditOperation, kind: CoalesceKind,
                                render: RenderPass, endsDrag: Bool = false,
                                rotationVisit: UInt64? = nil) -> Int? {
        guard !isSaving, !isTransitioning else { return nil }
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
            guard self.isActive, self.recipe === recipe, !Task.isCancelled else { return }
            if let rotationVisit {
                let value: EditOperation? = Self.isNoChange(op, ops: ops) ? nil : op
                let previousDepth = await recipe.undoDepth
                guard let segment = await self.resolveFreeRotationSegment(
                    in: recipe, visit: rotationVisit, createIfMissing: value != nil
                ) else { return }
                let changed = await recipe.setOwnedFreeRotation(value, owner: segment.owner,
                                                                beginsUndoStep: self.lastWrittenDrag != drag)
                guard self.validFreeRotationVisit(recipe, visit: rotationVisit) else { return }
                if changed {
                    self.lastWrittenDrag = drag
                    let depth = await recipe.undoDepth
                    guard self.validFreeRotationVisit(recipe, visit: rotationVisit) else { return }
                    if depth >= previousDepth { await self.nameLastStep(recipe, nil) }
                }
                return
            }
            if self.lastWrittenDrag == drag, let last = ops.last, Self.kind(of: last) == kind {
                await recipe.replaceLast(op)
                return
            }
            if Self.isNoChange(op, ops: ops) { return }
            await recipe.append(op)
            await self.nameLastStep(recipe, nil)
            guard self.isActive, self.recipe === recipe, !Task.isCancelled else { return }
            self.lastWrittenDrag = drag
        }
        return drag
    }

    private static func kind(of op: EditOperation) -> CoalesceKind? {
        switch op {
        case .colorAdjust: return .color
        case .rotate, .rotateAutoCrop: return .freeRotate
        case .levels: return .levels
        default: return nil
        }
    }

    private static func isNoChange(_ op: EditOperation, ops: [EditOperation]) -> Bool {
        switch op {
        case .colorAdjust(let p): return p == EditRecipe.effectiveColorAdjust(ops)
        case .rotate(let degrees), .rotateAutoCrop(let degrees): return abs(degrees) < 0.0001
        case .levels(let p): return p == EditRecipe.effectiveLevels(ops)
        default: return false
        }
    }

    /// After undo / redo / Reset / Apply the panels show what the
    /// recipe draws.
    private func syncPanelsFromRecipe(_ ops: [EditOperation],
                                      ownedRotation: (owner: EditRecipe.GeometryOwner, operation: EditOperation?)?) {
        lastColorParams = EditRecipe.effectiveColorAdjust(ops)
        if let colour = installedTool as? ColorAdjustPanel {
            colour.setParams(lastColorParams)
        } else if let rot = installedTool as? RotatePanel {
            if let ownedRotation, fineRotationSegments.contains(ownedRotation.owner) {
                fineRotationSegment = ownedRotation.owner
                rot.setAngle(ownedRotation.operation?.freeRotation?.degrees ?? 0)
                rot.setAutoCrop(ownedRotation.operation?.freeRotation?.autoCrop ?? Prefs.editAutoCropOnFreeRotate)
            } else {
                fineRotationSegment = nil
                rot.setAngle(0)
                rot.setAutoCrop(Prefs.editAutoCropOnFreeRotate)
            }
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
        await toolTransitionTask?.value
        _ = await toolCheckpointTask?.value
        await settlePendingChanges()
        await capabilityTask?.value
    }

    /// Tool decisions depend on accepted recipe writes, not preview latency.
    private func settleMutations() async {
        while true {
            let tail = mutationTail
            await tail?.value
            if tail == mutationTail { return }
        }
    }

    func waitForToolTransitionForTesting() async { await toolTransitionTask?.value }

    private func settlePendingChanges() async {
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
        panelGeneration &+= 1
        switch tool {
        case .crop:   installCropPanel()
        case .rotate: installRotatePanel()
        case .resize: installResizePanel()
        case .color:  installColorPanel()
        case .levels: installLevelsPanel()
        }
    }

    private func cropRectForDimensions(width: Int?, height: Int?, side: CropPanel.Axis) -> CGRect? {
        guard let crop = overlayCropRect() else { return nil }
        let size = currentPixelSize
        var rect = CGRect(x: crop.originX * size.width, y: crop.originY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        guard let entered = side == .width ? width : height, entered > 0 else { return nil }
        if side == .width { rect.size.width = CGFloat(entered) }
        else { rect.size.height = CGFloat(entered) }
        if let ratio = cropOverlay.aspectRatio, ratio > 0 {
            if side == .width { rect.size.height = rect.width / ratio }
            else { rect.size.width = rect.height * ratio }
            let scale = min(1, (size.width - rect.minX) / rect.width, (size.height - rect.minY) / rect.height)
            rect.size.width *= scale; rect.size.height *= scale
        }
        rect.size.width = max(1, min(rect.width.rounded(), size.width - rect.minX))
        rect.size.height = max(1, min(rect.height.rounded(), size.height - rect.minY))
        return rect
    }

    private func installCropPanel() {
        let panel = CropPanel()
        let generation = panelGeneration
        panel.setDimensions(width: Int(currentPixelSize.width),
                            height: Int(currentPixelSize.height))
        panel.onDimensionsEdited = { [weak self, weak panel] width, height, side in
            guard let self, self.panelGeneration == generation, self.isActive,
                  !self.isSaving, !self.isTransitioning else { return }
            if let rect = self.cropRectForDimensions(width: width, height: height, side: side) {
                self.cropOverlay.setRectFromImageSpace(rect)
            } else if let crop = self.overlayCropRect() {
                panel?.setDimensions(width: Int((crop.width * self.currentPixelSize.width).rounded()),
                                     height: Int((crop.height * self.currentPixelSize.height).rounded()))
            }
        }
        panel.onDraftChanged = { [weak self] in
            guard self?.panelGeneration == generation else { return }
            self?.refreshPendingToolEdits()
        }
        panel.onApply = { [weak self] in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.applyCurrentCrop()
        }
        panel.onReset = { [weak self] in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.cropOverlay.resetToFull()
        }
        panel.onAspectChanged = { [weak self] aspect in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
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
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.cropOverlay.showThirds = flag
        }
        panel.onShowGoldenChanged = { [weak self] flag in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.cropOverlay.showGolden = flag
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installRotatePanel() {
        fineRotationSegment = nil
        fineRotationSegments.removeAll(keepingCapacity: true)
        let panel = RotatePanel()
        let generation = panelGeneration
        panel.setAutoCrop(Prefs.editAutoCropOnFreeRotate)
        panel.onQuickRotate = { [weak self] quarters in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.appendSnapped90(quarters: quarters)
        }
        panel.onAngleChanged = { [weak self] degrees in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.previewFreeRotate(degrees: degrees)
        }
        panel.onAngleCommitted = { [weak self] degrees in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.commitFreeRotate(degrees: degrees)
        }
        panel.onReset = { [weak self] in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            // Drop the one free-rotation step, including its Auto Crop choice.
            self?.resetFreeRotate()
        }
        panel.onAutoCropChanged = { [weak self] flag in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.changeFreeRotateAutoCrop(flag)
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installResizePanel() {
        let panel = ResizePanel()
        let generation = panelGeneration
        panel.sourcePixelSize = currentPixelSize
        panel.onApply = { [weak self] spec in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.applyResize(spec: spec)
        }
        panel.onDraftChanged = { [weak self] in
            guard self?.panelGeneration == generation else { return }
            self?.refreshPendingToolEdits()
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installColorPanel() {
        let panel = ColorAdjustPanel()
        let generation = panelGeneration
        panel.setParams(effectiveColor)
        panel.onParamsChanged = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.previewColorAdjust(params: params)
        }
        panel.onParamsCommitted = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.commitColorAdjust(params: params)
        }
        panel.onEditEnded = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.commitColorAdjust(params: params, endsDrag: true)
        }
        panel.onResetAll = { [weak self] in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.lastColorParams = .identity
        }
        parameterPanel.install(panel)
        installedTool = panel
    }

    private func installLevelsPanel() {
        let panel = LevelsPanel()
        let generation = panelGeneration
        panel.setParams(effectiveLevels)
        panel.onDraftChanged = { [weak self] in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.refreshPendingToolEdits()
        }
        panel.onParamsChanged = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.writeCoalesced(.levels(params), kind: .levels, render: .draft)
        }
        panel.onParamsCommitted = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.writeCoalesced(.levels(params), kind: .levels, render: .full)
        }
        panel.onEditEnded = { [weak self] params in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            // Drag end, a field commit, Reset: one undo step.
            self?.writeCoalesced(.levels(params), kind: .levels, render: .full, endsDrag: true)
        }
        panel.onAuto = { [weak self] kind in
            guard self?.panelGeneration == generation, self?.isTransitioning == false else { return }
            self?.applyLevelsAuto(kind)
        }
        parameterPanel.install(panel)
        installedTool = panel
        if let recipe {
            Task { [weak self] in
                let ops = await recipe.snapshot()
                guard let self, self.recipe === recipe, self.panelGeneration == generation else { return }
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

    /// Undo names by history index ("Auto Contrast"), for Edit ▸ Undo's title.
    /// Every append sets its index, so a stale name never shows.
    private var undoNames: [Int: String] = [:]
    /// Mirrors of the recipe's undo / redo history depths (set after every write).
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
        let index = await recipe.undoDepth - 1
        guard index >= 0, isActive, self.recipe === recipe, !Task.isCancelled else { return }
        undoNames[index] = name
    }

    /// Auto Contrast / Auto Color: switch to Levels (as picking
    /// the Levels tool does), read the histogram of the image as it enters Levels, and
    /// replace the recipe's Levels values with the result as one undo
    /// step — or, when the result is what the recipe already draws,
    /// write nothing and say why on the status line.
    public func applyLevelsAuto(_ kind: LevelsAutoKind) {
        guard isActive, recipe != nil else { return }
        guard !isSaving, !isTransitioning else { return }
        if currentTool != .levels {
            selectTool(.levels) { [weak self] accepted in
                if accepted { self?.applyLevelsAuto(kind) }
            }
            return
        }
        endCoalescing()
        if kind == .contrast { (installedTool as? LevelsPanel)?.setChannel(.rgb) }
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            guard let self else { return }
            let ops = await recipe.snapshot()
            guard self.recipe === recipe, self.currentTool == .levels, !Task.isCancelled else { return }
            let histogram = await self.levelsInputHistogram(ops: ops)
            guard self.recipe === recipe, self.currentTool == .levels, !Task.isCancelled else { return }
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
            guard self.recipe === recipe, !Task.isCancelled else { return }
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
        let session = recipe, generation = panelGeneration
        levelsHistogramTask = Task { [weak self] in
            guard let self else { return }
            let data = await self.levelsInputHistogram(ops: ops)
            guard !Task.isCancelled, self.recipe === session, self.panelGeneration == generation,
                  let panel = self.installedTool as? LevelsPanel else { return }
            panel.setHistogram(data)
        }
    }

    /// Test seam: waits for the Levels histogram in flight.
    func settleLevelsHistogramForTesting() async {
        await levelsHistogramTask?.value
    }

    // MARK: - Tool actions

    private func applyCurrentCrop() {
        guard !isTransitioning else { return }
        guard recipe != nil, let crop = pendingCropRect() else { return }
        appendGeometry(.crop(crop))
    }

    private static func freeRotateOperation(degrees: Double, autoCrop: Bool) -> EditOperation {
        autoCrop ? .rotateAutoCrop(degrees: degrees) : .rotate(degrees: degrees)
    }

    private func validFreeRotationVisit(_ recipe: EditRecipe, visit: UInt64) -> Bool {
        isActive && self.recipe === recipe && !Task.isCancelled
            && panelGeneration == visit && currentTool == .rotate
    }

    /// Resolve after preceding mutations, not when the input was admitted.
    /// Queued Undo/Redo/Reset/quarter-turns may change the editable baseline.
    private func resolveFreeRotationSegment(in recipe: EditRecipe, visit: UInt64,
                                            createIfMissing: Bool) async
        -> (owner: EditRecipe.GeometryOwner, operation: EditOperation?)? {
        let restored = await recipe.ownedFreeRotation()
        guard validFreeRotationVisit(recipe, visit: visit) else { return nil }
        if let restored, fineRotationSegments.contains(restored.owner) {
            fineRotationSegment = restored.owner
            return restored
        }
        fineRotationSegment = nil
        guard createIfMissing else { return nil }
        let owner = EditRecipe.GeometryOwner()
        fineRotationSegment = owner
        fineRotationSegments.insert(owner)
        return (owner, nil)
    }

    private func previewFreeRotate(degrees: Double) {
        let autoCrop = (installedTool as? RotatePanel)?.autoCropEnabled ?? Prefs.editAutoCropOnFreeRotate
        let op = Self.freeRotateOperation(degrees: degrees, autoCrop: autoCrop)
        if let drag = writeCoalesced(op, kind: .freeRotate, render: .draft,
                                      rotationVisit: panelGeneration) {
            fineRotation = (drag, degrees, false)
        }
    }

    private func commitFreeRotate(degrees: Double) {
        guard !isSaving, !isTransitioning else { return }
        if let owned = fineRotation, owned.degrees == degrees {
            guard !owned.finalized else { return }
            fineRotation = (owned.drag, degrees, true)
            if coalescing?.drag == owned.drag { coalescing = nil }
            coalesceIdleTask?.cancel()
            coalesceIdleTask = nil
            // The preview write is already in mutationTail. Refine its pixels
            // after that write; never start another geometry step at idle.
            enqueue(render: .full) { _ in }
        } else {
            // A direct commit without preview is still a complete interaction.
            let autoCrop = (installedTool as? RotatePanel)?.autoCropEnabled ?? Prefs.editAutoCropOnFreeRotate
            let op = Self.freeRotateOperation(degrees: degrees, autoCrop: autoCrop)
            if let drag = writeCoalesced(op, kind: .freeRotate, render: .full, endsDrag: true,
                                          rotationVisit: panelGeneration) {
                fineRotation = (drag, degrees, true)
            }
        }
    }

    private func changeFreeRotateAutoCrop(_ flag: Bool) {
        guard !isSaving, !isTransitioning else { return }
        Prefs.editAutoCropOnFreeRotate = flag
        let visit = panelGeneration
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            guard let self,
                  let segment = await self.resolveFreeRotationSegment(in: recipe, visit: visit, createIfMissing: false),
                  let angle = segment.operation?.freeRotation?.degrees, abs(angle) >= 0.0001 else { return }
            let op = Self.freeRotateOperation(degrees: angle, autoCrop: flag)
            let changed = await recipe.setOwnedFreeRotation(op, owner: segment.owner, beginsUndoStep: true)
            guard self.validFreeRotationVisit(recipe, visit: visit) else { return }
            if changed {
                self.lastWrittenDrag = nil
                await self.nameLastStep(recipe, nil)
            }
        }
    }

    private func resetFreeRotate() {
        guard !isTransitioning, !isSaving else { return }
        let visit = panelGeneration
        endCoalescing()
        enqueue(render: .full, syncPanels: true) { [weak self] recipe in
            guard let self,
                  let segment = await self.resolveFreeRotationSegment(in: recipe, visit: visit, createIfMissing: false)
            else { return }
            let changed = await recipe.setOwnedFreeRotation(nil, owner: segment.owner, beginsUndoStep: true)
            guard self.validFreeRotationVisit(recipe, visit: visit) else { return }
            self.lastWrittenDrag = nil
            if changed { await self.nameLastStep(recipe, nil) }
        }
    }

    private func applyResize(spec: ResizeSpec) {
        guard !isTransitioning,
              EditRenderer.outputPixelSize(from: currentPixelSize, operations: [.resize(spec)]) != currentPixelSize else { return }
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
                        _ hint: RenderQualityHint) async -> (image: CGImage, lease: ImageResourceLease)? {
        if let override = renderOverrideForTesting {
            let image = await override(recipe, original, hint)
            return image.map { ($0, resources.retain(image: $0, owner: resourceOwner, category: .editPreview)) }
        }
        guard let estimate = try? ImageWorkingSetEstimate(width: original.width, height: original.height,
            bitsPerComponent: original.bitsPerComponent, floatingPoint: original.bitmapInfo.contains(.floatComponents),
            outputWidth: max(1, Int(currentPixelSize.width)), outputHeight: max(1, Int(currentPixelSize.height))) else { return nil }
        guard let reservation = try? await resources.reserve(bytes: estimate.totalBytes, owner: resourceOwner,
            category: .editPreview, priority: .visible, policy: .oneOversizedOperation) else { return nil }
        defer { reservation.release() }
        guard !Task.isCancelled else { return nil }
        guard let image = await renderer.render(recipe: recipe, from: original, qualityHint: hint) else { return nil }
        // Charge the result before admission is released, including actor handoff.
        let lease = resources.retain(image: image, owner: resourceOwner, category: .editPreview)
        return (image, lease)
    }

    /// True while the session that started a render is still the one on
    /// screen. A render finishing after a discard (or after the session
    /// was left and a new one entered) must not paint over the viewer.
    private func isSameSession(_ recipe: EditRecipe, _ original: CGImage) -> Bool {
        isActive && self.recipe === recipe && originalImage === original
    }

    private func renderDraft(revision: UInt64) async {
        guard let recipe, let original = originalImage else { return }
        if let result = await render(recipe, original, .draft),
           isSameSession(recipe, original), revision == renderRevision {
            present(result.image, lease: result.lease, preservingCrop: true)
        }
    }

    private func renderFull(revision: UInt64) async {
        guard let recipe, let original = originalImage else { return }
        if let result = await render(recipe, original, .full),
           isSameSession(recipe, original), revision == renderRevision {
            let size = CGSize(width: result.image.width, height: result.image.height)
            let changed = size != currentPixelSize
            currentPixelSize = size
            present(result.image, lease: result.lease, preservingCrop: !changed)
            if changed {
                // A new shape (crop, 90° rotate, resize): the frame starts
                // on the whole image, and W × H follow (rotate swaps them).
                cropOverlay.imagePixelSize = size
                cropOverlay.resetToFull()
                (installedTool as? CropPanel)?.setDimensions(width: result.image.width, height: result.image.height)
                (installedTool as? ResizePanel)?.sourcePixelSize = size
            }
        }
    }

    private func present(_ image: CGImage, lease: ImageResourceLease, preservingCrop: Bool) {
        // A render can change the canvas aspect and reset its frame.
        // Keep a newer crop drawn against the logical geometry output.
        let pending = preservingCrop ? overlayCropRect() : nil
        renderedLease = lease
        onPresentImage?(image)
        if let pending {
            let size = currentPixelSize
            cropOverlay.setRectFromImageSpace(CGRect(x: pending.originX * size.width,
                y: pending.originY * size.height, width: pending.width * size.width,
                height: pending.height * size.height))
        }
    }

    // MARK: - Toolbar / status sync

    private func refreshStatusCountsAsync() async {
        guard let recipe else {
            updatePendingEditsMirror(false)
            return
        }
        let revision = renderRevision
        let initial = await sessionCheckpointTask?.value
        let changed = if let initial { await recipe.hasContentChanges(since: initial) }
            else { !EditRecipe.effectiveOperations(await recipe.snapshot()).isEmpty }
        let ops = await recipe.undoDepth
        let redos = await recipe.redoDepth
        guard isActive, self.recipe === recipe, !Task.isCancelled,
              revision == renderRevision else { return }
        operationCount = ops
        undoneCount = redos
        publishChrome {
            $0.canUndo = ops > 0
            $0.canRedo = redos > 0
            // Reset can leave undoable parameter history without a current image change.
            $0.hasEdits = changed
        }
        guard isActive, self.recipe === recipe, !Task.isCancelled,
              revision == renderRevision else { return }
        updatePendingEditsMirror(ops > 0 || redos > 0)
    }

    private func refreshToolbarButtons() {
        guard recipe != nil else { return }
        Task { [weak self] in
            await self?.refreshStatusCountsAsync()
        }
    }
}

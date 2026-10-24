//
//  ViewerWindow+Save.swift
//  ShrikeUI
//
//  Edit data safety in the viewer:
//
//  * ⌘S routes through `SaveTarget`: writable single-frame files are
//    backed up, exported in their own format and replaced atomically;
//    RAW, multi-frame and other non-writable files get the Save panel
//    with an explanatory message.
//  * Save As keeps the viewer on the original; a copy in the same folder
//    joins the list next to it.
//  * Revert to Original and Undo / Redo Save swap file
//    versions through `BackupStore`; each swap is one undo step.
//  * After every write: caches evicted, image redrawn, pencil mark read
//    again.
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// A file version an undo step puts back. The swap that fills `record`
/// runs async; the next step in the chain waits for `task` first.
@MainActor
final class FileVersionStep {
    var record: BackupRecord?
    var task: Task<Void, Never>?
    init(record: BackupRecord? = nil) { self.record = record }
}

/// Copy for
enum SaveCopy {
    static func saved(_ name: String) -> String { "Saved “\(FileNameFit.short(name))”. Original backup available." }
    static func savedCopy(_ name: String) -> String { "Saved copy “\(FileNameFit.short(name))”. Original unchanged." }
    static func saveUndone(_ name: String) -> String { "Save undone. “\(FileNameFit.short(name))” is back to how it was." }
    static func reverted(_ name: String) -> String { "Reverted “\(FileNameFit.short(name))” to the original." }
    static func revertUndone(_ name: String) -> String { "“\(FileNameFit.short(name))” is back to how it was before the revert." }
    static func saveFailed(_ name: String) -> String { "Couldn't save “\(FileNameFit.short(name))”." }
    static func undoFailed(_ name: String) -> String { "Couldn't undo — the kept copy of “\(FileNameFit.short(name))” is gone." }

    /// FS-7: the file changed on disk while it was open in edit mode.
    static func changedOnDiskTitle(_ name: String) -> String { "“\(name)” changed while you were editing it." }
    static let changedOnDiskMessage = "Another app changed this file after you started editing. Saving applies your edits to the new version, not to the picture you edited."

    /// A5 title / message.
    static func backupFailedTitle(_ name: String) -> String { "Shrike didn't save “\(name)”." }
    static func backupFailedMessage(volume: String?) -> String {
        if let volume {
            return "It couldn't keep a copy of the original. There isn't enough space on “\(volume)”. "
                + "Free up space, or use Save Copy…"
        }
        return "Shrike couldn't keep an original backup, so this file was not changed. Use Save Copy… to keep your edits."
    }

    /// A4.
    static func revertTitle(_ name: String) -> String { "Revert “\(name)” to the original?" }
    static func revertMessage(_ date: Date) -> String {
        let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return "The file goes back to the version Shrike backed up on \(day) at \(time). "
            + "You can undo this."
    }

    /// The volume name inside a flattened `BackupError.insufficientSpace`
    /// (the exporter reports backup errors as text).
    static func volumeName(inBackupError text: String) -> String? {
        guard text.contains("insufficientSpace"),
              let start = text.range(of: "volumeName: \""),
              let end = text[start.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(text[start.upperBound..<end])
    }
}

extension ViewerWindow {

    // MARK: - Quit with unsaved edits

    /// ⌘Q while this viewer is in edit mode: the edit exit alert, like
    /// Esc or ⌘W. Returns true when the quit may go on (saved, not
    /// changed, or Don't Save); false on Cancel or a failed save.
    func resolveUnsavedEditsForQuit() async -> Bool {
        await resolveUnsavedEdits(reason: .appQuit)
    }

    static let quitWaitsForSave = "Finishing the save. Shrike quits when it is done."
    static var quitSaveWaitLimit: TimeInterval = 120

    /// Leaves edit mode through the exit alert when there are changes.
    /// True when the caller may go on: nothing changed,
    /// saved, or Don't Save. False on Cancel or a failed save.
    func resolveUnsavedEdits(reason: EditExitReason) async -> Bool {
        let editor = contentRoot.editModeController
        guard !didTearDown else { return false }
        guard editor.isActive else { return true }
        if editor.isTransitioning || editor.isSaving {
            // COR-7: ⌘Q during a save used to cancel the quit without a word. For a quit,
            // say so and wait for the save to end; the exit flow (or the quit) goes on after.
            guard reason == .appQuit else { return false }
            contentRoot.toast(ToastContent(Self.quitWaitsForSave))
            let deadline = Date().addingTimeInterval(Self.quitSaveWaitLimit)
            while editor.isTransitioning || editor.isSaving, Date() < deadline, !didTearDown {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !didTearDown else { return false }
            guard editor.isActive else { return true }   // the save ended edit mode
            guard !editor.isTransitioning, !editor.isSaving else { return false }
        }
        if isVisible { makeKeyAndOrderFront(nil) }
        var departure: EditModeController.DepartureToken?
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<EditExitOutcome, Never>) in
            editor.attemptExit(reason: reason) { outcome in
                continuation.resume(returning: outcome)
            }
            departure = editor.departureToken
        }
        switch outcome {
        case .exited: return true
        case .cancelled: return false
        case .needsSave, .needsSaveAs:
            guard let departure else { return false }
            let saved = await saveEditedFile(asPanel: outcome == .needsSaveAs, departure: departure) && !editor.isActive
            if !saved { await editor.restoreCancelledDeparture(for: departure) }
            return saved
        }
    }

    /// Runs `body` now when not editing; otherwise after the exit alert
    /// lets it (Save or Don't Save). Cancel keeps editing and drops
    /// `body`. A request while the alert is up is dropped.
    func leaveEditModeThen(reason: EditExitReason, _ body: @escaping @MainActor () -> Void) {
        guard contentRoot.isEditModeActive else {
            body()
            return
        }
        guard editExitTask == nil, !contentRoot.editModeController.isTransitioning else { return }
        let source = contentRoot.editModeController.sourceURL
        editExitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let mayGoOn = await self.resolveUnsavedEdits(reason: reason)
            self.editExitTask = nil
            if mayGoOn, !Task.isCancelled, !self.didTearDown,
               !self.contentRoot.editModeController.isActive,
               self.displayedItem?.group.primary == source { body() }
        }
    }

    /// `windowShouldClose` (via `ViewerFullScreenTransition`, the window's
    /// delegate). Not editing: close. Editing: keep the window, ask, and
    /// close after Save or Don't Save.
    func shouldCloseResolvingEdits() -> Bool {
        guard contentRoot.isEditModeActive else { return true }
        leaveEditModeThen(reason: .windowClose) { [weak self] in self?.close() }
        return false
    }

    /// Actions that leave the photo on screen ("navigating
    /// away").
    static func leavesPhoto(_ action: ViewerAction) -> Bool {
        switch action {
        case .nextImage, .prevImage, .firstImage, .lastImage, .prevFolder, .nextFolder:
            return true
        default:
            return false
        }
    }

    /// Waits for a running exit alert flow (tests).
    func waitForEditExit() async { await editExitTask?.value }

    // MARK: - Save

    /// ⌘S (`asPanel == false`) or ⇧⌘S. True authorizes completion of the
    /// originating edit session. False can also mean an old export committed
    /// after its UI ownership ended; it must not resume another photo's UI.
    @discardableResult
    func saveEditedFile(asPanel: Bool, departure: EditModeController.DepartureToken? = nil) async -> Bool {
        let ctrl = contentRoot.editModeController
        guard ctrl.isActive, !ctrl.isSaving, ctrl.acceptsDepartureSave(departure), let recipe = ctrl.recipe, let source = ctrl.sourceURL,
              let item = displayedItem else { return false }
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        guard await ctrl.prepareForSave(allowDecision: ctrl.isAwaitingDepartureSave),
              acceptsEditSave(recipe: recipe, source: source, item: item),
              !ctrl.isSaving, ctrl.acceptsDepartureSave(departure) else { return false }
        guard ctrl.handOffDepartureToSave(departure) else { return false }
        ctrl.setSaving(true)
        defer { ctrl.finishSaving(for: recipe, departure: departure) }
        let operations = await recipe.snapshot()
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        if !asPanel, operations.isEmpty { ctrl.finalizeExit(); return true }
        // Another program changed the file while it was open in edit mode: the
        // edits were drawn on the old picture. Ask before they land on the new one.
        if let stamp = ctrl.sourceStamp, FileStamp(of: source) != stamp {
            let answer = await presentFileAlert(
                message: SaveCopy.changedOnDiskTitle(source.lastPathComponent),
                information: SaveCopy.changedOnDiskMessage,
                buttons: [.cancel(), ShrikeAlert.Button("Save Anyway")])
            guard answer == 1, acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        }
        let capability = await Task.detached(priority: .userInitiated) {
            ImageExporter.capability(for: source, operations: operations)
        }.value
        let decision = await Task.detached(priority: .userInitiated) { SaveTarget.evaluate(source) }.value
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        if !asPanel, !capability.requiresCopy, case .inPlace(let format) = decision {
            if await recipe.operations.isEmpty {
                ctrl.finalizeExit()
                return true
            }
            return await saveInPlace(recipe: recipe, source: source, item: item, format: format)
        }
        let suggested = SaveTarget.saveAsURL(for: source, decision: decision)
        guard let (destination, format) = await askSaveAsDestination(
            suggested: suggested, format: decision.format, message: [decision.reason?.message(for: source), capability.conversionDisclosure].compactMap { $0 }.joined(separator: "\n")
        ) else { return false }
        guard !Self.sameFile(source, destination) else {
            contentRoot.toast(ToastContent("Choose a different file name to keep the original.", kind: .error))
            return false
        }
        return await saveCopy(recipe: recipe, source: source, item: item, to: destination, format: format)
    }

    /// Pure ownership check, also safe AFTER a legitimate disk commit. It
    /// deliberately compares accepted source identity rather than file mtime.
    private func ownsEditSave(recipe: EditRecipe, source: URL, item: DisplayedItem) -> Bool {
        let controller = contentRoot.editModeController
        guard !didTearDown, navCoalescer.isIdle, controller.isActive,
              controller.recipe === recipe, controller.sourceURL == source,
              let current = displayedItem, current.group.primary == item.group.primary else { return false }
        return editSourceMatchesDisplayed(source, item: current)
    }

    private func acceptsEditSave(recipe: EditRecipe, source: URL, item: DisplayedItem) -> Bool {
        let controller = contentRoot.editModeController
        guard !didTearDown, navCoalescer.isIdle, controller.isActive,
              controller.recipe === recipe, controller.sourceURL == source,
              editSourceMatchesDisplayed(source, item: item) else {
            if !didTearDown {
                contentRoot.toast(ToastContent("The photo on screen no longer matches this edit. Your edits are still open. No file was changed.", kind: .error))
            }
            return false
        }
        return true
    }

    fileprivate static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let av = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let bv = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let ai = av.fileResourceIdentifier as? NSObject, let bi = bv.fileResourceIdentifier as? NSObject else { return false }
        return ai.isEqual(bi)
    }

    private func exporter() -> ImageExporter? {
        guard let store = services.backupStore else { return nil }
        return ImageExporter(backupStore: store, metadataStore: services.metadataStore, checkpoint: exportCheckpointForTesting)
    }

    private static func quality(for format: ExportFormat) -> Double {
        Double(format == .heic ? Prefs.editHEICQualityDefault : Prefs.editJPEGQualityDefault) / 100
    }

    private func saveInPlace(recipe: EditRecipe, source: URL, item: DisplayedItem, format: ExportFormat) async -> Bool {
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        let name = source.lastPathComponent
        guard let exporter = exporter() else {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error))
            return false
        }
        watcherScope.ignore(paths: [source], for: .seconds(2))
        do {
            let record = try await exporter.export(
                recipe: recipe, from: source, to: source, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
            // The exporter may have committed A after its viewer moved to B.
            // That is a disk success, but does not authorize B UI or navigation.
            guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
            contentRoot.editModeController.finalizeExit(keepDisplay: true)
            didChangeFileOnDisk(source, fit: true)
            if let record {
                registerVersionUndo(url: source, step: FileVersionStep(record: record), actionName: "Save",
                                    undoToast: SaveCopy.saveUndone(name), redoToast: SaveCopy.saved(name))
            }
            contentRoot.toast(ToastContent(SaveCopy.saved(name), actionTitle: "Undo")) { [weak self] in
                self?.performUndo()
            }
            return true
        } catch ExportError.backupFailed(let underlying) {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
            let answer = await presentFileAlert(
                message: SaveCopy.backupFailedTitle(name),
                information: "Shrike couldn't keep an original backup, so this file was not changed.",
                buttons: [ShrikeAlert.Button("Save Copy…", role: .default), ShrikeAlert.Button("Cancel", role: .cancel)]
            )
            if answer == 0 {
                let suggested = SaveTarget.saveAsURL(for: source, decision: SaveTarget.evaluate(source))
                if let (destination, copyFormat) = await askSaveAsDestination(suggested: suggested, format: format, message: "The original will not be changed."), !Self.sameFile(source, destination) {
                    return await saveCopy(recipe: recipe, source: source, item: item, to: destination, format: copyFormat)
                }
            }
            _ = underlying
            return false
        } catch {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error))
            return false
        }
    }

    /// Save As: the viewer stays on the original; a copy in the same
    /// folder joins the list next to it, and the toast's Show jumps there.
    private func saveCopy(recipe: EditRecipe, source: URL, item: DisplayedItem, to destination: URL, format: ExportFormat) async -> Bool {
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        guard let exporter = exporter() else {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(destination.lastPathComponent), kind: .error))
            return false
        }
        // Only this viewer's own watcher ignores the copy (it inserts the copy
        // itself below). The registry would also silence the Browser's watcher,
        // which then never learned about the new file.
        folderWatcher?.ignore(paths: [destination], for: .seconds(2))
        do {
            try await exporter.export(
                recipe: recipe, from: source, to: destination, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
        } catch ExportError.backupFailed(let underlying) {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
            _ = await presentFileAlert(
                message: SaveCopy.backupFailedTitle(destination.lastPathComponent),
                information: SaveCopy.backupFailedMessage(volume: SaveCopy.volumeName(inBackupError: underlying)),
                buttons: [ShrikeAlert.Button("OK", role: .default)]
            )
            return false
        } catch {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(destination.lastPathComponent), kind: .error))
            return false
        }
        guard ownsEditSave(recipe: recipe, source: source, item: item) else { return false }
        contentRoot.editModeController.finalizeExit()
        if list.index(of: destination) != nil {
            didChangeFileOnDisk(destination, fit: false)
        } else if GroupList.canonical(destination.deletingLastPathComponent())
                    == GroupList.canonical(source.deletingLastPathComponent()),
                  let index = list.index(of: source) {
            list.insert([RemovedGroup(index: index + 1, group: ImageGroup(primary: destination))])
            syncListKeepingDisplayed()
        }
        contentRoot.toast(ToastContent(SaveCopy.savedCopy(destination.lastPathComponent), actionTitle: "Show")) {
            [weak self] in
            guard let self, let index = self.list.index(of: destination) else { return }
            self.coalesceNav { [weak self] in await self?.navigate(to: index) }
        }
        return true
    }

    /// The Save panel with its accessory; returns the chosen URL and
    /// format. Tests answer through `savePanelResponderForTesting`.
    func askSaveAsDestination(suggested: URL, format: ExportFormat, message: String?) async -> (URL, ExportFormat)? {
        let ctrl = contentRoot.editModeController
        ctrl.setAwaitingDestination(true)
        defer { ctrl.setAwaitingDestination(false) }
        return await presentSaveAsPanel(suggested: suggested, format: format, message: message)
    }

    private func presentSaveAsPanel(suggested: URL, format: ExportFormat, message: String?) async -> (URL, ExportFormat)? {
        if let responder = savePanelAsyncResponderForTesting {
            return await responder(suggested, message).map { ($0, format) }
        }
        if let responder = savePanelResponderForTesting {
            return responder(suggested, message).map { ($0, format) }
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        let accessory = SaveAsAccessory(message: message, format: format, panel: panel)
        panel.accessoryView = accessory
        let validation = CopyDestinationValidation(source: contentRoot.editModeController.sourceURL)
        panel.delegate = validation
        defer { withExtendedLifetime(validation) {} }
        let response = await panel.beginSheetModal(for: self)
        guard response == .OK, let url = panel.url else { return nil }
        return (url, accessory.format)
    }

    // MARK: - Revert to Original

    /// File ▸ Revert to Original…, the context menu. Alert A4 first.
    func revertDisplayedToOriginal() {
        guard !contentRoot.isEditModeActive, let item = displayedItem,
              let store = services.backupStore else { return }
        let url = item.group.primary
        let name = item.group.displayName
        Task { @MainActor [weak self] in
            let availability = await store.availability(for: url)
            guard let self, !self.didTearDown, self.displayedItem?.group.primary == url else { return }
            guard availability.canRevert, let original = availability.originalRecord else {
                self.contentRoot.toast(ToastContent("Original backup unavailable", kind: .error)); self.refreshInspectorFileState(); return
            }
            let choice = await self.presentFileAlert(
                message: SaveCopy.revertTitle(name),
                information: SaveCopy.revertMessage(original.createdAt),
                buttons: [.cancel(), ShrikeAlert.Button("Revert", role: .default)]
            )
            guard choice == 1 else { return }
            watcherScope.ignore(paths: [url], for: .seconds(2))
            do {
                let preRevert = try await store.revertToOriginal(url)
                self.didChangeFileOnDisk(url, fit: false)
                self.registerVersionUndo(url: url, step: FileVersionStep(record: preRevert),
                                         actionName: "Revert to Original",
                                         undoToast: SaveCopy.revertUndone(name),
                                         redoToast: SaveCopy.reverted(name))
                self.contentRoot.toast(ToastContent(SaveCopy.reverted(name), actionTitle: "Undo")) { [weak self] in
                    self?.performUndo()
                }
            } catch {
                self.contentRoot.toast(ToastContent("Couldn't revert “\(name)”.", kind: .error))
            }
        }
    }

    // MARK: - Undo / Redo of file versions

    /// Registers "Undo <actionName>": puts `step`'s bytes back. The inverse
    /// is registered inside the undo (so it lands on the redo stack) and
    /// is filled by the swap's safety copy.
    func registerVersionUndo(url: URL, step: FileVersionStep, actionName: String,
                             undoToast: String?, redoToast: String?) {
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.swapFileVersion(url: url, from: step, actionName: actionName,
                                       toast: undoToast, inverseToast: redoToast)
            }
        }
        windowUndoManager.setActionName(actionName)
    }

    private func swapFileVersion(url: URL, from step: FileVersionStep, actionName: String,
                                 toast: String?, inverseToast: String?) {
        let inverse = FileVersionStep()
        registerVersionUndo(url: url, step: inverse, actionName: actionName,
                            undoToast: inverseToast, redoToast: toast)
        let store = services.backupStore
        let name = url.lastPathComponent
        inverse.task = Task { @MainActor [weak self] in
            await step.task?.value
            guard let store, let record = step.record else {
                self?.contentRoot.toast(ToastContent(SaveCopy.undoFailed(name), kind: .error))
                return
            }
            self?.watcherScope.ignore(paths: [url], for: .seconds(2))
            do {
                inverse.record = try await store.restore(record)
                self?.didChangeFileOnDisk(url, fit: false)
                if let toast { self?.contentRoot.toast(ToastContent(toast)) }
            } catch {
                self?.contentRoot.toast(ToastContent(SaveCopy.undoFailed(name), kind: .error))
            }
        }
        pendingFileVersionTask = inverse.task
    }

    /// Waits for the latest undo / redo file swap (tests).
    func waitForFileVersionSwap() async {
        await pendingFileVersionTask?.value
    }

    // MARK: - Refresh after file changes

    /// Evicts both caches for `url`, redraws it when it is on screen
    /// (at Fit after a save) and reads its pencil state again.
    func didChangeFileOnDisk(_ url: URL, fit: Bool) {
        let cache = services.thumbnailCache
        // The strip cell asks again once the old thumbnail is gone (spec 27 B4).
        Task { [weak self] in
            await cache.evict(url: url)
            guard let self else { return }
            await MainActor.run { _ = self.contentRoot.reloadFilmstripThumbnail(for: url, services: self.services) }
        }
        let key = list.index(of: url).flatMap { list[$0]?.primary } ?? url
        headerPixelSizes[url] = nil
        headerPixelSizes[key] = nil
        if displayedItem?.group.primary == key { contentRoot.reloadInspectorFile() }
        if let displayed = displayedItem?.group.primary,
           GroupList.canonical(displayed) == GroupList.canonical(url) {
            redrawDisplayedKeepingView(fit: fit)
        } else {
            evictFromDecodeCache(url)
        }
        refreshBackupState(key)
        pairedBrowser?.fileContentsChanged([url, key])
    }

    /// Pencil mark and the Revert row follow `BackupStore.state(for:)`.
    func refreshBackupState(_ url: URL) {
        guard let store = services.backupStore else { return }
        Task { @MainActor [weak self] in
            let state = await store.state(for: url)
            guard let self else { return }
            var extras = self.fileBadges[url] ?? FileBadgeExtras()
            extras.edited = state == .edited
            self.fileBadges[url] = extras
            self.badgeReadGuard.noteWrite([url])
            self.refreshPositionMarks(flash: false)
            self.contentRoot.refreshFilmstripMarks()
            self.backupStateGeneration &+= 1
        }
    }
}

@MainActor
private final class CopyDestinationValidation: NSObject, NSOpenSavePanelDelegate {
    let source: URL?
    init(source: URL?) { self.source = source }
    func panel(_ sender: Any, validate url: URL) throws {
        guard let source, ViewerWindow.sameFile(source, url) else { return }
        throw NSError(domain: "app.shrike.SaveCopy", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Choose a different file name to keep the original."])
    }
}

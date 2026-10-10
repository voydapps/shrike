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
    static func saved(_ name: String) -> String { "Saved “\(name)”. The original is kept." }
    static func savedCopy(_ name: String) -> String { "Saved a copy as “\(name)”." }
    static func saveUndone(_ name: String) -> String { "Save undone. “\(name)” is back to how it was." }
    static func reverted(_ name: String) -> String { "Reverted “\(name)” to the original." }
    static func revertUndone(_ name: String) -> String { "“\(name)” is back to how it was before the revert." }
    static func saveFailed(_ name: String) -> String { "Couldn't save “\(name)”." }
    static func undoFailed(_ name: String) -> String { "Couldn't undo — the kept copy of “\(name)” is gone." }

    /// A5 title / message.
    static func backupFailedTitle(_ name: String) -> String { "Shrike didn't save “\(name)”." }
    static func backupFailedMessage(volume: String?) -> String {
        if let volume {
            return "It couldn't keep a copy of the original. There isn't enough space on “\(volume)”. "
                + "Free up space, or use Save As."
        }
        return "It couldn't keep a copy of the original. Use Save As."
    }

    /// A4.
    static func revertTitle(_ name: String) -> String { "Revert “\(name)” to the original?" }
    static func revertMessage(_ date: Date) -> String {
        let day = DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
        let time = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        return "The file goes back to how it was on \(day) at \(time), before Shrike first changed it. "
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

    /// Leaves edit mode through the exit alert when there are changes.
    /// True when the caller may go on: nothing changed,
    /// saved, or Don't Save. False on Cancel or a failed save.
    func resolveUnsavedEdits(reason: EditExitReason) async -> Bool {
        let editor = contentRoot.editModeController
        guard editor.isActive else { return true }
        if isVisible { makeKeyAndOrderFront(nil) }
        let previous = editor.onExitOutcome
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<EditExitOutcome, Never>) in
            var resumed = false
            editor.onExitOutcome = { outcome in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: outcome)
            }
            editor.attemptExit(reason: reason)
        }
        editor.onExitOutcome = previous
        switch outcome {
        case .exited: return true
        case .cancelled: return false
        case .needsSave: return await saveEditedFile(asPanel: false) && !editor.isActive
        case .needsSaveAs: return await saveEditedFile(asPanel: true) && !editor.isActive
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
        guard editExitTask == nil else { return }
        editExitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let mayGoOn = await self.resolveUnsavedEdits(reason: reason)
            self.editExitTask = nil
            if mayGoOn { body() }
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

    /// ⌘S (`asPanel == false`) or ⇧⌘S. Returns true when the file was
    /// written; edit mode is then closed.
    @discardableResult
    func saveEditedFile(asPanel: Bool) async -> Bool {
        let ctrl = contentRoot.editModeController
        guard ctrl.isActive, let recipe = ctrl.recipe, let source = ctrl.sourceURL else { return false }
        let decision = await Task.detached(priority: .userInitiated) { SaveTarget.evaluate(source) }.value
        if !asPanel, case .inPlace(let format) = decision {
            if await recipe.operations.isEmpty {
                ctrl.finalizeExit()
                return true
            }
            return await saveInPlace(recipe: recipe, source: source, format: format)
        }
        let suggested = SaveTarget.saveAsURL(for: source, decision: decision)
        guard let (destination, format) = await askSaveAsDestination(
            suggested: suggested, format: decision.format, message: decision.reason?.message(for: source)
        ) else { return false }
        return await saveCopy(recipe: recipe, source: source, to: destination, format: format)
    }

    private func exporter() -> ImageExporter? {
        guard let store = services.backupStore else { return nil }
        return ImageExporter(backupStore: store, metadataStore: services.metadataStore)
    }

    private static func quality(for format: ExportFormat) -> Double {
        Double(format == .heic ? Prefs.editHEICQualityDefault : Prefs.editJPEGQualityDefault) / 100
    }

    private func saveInPlace(recipe: EditRecipe, source: URL, format: ExportFormat) async -> Bool {
        let name = source.lastPathComponent
        guard let exporter = exporter() else {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error))
            return false
        }
        FolderWatcherRegistry.shared.ignore(paths: [source], for: .seconds(2))
        do {
            let record = try await exporter.export(
                recipe: recipe, from: source, to: source, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
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
            _ = await presentFileAlert(
                message: SaveCopy.backupFailedTitle(name),
                information: SaveCopy.backupFailedMessage(volume: SaveCopy.volumeName(inBackupError: underlying)),
                buttons: [ShrikeAlert.Button("OK", role: .default)]
            )
            return false
        } catch {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error))
            return false
        }
    }

    /// Save As: the viewer stays on the original; a copy in the same
    /// folder joins the list next to it, and the toast's Show jumps there.
    private func saveCopy(recipe: EditRecipe, source: URL, to destination: URL, format: ExportFormat) async -> Bool {
        guard let exporter = exporter() else {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(destination.lastPathComponent), kind: .error))
            return false
        }
        FolderWatcherRegistry.shared.ignore(paths: [destination], for: .seconds(2))
        do {
            try await exporter.export(
                recipe: recipe, from: source, to: destination, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
        } catch ExportError.backupFailed(let underlying) {
            _ = await presentFileAlert(
                message: SaveCopy.backupFailedTitle(destination.lastPathComponent),
                information: SaveCopy.backupFailedMessage(volume: SaveCopy.volumeName(inBackupError: underlying)),
                buttons: [ShrikeAlert.Button("OK", role: .default)]
            )
            return false
        } catch {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(destination.lastPathComponent), kind: .error))
            return false
        }
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
        if let responder = savePanelResponderForTesting {
            return responder(suggested, message).map { ($0, format) }
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.directoryURL = suggested.deletingLastPathComponent()
        panel.nameFieldStringValue = suggested.lastPathComponent
        let accessory = SaveAsAccessory(message: message, format: format, panel: panel)
        panel.accessoryView = accessory
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
            guard let original = await store.records(for: url).last, let self else { return }
            let choice = await self.presentFileAlert(
                message: SaveCopy.revertTitle(name),
                information: SaveCopy.revertMessage(original.createdAt),
                buttons: [.cancel(), ShrikeAlert.Button("Revert", role: .default)]
            )
            guard choice == 1 else { return }
            FolderWatcherRegistry.shared.ignore(paths: [url], for: .seconds(2))
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
            FolderWatcherRegistry.shared.ignore(paths: [url], for: .seconds(2))
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
        Task { await cache.evict(url: url) }
        let key = list.index(of: url).flatMap { list[$0]?.primary } ?? url
        if let displayed = displayedItem?.group.primary,
           GroupList.canonical(displayed) == GroupList.canonical(url) {
            redrawDisplayedKeepingView(fit: fit)
        } else {
            evictFromDecodeCache(url)
        }
        refreshBackupState(key)
        pairedBrowser?.reloadCurrentFolder()
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

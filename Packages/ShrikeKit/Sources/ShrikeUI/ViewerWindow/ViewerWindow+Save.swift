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

/// An in-place save that wrote its file but could not finish its session's UI, while
/// the session's recipe had changed after the write or the file is no longer what the
/// save wrote (normally the session is ended instead, see `finishUnownedSave`). That
/// session may never export from the file again: the file holds (or may derive from)
/// its earlier edits, so they would be applied twice.
@MainActor
struct UnclosedInPlaceWrite {
    weak var recipe: EditRecipe?
    let url: URL
    let written: FileStamp?
}

/// The edit exit answer kept for later.
@MainActor
final class DeferredExitChoice {
    var choice: EditExitModal.Choice?
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

    /// The file changed on disk while it was open in edit mode.
    static func changedOnDiskTitle(_ name: String) -> String { "“\(name)” changed while you were editing it." }
    static let changedOnDiskMessage = "Another app changed this file after you started editing. Saving applies your edits to the new version, not to the photo you edited."

    /// Title and message of the backup-failed alert.
    static func backupFailedTitle(_ name: String) -> String { "Shrike didn't save “\(name)”." }
    static func backupFailedMessage(volume: String?) -> String {
        if let volume {
            return "It couldn't keep a copy of the original. There isn't enough space on “\(volume)”. "
                + "Free up space, or use Save Copy…"
        }
        return "Shrike couldn't keep an original backup, so this file was not changed. Use Save Copy… to keep your edits."
    }

    /// Title and message of the Revert question.
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

    /// The answer to the unsaved-edits question at quit, not acted on yet.
    /// `choice` nil: nothing is left to save.
    struct QuitEditAnswer: Sendable {
        let choice: EditExitModal.Choice?
    }

    /// ⌘Q while work runs: asks the edit exit question but saves and
    /// discards nothing (the work question may still cancel the quit).
    /// nil on Cancel.
    func askUnsavedEditsForQuit() async -> QuitEditAnswer? {
        let box = DeferredExitChoice()
        guard await resolveUnsavedEdits(reason: .appQuit, deferring: box) else { return nil }
        return QuitEditAnswer(choice: box.choice)
    }

    /// The quit goes on: Save (a failed save cancels the quit) or Don't Save.
    func applyQuitEditAnswer(_ answer: QuitEditAnswer) async -> Bool {
        guard let choice = answer.choice else { return true }
        return await resolveUnsavedEdits(reason: .appQuit, preset: choice)
    }

    static let quitWaitsForSave = "Finishing the save. Shrike quits when it is done."
    static var quitSaveWaitLimit: TimeInterval = 120

    /// Leaves edit mode through the exit alert when there are changes.
    /// True when the caller may go on: nothing changed,
    /// saved, or Don't Save. False on Cancel or a failed save.
    func resolveUnsavedEdits(reason: EditExitReason, preset: EditExitModal.Choice? = nil,
                             deferring deferred: DeferredExitChoice? = nil) async -> Bool {
        let editor = contentRoot.editModeController
        guard !didTearDown else { return false }
        guard editor.isActive else { return true }
        if editor.isTransitioning || editor.isSaving {
            // ⌘Q during a save used to cancel the quit without a word. For a quit,
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
            var deferAnswer: (@MainActor (EditExitModal.Choice) -> Void)?
            if let deferred { deferAnswer = { choice in deferred.choice = choice } }
            editor.attemptExit(reason: reason, presetChoice: preset, deferAnswer: deferAnswer) { outcome in
                continuation.resume(returning: outcome)
            }
            departure = editor.departureToken
        }
        switch outcome {
        case .exited: return true
        case .cancelled: return deferred?.choice != nil
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
        // This session already wrote the file and changed after (its save could not finish
        // the UI): the file holds the earlier edits, so exporting would apply them twice.
        if let write = unclosedInPlaceWrite, write.recipe === recipe, write.url == source {
            // "Changed on disk" only when it is known: no stamp after the write proves nothing.
            let message = write.written == nil || FileStamp(of: source) == write.written
                ? "The photo on screen no longer matches this edit. Your edits are still open. No file was changed."
                : SaveCopy.changedOnDiskTitle(source.lastPathComponent)
            contentRoot.toast(ToastContent(message, kind: .error))
            return false
        }
        // Read before the skip below: a file changed on disk is never left silently.
        let changedOnDisk = ctrl.sourceStamp.map { FileStamp(of: source) != $0 } ?? false
        // ⌘S writes only when Done would: edits that cancel out just leave.
        if !asPanel, !changedOnDisk, !(await ctrl.hasSessionContentChanges(recipe)) {
            guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
            ctrl.finalizeExit(); return true
        }
        // Another program changed the file while it was open in edit mode: the
        // edits were drawn on the old picture. Ask before they land on the new one.
        if changedOnDisk {
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
            if !changedOnDisk, !(await ctrl.hasSessionContentChanges(recipe)) {
                ctrl.finalizeExit()
                return true
            }
            return await saveInPlace(recipe: recipe, source: source, item: item, format: format, operations: operations)
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
    private func ownsEditSave(recipe: EditRecipe, source: URL, item: DisplayedItem,
                              ignoringNavigation: Bool = false) -> Bool {
        let controller = contentRoot.editModeController
        guard !didTearDown, ignoringNavigation || navCoalescer.isIdle, controller.isActive,
              controller.recipe === recipe, controller.sourceURL == source,
              let current = displayedItem, current.group.primary == item.group.primary else { return false }
        return editSourceMatchesDisplayed(source, item: current)
    }

    /// What a save that wrote its file may do with the window's UI.
    private enum SaveOwnership {
        /// Owns the UI: a normal save (Undo registered, toast with Undo).
        case proved
        /// The wait for the list ran out, so the plain toast was shown and no undo is
        /// registered; later the list settled on the same photo with the file as written:
        /// the session is closed out like after a normal save, without an undo.
        case closeOut
        /// The UI belongs to something else. `toastShown`: the plain toast is already up.
        case lost(toastShown: Bool)
    }

    /// After the write. When only a navigation (for example the list being rebuilt)
    /// stands in the way, waits for it, at most `saveOwnershipWait`, then checks
    /// everything again, because the rebuilt list may show another photo. If the wait
    /// runs out on the same photo, says "Saved" and keeps waiting (up to
    /// `saveCloseOutLimit`) with the session still locked for saving (controls off,
    /// ⌘S refused), so nothing is added to the written edit. If the list settles on
    /// the same photo with the file as written, the session is closed out. Otherwise
    /// (the file changed, or the limit ran out) `finishUnownedSave` ends the session
    /// only when the file is still exactly what the save wrote (`written`); if not, the
    /// session stays open and its next Save is refused. Teardown cancels the
    /// navigation, which ends the wait.
    private func regainsSaveOwnership(recipe: EditRecipe, source: URL, item: DisplayedItem,
                                      written: FileStamp?) async -> SaveOwnership {
        if ownsEditSave(recipe: recipe, source: source, item: item) { return .proved }
        guard ownsEditSave(recipe: recipe, source: source, item: item, ignoringNavigation: true) else {
            return .lost(toastShown: false)
        }
        if await navCoalescer.waitUntilIdle(timeout: saveOwnershipWait),
           ownsEditSave(recipe: recipe, source: source, item: item) {
            return .proved
        }
        // The wait ran out, or answered idle while a second navigation had already
        // started: only that navigation stands in the way, so go on to the close-out wait.
        guard ownsEditSave(recipe: recipe, source: source, item: item, ignoringNavigation: true) else {
            return .lost(toastShown: false)
        }
        contentRoot.toast(ToastContent(SaveCopy.saved(source.lastPathComponent)))
        // Bounded so a quit does not wait for long (a ⌘W during a save is dropped, as in 0.2.32).
        let deadline = ContinuousClock.now + saveCloseOutLimit
        while ContinuousClock.now < deadline {
            _ = await navCoalescer.waitUntilIdle(timeout: saveOwnershipWait)
            if ownsEditSave(recipe: recipe, source: source, item: item) {
                // The file must still be the one this save wrote.
                return written != nil && FileStamp(of: source) == written ? .closeOut : .lost(toastShown: true)
            }
            guard ownsEditSave(recipe: recipe, source: source, item: item, ignoringNavigation: true) else {
                return .lost(toastShown: true)
            }
        }
        return .lost(toastShown: true)
    }

    /// The file was written but the window's UI belongs to something else now
    /// (another photo, another edit, or the list did not settle in time). A closed
    /// window gets nothing. If the saving session is still open, its recipe is the one
    /// written and the file is still what the save wrote (`written`), the file already
    /// holds everything it has: the session ends the way Don't Save ends it (nothing
    /// written, the photo shown from disk), so there is no question and nothing that
    /// could export the same edit twice. Otherwise (the recipe changed after the write,
    /// or another program changed the file) the session stays open and its next Save
    /// is refused (`UnclosedInPlaceWrite`). Another session is left alone.
    ///
    /// No undo is registered here (as in 0.2.32). An undo holds the path from save
    /// time; if Shrike later renames this photo away and gives that name to another
    /// photo, Undo would write this photo's original over the other one. The
    /// original stays in the backup (File ▸ Revert to Original).
    private func finishUnownedSave(recipe: EditRecipe, operations: [EditOperation], source: URL,
                                   written: FileStamp?, showToast: Bool) async {
        guard !didTearDown else { return }
        let name = source.lastPathComponent
        let ctrl = contentRoot.editModeController
        var ended = false
        if ctrl.isActive, ctrl.recipe === recipe {
            let unchanged = await recipe.snapshot() == operations
            guard !didTearDown else { return }
            if ctrl.isActive, ctrl.recipe === recipe {
                // finalizeExit() finds the file changed and draws it from disk.
                if unchanged, written != nil, FileStamp(of: source) == written {
                    // A crop or resize changed the size: the title, Info panel and "100 %"
                    // read it again (the redraw that ends the session may not get that far).
                    headerPixelSizes[source] = nil
                    headerPixelSizes[list.index(of: source).flatMap { list[$0]?.primary } ?? source] = nil
                    ctrl.finalizeExit(); ended = true
                } else { unclosedInPlaceWrite = UnclosedInPlaceWrite(recipe: recipe, url: source, written: written) }
            }
        }
        if let shown = displayedItem?.group.primary, GroupList.canonical(shown) == GroupList.canonical(source),
           ended || contentRoot.isEditModeActive {
            // On screen and drawn already (just ended) or by an edit session: only the
            // thumbnail, pencil mark and Browser cell of the saved file.
            refreshFileMarks(source)
        } else {
            didChangeFileOnDisk(source, fit: false)
        }
        // No Undo button: nothing was registered, and the toast's Undo would act on whatever the window shows.
        if showToast { contentRoot.toast(ToastContent(SaveCopy.saved(name))) }
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

    private func saveInPlace(recipe: EditRecipe, source: URL, item: DisplayedItem, format: ExportFormat,
                             operations: [EditOperation]) async -> Bool {
        guard acceptsEditSave(recipe: recipe, source: source, item: item) else { return false }
        let name = source.lastPathComponent
        guard let exporter = exporter() else {
            contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error))
            return false
        }
        watcherScope.ignore(paths: [source], for: .seconds(2))
        // The quit alert's "still saving" line counts viewer saves only (a Batch's writes are its own line).
        ViewerSaveCounter.running += 1
        defer { ViewerSaveCounter.running -= 1 }
        do {
            let record = try await exporter.export(
                recipe: recipe, from: source, to: source, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
            let written = FileStamp(of: source)
            // The exporter may have committed A after its viewer moved to B.
            // That is a disk success, but does not authorize B UI or navigation.
            switch await regainsSaveOwnership(recipe: recipe, source: source, item: item, written: written) {
            case .proved: break
            case .closeOut:
                contentRoot.editModeController.finalizeExit(keepDisplay: true)
                didChangeFileOnDisk(source, fit: true)
                return true
            case .lost(let toastShown):
                // False on purpose, even when the session was ended: the Next, close or
                // quit whose Save ran this must not go on late over a list that has not
                // settled. That quit is cancelled; a second ⌘Q works.
                await finishUnownedSave(recipe: recipe, operations: operations, source: source,
                                        written: written, showToast: !toastShown)
                return false
            }
            contentRoot.editModeController.finalizeExit(keepDisplay: true)
            didChangeFileOnDisk(source, fit: true)
            if let record {
                registerVersionUndo(url: source, step: FileVersionStep(record: record), actionName: "Save",
                                    undoToast: SaveCopy.saveUndone(name), redoToast: SaveCopy.saved(name))
                // Undo undoes this save only; the toast goes when anything else changes the stack.
                showUndoToast(ToastContent(SaveCopy.saved(name), actionTitle: "Undo"))
            } else {
                // Nothing was registered, so an Undo button would undo some older action.
                contentRoot.toast(ToastContent(SaveCopy.saved(name)))
            }
            return true
        } catch ExportError.backupFailed(let underlying) {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else {
                // No alert: its Save Copy… would act on the photo shown now.
                if !didTearDown { contentRoot.toast(ToastContent(SaveCopy.backupFailedTitle(name), kind: .error)) }
                return false
            }
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
            // Said even when the window has moved on: a failed save is never silent.
            if !didTearDown { contentRoot.toast(ToastContent(SaveCopy.saveFailed(name), kind: .error)) }
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
        // The quit alert's "still saving" line counts viewer saves only (a Batch's writes are its own line).
        ViewerSaveCounter.running += 1
        defer { ViewerSaveCounter.running -= 1 }
        do {
            try await exporter.export(
                recipe: recipe, from: source, to: destination, format: format,
                quality: Self.quality(for: format),
                preserveEXIF: Prefs.editPreserveEXIFOnSave, stripGPS: Prefs.editStripGPSOnSave
            )
        } catch ExportError.backupFailed(let underlying) {
            guard ownsEditSave(recipe: recipe, source: source, item: item) else {
                // No alert over the photo shown now, but a failed save is never silent.
                if !didTearDown { contentRoot.toast(ToastContent(SaveCopy.backupFailedTitle(destination.lastPathComponent), kind: .error)) }
                return false
            }
            _ = await presentFileAlert(
                message: SaveCopy.backupFailedTitle(destination.lastPathComponent),
                information: SaveCopy.backupFailedMessage(volume: SaveCopy.volumeName(inBackupError: underlying)),
                buttons: [ShrikeAlert.Button("OK", role: .default)]
            )
            return false
        } catch {
            // Said even when the window has moved on: a failed save is never silent.
            if !didTearDown { contentRoot.toast(ToastContent(SaveCopy.saveFailed(destination.lastPathComponent), kind: .error)) }
            return false
        }
        guard ownsEditSave(recipe: recipe, source: source, item: item) else {
            // Written, but the window shows something else now: say so, without "Show"
            // (it would navigate away from the photo shown now). The original is unchanged.
            if !didTearDown { contentRoot.toast(ToastContent(SaveCopy.savedCopy(destination.lastPathComponent))) }
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

    /// File ▸ Revert to Original…, the context menu. The Revert question comes first.
    func revertDisplayedToOriginal() {
        guard !contentRoot.isEditModeActive, let item = displayedItem,
              let store = services.backupStore else { return }
        let url = item.group.primary
        let name = item.group.displayName
        Task { @MainActor [weak self] in
            let availability = await store.availability(for: url)
            guard let self, !self.didTearDown, self.displayedItem?.group.primary == url else { return }
            guard availability.canRevert, let original = availability.originalRecord else {
                self.contentRoot.toast(ToastContent(BackupNotice.revertNotPossible, kind: .error)); self.refreshInspectorFileState(); return
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
                self.showUndoToast(ToastContent(SaveCopy.reverted(name), actionTitle: "Undo"))
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
        let key = refreshFileMarks(url)
        headerPixelSizes[url] = nil
        headerPixelSizes[key] = nil
        if displayedItem?.group.primary == key { contentRoot.reloadInspectorFile() }
        if let displayed = displayedItem?.group.primary,
           GroupList.canonical(displayed) == GroupList.canonical(url) {
            redrawDisplayedKeepingView(fit: fit)
        } else {
            evictFromDecodeCache(url)
        }
    }

    /// The thumbnail (filmstrip and Browser) and pencil mark of `url`, without touching
    /// what the viewer draws. Returns the list's key for `url`.
    @discardableResult
    func refreshFileMarks(_ url: URL) -> URL {
        let cache = services.thumbnailCache
        // The strip cell asks again once the old thumbnail is gone.
        Task { [weak self] in
            await cache.evict(url: url)
            guard let self else { return }
            await MainActor.run { _ = self.contentRoot.reloadFilmstripThumbnail(for: url, services: self.services) }
        }
        let key = list.index(of: url).flatMap { list[$0]?.primary } ?? url
        refreshBackupState(key)
        pairedBrowser?.fileContentsChanged([url, key])
        return key
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

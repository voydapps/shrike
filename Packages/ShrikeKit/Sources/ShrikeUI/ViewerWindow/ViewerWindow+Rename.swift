//
//  ViewerWindow+Rename.swift
//  ShrikeUI
//
//  Rename in the viewer: F2 / File ▸ Rename… opens the
//  sheet for the displayed group. Success shows no toast (the title
//  changes); the item keeps its place in the list. One undo step.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow {

    func renameDisplayed() {
        guard let item = displayedItem, !contentRoot.isEditModeActive else {
            NSSound.beep()
            return
        }
        let ops = fileOps
        let group = item.group
        let model = RenameSheetModel(group: group, validate: { ops.validate(stem: $0, for: group) })
        Task { @MainActor [weak self] in
            guard let self else { return }
            let stem: String?
            if let responder = self.renameResponderForTesting {
                stem = responder(model)
            } else {
                stem = await RenameSheet(model: model).run(on: self)
            }
            guard let stem, stem != model.oldStem else { return }
            self.rename(group, to: stem, registerUndo: true)
        }
    }

    /// Renames every file of `group`, queued behind other file work.
    func rename(_ group: ImageGroup, to stem: String, registerUndo: Bool) {
        runRename({ group }, { ops in try await ops.renameReporting(group, toStem: stem) }, done: { [weak self] result in
            if registerUndo { self?.registerRenameUndo(RenameStep(result)) }
        })
    }

    /// Undo / Redo of a rename: from its own result (filled in `from` when
    /// the earlier step finished), through this window's `FileOps` (the
    /// earlier-name memory is per instance; relaxed rules). Its result goes
    /// into `into`, which the step already registered on the other stack reads.
    func undoRename(from box: RenameStep, into next: RenameStep) {
        // Read after the earlier step ran (it may still be queued now).
        runRename({ box.shownGroup }, { ops in
            // The earlier step failed: told with the rename failure toast, never silent.
            guard let result = box.result else { throw CancellationError() }
            return try await ops.undoRename(result)
        }, done: { next.result = $0 })
    }

    private func runRename(_ shownGroup: @escaping @MainActor () -> ImageGroup?, _ work: @escaping @MainActor (FileOps) async throws -> RenameResult?,
                           done: @escaping @MainActor (RenameResult) -> Void) {
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            let group = shownGroup()
            do {
                guard let result = try await work(ops) else { return }
                done(result)
                self?.didRename(from: group ?? result.group, to: result.group)
                if let notice = BackupNotice.standaloneToast(lead: BackupNotice.renamed,
                                                             notSaved: result.backupsNotSaved, of: 1) {
                    self?.contentRoot.toast(notice)
                }
            } catch {
                guard let group else { return }
                self?.contentRoot.toast(ToastContent(RenameCopy.failed(group, error: error), kind: .error))
            }
        }
    }

    private func didRename(from old: ImageGroup, to new: ImageGroup) {
        if let index = list.index(of: old.primary) {
            list.replace(at: index, with: new)
            evictFromDecodeCache(old.primary)
            reloadList(showing: intent.currentIndex)
        }
    }

    private func registerRenameUndo(_ step: RenameStep) {
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                // Registered here, while the manager is undoing, so the
                // inverse lands on the redo stack (and the other way round).
                let next = RenameStep(nil, source: step)
                target.registerRenameUndo(next)
                target.undoRename(from: step, into: next)
            }
        }
        windowUndoManager.setActionName("Rename")
    }
}

//
//  BrowserWindowController+Rename.swift
//  ShrikeUI
//
//  Rename in the Browser. One item: the sheet. Several:
//  the Batch window with Rename on.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    func renameSelection() {
        let items = contentController.selectedItems
        guard items.count == 1, let item = items.first else {
            if items.count > 1 { openBatch(renameOn: true) }
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
            } else if let window = self.window {
                stem = await RenameSheet(model: model).run(on: window)
            } else {
                stem = nil
            }
            guard let stem, stem != model.oldStem else { return }
            self.rename(group, to: stem, registerUndo: true)
        }
    }

    /// Photo ▸ Batch… ⌥⌘B, the context menu's "Batch…" and F2 with
    /// several items: the selection, or every listed item
    /// when nothing is selected.
    func openBatch(renameOn: Bool) {
        let selected = contentController.selectedItems
        let items = selected.isEmpty ? contentController.visibleItems : selected
        guard !items.isEmpty else { return }
        BatchWindowController.open(
            groups: items.map(\.group), services: services, launcher: window, renameOn: renameOn,
            originScope: BatchScope.browser(selectedAny: !selected.isEmpty, folderName: currentFolder?.lastPathComponent),
            toast: { [weak self] content in self?.toast(content) })
    }

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
                    self?.toast(notice)
                }
            } catch {
                guard let group else { return }
                self?.toast(RenameCopy.failed(group, error: error), kind: .error)
            }
        }
    }

    /// The item keeps its place (no re-sort) and its culling values.
    private func didRename(from old: ImageGroup, to new: ImageGroup) {
        let all = contentController.allItems
        if let index = all.firstIndex(where: { $0.group.primary == old.primary }),
           var fresh = try? BrowserItem.make(from: new.primary) {
            let previous = all[index]
            fresh.group = new
            fresh.rating = previous.rating
            fresh.isFlagged = previous.isFlagged
            fresh.tags = previous.tags
            fresh.finderTags = previous.finderTags
            fresh.edited = previous.edited
            var items = all
            items[index] = fresh
            contentController.setItems(items)
            _ = contentController.select(url: new.primary)
        }
    }

    private func registerRenameUndo(_ step: RenameStep) {
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                // Registered here, while the manager is undoing, so the
                // inverse lands on the redo stack (and the other way round).
                let next = RenameStep(nil, source: step)
                target.registerRenameUndo(next)
                target.undoRename(from: step, into: next)
            }
        }
        undo.setActionName("Rename")
    }
}

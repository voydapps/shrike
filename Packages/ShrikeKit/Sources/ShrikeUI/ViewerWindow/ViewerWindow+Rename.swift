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
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let renamed = try await ops.rename(group, toStem: stem)
                self?.didRename(from: group, to: renamed, registerUndo: registerUndo)
            } catch {
                self?.contentRoot.toast(ToastContent(RenameCopy.failed(group, error: error), kind: .error))
            }
        }
    }

    private func didRename(from old: ImageGroup, to new: ImageGroup, registerUndo: Bool) {
        if let index = list.index(of: old.primary) {
            list.replace(at: index, with: new)
            evictFromDecodeCache(old.primary)
            reloadList(showing: intent.currentIndex)
        }
        if registerUndo { registerRenameUndo(from: old, to: new) }
    }

    /// The inverse is registered inside the undo so it lands on the redo
    /// stack (and the other way round).
    private func registerRenameUndo(from old: ImageGroup, to new: ImageGroup) {
        let oldStem = old.primary.deletingPathExtension().lastPathComponent
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerRenameUndo(from: new, to: old)
                target.rename(new, to: oldStem, registerUndo: false)
            }
        }
        windowUndoManager.setActionName("Rename")
    }
}

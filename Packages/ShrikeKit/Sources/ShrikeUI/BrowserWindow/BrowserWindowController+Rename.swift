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

    /// Image ▸ Batch… ⌥⌘B, the context menu's "Batch…" and F2 with
    /// several items: the selection, or every listed item
    /// when nothing is selected.
    func openBatch(renameOn: Bool) {
        let selected = contentController.selectedItems
        let items = selected.isEmpty ? contentController.visibleItems : selected
        guard !items.isEmpty else { return }
        BatchWindowController.open(
            groups: items.map(\.group), services: services, launcher: window, renameOn: renameOn,
            toast: { [weak self] message in self?.toast(message, kind: .error) })
    }

    func rename(_ group: ImageGroup, to stem: String, registerUndo: Bool) {
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            do {
                let renamed = try await ops.rename(group, toStem: stem)
                self?.didRename(from: group, to: renamed, registerUndo: registerUndo)
            } catch {
                self?.toast(RenameCopy.failed(group, error: error), kind: .error)
            }
        }
    }

    /// The item keeps its place (no re-sort) and its culling values.
    private func didRename(from old: ImageGroup, to new: ImageGroup, registerUndo: Bool) {
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
        if registerUndo { registerRenameUndo(from: old, to: new) }
    }

    private func registerRenameUndo(from old: ImageGroup, to new: ImageGroup) {
        guard let undo = window?.undoManager else { return }
        let oldStem = old.primary.deletingPathExtension().lastPathComponent
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerRenameUndo(from: new, to: old)
                target.rename(new, to: oldStem, registerUndo: false)
            }
        }
        undo.setActionName("Rename")
    }
}

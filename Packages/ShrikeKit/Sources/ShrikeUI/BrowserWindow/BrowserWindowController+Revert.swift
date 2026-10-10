//
//  BrowserWindowController+Revert.swift
//  ShrikeUI
//
//  File ▸ Revert to Original… in the Browser: acts on the
//  selection when it is ONE item that Shrike edited (pencil badge). Same
//  flow as the viewer: the Revert alert, the original's bytes replace the file
//  (the current bytes are kept first), the thumbnail and a paired viewer
//  refresh, toast "Reverted “x” to the original." · Undo. ⌘Z puts the
//  edited version back.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    /// The one selected item, when Shrike edited it and kept the original.
    var revertableSelection: BrowserItem? {
        let items = contentController.selectedItems
        guard items.count == 1, items[0].edited, items[0].url.isFileURL,
              services.backupStore != nil else { return nil }
        return items[0]
    }

    func revertSelectionToOriginal() {
        guard let item = revertableSelection, let store = services.backupStore else { return }
        let url = item.url
        let name = item.group.displayName
        revertTask = Task { @MainActor [weak self] in
            guard let original = await store.records(for: url).last, let self else { return }
            let title = SaveCopy.revertTitle(name)
            let choice: Int?
            if let responder = self.alertResponderForTesting {
                choice = responder(title)
            } else {
                choice = await ShrikeAlert.run(
                    message: title, information: SaveCopy.revertMessage(original.createdAt),
                    buttons: [.cancel(), ShrikeAlert.Button("Revert", role: .default)], on: self.window
                )
            }
            guard choice == 1 else { return }
            FolderWatcherRegistry.shared.ignore(paths: [url], for: .seconds(2))
            do {
                let preRevert = try await store.revertToOriginal(url)
                self.fileVersionsLanded(urls: [url])
                self.registerFileVersionUndo([(url, FileVersionStep(record: preRevert))],
                                             actionName: "Revert to Original")
                self.toast(SaveCopy.reverted(name), actionTitle: "Undo") { [weak self] in
                    self?.window?.undoManager?.undo()
                }
            } catch {
                self.toast("Couldn't revert “\(name)”.", kind: .error)
            }
        }
    }
}

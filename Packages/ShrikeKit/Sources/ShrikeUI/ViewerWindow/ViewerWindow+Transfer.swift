//
//  ViewerWindow+Transfer.swift
//  ShrikeUI
//
//  Copy and Move to folder in the viewer. The displayed
//  group is snapshotted at the key press. A moved item leaves the list at
//  once, like a trashed one; a copied item stays. The
//  file work runs in press order on `trashChain`. One undo step each.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow {

    func makeTransferCoordinator() -> FileTransferCoordinator {
        let coordinator = FileTransferCoordinator(window: self)
        coordinator.presentAlert = { [weak self] title, info, buttons in
            await self?.presentFileAlert(message: title, information: info, buttons: buttons)
        }
        coordinator.showProgressToast = { [weak self] content in
            self?.contentRoot.toastHost.showProgress(content)
        }
        coordinator.updateProgressToast = { [weak self] content, ticket in
            self?.contentRoot.toastHost.updateProgress(content, matching: ticket)
        }
        coordinator.dismissProgressToast = { [weak self] ticket in
            self?.contentRoot.toastHost.dismissProgress(matching: ticket)
        }
        coordinator.onHUDPick = { [weak self] verb, choice in
            self?.clearChord()
            self?.fileToFolder(verb, choice)
        }
        coordinator.onHUDCancel = { [weak self] in self?.clearChord() }
        return coordinator
    }

    /// `C 1`, `M M`, `C 0`, File ▸ Copy to Folder ▸ … on the displayed item.
    func fileToFolder(_ verb: FileVerb, _ choice: DestinationChoice) {
        guard let item = displayedItem, !contentRoot.isEditModeActive else {
            NSSound.beep()
            return
        }
        let resolution = transfers.resolveNow(choice, verb: verb)
        if case .folder(let folder) = resolution {
            transfer(verb, item.group, to: folder)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let folder = await self.transfers.resolve(resolution) else { return }
            self.transfer(verb, item.group, to: folder)
        }
    }

    /// Runs the copy / move of `group` into `folder`.
    func transfer(_ verb: FileVerb, _ group: ImageGroup, to folder: URL) {
        let source = group.primary.deletingLastPathComponent()
        if GroupList.canonical(source) == GroupList.canonical(folder) {
            contentRoot.toast(ToastContent(FileTransferCopy.alreadyIn([group], folder: folder)))
            return
        }
        transfers.slots.setLast(folder, for: verb)

        var removed: [RemovedGroup] = []
        var current = group
        if verb == .move, let index = list.index(of: group.primary), let listed = list[index] {
            current = listed
            removed = list.remove(primaries: [listed.primary])
            evictFromDecodeCache(listed.primary)
            showAfterRemoval(at: index, folder: source)
        }

        let ops = fileOps
        let coordinator = transfers
        let previous = trashChain
        let groups = [current]
        let task = Task { @MainActor [weak self] in
            await previous?.value
            let outcome = await coordinator.run(verb, groups, to: folder, ops: ops)
            self?.finishTransfer(verb, outcome, folder: folder, removed: removed, fallback: current)
        }
        trashChain = task
        coordinator.runningTask = task
    }

    private func finishTransfer(
        _ verb: FileVerb, _ outcome: FileTransferCoordinator.Outcome,
        folder: URL, removed: [RemovedGroup], fallback: ImageGroup
    ) {
        let done = Set(outcome.items.map { GroupList.canonical($0.source.primary) })
        // Whatever did not move goes back where it was.
        let back = removed.filter { !done.contains(GroupList.canonical($0.group.primary)) }
        if !back.isEmpty { reinsert(back) }

        guard let receipt = outcome.receipt, !receipt.isEmpty else {
            if let failure = outcome.failures.first {
                contentRoot.toast(ToastContent(
                    FileTransferCopy.failed(verb, failure.group, folder: folder, error: failure.error), kind: .error))
            } else if let error = outcome.error {
                contentRoot.toast(ToastContent(
                    FileTransferCopy.failed(verb, fallback, folder: folder, error: error), kind: .error))
            } else if outcome.cancelled {
                contentRoot.toast(ToastContent(FileTransferCopy.cancelled(verb, done: 0, total: outcome.total)))
            } else if outcome.skipped.contains(where: { $0.reason == .alreadyInFolder }) {
                contentRoot.toast(ToastContent(FileTransferCopy.alreadyIn([fallback], folder: folder)))
            }
            // A skipped name clash was the user's choice: nothing to say.
            return
        }

        let moved = removed.filter { done.contains(GroupList.canonical($0.group.primary)) }
        registerTransferUndo(receipt, removed: moved)
        let text = outcome.cancelled
            ? FileTransferCopy.cancelled(verb, done: receipt.items.count, total: outcome.total)
            : FileTransferCopy.done(verb, receipt.items.map(\.source), folder: folder)
        contentRoot.toast(ToastContent(text, actionTitle: "Undo")) { [weak self] in
            self?.performUndo()
        }
    }

    private func registerTransferUndo(_ receipt: FileOpReceipt, removed: [RemovedGroup]) {
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.undoTransfer(receipt, removed: removed) }
        }
        windowUndoManager.setActionName(receipt.kind == .copy ? "Copy" : "Move")
    }

    /// Copy: the copies go to the Trash. Move: the files go back and the
    /// item returns to its old place in the list.
    func undoTransfer(_ receipt: FileOpReceipt, removed: [RemovedGroup]) {
        windowUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.redoTransfer(receipt) }
        }
        windowUndoManager.setActionName(receipt.kind == .copy ? "Copy" : "Move")
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            var failure: (any Error)?
            do { try await ops.undo(receipt) } catch { failure = error }
            guard let self else { return }
            if receipt.kind == .move {
                let home = removed.filter { FileManager.default.fileExists(atPath: $0.group.primary.path) }
                if !home.isEmpty { self.reinsert(home) }
            }
            if let failure {
                self.contentRoot.toast(ToastContent(
                    FileTransferCopy.undoFailed(failure, folder: receipt.destination), kind: .error))
            }
        }
    }

    private func redoTransfer(_ receipt: FileOpReceipt) {
        let verb: FileVerb = receipt.kind == .copy ? .copy : .move
        for item in receipt.items {
            let group = list.index(of: item.source.primary).flatMap { list[$0] } ?? item.source
            transfer(verb, group, to: receipt.destination)
        }
    }

    /// Waits for queued trashes, copies and moves (tests).
    func waitForPendingFileWork() async {
        while let task = trashChain {
            await task.value
            if trashChain == task { break }
        }
    }
}

//
//  BrowserWindowController+Transfer.swift
//  ShrikeUI
//
//  Copy and Move to folder in the Browser. The selection
//  is snapshotted at the key press and goes as one action: one toast, one
//  undo step. Moved items leave the list; the selection moves on.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    func makeTransferCoordinator() -> FileTransferCoordinator {
        let coordinator = FileTransferCoordinator(window: window)
        coordinator.presentAlert = { [weak self] title, info, buttons in
            guard let self else { return nil }
            if let responder = self.alertResponderForTesting { return responder(title) }
            return await ShrikeAlert.run(message: title, information: info, buttons: buttons, on: self.window)
        }
        // Progress shares the result's band above the photos, so it never
        // covers a file name.
        coordinator.showProgressToast = { [weak self] content in self?.showTransferProgress(content) }
        coordinator.updateProgressToast = { [weak self] content, ticket in
            self?.updateTransferProgress(content, matching: ticket)
        }
        coordinator.dismissProgressToast = { [weak self] ticket in
            self?.dismissTransferProgress(matching: ticket)
        }
        coordinator.onHUDPick = { [weak self] verb, choice in
            self?.clearChord()
            self?.fileToFolder(verb, choice)
        }
        coordinator.onHUDCancel = { [weak self] in self?.clearChord() }
        return coordinator
    }

    /// `C 1`, `M M`, … on the selection.
    func fileToFolder(_ verb: FileVerb, _ choice: DestinationChoice) {
        let groups = contentController.selectedItems.map(\.group)
        guard !groups.isEmpty else {
            NSSound.beep()
            return
        }
        let resolution = transfers.resolveNow(choice, verb: verb)
        if case .folder(let folder) = resolution {
            transfer(verb, groups, to: folder)
            return
        }
        Task { @MainActor [weak self] in
            guard let self, let folder = await self.transfers.resolve(resolution) else { return }
            self.transfer(verb, groups, to: folder)
        }
    }

    func transfer(_ verb: FileVerb, _ groups: [ImageGroup], to folder: URL) {
        let target = GroupList.canonical(folder)
        let work = groups.filter {
            GroupList.canonical($0.primary.deletingLastPathComponent()) != target
        }
        guard !work.isEmpty else {
            toast(FileTransferCopy.alreadyIn(groups, folder: folder))
            return
        }
        transfers.slots.setLast(folder, for: verb)
        let next = verb == .move
            ? Self.selectionAfterRemoving(work.map(\.primary), from: contentController.visibleItems.map(\.url))
            : nil
        let ops = fileOps
        let coordinator = transfers
        let previous = trashChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            let outcome = await coordinator.run(verb, work, to: folder, ops: ops)
            self?.finishTransfer(verb, outcome, folder: folder, next: next, fallback: work[0])
        }
        trashChain = task
    }

    private func finishTransfer(
        _ verb: FileVerb, _ outcome: FileTransferCoordinator.Outcome, folder: URL, next: URL?,
        fallback: ImageGroup
    ) {
        if verb == .move, !outcome.items.isEmpty {
            removeFromList(Set(outcome.items.map(\.source.primary)), next: next)
        }
        if let failure = outcome.failures.first {
            toast(FileTransferCopy.failed(verb, failure.group, folder: folder, error: failure.error), kind: .error)
        } else if outcome.items.isEmpty, let error = outcome.error {
            toast(FileTransferCopy.failed(verb, fallback, folder: folder, error: error), kind: .error)
        }
        guard let receipt = outcome.receipt, !receipt.isEmpty else {
            if outcome.cancelled {
                toast(FileTransferCopy.cancelled(verb, done: 0, total: outcome.total))
            }
            return
        }
        if let undo = window?.undoManager {
            undo.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.undoTransfer(receipt) }
            }
            undo.setActionName(receipt.kind == .copy ? "Copy" : "Move")
        }
        if outcome.failures.isEmpty {
            let text = outcome.cancelled
                ? FileTransferCopy.cancelled(verb, done: receipt.items.count, total: outcome.total)
                : FileTransferCopy.done(verb, receipt.items.map(\.source), folder: folder)
            showTransferNotice(text) { [weak self] in
                self?.window?.undoManager?.undo()
            }
        }
    }

    func undoTransfer(_ receipt: FileOpReceipt) {
        if let undo = window?.undoManager {
            undo.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.redoTransfer(receipt) }
            }
            undo.setActionName(receipt.kind == .copy ? "Copy" : "Move")
        }
        let ops = fileOps
        let previous = trashChain
        trashChain = Task { @MainActor [weak self] in
            await previous?.value
            var failure: (any Error)?
            do { try await ops.undo(receipt) } catch { failure = error }
            guard let self else { return }
            if receipt.kind == .move, let folder = self.currentFolder {
                self.follow(folder: folder, selecting: receipt.items.first?.source.primary)
            }
            if let failure {
                self.toast(FileTransferCopy.undoFailed(failure, folder: receipt.destination), kind: .error)
            }
        }
    }

    private func redoTransfer(_ receipt: FileOpReceipt) {
        transfer(receipt.kind == .copy ? .copy : .move, receipt.items.map(\.source), to: receipt.destination)
    }

    /// Waits for queued trashes, copies and moves (tests).
    func waitForPendingFileWork() async {
        while let task = trashChain {
            await task.value
            if trashChain == task { break }
        }
    }
}

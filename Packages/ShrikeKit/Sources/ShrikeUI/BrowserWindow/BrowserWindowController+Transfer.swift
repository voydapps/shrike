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
        coordinator.ownsProgressToast = { [weak self] ticket in self?.ownsTransferProgress(ticket) ?? false }
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
        let coordinator = transfers
        Task { @MainActor [weak self] in
            // Reserved in the panel's OK turn: ⌘Q right after asks.
            let box = ReservationBox()
            let folder = await coordinator.resolve(resolution) { _ in
                box.reservation = coordinator.reserveShowingProgress(verb, total: groups.count)
            }
            guard let self, let folder else { FileTransferCoordinator.release(box.reservation); return }
            self.transfer(verb, groups, to: folder, reservation: box.reservation)
        }
    }

    /// `canonical`: resolves a folder path through symbolic links (a disk
    /// call per path component). Run for every photo on the
    /// main thread, it froze the window ~2 s after Choose for 2000 photos; it
    /// now runs off the main thread, once per parent folder, and only for
    /// photos a plain path comparison cannot settle. Test seam.
    func transfer(_ verb: FileVerb, _ groups: [ImageGroup], to folder: URL,
                  reservation: FileTransferCoordinator.TransferReservation? = nil,
                  canonical: @escaping @Sendable (URL) -> String = { GroupList.canonical($0) }) {
        // Disk-free: every photo already sits in the folder by its plain path.
        let plainTarget = folder.standardizedFileURL.path
        if groups.allSatisfy({ $0.primary.deletingLastPathComponent().standardizedFileURL.path == plainTarget }) {
            FileTransferCoordinator.release(reservation)
            toast(FileTransferCopy.alreadyIn(groups, folder: folder))
            return
        }
        // Counts as running from here, with the selection count, while it
        // waits for earlier work; `run` corrects the total.
        let reserved = reservation ?? transfers.reserveShowingProgress(verb, total: groups.count)
        transfers.slots.setLast(folder, for: verb)
        let visible = verb == .move ? contentController.visibleItems.map(\.url) : []
        let ops = fileOps
        let coordinator = transfers
        let previous = trashChain
        let task = Task { @MainActor [weak self] in
            await previous?.value
            let work = await Task.detached(priority: .userInitiated) {
                Self.transferWork(groups, to: folder, canonical: canonical)
            }.value
            guard let first = work.first else {
                FileTransferCoordinator.release(reserved)
                self?.toast(FileTransferCopy.alreadyIn(groups, folder: folder))
                return
            }
            let next = verb == .move ? Self.selectionAfterRemoving(work.map(\.primary), from: visible) : nil
            let outcome = await coordinator.run(verb, work, to: folder, ops: ops, reservation: reserved)
            self?.finishTransfer(verb, outcome, folder: folder, next: next, fallback: first)
        }
        trashChain = task
    }

    /// The photos not already in `folder` (compared through symbolic
    /// links). Disk calls: call it off the main thread. One `canonical`
    /// call per distinct parent folder.
    nonisolated static func transferWork(_ groups: [ImageGroup], to folder: URL,
                                         canonical: (URL) -> String) -> [ImageGroup] {
        let target = canonical(folder)
        var parents: [String: Bool] = [:]
        return groups.filter { group in
            let parent = group.primary.deletingLastPathComponent()
            let key = parent.standardizedFileURL.path
            if let inside = parents[key] { return !inside }
            let inside = canonical(parent) == target
            parents[key] = inside
            return !inside
        }
    }

    private func finishTransfer(
        _ verb: FileVerb, _ outcome: FileTransferCoordinator.Outcome, folder: URL, next: URL?,
        fallback: ImageGroup
    ) {
        if verb == .move, !outcome.items.isEmpty {
            removeFromList(Set(outcome.items.map(\.source.primary)), next: next)
        }
        if let failure = outcome.failures.first {
            // With failures there is no band; the error toast carries the
            // count of the LAST receipt instead (never read twice).
            let lost = outcome.receipt?.backupsNotSaved ?? 0
            toast(BackupNotice.appending(
                to: FileTransferCopy.failed(verb, failure.group, folder: folder, error: failure.error),
                notSaved: lost, of: max(outcome.items.count, 1), leadNamesPhotos: false), kind: .error)
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
        let mark = window?.undoManager.map(undoTopMark.stamp)
        if outcome.failures.isEmpty {
            let text = outcome.cancelled
                ? FileTransferCopy.cancelled(verb, done: receipt.items.count, total: outcome.total)
                : FileTransferCopy.done(verb, receipt.items.map(\.source), folder: folder)
            let opening = FileTransferCopy.opening(text, cancelled: outcome.cancelled,
                                                   replacedPhotos: FileTransferCopy.replacedPhotos(receipt),
                                                   extraFilesTrashed: receipt.extraFilesTrashed)
            // The count of the LAST progress receipt.
            let line = FileTransferCopy.resultLine(opening, backupsNotSaved: receipt.backupsNotSaved,
                                                   of: receipt.items.count, extraFilesTrashed: receipt.extraFilesTrashed)
            showTransferNotice(line) { [weak self] in
                // Only this copy / move; a later change is undone from Edit ▸ Undo.
                guard let self, let mark else { return }
                self.undoTopMark.undo(mark, on: self.window?.undoManager)
            }
            // A later change disables this notice's Undo (Edit ▸ Undo names it).
            undoTopMark.onChange = { [weak self] in
                guard let self, self.transferNotice.message == line, self.transferNotice.buttonTitles == ["Undo"]
                else { return }
                self.transferNotice.disableButtons()
                self.undoTopMark.onChange = nil
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
            var notSaved = 0
            do { notSaved = try await ops.undo(receipt) } catch { failure = error }
            guard let self else { return }
            if receipt.kind == .move, let folder = self.currentFolder {
                self.follow(folder: folder, selecting: receipt.items.first?.source.primary)
            }
            if let failure {
                self.toast(BackupNotice.appending(to: FileTransferCopy.undoFailed(failure, folder: receipt.destination),
                                                  notSaved: notSaved, of: receipt.items.count, leadNamesPhotos: false), kind: .error)
            } else if let notice = BackupNotice.standaloneToast(lead: nil, notSaved: notSaved, of: receipt.items.count) {
                self.toast(notice)
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

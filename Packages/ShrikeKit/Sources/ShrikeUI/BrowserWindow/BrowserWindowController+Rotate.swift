//
//  BrowserWindowController+Rotate.swift
//  ShrikeUI
//
//  Rotate / flip the Browser selection ("Browser: rotates
//  the selection"). Same rules as the viewer: lossless EXIF / PNG writes
//  500 ms after the last press, presses add up, view-only types are left
//  alone with a toast. The whole selection is one undo step.
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// Presses waiting for their write: one set of files, the ops in order.
struct BrowserPendingOrientation: Equatable {
    let urls: [URL]
    var ops: [OrientationOp]
    var net: ExifOrientation { ops.reduce(.up) { $0.applying($1) } }
}

extension BrowserWindowController {

    /// ⌘L / ⌘R / ⇧⌘R and the flips on the selection.
    func orientSelection(_ op: OrientationOp) {
        let urls = contentController.selectedItems.map(\.url).filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        Culling.announce(RotateCopy.announcement(op))
        let writable = services.backupStore == nil ? [] : urls.filter { LosslessRotator.isSupported($0) }
        if writable.count < urls.count {
            if case .rotate = op { toast(RotateCopy.browserSkipped) } else { toast(RotateCopy.browserSkippedFlip) }
        }
        guard !writable.isEmpty else { return }
        if var pending = pendingOrientation, pending.urls == writable {
            pending.ops.append(op)
            pendingOrientation = pending
        } else {
            flushPendingOrientation()
            pendingOrientation = BrowserPendingOrientation(urls: writable, ops: [op])
        }
        orientationTimer?.cancel()
        orientationTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: ViewerWindow.orientationWriteDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingOrientation()
        }
    }

    /// Writes the pending presses now (timer, folder change, quit).
    func flushPendingOrientation() {
        orientationTimer?.cancel()
        orientationTimer = nil
        guard let pending = pendingOrientation else { return }
        pendingOrientation = nil
        let writes = ViewerWindow.writeOps(for: pending.net)
        guard !writes.isEmpty, let store = services.backupStore else { return }
        let rotator = LosslessRotator(backupStore: store)
        let previous = orientationWriteChain
        let allFlips = pending.ops.allSatisfy { if case .rotate = $0 { return false }; return true }
        orientationWriteChain = Task { @MainActor [weak self] in
            await previous?.value
            self?.watcherScope.ignore(paths: pending.urls, for: .seconds(2))
            var steps: [(URL, FileVersionStep)] = []
            var failed: [URL] = []
            for url in pending.urls {
                var results: [LosslessRotateResult] = []
                do {
                    for op in writes { results.append(try await rotator.apply(op, to: url)) }
                    steps.append((url, FileVersionStep(record: results[0].backup)))
                } catch {
                    if let first = results.first { try? await rotator.undo(first) }
                    failed.append(url)
                }
            }
            guard let self else { return }
            self.fileVersionsLanded(urls: steps.map(\.0))
            if !steps.isEmpty {
                self.registerFileVersionUndo(steps, actionName: allFlips ? "Flip" : "Rotate")
            }
            if let first = failed.first {
                self.toast(RotateCopy.failed(first.lastPathComponent), kind: .error)
            }
        }
    }

    /// Waits for every pending and running write (tests, quit).
    func waitForOrientationWrites() async {
        flushPendingOrientation()
        await orientationWriteChain?.value
    }

    var hasPendingOrientationWrites: Bool { pendingOrientation != nil || orientationWriteChain != nil }

    /// Thumbnails (and a paired viewer) refresh when the writes land
    /// (rotate, flip, revert, and their undo).
    func fileVersionsLanded(urls: [URL]) {
        guard !urls.isEmpty else { return }
        photoInfoCache.invalidate(urls)
        let cache = services.thumbnailCache
        Task { @MainActor [weak self] in
            for url in urls { await cache.evict(url: url) }
            self?.fileContentsChanged(urls)
        }
        for url in urls { pairedViewer?.didChangeFileOnDisk(url, fit: false) }
    }

    /// One undo step for the whole selection: restore every kept copy.
    /// Each restore returns the record redo needs.
    func registerFileVersionUndo(_ steps: [(URL, FileVersionStep)], actionName: String) {
        guard let undo = window?.undoManager else { return }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                let inverse = steps.map { ($0.0, FileVersionStep()) }
                target.registerFileVersionUndo(inverse, actionName: actionName)
                target.restoreVersions(from: steps, into: inverse)
            }
        }
        undo.setActionName(actionName)
    }

    private func restoreVersions(from steps: [(URL, FileVersionStep)], into inverse: [(URL, FileVersionStep)]) {
        guard let store = services.backupStore else { return }
        let previous = orientationWriteChain
        let urls = steps.map(\.0)
        let task = Task { @MainActor [weak self] in
            await previous?.value
            self?.watcherScope.ignore(paths: urls, for: .seconds(2))
            var failedName: String?
            for ((url, step), (_, out)) in zip(steps, inverse) {
                await step.task?.value
                guard let record = step.record else { failedName = url.lastPathComponent; continue }
                do { out.record = try await store.restore(record) } catch { failedName = url.lastPathComponent }
            }
            self?.fileVersionsLanded(urls: urls)
            if let failedName { self?.toast(SaveCopy.undoFailed(failedName), kind: .error) }
        }
        for (_, out) in inverse { out.task = task }
        orientationWriteChain = task
    }
}

//
//  ViewerWindow+Rotate.swift
//  ShrikeUI
//
//  One rotate concept on top of the file
//  rotate:
//
//  * The view turns at once. JPEG / HEIC / TIFF get a new EXIF
//    orientation and PNG rotated pixels (`LosslessRotator`), written
//    500 ms after the last press on that file, or at once on navigation
//    and window close. Presses add up; a net-zero turn writes nothing.
//  * No toast on success; "Undo Rotate" / "Undo Flip" put the backed-up
//    bytes back.
//  * Types that can't be written (RAW, GIF, WebP, …) turn for viewing
//    only, with a once-per-window toast; the turn resets on navigation.
//  * Pairs: only the display file is written; the RAW never is.
//

import AppKit
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// Presses waiting to be written to one file.
struct PendingOrientation: Equatable {
    let url: URL
    var ops: [OrientationOp]

    /// The net turn of all presses (identity = no write).
    var net: ExifOrientation { ops.reduce(.up) { $0.applying($1) } }
}

enum RotateCopy {
    static let viewOnlyRotate =
        "Rotated for viewing only. This file type can't be rotated without re-encoding, so the file wasn't changed."
    static let viewOnlyFlip =
        "Flipped for viewing only. This file type can't be flipped without re-encoding, so the file wasn't changed."
    /// Browser selection with some view-only types (they are skipped).
    static let browserSkipped =
        "Some files weren't rotated. Their file type can't be rotated without re-encoding."
    static let browserSkippedFlip =
        "Some files weren't flipped. Their file type can't be flipped without re-encoding."
    static func failed(_ name: String) -> String { "Couldn't rotate “\(name)”. The file wasn't changed." }

    static func announcement(_ op: OrientationOp) -> String {
        switch op {
        case .rotate(let q):
            switch ((q % 4) + 4) % 4 {
            case 1: return "Rotated right"
            case 3: return "Rotated left"
            default: return "Rotated 180 degrees"
            }
        case .flipHorizontal: return "Flipped horizontally"
        case .flipVertical: return "Flipped vertically"
        }
    }
}

extension ViewerWindow {

    /// Quiet period before a rotate is written.
    static var orientationWriteDelay: Duration = .milliseconds(500)

    /// The fewest writes that give `net`: one op for a pure turn or flip,
    /// flip + turn for a mixed one, none for the identity.
    static func writeOps(for net: ExifOrientation) -> [OrientationOp] {
        var candidates: [[OrientationOp]] = [[]]
        candidates += (1...3).map { [.rotate(quarters: $0)] }
        candidates += [[.flipHorizontal], [.flipVertical]]
        candidates += (1...3).map { [.flipHorizontal, .rotate(quarters: $0)] }
        return candidates.first { $0.reduce(ExifOrientation.up) { $0.applying($1) } == net } ?? []
    }

    /// ⌘L / ⌘R / ⇧⌘R, flips, the toolbar, the context menu (outside edit
    /// mode). Turns the view now; schedules the file write.
    func orientFile(_ op: OrientationOp) {
        guard !contentRoot.isEditModeActive, contentRoot.imageView.image != nil else { return }
        applyToView(op)
        Culling.announce(RotateCopy.announcement(op))
        guard let url = displayedItem?.group.primary, url.isFileURL else { return }

        guard services.backupStore != nil, orientationSupported(url) else {
            let copy: String
            if case .rotate = op { copy = RotateCopy.viewOnlyRotate } else { copy = RotateCopy.viewOnlyFlip }
            if !shownOnceToasts.contains(copy) {
                shownOnceToasts.insert(copy)
                contentRoot.toast(ToastContent(copy))
            }
            return
        }
        if var pending = pendingOrientation, pending.url == url {
            pending.ops.append(op)
            pendingOrientation = pending
        } else {
            flushPendingOrientation()
            pendingOrientation = PendingOrientation(url: url, ops: [op])
        }
        orientationTimer?.cancel()
        orientationTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.orientationWriteDelay)
            guard !Task.isCancelled else { return }
            self?.flushPendingOrientation()
        }
    }

    private func orientationSupported(_ url: URL) -> Bool {
        if let known = orientationSupport[url] { return known }
        let supported = LosslessRotator.isSupported(url)
        orientationSupport[url] = supported
        return supported
    }

    private func applyToView(_ op: OrientationOp) {
        let view = contentRoot.imageView
        switch op {
        case .rotate(let q): view.rotateBy(degrees: Double(q) * 90)
        case .flipHorizontal: view.flipHorizontal()
        case .flipVertical: view.flipVertical()
        }
        // The photo's corner moved: the LIVE badge follows.
        contentRoot.layoutLiveBadge()
    }

    private static func inverse(_ op: OrientationOp) -> OrientationOp {
        if case .rotate(let q) = op { return .rotate(quarters: -q) }
        return op
    }

    /// Writes the pending presses now (timer, navigation, close).
    func flushPendingOrientation() {
        orientationTimer?.cancel()
        orientationTimer = nil
        guard let pending = pendingOrientation else { return }
        pendingOrientation = nil
        let writes = Self.writeOps(for: pending.net)
        guard !writes.isEmpty, let store = services.backupStore else { return }
        let rotator = LosslessRotator(backupStore: store)
        let url = pending.url
        let previous = orientationWriteChain
        orientationWriteChain = Task { @MainActor [weak self] in
            await previous?.value
            FolderWatcherRegistry.shared.ignore(paths: [url], for: .seconds(2))
            var results: [LosslessRotateResult] = []
            do {
                for op in writes { results.append(try await rotator.apply(op, to: url)) }
                self?.orientationWriteLanded(url: url, first: results[0], ops: pending.ops)
            } catch {
                if let first = results.first { try? await rotator.undo(first) }
                self?.orientationWriteFailed(url: url, ops: pending.ops)
            }
        }
    }

    /// Waits for every pending and running orientation write (tests).
    func waitForOrientationWrites() async {
        flushPendingOrientation()
        await orientationWriteChain?.value
    }

    private func orientationWriteLanded(url: URL, first: LosslessRotateResult, ops: [OrientationOp]) {
        // The view already shows the turn: evict so the next visit
        // decodes the new orientation; no redraw now.
        let cache = services.thumbnailCache
        Task { await cache.evict(url: url) }
        evictFromDecodeCache(url)
        let key = list.index(of: url).flatMap { list[$0]?.primary } ?? url
        refreshBackupState(key)
        pairedBrowser?.reloadCurrentFolder()
        let allFlips = ops.allSatisfy { if case .rotate = $0 { return false }; return true }
        registerVersionUndo(url: url, step: FileVersionStep(record: first.backup),
                            actionName: allFlips ? "Flip" : "Rotate", undoToast: nil, redoToast: nil)
    }

    private func orientationWriteFailed(url: URL, ops: [OrientationOp]) {
        if let displayed = displayedItem?.group.primary,
           GroupList.canonical(displayed) == GroupList.canonical(url) {
            for op in ops.reversed() { applyToView(Self.inverse(op)) }
        }
        contentRoot.toast(ToastContent(RotateCopy.failed(url.lastPathComponent), kind: .error))
    }
}

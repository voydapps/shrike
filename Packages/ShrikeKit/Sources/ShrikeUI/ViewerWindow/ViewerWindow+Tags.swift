//
//  ViewerWindow+Tags.swift
//  ShrikeUI
//
//  `T` / File ▸ Tags… / the context menu in the viewer:
//  the Tags popover on the displayed group, anchored on the position
//  pill. One undo step per popover session; the pill (and a paired
//  Browser's cell) re-read the tags after every write.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow {

    /// Opens the Tags popover on the displayed item. Returns the session
    /// (tests drive it directly).
    @discardableResult
    func showTagEditor(anchor inspectorRow: NSView? = nil) -> TagEditSession? {
        guard let session = makeTagSession() else {
            NSSound.beep()
            return nil
        }
        if let presenter = tagPopoverPresenterForTesting {
            presenter(session)
            return session
        }
        let controller = TagsPopoverController(session: session)
        if let inspectorRow, inspectorRow.window != nil {
            controller.present(relativeTo: inspectorRow.bounds, of: inspectorRow, edge: .minX)
            return session
        }
        let pill = contentRoot.positionPillView
        let anchor: NSView = pill.isHidden || pill.window == nil ? contentRoot : pill
        let rect = anchor === pill ? pill.bounds
            : NSRect(x: contentRoot.bounds.midX - 1, y: 24, width: 2, height: 2)
        controller.present(relativeTo: rect, of: anchor, edge: .maxY)
        return session
    }

    /// The inspector's tag chip remove button: one
    /// undo step.
    @discardableResult
    func removeTagFromDisplayed(_ name: String) -> TagEditSession? {
        guard let session = makeTagSession() else {
            NSSound.beep()
            return nil
        }
        session.remove([name])
        return session
    }

    private func makeTagSession() -> TagEditSession? {
        guard let item = displayedItem, !contentRoot.isEditModeActive else { return nil }
        return TagEditSession(
            groups: [item.group], undoManager: windowUndoManager,
            onChange: { [weak self] primaries in self?.tagsDidChange(primaries) },
            onError: { [weak self] line in
                self?.contentRoot.toast(ToastContent(line, kind: .error))
            }
        )
    }

    /// Tags written (or undone): refresh the pill and the paired Browser.
    func tagsDidChange(_ primaries: [URL]) {
        refreshTags(for: primaries)
        pairedBrowser?.refreshTags(for: primaries)
    }
}

//
//  BrowserWindowController+Tags.swift
//  ShrikeUI
//
//  `T` / File ▸ Tags… in the Browser: the Tags popover on
//  the selection, anchored on the selected cell. Several items: tokens
//  are the tags all items share, colours some items have are half
//  filled; a click sets that colour on all. One undo step per session.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    /// Opens the Tags popover on the selection (snapshot at the press),
    /// anchored on `anchor` (the inspector's Tags row) or the selected cell.
    @discardableResult
    func showTagEditor(anchor: NSView? = nil) -> TagEditSession? {
        guard let session = makeTagSession() else {
            NSSound.beep()
            return nil
        }
        if let presenter = tagPopoverPresenterForTesting {
            presenter(session)
            return session
        }
        let controller = TagsPopoverController(session: session)
        let view = anchor ?? contentController.anchorForSelection()
        controller.present(relativeTo: view.bounds, of: view, edge: anchor == nil ? .maxY : .minX)
        return session
    }

    /// A tag chip's ⓧ in the inspector: removes `name` from
    /// every selected item that has it, one undo step, through the same
    /// session and writer as the popover.
    @discardableResult
    func removeTagFromSelection(_ name: String) -> TagEditSession? {
        guard let session = makeTagSession() else {
            NSSound.beep()
            return nil
        }
        session.remove([name])
        return session
    }

    private func makeTagSession() -> TagEditSession? {
        let items = contentController.selectedItems
        guard !items.isEmpty else { return nil }
        return TagEditSession(
            groups: items.map(\.group), undoManager: window?.undoManager,
            onChange: { [weak self] primaries in
                self?.refreshTags(for: primaries)
                self?.pairedViewer?.refreshTags(for: primaries)
            },
            onError: { [weak self] line in self?.toast(line, kind: .error) }
        )
    }

    /// Re-reads the Finder tags of `urls` into their cells and the
    /// inspector (after a tag edit, an undo, or a watcher event).
    func refreshTags(for urls: [URL]) {
        var values: [URL: [FinderTag]] = [:]
        for url in urls { values[url] = FinderTags.readWithColors(url) }
        contentController.applyTags(values)
        updateInspectorFromSelection()
    }
}

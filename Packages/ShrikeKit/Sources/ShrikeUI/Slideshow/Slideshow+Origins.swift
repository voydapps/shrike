//
//  Slideshow+Origins.swift
//  ShrikeUI
//
//  F5 / View ▸ Slideshow… from the viewer and the Browser:
//  the sheet, the start item, and where each lands on exit.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension ViewerWindow: SlideshowOrigin {

    var slideshowUndoManager: UndoManager? { windowUndoManager }
    var slideshowWatcherScope: (any FolderChangeSuppressing)? { watcherScope }

    func slideshowDidChangeCulling(_ values: [URL: FileRecord]) {
        cullingDidChange(values)
    }

    func slideshowDidEnd(lastShown: ImageGroup?, finished: Bool) {
        if let group = lastShown, let index = list.index(of: group.primary),
           index != displayedItem?.listIndex {
            coalesceNav { [weak self] in await self?.navigate(to: index) }
        }
        if isVisible { makeKeyAndOrderFront(nil) }
        if finished { contentRoot.toast("Slideshow finished.") }
    }

    /// Starts at the displayed image.
    func startSlideshow() {
        guard !list.isEmpty else { return }
        let scope = SlideshowScope(allCount: list.count,
                                   folderName: displayedFolder?.lastPathComponent ?? "",
                                   selectedCount: 0)
        SlideshowSheet.present(on: self, scope: scope) { [weak self] request in
            guard let self, let request else { return }
            let controller = SlideshowController(
                groups: self.list.groups, start: self.displayedItem?.listIndex ?? 0,
                settings: request.settings, services: self.services, origin: self)
            controller.start(on: self.screen)
        }
    }
}

extension BrowserWindowController: SlideshowOrigin {

    var slideshowUndoManager: UndoManager? { window?.undoManager }
    var slideshowWatcherScope: (any FolderChangeSuppressing)? { watcherScope }

    func slideshowDidChangeCulling(_ values: [URL: FileRecord]) {
        cullingDidChange(values)
    }

    func slideshowDidEnd(lastShown: ImageGroup?, finished: Bool) {
        if let group = lastShown { select(url: group.primary) }
        window?.makeKeyAndOrderFront(nil)
        if finished { toast("Slideshow finished.") }
    }

    /// Starts at the first selected item (or the first item); "The N
    /// selected images" plays only the selection.
    func startSlideshow() {
        let all = contentController.visibleItems.map(\.group)
        guard !all.isEmpty else { return }
        let selected = contentController.selectedItems
        let scope = SlideshowScope(allCount: all.count,
                                   folderName: currentFolder?.lastPathComponent ?? "",
                                   selectedCount: selected.count)
        SlideshowSheet.present(on: window, scope: scope) { [weak self] request in
            guard let self, let request else { return }
            let groups = request.selectedOnly ? selected.map(\.group) : all
            let start = request.selectedOnly ? 0
                : (selected.first.flatMap { first in all.firstIndex { $0.primary == first.url } } ?? 0)
            let controller = SlideshowController(
                groups: groups, start: start, settings: request.settings,
                services: self.services, origin: self)
            controller.start(on: self.window?.screen)
        }
    }
}

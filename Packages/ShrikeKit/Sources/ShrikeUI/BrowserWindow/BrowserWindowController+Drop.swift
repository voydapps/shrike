//
//  BrowserWindowController+Drop.swift
//  ShrikeUI
//
//  Files dropped on the Browser content area. A folder
//  opens; images open their folder with the dropped images selected.
//  Nothing is copied. Whether a dropped item is a folder is read off the
//  main thread.
//

import AppKit
import ShrikeCore

extension BrowserWindowController {

    func handleContentDrop(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        contentDropTask = Task { @MainActor [weak self] in
            let drop = await Task.detached(priority: .userInitiated) {
                BrowserDropRules.resolveContentDrop(urls)
            }.value
            guard let self, let drop else { return }
            self.applyContentDrop(drop)
        }
    }

    func applyContentDrop(_ drop: BrowserDropRules.ContentDrop) {
        // Like a sidebar pick: a new folder starts without a search.
        clearSearchForNewFolder()
        switch drop {
        case .folder(let folder):
            navigate(to: folder)
        case .images(let folder, let files):
            pendingDropSelection = files
            navigate(to: folder)
        }
    }
}

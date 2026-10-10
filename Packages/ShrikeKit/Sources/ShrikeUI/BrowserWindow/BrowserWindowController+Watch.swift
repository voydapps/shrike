//
//  BrowserWindowController+Watch.swift
//  ShrikeUI
//
//  File watching in the Browser: the listed folder is
//  watched with `FolderWatcher` (batched, 200 ms debounce). Added,
//  removed and renamed files list the folder again with the selection
//  kept; modified files drop their cached thumbnail first. Shrike's own
//  trash / move / rename / save are ignored: `FileOps` tells
//  `FolderWatcherRegistry` about its own paths for 1 s. The folder itself
//  going away shows "“Italy 2026” is no longer available."
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    /// Starts watching `folder` (no-op when it is already watched).
    func startWatching(_ folder: URL) {
        if let watcher = folderWatcher, GroupList.canonical(watcher.folder) == GroupList.canonical(folder) {
            return
        }
        stopWatching()
        guard let watcher = try? FolderWatcher(folder: folder) else { return }
        FolderWatcherRegistry.shared.register(watcher)
        folderWatcher = watcher
        folderWatchTask = Task { @MainActor [weak self] in
            for await change in watcher.changes {
                guard let self else { return }
                self.handleFolderChange(change, in: watcher.folder)
            }
        }
    }

    func stopWatching() {
        folderWatchTask?.cancel()
        folderWatchTask = nil
        if let watcher = folderWatcher {
            watcher.stop()
            FolderWatcherRegistry.shared.unregister(watcher)
        }
        folderWatcher = nil
    }

    /// One batch of outside changes to `folder`.
    func handleFolderChange(_ change: FolderChange, in folder: URL) {
        guard let current = currentFolder,
              GroupList.canonical(current) == GroupList.canonical(folder) else { return }
        if change.folderEvent != nil {
            showFolderGone(folder)
            return
        }
        guard !change.isEmpty else { return }
        // A header read of a changed file is stale.
        photoInfoCache.invalidate(change.modified + change.removed + change.renamed.flatMap { [$0.from, $0.to] })
        let cache = services.thumbnailCache
        let modified = change.modified
        Task { @MainActor [weak self] in
            for url in modified { await cache.evict(url: url) }
            self?.reloadCurrentFolder()
        }
    }

    /// "Folder gone" content state, with Go to Enclosing Folder.
    func showFolderGone(_ folder: URL) {
        stopWatching()
        contentController.showFolderGone(folder) { [weak self] in
            guard let self else { return }
            self.navigate(to: Self.nearestExistingAncestor(of: folder))
        }
        updateInspectorFromSelection()
        // The status bar and subtitle stop counting the
        // folder that is gone (they said "24 images").
        refreshStatusBar()
        updateSubtitle()
    }

    /// The nearest parent that still exists, found by path (never a tree
    /// walk). Falls back to Home.
    nonisolated static func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url.standardizedFileURL.deletingLastPathComponent()
        let fm = FileManager.default
        while candidate.path != "/" {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

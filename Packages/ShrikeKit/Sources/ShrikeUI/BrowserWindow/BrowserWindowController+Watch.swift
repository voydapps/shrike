//
//  BrowserWindowController+Watch.swift
//  ShrikeUI
//
//  File watching in the Browser: the listed folder is
//  watched with `FolderWatcher` (batched, 200 ms debounce). Added,
//  removed and renamed files list the folder again with the selection
//  kept; modified files drop their cached thumbnail first. This window's
//  own trash / move / rename / rotate / revert are ignored in its own and
//  its paired viewer's watcher only (`watcherScope`); other windows on the
//  folder hear them and refresh. The folder itself
//  going away shows "“Italy 2026” is no longer available."
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    /// Starts watching `folder` (no-op when it is already watched).
    func startWatching(_ folder: URL) {
        guard !browserDidClose else { return }
        let generation = folderRequestGeneration
        if let watcher = folderWatcher, GroupList.canonical(watcher.folder) == GroupList.canonical(folder) {
            return
        }
        stopWatching()
        guard let watcher = try? FolderWatcher(folder: folder) else { return }
        FolderWatcherRegistry.shared.register(watcher)
        folderWatcher = watcher
        folderWatchTask = Task { @MainActor [weak self] in
            for await change in watcher.changes {
                guard let self, !Task.isCancelled, self.acceptsFolderRequest(generation, folder: watcher.folder) else { return }
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
        guard !browserDidClose, let current = currentFolder,
              GroupList.canonical(current) == GroupList.canonical(folder) else { return }
        if change.folderEvent != nil {
            showFolderGone(folder)
            return
        }
        guard !change.isEmpty else { return }
        // "Modified" is also reported for a rating / flag / tag write (an
        // extended attribute): size and content date stay. Only a file whose
        // content changed loses its thumbnail, header read and sizes. The
        // thumbnail key holds the date and size, so the re-list below finds
        // the same thumbnail for the others.
        let modified = Self.contentChanged(change.modified, items: contentController.allItems)
        let changed = modified + change.removed + change.renamed.flatMap { [$0.from, $0.to] }
        guard !changed.isEmpty else {
            reloadCurrentFolder()
            return
        }
        photoInfoCache.invalidate(changed)
        let cache = services.thumbnailCache
        let generation = folderRequestGeneration
        Task { @MainActor [weak self] in
            for url in modified { await cache.evict(url: url) }
            guard self?.acceptsFolderRequest(generation, folder: folder) == true else { return }
            self?.fileContentsChanged(changed)
        }
    }

    /// The `modified` files whose size or content date differs from the
    /// listing (or that are not listed): the others only had an attribute
    /// written.
    static func contentChanged(_ modified: [URL], items: [BrowserItem]) -> [URL] {
        guard !modified.isEmpty else { return [] }
        var listed: [String: FileContentStamp] = [:]
        for item in items {
            listed[GroupList.canonical(item.group.primary)] =
                FileContentStamp(size: item.fileSize, modified: item.modificationDate)
        }
        return modified.filter { url in
            guard let known = listed[GroupList.canonical(url)] else { return true }
            return known.differs(from: url)
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

    /// "CARD" for /Volumes/CARD/DCIM when /Volumes/CARD is not mounted any more.
    nonisolated static func goneVolumeName(of url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count >= 3, parts[0] == "/", parts[1] == "Volumes" else { return nil }
        let root = "/Volumes/" + parts[2]
        return FileManager.default.fileExists(atPath: root) ? nil : parts[2]
    }

    /// The nearest parent that still exists, found by path (never a tree
    /// walk). Falls back to Home.
    nonisolated static func nearestExistingAncestor(of url: URL) -> URL {
        // A disk that is gone: its folders have no parent worth showing (the walk
        // would stop in /Volumes). Go to Pictures, else Home.
        if goneVolumeName(of: url) != nil {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let pictures = home.appendingPathComponent("Pictures", isDirectory: true)
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: pictures.path, isDirectory: &isDir) && isDir.boolValue
                ? pictures : home
        }
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

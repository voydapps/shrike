//
//  ViewerWindow+Watch.swift
//  ShrikeUI
//
//  File watching in the viewer. The displayed item's
//  folder is watched with `FolderWatcher` (batched, 200 ms debounce) and
//  registered with `FolderWatcherRegistry`, so Shrike's own trash / move /
//  rename / save are ignored for 1 s.
//
//  * Added: inserted in name order; the displayed item does not change.
//  * Removed: leaves the list with no toast and no undo; when it was the
//    displayed item, the next one shows and the toast "“x.jpg” was
//    removed outside Shrike." appears.
//  * Renamed: keeps its place and its marks; the title updates.
//  * Modified: decode and thumbnail caches are evicted, then the
//    displayed image is redrawn without resetting zoom or pan.
//  * The folder itself gone: the empty state "“Italy 2026” is no longer
//    available."
//

import AppKit
import ShrikeCore
import ShrikeIO
import ShrikeRendering

extension ViewerWindow {

    /// Test seam: a test that writes its own photos into a folder turns the
    /// watcher off. File-system events for those writes arrive late (more
    /// so under load) and would redraw the shown photo, a second paint
    /// the test did not ask for.
    static var watchFoldersForTesting = true
    var watchesFolderForTesting: Bool { Self.watchFoldersForTesting }

    /// Watches the folder of `url` (no-op when it is already watched).
    func watchFolder(of url: URL) {
        guard url.isFileURL, watchesFolderForTesting else { return }
        let folder = url.deletingLastPathComponent().standardizedFileURL
        guard folder.path != watchedFolderPath else { return }
        stopWatching()
        watchedFolderPath = folder.path
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
        watchedFolderPath = nil
    }

    /// One batch of outside changes to `folder`.
    func handleFolderChange(_ change: FolderChange, in folder: URL) {
        guard let watched = watchedFolderPath,
              GroupList.canonical(URL(fileURLWithPath: watched)) == GroupList.canonical(folder) else { return }
        if change.folderEvent != nil {
            showFolderGone(folder)
            return
        }
        guard !change.isEmpty else { return }

        // Modified: evict both caches; redraw the displayed image in place.
        let cache = services.thumbnailCache
        let navigation = self.navigation
        let displayedURLs = Set((displayedItem?.group.allURLs ?? []).map(GroupList.canonical))
        var redraw = false
        for url in change.modified {
            if displayedURLs.contains(GroupList.canonical(url)) { redraw = true }
        }
        if !change.modified.isEmpty {
            let modified = change.modified
            Task {
                for url in modified {
                    await navigation.decodeQueue.evict(url: url)
                    await cache.evict(url: url)
                }
            }
            refreshTags(for: modified.filter { list.index(of: $0) != nil })
        }

        var listChanged = applyRenames(change.renamed)
        let removedDisplayed = applyRemovals(change.removed, changed: &listChanged)

        if let (index, group) = removedDisplayed {
            showAfterRemoval(at: index, folder: folder)
            contentRoot.toast(ToastContent(Self.removedOutsideCopy(group)))
        } else if listChanged {
            syncListKeepingDisplayed()
        }
        if redraw && removedDisplayed == nil { redrawDisplayedKeepingView() }

        if !change.added.isEmpty { insertAddedFiles(in: folder) }
    }

    /// "“DSC_0042.jpg” was removed outside Shrike."
    static func removedOutsideCopy(_ group: ImageGroup) -> String {
        "“\(group.displayName)” was removed outside Shrike."
    }

    // MARK: - List changes

    /// Renames keep the item's place; marks follow the new URL.
    private func applyRenames(_ renames: [FolderChange.Rename]) -> Bool {
        var changed = false
        for rename in renames {
            guard let index = list.index(of: rename.from), let group = list[index] else { continue }
            let old = GroupList.canonical(rename.from)
            let renamed: ImageGroup
            if GroupList.canonical(group.primary) == old {
                renamed = ImageGroup(primary: rename.to, companions: group.companions,
                                     primaryIsRAW: group.primaryIsRAW)
                if let record = cullingRecords.removeValue(forKey: group.primary) {
                    cullingRecords[rename.to] = record
                }
                if let extras = fileBadges.removeValue(forKey: group.primary) {
                    fileBadges[rename.to] = extras
                }
            } else {
                let companions = group.companions.map {
                    GroupList.canonical($0.url) == old ? ImageGroup.Companion(url: rename.to, kind: $0.kind) : $0
                }
                renamed = ImageGroup(primary: group.primary, companions: companions,
                                     primaryIsRAW: group.primaryIsRAW)
            }
            list.replace(at: index, with: renamed)
            evictFromDecodeCache(rename.from)
            changed = true
        }
        return changed
    }

    /// Removed primaries leave the list; a removed companion only leaves
    /// its group. Returns the displayed group when it was removed.
    func applyRemovals(_ removed: [URL], changed: inout Bool) -> (Int, ImageGroup)? {
        guard !removed.isEmpty else { return nil }
        let gone = Set(removed.map(GroupList.canonical))
        var primaries: Set<URL> = []
        for (index, group) in list.groups.enumerated() {
            if gone.contains(GroupList.canonical(group.primary)) {
                primaries.insert(group.primary)
            } else if group.companions.contains(where: { gone.contains(GroupList.canonical($0.url)) }) {
                let kept = group.companions.filter { !gone.contains(GroupList.canonical($0.url)) }
                list.replace(at: index, with: ImageGroup(primary: group.primary, companions: kept,
                                                         primaryIsRAW: group.primaryIsRAW))
                changed = true
            }
        }
        guard !primaries.isEmpty else { return nil }
        let displayedPrimary = displayedItem?.group.primary
        let displayedIndex = displayedPrimary.flatMap { list.index(of: $0) }
        let removedGroups = list.remove(primaries: primaries)
        for entry in removedGroups { evictFromDecodeCache(entry.group.primary) }
        changed = true
        if let displayedPrimary, let displayedIndex,
           let hit = removedGroups.first(where: { $0.group.primary == displayedPrimary }) {
            // Removed items before the displayed one shift it left.
            let shift = removedGroups.filter { $0.index < displayedIndex }.count
            return (displayedIndex - shift, hit.group)
        }
        return nil
    }

    /// Lists the folder again and inserts groups the list doesn't have,
    /// each after its nearest listed predecessor in name order. A group
    /// that gained a companion (a RAW next to its JPEG) is swapped in place.
    func insertAddedFiles(in folder: URL) {
        let hidden = Prefs.showHiddenFiles
        Task { @MainActor [weak self] in
            guard let scanned = try? await FolderScanner.imageGroups(in: folder, showHidden: hidden),
                  let self else { return }
            var changed = false
            var insertAt = 0
            for group in scanned {
                if let index = self.list.index(of: group.primary) {
                    if let current = self.list[index], current != group,
                       GroupList.canonical(current.primary) == GroupList.canonical(group.primary) {
                        self.list.replace(at: index, with: group)
                        changed = true
                    }
                    insertAt = index + 1
                } else if group.allURLs.allSatisfy({ self.list.index(of: $0) == nil }) {
                    self.list.insert([RemovedGroup(index: insertAt, group: group)])
                    insertAt += 1
                    changed = true
                }
            }
            if changed {
                if self.isShowingEmptyState, !self.list.isEmpty {
                    self.hideEmptyState()
                    self.reloadList(showing: 0)
                } else {
                    self.syncListKeepingDisplayed()
                }
            }
        }
    }

    /// Pushes the list to the decode queue, filmstrip and pill without
    /// navigating: the displayed item stays on screen as it is.
    func syncListKeepingDisplayed() {
        guard !list.isEmpty else { return }
        let sources: [any ImageSource] = list.groups.map { FileImageSource(url: $0.primary) }
        let index = displayedItem.flatMap { list.index(of: $0.group.primary) }
            ?? min(max(0, intent.currentIndex), list.count - 1)
        intent.setNavigation(list: sources, currentIndex: index)
        if displayedItem != nil, let group = list[index] {
            displayedItem = DisplayedItem(group: group, listIndex: index, generation: list.generation)
        }
        updateTitle()
        loadCullingRecords()
        let total = list.count
        let name = list[index]?.displayName
        contentRoot.showNavigationPosition(index: index, total: total, filename: name)
        let navigation = self.navigation
        coalesceNav { [weak self] in
            await navigation.setNavigation(list: sources, currentIndex: index)
            await self?.updateFilmstrip(centeredOn: index)
        }
    }

    /// Decodes the displayed file again (caches evicted by the caller)
    /// and swaps the pixels in, keeping zoom, pan and view rotation
    /// (the file was modified).
    func redrawDisplayedKeepingView(fit: Bool = false) {
        guard let item = displayedItem else { return }
        let url = item.group.primary
        let navigation = self.navigation
        Task { @MainActor [weak self] in
            await navigation.decodeQueue.evict(url: url)
            guard let self, let index = self.list.index(of: url),
                  let entry = try? await navigation.jumpEntry(to: index),
                  self.displayedItem?.group.primary == url else { return }
            let view = self.contentRoot.imageView
            let mode = view.contentMode
            let zoom = view.zoom
            let pan = view.pan
            self.contentRoot.setImage(entry.image, index: index, total: self.list.count,
                                      sourceID: entry.sourceID,
                                      prepared: entry.prepared as? DisplayTexture)
            self.contentRoot.histogramImageShown(entry.image, url: url)
            // The fresh decode carries the file's orientation.
            view.resetOrientation()
            // The file changed: its size is read again (spec 25 §1.1).
            self.headerPixelSizes[url] = nil
            self.headerPixelSizes[item.shownURL] = nil
            if fit {
                view.zoomToFit()
            } else {
                view.contentMode = mode
                if case .bestFit = mode {} else { view.zoom = zoom }
                view.pan = pan
            }
            self.updateTitle()
            self.redrawCount &+= 1
        }
    }

    // MARK: - Folder gone

    /// The watched folder was deleted, moved or unmounted.
    func showFolderGone(_ folder: URL) {
        stopWatching()
        list.replace(with: [])
        displayedItem = nil
        reloadList(showing: 0)
        showEmptyState(ViewerEmptyStateView.folderGone(folder), folder: folder)
    }
}

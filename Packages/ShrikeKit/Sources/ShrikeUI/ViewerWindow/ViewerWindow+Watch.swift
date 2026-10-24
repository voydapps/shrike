//
//  ViewerWindow+Watch.swift
//  ShrikeUI
//
//  File watching in the viewer. The displayed item's
//  folder is watched with `FolderWatcher` (batched, 200 ms debounce) and
//  held by `watcherScope`, so this window's own trash / move / rename /
//  save / rotate are ignored for 1-2 s here and in the paired Browser's
//  watcher (both are updated explicitly). Any other window's watcher
//  still reports them, so a second Browser refreshes its thumbnail.
//
//  * Added: inserted in name order; the displayed item does not change.
//  * Removed: leaves the list with no toast and no undo; when it was the
//    displayed item, the next one shows and the toast "“x.jpg” was
//    moved or deleted." appears (by Finder, another app, or another
//    Shrike window).
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

        // Modified: a rating / flag / tag write is an extended attribute and
        // is reported too; only a file whose content changed loses its
        // decoded image and thumbnail, and is redrawn.
        let cache = services.thumbnailCache
        let navigation = self.navigation
        let displayedURLs = Set((displayedItem?.group.allURLs ?? []).map(GroupList.canonical))
        if !change.modified.isEmpty {
            let modified = change.modified
            Task { @MainActor [weak self] in
                let contentChanged = await navigation.decodeQueue.evictIfContentChanged(urls: modified)
                for url in contentChanged { await cache.evictIfContentChanged(url: url) }
                guard let self,
                      contentChanged.contains(where: { displayedURLs.contains(GroupList.canonical($0)) }),
                      self.displayedItem != nil else { return }
                self.redrawDisplayedKeepingView()
            }
            refreshTags(for: modified.filter { list.index(of: $0) != nil })
        }

        var listChanged = applyRenames(change.renamed)
        let removedDisplayed = applyRemovals(change.removed, changed: &listChanged)

        if let (index, group) = removedDisplayed {
            showAfterRemoval(at: index, folder: folder)
            contentRoot.toast(ToastContent(Self.goneCopy(group)))
        } else if listChanged {
            syncListKeepingDisplayed()
        }

        if !change.added.isEmpty { insertAddedFiles(in: folder) }
    }

    /// "“DSC_0042.jpg” was moved or deleted."
    static func goneCopy(_ group: ImageGroup) -> String {
        "“\(group.displayName)” was moved or deleted."
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
        // Look the removed files up (a few) instead of resolving every
        // group's paths (audit MP-01).
        let gone = Set(removed.map(GroupList.canonical))
        let touched = Set(removed.compactMap { list.index(of: $0) })
        var primaries: Set<URL> = []
        for index in touched.sorted() {
            guard let group = list[index] else { continue }
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
            // One pass over the unchanged list (hash lookups), then one
            // insert: a per-file insert would rebuild the lookup each time.
            var changed = false
            var insertAt = 0
            var additions: [RemovedGroup] = []
            for group in scanned {
                if let index = self.list.index(of: group.primary) {
                    if let current = self.list[index], current != group,
                       GroupList.canonical(current.primary) == GroupList.canonical(group.primary) {
                        self.list.replace(at: index, with: group)
                        changed = true
                    }
                    insertAt = index + additions.count + 1
                } else if group.allURLs.allSatisfy({ self.list.index(of: $0) == nil }) {
                    additions.append(RemovedGroup(index: insertAt, group: group))
                    insertAt += 1
                }
            }
            if !additions.isEmpty {
                self.list.insert(additions)
                changed = true
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
        // COR-4: a navigation still in flight (→ onto a slow photo) is cancelled by the
        // coalesced list sync below, and nothing would ask for that photo again: the
        // viewer stayed on the low-res preview, or the dimmed old photo. The intent
        // cursor holds the photo the user asked for; find it in the NEW list.
        let pendingTarget: Int? = navCoalescer.isIdle ? nil
            : (intent.sourceAt(intent.currentIndex) as? FileImageSource).flatMap { list.index(of: $0.url) }
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
            if let pendingTarget, !Task.isCancelled {
                // Finish the navigation the sync cancelled; it paints the photo and
                // clears the dim, the hairline and the PREVIEW badge itself.
                await self?.navigate(to: pendingTarget)
                return
            }
            await self?.updateFilmstrip(centeredOn: index)
        }
    }

    /// Decodes the displayed file again (caches evicted by the caller)
    /// and swaps the pixels in, keeping zoom, pan and view rotation
    /// (the file was modified).
    func redrawDisplayedKeepingView(fit: Bool = false) {
        Task { @MainActor [weak self] in await self?.redrawDisplayedKeepingViewNow(fit: fit) }
    }

    /// The same, for a caller that must wait until the new pixels are in.
    func redrawDisplayedKeepingViewNow(fit: Bool = false) async {
        guard let item = displayedItem else { return }
        let url = item.group.primary
        let navigation = self.navigation
        // Snapshot dimensions before the async decode can overlap another
        // watcher redraw. The first redraw may swap in new pixels and clear
        // the view's size before a second redraw reaches its own apply step.
        let knownDrawnSize = headerPixelSizes[item.shownURL]
            ?? headerPixelSizes[url]
            ?? contentRoot.imageView.sourcePixelSize
        do {
            await navigation.decodeQueue.evict(url: url)
            guard let index = self.list.index(of: url),
                  let entry = try? await navigation.jumpEntry(to: index),
                  self.displayedItem?.group.primary == url else { return }
            let view = self.contentRoot.imageView
            // Keep the last known dimensions attached to the displayed
            // pixels while the file's replacement is decoded and its new
            // metadata is read. setImage clears this value when the source
            // ID changes; that transient nil can outlive a delayed watcher
            // event on a loaded host.
            let mode = view.contentMode
            let zoom = view.zoom
            let pan = view.pan
            self.contentRoot.setImage(entry.image, index: index, total: self.list.count,
                                      sourceID: entry.sourceID,
                                      prepared: entry.prepared as? DisplayTexture, resourceLease: entry.resourceLease, imageIsLazy: entry.imageIsLazy)
            self.contentRoot.histogramImageShown(entry.image, url: url)
            // The fresh decode carries the file's orientation.
            view.resetOrientation()
            // The file changed: its size is read again (spec 25 §1.1).
            self.headerPixelSizes[url] = nil
            self.headerPixelSizes[item.shownURL] = nil
            view.sourcePixelSize = knownDrawnSize
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

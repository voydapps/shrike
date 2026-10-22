//
//  Compare+Origins.swift
//  ShrikeUI
//
//  ⌘4 / View ▸ Compare / FastStone `P` from the Browser and the viewer:
//  which images open, and how the origin window hears
//  about ratings, trashed files and rotations made in Compare.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController: CompareOrigin {

    var compareWatcherScope: WindowWatcherScope { watcherScope }

    /// 2–4 selected = those; 1 = it and the next; over 4 = the first 4.
    func openCompare() {
        let items = contentController.visibleItems
        let selected = Set(contentController.selectedItems.map(\.url))
        let indices = items.indices.filter { selected.contains(items[$0].url) }
        guard let request = CompareSources.fromBrowser(list: items.map(\.group), selected: indices) else { return }
        flushPendingOrientation()
        CompareWindow.open(request, services: services, origin: self, frame: Self.compareFrame(over: window))
    }

    /// Compare cascades from the Browser (24 pt right and
    /// down) like the paired viewer, so the Browser stays visible behind
    /// it. From a viewer it still opens on the viewer's frame:
    /// there it takes the viewer's place.
    static func compareFrame(over browser: NSWindow?) -> NSRect? {
        guard let browser else { return nil }
        return WindowCoordinator.pairedViewerFrame(over: browser.frame, visible: browser.screen?.visibleFrame)
    }

    func compareDidChangeCulling(_ values: [URL: FileRecord]) {
        cullingDidChange(values)
    }

    /// The selection stays as it was, less the trashed items.
    func compareDidRemove(_ primaries: Set<URL>) {
        let keep = contentController.selectedItems.map(\.url).filter { !primaries.contains($0) }
        removeFromList(primaries, next: nil)
        if !keep.isEmpty { contentController.select(urls: keep) }
    }

    func compareDidRestore(_ groups: [ImageGroup]) {
        reloadCurrentFolder()
    }

    func compareDidChangeFiles(_ urls: [URL]) {
        fileVersionsLanded(urls: urls)
    }

    /// The grid or list takes the keys again, so ⇧→ right after Esc
    /// extends the selection.
    func compareDidClose() {
        guard let window else { return }
        window.makeFirstResponder(contentController.focusView)
        if window.isVisible, !window.isMiniaturized { window.makeKeyAndOrderFront(nil) }
    }
}

extension ViewerWindow: CompareOrigin {

    var compareWatcherScope: WindowWatcherScope { watcherScope }

    /// The shown photo and the next (the one before at the end).
    func openCompare() {
        guard let item = displayedItem,
              let request = CompareSources.fromViewer(list: list.groups, displayed: item.listIndex) else { return }
        flushPendingOrientation()
        CompareWindow.open(request, services: services, origin: self, frame: frame)
    }

    func compareDidChangeCulling(_ values: [URL: FileRecord]) {
        cullingDidChange(values)
    }

    func compareDidRemove(_ primaries: Set<URL>) {
        guard let folder = displayedFolder ?? primaries.first?.deletingLastPathComponent() else { return }
        var changed = false
        if let (index, _) = applyRemovals(Array(primaries), changed: &changed) {
            showAfterRemoval(at: index, folder: folder)
        } else if changed {
            syncListKeepingDisplayed()
        }
    }

    func compareDidRestore(_ groups: [ImageGroup]) {
        guard let folder = groups.first?.primary.deletingLastPathComponent() else { return }
        insertAddedFiles(in: folder)
    }

    func compareDidChangeFiles(_ urls: [URL]) {
        let cache = services.thumbnailCache
        let navigation = self.navigation
        Task {
            for url in urls {
                await navigation.decodeQueue.evict(url: url)
                await cache.evict(url: url)
            }
        }
        if let shown = displayedItem?.group.primary, urls.contains(shown) {
            redrawDisplayedKeepingView(fit: true)
        }
    }

    /// The viewer takes the keys again with its canvas focused.
    /// A focused view inside it (a crop frame) keeps focus.
    func compareDidClose() {
        if !(firstResponder is NSView) || firstResponder is NSText {
            makeFirstResponder(canvasResponder)
        }
        if isVisible, !isMiniaturized { makeKeyAndOrderFront(nil) }
    }
}

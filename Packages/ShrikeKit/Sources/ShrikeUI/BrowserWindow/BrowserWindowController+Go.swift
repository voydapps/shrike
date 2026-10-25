//
//  BrowserWindowController+Go.swift
//  ShrikeUI
//
//  Go menu commands in the Browser: Next / Previous Folder
//  (⌥⌘→ / ⌥⌘←). The sibling with an image is found off the main thread,
//  the same rule the viewer uses.
//

import AppKit
import ShrikeCore
import ShrikeIO

extension BrowserWindowController {

    func goToAdjacentFolder(_ direction: FolderScanner.Direction) {
        guard let folder = currentFolder else { return }
        let hidden = Prefs.showHiddenFiles
        let generation = folderRequestGeneration
        adjacentFolderTask = Task { @MainActor [weak self] in
            let target = await FolderScanner.adjacentFolder(of: folder, direction, showHidden: hidden)
            guard let self, self.acceptsFolderRequest(generation, folder: folder) else { return }
            guard let target else {
                self.toast(direction == .next ? "No next folder." : "No previous folder.")
                return
            }
            // Like a sidebar pick: a new folder starts without a search.
            self.clearSearchForNewFolder()
            self.navigate(to: target)
        }
    }

    // MARK: Go to Folder…

    /// ⇧⌘G: the Go to Folder sheet on this window.
    func showGoToFolderSheet() {
        guard let window, window.attachedSheet == nil, goToFolderSheet == nil else { return }
        let sheet = GoToFolderSheet(base: currentFolder)
        goToFolderSheet = sheet
        Task { @MainActor [weak self] in
            let target = await sheet.run(on: window)
            guard let self else { return }
            self.goToFolderSheet = nil
            if let target { self.go(to: target) }
        }
    }

    /// Shows `target`'s folder like a sidebar pick (no search carried
    /// over); a file is selected once the folder is listed.
    public func go(to target: GoToFolderTarget) {
        clearSearchForNewFolder()
        follow(folder: target.folder, selecting: target.selecting)
    }

    /// An empty folder with subfolders says "Subfolders are
    /// in the sidebar." only when the sidebar really shows
    /// them (the sidebar is open and the folder is a row of its tree);
    /// otherwise "This folder has N subfolders." One directory listing,
    /// off main.
    func checkSubfolders(of folder: URL) {
        let hidden = Prefs.showHiddenFiles
        let generation = folderRequestGeneration
        subfolderCheckTask?.cancel()
        subfolderCheckTask = Task { @MainActor [weak self] in
            let count = await Task.detached(priority: .utility) {
                Self.subfolderCount(folder, showHidden: hidden)
            }.value
            guard let self, !Task.isCancelled, self.acceptsFolderRequest(generation, folder: folder) else { return }
            let inSidebar = count > 0 ? await self.sidebarShowsSubfolders(of: folder) : false
            guard !Task.isCancelled, self.acceptsFolderRequest(generation, folder: folder),
                  self.contentController.allItems.isEmpty else { return }
            self.contentController.emptyFolder = (folder.lastPathComponent, count, inSidebar)
            self.onSubfolderCheckForTesting?()
        }
    }

    /// True when the sidebar shows `folder`'s subfolders: the sidebar is
    /// open. The current folder is always a row of its tree (spec
    /// 22-sidebar §4.3), so nothing else is needed; the check keeps its
    /// shape so the empty-folder text stays one rule.
    func sidebarShowsSubfolders(of folder: URL) async -> Bool {
        splitController.splitViewItems.first?.isCollapsed == false
    }

    /// True when `folder` holds a folder (not a package such as a
    /// `.photoslibrary`). Reads one level only.
    nonisolated static func hasSubfolders(_ folder: URL, showHidden: Bool) -> Bool {
        subfolderCount(folder, showHidden: showHidden) > 0
    }

    /// The folders in `folder` (packages are files). Reads one level only.
    nonisolated static func subfolderCount(_ folder: URL, showHidden: Bool) -> Int {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: options) else { return 0 }
        return children.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isPackage != true
        }.count
    }
}

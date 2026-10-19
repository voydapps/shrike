//
//  FolderTreeDataSource.swift
//  ShrikeUI
//
//  Data source behind `FolderTreeViewController`'s `NSOutlineView`. Walks
//  the file system lazily — children are enumerated only when a node
//  expands, so a 50k-item home directory never pays its cost upfront.
//
//  Threading: `Node` mutation is all MainActor. The file system is read
//  OFF the main thread: `loadChildren` is async and runs
//  the listing in a detached task, so a slow network volume or a folder
//  with thousands of entries never stalls the UI. The outline data source
//  calls (`numberOfChildren`, `child`) only read what is already loaded.
//

import AppKit
import Foundation

// MARK: - Section

/// Root-level grouping in the source list. Renders as a non-selectable header
/// row in `NSOutlineView` (styled via `.sourceList`).
/// Order: Favorites, Locations (volumes), then
/// the folder tree (Home, Desktop, …) under "Folders". Empty sections are
/// not shown.
public enum FolderTreeSection: Sendable, Hashable, CaseIterable {
    case favorites
    case currentFolder
    case locations
    case folders

    public var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .currentFolder: return "Current Folder"
        case .locations: return "Locations"
        case .folders: return "Folders"
        }
    }
}

// MARK: - Node

@MainActor
public final class FolderTreeNode: NSObject {
    /// `nil` for section headers, non-nil for real folders.
    public let url: URL?
    public var title: String
    public var children: [FolderTreeNode] = []
    public let section: FolderTreeSection?
    public weak var parent: FolderTreeNode?

    /// True when this node's `children` array has been populated from disk
    /// at least once. Mutated within the module by `FolderTreeDataSource`.
    internal(set) public var childrenLoaded: Bool = false
    /// Bumped by `invalidate`, so a read that finishes late is dropped.
    var loadGeneration = 0

    /// Indicator that the filesystem says this is a directory.
    public let isFolder: Bool

    public init(url: URL?, title: String, section: FolderTreeSection? = nil, isFolder: Bool = true) {
        self.url = url
        self.title = title
        self.section = section
        self.isFolder = isFolder
    }

    public var isSection: Bool { url == nil }

    /// What the row is: a plain folder, a Favorites row (a leaf that jumps
    /// to its folder) or a mounted volume.
    public enum Kind: Sendable, Equatable { case folder, favorite, volume }
    public var kind: Kind = .folder
    /// A favorite whose folder is gone (disk disconnected): 50 % row.
    public var isMissing = false
    public var isPackage = false
    /// Volume rows that can be ejected show the eject button.
    public var volume: SidebarVolume?
    /// Row symbol.
    public var symbolName = "folder"

    /// The symbol for a known folder, "folder" otherwise.
    /// Path compare only, no disk read.
    public static func symbolName(for url: URL) -> String {
        let fm = FileManager.default
        let path = url.standardizedFileURL.path
        if path == fm.homeDirectoryForCurrentUser.standardizedFileURL.path { return "house" }
        let known: [(FileManager.SearchPathDirectory, String)] = [
            (.desktopDirectory, "menubar.dock.rectangle"), (.documentDirectory, "doc"),
            (.picturesDirectory, "photo"), (.downloadsDirectory, "arrow.down.circle"),
            (.moviesDirectory, "film"),
        ]
        for (dir, symbol) in known where fm.urls(for: dir, in: .userDomainMask).first?.standardizedFileURL.path == path {
            return symbol
        }
        return "folder"
    }
}

// MARK: - Data source

@MainActor
public final class FolderTreeDataSource {

    public var roots: [FolderTreeNode] = []
    public private(set) var currentFolder: URL?
    private var baseFolderNodes: [FolderTreeNode] = []

    /// Establishes a known root without walking any parent directory.
    public func setCurrentFolder(_ url: URL) {
        currentFolder = url.standardizedFileURL
        roots.removeAll { $0.section == .currentFolder }
        let path = url.standardizedFileURL.path
        roots.first { $0.section == .folders }?.children = baseFolderNodes.filter { $0.url?.standardizedFileURL.path != path }
        if favoritesSection?.children.contains(where: { $0.url?.standardizedFileURL.path == path }) == true { return }
        let section = Self.section(.currentFolder)
        let node = FolderTreeNode(url: url, title: url.lastPathComponent)
        node.parent = section; section.children = [node]
        roots.insert(section, at: roots.first?.section == .favorites ? 1 : 0)
    }

    /// If true, hidden files (leading `.`) are included when enumerating.
    /// Defaults to false; the browser toolbar toggle mutates this.
    public var showHiddenFiles: Bool = false

    /// Test seam: called with each folder `loadChildren` actually lists
    /// from disk. Nil in the app.
    internal var didListFolder: ((URL) -> Void)?

    public init() {
        rebuildRoots()
    }

    // MARK: Roots

    /// Rebuild the top-level sections: Favorites, Locations, then the
    /// folder tree (Home, Desktop, Documents, Pictures, Downloads). Only
    /// paths are used here; nothing is listed or read.
    public func rebuildRoots(extraBookmarks: [URL] = []) {
        rebuildRoots(favorites: extraBookmarks.map { SidebarFavoriteRow(url: $0, isMissing: false) },
                     volumes: [])
    }

    public func rebuildRoots(favorites: [SidebarFavoriteRow], volumes: [SidebarVolume]) {
        let fm = FileManager.default
        var roots: [FolderTreeNode] = []

        if !favorites.isEmpty {
            let section = Self.section(.favorites)
            for row in favorites {
                let node = FolderTreeNode(url: row.url, title: row.url.lastPathComponent)
                node.kind = .favorite
                node.isMissing = row.isMissing
                node.symbolName = FolderTreeNode.symbolName(for: row.url)
                node.childrenLoaded = true
                node.parent = section
                section.children.append(node)
            }
            roots.append(section)
        }

        if !volumes.isEmpty {
            let section = Self.section(.locations)
            for volume in volumes {
                let node = FolderTreeNode(url: volume.url, title: volume.name)
                node.kind = .volume
                node.volume = volume
                node.symbolName = volume.symbolName
                node.parent = section
                section.children.append(node)
            }
            roots.append(section)
        }

        let folders = Self.section(.folders)
        let sources: [(URL?, String)] = [
            (fm.homeDirectoryForCurrentUser, "Home"),
            (fm.urls(for: .desktopDirectory, in: .userDomainMask).first, "Desktop"),
            (fm.urls(for: .documentDirectory, in: .userDomainMask).first, "Documents"),
            (fm.urls(for: .picturesDirectory, in: .userDomainMask).first, "Pictures"),
            (fm.urls(for: .downloadsDirectory, in: .userDomainMask).first, "Downloads"),
        ]
        // A place already in Favorites is not repeated
        // here. Home stays: it is the tree the other folders open under.
        let favoritePaths = Set(favorites.map { $0.url.standardizedFileURL.path })
        for (maybe, title) in sources {
            guard let url = maybe else { continue }
            if favoritePaths.contains(url.standardizedFileURL.path) || currentFolder?.standardizedFileURL == url.standardizedFileURL { continue }
            let node = FolderTreeNode(url: url, title: title)
            node.symbolName = FolderTreeNode.symbolName(for: url)
            node.parent = folders
            folders.children.append(node)
        }
        baseFolderNodes = folders.children
        roots.append(folders)

        self.roots = roots
        if let currentFolder { setCurrentFolder(currentFolder) }
    }

    private static func section(_ section: FolderTreeSection) -> FolderTreeNode {
        let node = FolderTreeNode(url: nil, title: section.title, section: section)
        node.childrenLoaded = true
        return node
    }

    /// The Favorites section, when shown.
    public var favoritesSection: FolderTreeNode? { roots.first { $0.section == .favorites } }

    // MARK: Lazy children

    /// Lists the child folders of a folder, sorted Finder-style. Runs off
    /// the main thread; tests swap in a slow or fake lister.
    public typealias Lister = @Sendable (_ folder: URL, _ showHidden: Bool) -> [URL]

    /// The file-system read `loadChildren` runs off the main thread.
    var lister: Lister = { FolderTreeDataSource.listSubfolders(of: $0, showHidden: $1) }

    /// Loads in flight, by node, so two callers share one disk read.
    private var inFlight: [ObjectIdentifier: Task<[FolderTreeNode], Never>] = [:]

    /// The child folders of `folder` (not files), sorted like Finder.
    /// Synchronous disk read: call it off the main thread.
    public nonisolated static func listSubfolders(of folder: URL, showHidden: Bool) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: options
        )) ?? []
        let folderURLs = entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return folderURLs.sorted { a, b in
            BrowserNaturalSort.compare(a.lastPathComponent, b.lastPathComponent) == .orderedAscending
        }
    }

    /// True while `node`'s children are being read.
    public func isLoading(_ node: FolderTreeNode) -> Bool {
        inFlight[ObjectIdentifier(node)] != nil
    }

    /// Populates `node.children` from the file system if not already done.
    /// The read runs off the main thread; the nodes are built back on the
    /// main actor. Section nodes are pre-populated by `rebuildRoots`.
    ///
    /// Returns the (possibly cached) child array.
    @discardableResult
    public func loadChildren(_ node: FolderTreeNode) async -> [FolderTreeNode] {
        if node.isSection || node.childrenLoaded { return node.children }
        guard let url = node.url, node.isFolder, !node.isPackage, node.kind != .favorite else {
            node.childrenLoaded = true
            return []
        }
        let key = ObjectIdentifier(node)
        if let running = inFlight[key] { return await running.value }
        didListFolder?(url)
        let lister = self.lister
        let hidden = showHiddenFiles
        let generation = node.loadGeneration
        let task = Task { @MainActor [weak node] () -> [FolderTreeNode] in
            let entries = await Task.detached(priority: .userInitiated) {
                lister(url, hidden).map { ($0, (try? $0.resourceValues(forKeys: [.isPackageKey]).isPackage) == true) }
            }.value
            guard let node else { return [] }
            // Invalidated while reading: the next load reads again.
            guard node.loadGeneration == generation else { return node.children }
            node.children = entries.map { childURL, package in
                let child = FolderTreeNode(url: childURL, title: childURL.lastPathComponent)
                child.isPackage = package
                child.parent = node
                return child
            }
            node.childrenLoaded = true
            return node.children
        }
        inFlight[key] = task
        let children = await task.value
        if node.loadGeneration == generation { inFlight[key] = nil }
        return children
    }

    // MARK: Lookup by path

    /// The node for folder `url`, found by path alone.
    ///
    /// Picks the sidebar root whose path is the longest prefix of `url`
    /// (so a folder in ~/Pictures resolves under "Pictures", not
    /// Home → Pictures), then loads children one path component at a
    /// time. Only the target's ancestor chain is ever listed from disk.
    ///
    /// WHY: the old depth-first search listed every folder under every
    /// root on the main thread. Home is the first root and ~/Library sorts
    /// first under it, so opening any folder walked all of ~/Library
    /// (60 s+ beachball) and entered Desktop / Documents / Downloads,
    /// firing the "Shrike would like to access…" privacy prompts.
    ///
    /// Returns nil when no root contains `url`, or a component is not
    /// listed (for example a hidden folder while hidden files are off).
    public func node(for url: URL) async -> FolderTreeNode? {
        let target = url.standardizedFileURL.pathComponents
        // Favorites are leaves and the boot volume ("/") would make every
        // lookup walk from the disk root, so neither is a lookup root. A
        // favorite still matches exactly (a folder on no other root).
        let all = roots.flatMap { $0.isSection ? $0.children : [$0] }
        if let favorite = all.first(where: { $0.kind == .favorite && $0.url?.standardizedFileURL == url.standardizedFileURL }) { return favorite }
        let rootFolders = all.filter { $0.kind != .favorite && $0.url?.standardizedFileURL.path != "/" }

        var best: FolderTreeNode?
        var bestDepth = -1
        for root in rootFolders {
            guard let rootURL = root.url else { continue }
            let prefix = rootURL.standardizedFileURL.pathComponents
            guard prefix.count <= target.count,
                  prefix.count > bestDepth,
                  Array(target.prefix(prefix.count)) == prefix else { continue }
            best = root
            bestDepth = prefix.count
        }
        guard var cursor = best else {
            let path = url.standardizedFileURL.path
            return all.first { $0.kind == .favorite && $0.url?.standardizedFileURL.path == path }
        }

        for component in target.dropFirst(bestDepth) {
            let children = await loadChildren(cursor)
            let exact = children.first { $0.url?.lastPathComponent == component }
            // APFS is usually case-insensitive; accept a case-only mismatch
            // rather than dropping the selection.
            let loose = exact ?? children.first {
                $0.url?.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame
            }
            guard let next = loose else { return nil }
            cursor = next
        }
        return cursor
    }

    /// Leaf-style nodes (non-directories, or empty directories) need to tell
    /// NSOutlineView they are not expandable. The outline view asks
    /// `isItemExpandable` even for leaves; this returns false for them.
    public func isExpandable(_ node: FolderTreeNode) -> Bool {
        if node.isSection { return !node.children.isEmpty }
        guard node.isFolder, !node.isPackage, node.kind != .favorite else { return false }
        // If we haven't loaded yet, assume expandable so the disclosure
        // triangle shows. Expanding starts the read (off main); the row
        // opens when the children arrive.
        if !node.childrenLoaded { return true }
        return !node.children.isEmpty
    }

    /// Loaded children only: never reads the disk (main thread).
    public func numberOfChildren(of node: FolderTreeNode?) -> Int {
        guard let node else { return roots.count }
        return node.children.count
    }

    public func child(_ index: Int, of node: FolderTreeNode?) -> FolderTreeNode? {
        if let node {
            guard node.children.indices.contains(index) else { return nil }
            return node.children[index]
        }
        guard roots.indices.contains(index) else { return nil }
        return roots[index]
    }

    /// Folder objects already held in memory, including base folders temporarily
    /// excluded from roots by Current Folder. No filesystem discovery is performed.
    func instantiatedFolderNodes() -> [FolderTreeNode] {
        var queue = roots + baseFolderNodes
        var seen: Set<ObjectIdentifier> = []
        var folders: [FolderTreeNode] = []
        while let node = queue.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            queue.append(contentsOf: node.children)
            if !node.isSection, node.isFolder, node.kind != .favorite { folders.append(node) }
        }
        return folders
    }

    /// Invalidate cached children for `node` (so a fresh disk read happens
    /// next time). Useful after rename / new-folder / delete operations.
    public func invalidate(_ node: FolderTreeNode) {
        node.children = []
        node.childrenLoaded = false
        node.loadGeneration += 1
        inFlight[ObjectIdentifier(node)] = nil
    }
}

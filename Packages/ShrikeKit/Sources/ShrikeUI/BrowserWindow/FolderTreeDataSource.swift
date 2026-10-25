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

/// Root-level grouping in the source list. Renders as a header row in the
/// `NSOutlineView` (styled via `.sourceList`); headers do not collapse.
/// Order: Favorites (flat jumps, shown while there is at least one), then
/// Locations (Home first, then the volumes; each a tree root).
/// Spec 22-sidebar §4.1.
public enum FolderTreeSection: Sendable, Hashable, CaseIterable {
    case favorites
    case locations

    public var title: String {
        switch self {
        case .favorites: return "Favorites"
        case .locations: return "Locations"
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
    /// The Home root under Locations.
    public var isHome = false
    /// A row inserted for one path part that the parent's listing did not
    /// show (hidden while "Show hidden files" is off, or a listing that
    /// failed). Path only, drawn at 50 % (spec 22-sidebar §4.4 rule 5).
    public var isPathRow = false
    /// Name starts with "." or the file system says hidden: drawn at 50 %.
    public var isHidden = false
    /// The folder could not be read when it was opened (spec 22-sidebar §4.11).
    public var isUnreadable = false
    /// Drawn at 50 %: hidden folders and path rows.
    public var isDimmed: Bool { isHidden || isPathRow }

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
    /// The folder the Browser shows. Only a path: the tree row for it is
    /// found by `node(for:)`.
    public private(set) var currentFolder: URL?

    public func setCurrentFolder(_ url: URL?) {
        currentFolder = url?.standardizedFileURL
    }

    /// If true, hidden files (leading `.`) are included when enumerating.
    /// Defaults to false; the browser toolbar toggle mutates this.
    public var showHiddenFiles: Bool = false

    /// Test seam: called with each folder `loadChildren` actually lists
    /// from disk. Nil in the app.
    internal var didListFolder: ((URL) -> Void)?

    /// Called (main actor) when a folder could not be read. The controller
    /// shows the one toast per folder.
    var onUnreadable: ((FolderTreeNode) -> Void)?

    public init() {
        rebuildRoots()
    }

    // MARK: Roots

    /// Rebuild the top-level sections: Favorites, then Locations (Home and
    /// the volumes). Only paths are used here; nothing is listed or read.
    /// Location roots that are still there keep their node (and so their
    /// loaded children and open rows).
    public func rebuildRoots(extraBookmarks: [URL] = []) {
        rebuildRoots(favorites: extraBookmarks.map { SidebarFavoriteRow(url: $0, isMissing: false) },
                     volumes: [])
    }

    public func rebuildRoots(favorites: [SidebarFavoriteRow], volumes: [SidebarVolume]) {
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

        let section = locationsSection ?? Self.section(.locations)
        var old: [String: FolderTreeNode] = [:]
        for node in section.children { if let path = node.url?.standardizedFileURL.path { old[path] = node } }
        var children: [FolderTreeNode] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let homeNode = old[home.path] ?? FolderTreeNode(url: home, title: "Home")
        homeNode.isHome = true
        homeNode.title = "Home"
        homeNode.symbolName = "house"
        homeNode.parent = section
        children.append(homeNode)
        for volume in volumes {
            let path = volume.url.standardizedFileURL.path
            guard path != home.path else { continue }
            let node = old[path] ?? FolderTreeNode(url: volume.url, title: volume.name)
            node.title = volume.name
            node.kind = .volume
            node.volume = volume
            node.symbolName = volume.symbolName
            node.parent = section
            children.append(node)
        }
        section.children = children
        roots.append(section)

        self.roots = roots
    }

    private static func section(_ section: FolderTreeSection) -> FolderTreeNode {
        let node = FolderTreeNode(url: nil, title: section.title, section: section)
        node.childrenLoaded = true
        return node
    }

    /// The Favorites section, when shown.
    public var favoritesSection: FolderTreeNode? { roots.first { $0.section == .favorites } }
    /// The Locations section: Home and the volumes. Always there.
    public var locationsSection: FolderTreeNode? { roots.first { $0.section == .locations } }

    // MARK: Lazy children

    /// Lists the child folders of a folder, sorted Finder-style. Runs off
    /// the main thread; tests swap in a slow or fake lister.
    public typealias Lister = @Sendable (_ folder: URL, _ showHidden: Bool) throws -> [URL]

    /// The file-system read `loadChildren` runs off the main thread.
    var lister: Lister = { try FolderTreeDataSource.readSubfolders(of: $0, showHidden: $1) }

    /// Loads in flight, by node, so two callers share one disk read.
    private var inFlight: [ObjectIdentifier: Task<[FolderTreeNode], Never>] = [:]

    /// The child folders of `folder` (not files), sorted like Finder.
    /// Synchronous disk read: call it off the main thread. Throws when the
    /// folder cannot be read.
    public nonisolated static func readSubfolders(of folder: URL, showHidden: Bool) throws -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let entries = try FileManager.default.contentsOfDirectory(
            at: folder,
            // The package and hidden flags are asked for here too: the
            // caller reads them per row, and a key that was not prefetched
            // costs one more system call for every entry (a folder with
            // 50 000 subfolders, such as a temp folder, took seconds).
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey, .isPackageKey, .isHiddenKey],
            options: options
        )
        // A closed Browser cancels the read: no sorting of a huge folder
        // for a window that is gone.
        try Task.checkCancellation()
        let folderURLs = entries.filter { entry in
            (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return BrowserNaturalSort.sorted(folderURLs) { $0.lastPathComponent }
    }

    /// Same, with an unreadable folder reported as "no subfolders".
    public nonisolated static func listSubfolders(of folder: URL, showHidden: Bool) -> [URL] {
        (try? readSubfolders(of: folder, showHidden: showHidden)) ?? []
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
        let task = Task { @MainActor [weak node, weak self] () -> [FolderTreeNode] in
            let work = Task.detached(priority: .userInitiated) { () -> Result<[(URL, Bool, Bool)], any Error> in
                do {
                    return .success(try lister(url, hidden).map { entry in
                        let values = try? entry.resourceValues(forKeys: [.isPackageKey, .isHiddenKey])
                        return (entry, values?.isPackage == true,
                                values?.isHidden == true || entry.lastPathComponent.hasPrefix("."))
                    })
                } catch { return .failure(error) }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let node else { return [] }
            // Invalidated while reading: the next load reads again.
            guard node.loadGeneration == generation else { return node.children }
            switch result {
            case .success(let entries):
                node.isUnreadable = false
                node.children = entries.map { childURL, package, hidden in
                    let child = FolderTreeNode(url: childURL, title: childURL.lastPathComponent)
                    child.isPackage = package
                    child.isHidden = hidden
                    child.symbolName = package ? "shippingbox" : "folder"
                    child.parent = node
                    return child
                }
            case .failure(let error) where error is CancellationError:
                // The window closed while the folder was read: nothing is
                // known about it, and nothing is marked.
                return node.children
            case .failure(let error):
                node.children = []
                // A folder that is not there (a path row for a gone folder)
                // is not "can't read"; a permission or I/O error is.
                let missing = (error as? CocoaError)?.code == .fileReadNoSuchFile
                    || (error as? CocoaError)?.code == .fileNoSuchFile
                node.isUnreadable = !missing
            }
            node.childrenLoaded = true
            if node.isUnreadable { self?.onUnreadable?(node) }
            return node.children
        }
        inFlight[key] = task
        let children = await task.value
        if node.loadGeneration == generation { inFlight[key] = nil }
        return children
    }

    // MARK: Lookup by path

    /// The tree row for folder `url`, found by path alone (spec
    /// 22-sidebar §4.4).
    ///
    /// Picks the Locations root (Home or a volume, "/" last) whose path is
    /// the longest prefix of `url`, then loads children one path component
    /// at a time. Only the target's ancestor chain is ever listed from disk
    /// (the root down to the target's parent); the target itself is listed
    /// only when it is opened. A Favorite is never a lookup root, and the
    /// answer is always the tree row, never the Favorite.
    ///
    /// WHY: the old depth-first search listed every folder under every
    /// root on the main thread. Home is the first root and ~/Library sorts
    /// first under it, so opening any folder walked all of ~/Library
    /// (60 s+ beachball) and entered Desktop / Documents / Downloads,
    /// firing the "Shrike would like to access…" privacy prompts. Every
    /// ancestor on the chain is either unprotected (Home, "/", /Volumes) or
    /// inside the same protected area as the folder the Browser is already
    /// listing for its photos, so no new prompt can appear.
    ///
    /// A path part that its parent's listing does not show (hidden while
    /// hidden files are off, or a failed listing) gets a path row: no read,
    /// drawn at 50 %. Returns nil only when no root contains `url`.
    public func node(for url: URL) async -> FolderTreeNode? {
        let target = Self.lookupComponents(url)
        var best: FolderTreeNode?
        var bestDepth = -1
        for root in locationsSection?.children ?? [] {
            guard let rootURL = root.url else { continue }
            let prefix = Self.lookupComponents(rootURL)
            guard prefix.count <= target.count,
                  prefix.count > bestDepth,
                  Array(target.prefix(prefix.count)) == prefix else { continue }
            best = root
            bestDepth = prefix.count
        }
        guard var cursor = best else { return nil }

        for component in target.dropFirst(bestDepth) {
            let children = await loadChildren(cursor)
            if Task.isCancelled { return nil }
            let exact = children.first { $0.url?.lastPathComponent == component }
            // APFS is usually case-insensitive; accept a case-only mismatch
            // rather than dropping the selection.
            let loose = exact ?? children.first {
                $0.url?.lastPathComponent.caseInsensitiveCompare(component) == .orderedSame
            }
            if let next = loose { cursor = next; continue }
            guard let parentURL = cursor.url else { return nil }
            let row = FolderTreeNode(url: parentURL.appendingPathComponent(component, isDirectory: true),
                                     title: component)
            row.isPathRow = true
            row.parent = cursor
            let at = cursor.children.firstIndex {
                BrowserNaturalSort.compare($0.title, component) == .orderedDescending
            } ?? cursor.children.count
            cursor.children.insert(row, at: at)
            cursor = row
        }
        return cursor
    }

    /// The path parts of `url` as the file system lists them. Foundation's
    /// `standardizedFileURL` turns `/private/tmp/x` into `/tmp/x`, but at "/"
    /// `tmp`, `var` and `etc` are symbolic links (not folders) and the folder
    /// that is listed is `private`. Both sides of a lookup use this.
    nonisolated static func lookupComponents(_ url: URL) -> [String] {
        var parts = url.standardizedFileURL.pathComponents
        if parts.count >= 2, parts[0] == "/", ["tmp", "var", "etc"].contains(parts[1]) {
            parts.insert("private", at: 1)
        }
        return parts
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

    /// Folder objects already held in memory. No filesystem discovery is performed.
    func instantiatedFolderNodes() -> [FolderTreeNode] {
        var queue = roots
        var seen: Set<ObjectIdentifier> = []
        var folders: [FolderTreeNode] = []
        while let node = queue.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            queue.append(contentsOf: node.children)
            if !node.isSection, node.isFolder, node.kind != .favorite { folders.append(node) }
        }
        return folders
    }

    /// Stops every folder read that is still running (the Browser closed).
    func cancelLoads() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }

    /// Invalidate cached children for `node` (so a fresh disk read happens
    /// next time). Useful after rename / new-folder / delete operations.
    public func invalidate(_ node: FolderTreeNode) {
        node.children = []
        node.childrenLoaded = false
        node.isUnreadable = false
        node.loadGeneration += 1
        inFlight[ObjectIdentifier(node)] = nil
    }
}

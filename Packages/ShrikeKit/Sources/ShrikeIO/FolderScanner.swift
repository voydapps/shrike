//
//  FolderScanner.swift
//  ShrikeIO
//
//  Lists the images of one folder as `ImageGroup`s, and finds the folder
//  before / after it for ⌥⌘← / ⌥⌘→.
//
//  * One list: a file is an image when `ImageFormat.isSupported` says so
//    (what this Mac's ImageIO can decode). Sidecars (.xmp, .aae) and Live
//    Photo movies (.mov) are listed too so `ImageGrouping` can attach them.
//  * The file the user opened (`including`) is always in the result, even
//    when its extension is unknown or it is hidden. It is
//    matched with `standardizedFileURL.resolvingSymlinksInPath()`, then by
//    file identity, so `/var` vs `/private/var` or a case difference on a
//    case-insensitive volume never drops it.
//  * Never walks outside the folder: one directory listing, no recursion,
//    symlinked directories are not followed. `siblingFolders` lists the
//    parent once and looks one level into a sibling only to check that it
//    holds at least one image, one sibling at a time, stopping at the
//    first image it finds.
//  * All work runs off the main actor (`@concurrent`) and honours task
//    cancellation between entries.
//

import Foundation
import ShrikeCore

public enum FolderScannerError: Error, Equatable, Sendable {
    /// The URL is not an existing directory (deleted, unmounted, a file).
    case notADirectory(URL)
    /// The folder exists but Shrike may not read it.
    case permissionDenied(URL)
    /// Any other listing failure; `reason` is the system's one-line message.
    case unreadable(URL, reason: String)
}

public struct FolderScanIssue: Sendable, Hashable {
    public let url: URL
    public let reason: String
}
public struct FolderScanResult: Sendable {
    public let groups: [ImageGroup]
    public let skipped: [FolderScanIssue]
    public var skippedCount: Int { skipped.count }
}

/// The folders on either side of a folder, in its parent, for ⌥⌘← / ⌥⌘→.
public struct SiblingFolders: Sendable, Equatable {
    /// The nearest earlier sibling that holds at least one image.
    public let previous: URL?
    /// The nearest later sibling that holds at least one image.
    public let next: URL?

    public init(previous: URL?, next: URL?) {
        self.previous = previous
        self.next = next
    }

    public static let none = SiblingFolders(previous: nil, next: nil)
}

public enum FolderScanner {

    public enum Direction: Sendable {
        case previous, next
    }

    // MARK: - Images of a folder

    /// The images in `folder`, grouped (RAW+JPEG pairs, sidecars, Live
    /// Photo movies) and sorted by name with `localizedStandardCompare`
    /// (Finder order: "IMG_2" before "IMG_10").
    ///
    /// - Parameters:
    ///   - including: a file that must be in the result even if its type is
    ///     unknown or it is hidden (the file the user opened). Ignored when
    ///     it isn't directly inside `folder`.
    ///   - showHidden: list names starting with "." (`Prefs.showHiddenFiles`).
    ///   - grouping: defaults to the user's `shrike.grouping.pairRAW` choice.
    /// - Throws: `FolderScannerError`.
    @concurrent
    public static func imageGroups(
        in folder: URL,
        including: URL? = nil,
        showHidden: Bool = false,
        grouping: ImageGrouping.Options = ImageGroupingPreference.options
    ) async throws -> [ImageGroup] {
        let urls = try imageURLs(in: folder, including: including, showHidden: showHidden)
        try Task.checkCancellation()
        return ImageGrouping.group(urls, options: grouping)
    }

    @concurrent
    public static func imageGroupsWithDiagnostics(in folder: URL, including: URL? = nil, showHidden: Bool = false,
        grouping: ImageGrouping.Options = ImageGroupingPreference.options) async throws -> FolderScanResult {
        let result = try scanURLs(in: folder, including: including, showHidden: showHidden)
        try Task.checkCancellation()
        return FolderScanResult(groups: ImageGrouping.group(result.urls, options: grouping), skipped: result.skipped)
    }

    /// The flat, sorted file list `imageGroups` groups. Synchronous; call
    /// it off the main actor.
    public static func imageURLs(
        in folder: URL,
        including: URL? = nil,
        showHidden: Bool = false
    ) throws -> [URL] {
        try scanURLs(in: folder, including: including, showHidden: showHidden).urls
    }

    private static func scanURLs(in folder: URL, including: URL?, showHidden: Bool) throws
        -> (urls: [URL], skipped: [FolderScanIssue]) {
        let fm = FileManager.default
        let base = folder.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard base.isFileURL,
              fm.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw FolderScannerError.notADirectory(folder) }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: keys,
                options: showHidden ? [] : [.skipsHiddenFiles]
            )
        } catch {
            throw mapListingError(error, folder: folder)
        }

        var names: [String] = []
        var skipped: [FolderScanIssue] = []
        names.reserveCapacity(entries.count)
        for (i, entry) in entries.enumerated() {
            if i & 1023 == 0, Task.isCancelled { throw CancellationError() }
            guard ImageFormat.isFolderScanCandidate(entry) else { continue }
            do {
                let values = try entry.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true || (values.isSymbolicLink == true && isFile(entry)) else { continue }
                guard fm.isReadableFile(atPath: entry.path) else {
                    skipped.append(FolderScanIssue(url: entry, reason: "Permission denied or file unavailable.")); continue
                }
            } catch {
                skipped.append(FolderScanIssue(url: entry, reason: error.localizedDescription)); continue
            }
            names.append(entry.lastPathComponent)
        }

        if let including, let name = matchingName(of: including, in: base, listed: names) {
            if !names.contains(name) { names.append(name) }
            skipped.removeAll { $0.url.lastPathComponent == name }
        }

        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return (names.map { base.appendingPathComponent($0, isDirectory: false) }, skipped)
    }

    // MARK: - Sibling folders

    /// The previous and next folder next to `folder` in its parent: sorted
    /// with `localizedStandardCompare`, skipping hidden folders, packages,
    /// symlinks and folders with no image. Checks siblings lazily, nearest
    /// first, and stops at the first one with an image in each direction.
    @concurrent
    public static func siblingFolders(of folder: URL, showHidden: Bool = false) async -> SiblingFolders {
        guard let (siblings, index) = orderedSiblings(of: folder, showHidden: showHidden) else {
            return .none
        }
        let previous = firstFolderWithImage(in: siblings[..<index].reversed(), showHidden: showHidden)
        let next = firstFolderWithImage(in: siblings[(index + 1)...], showHidden: showHidden)
        return SiblingFolders(previous: previous, next: next)
    }

    /// One direction of `siblingFolders` (cheaper when only one is needed).
    @concurrent
    public static func adjacentFolder(
        of folder: URL, _ direction: Direction, showHidden: Bool = false
    ) async -> URL? {
        guard let (siblings, index) = orderedSiblings(of: folder, showHidden: showHidden) else {
            return nil
        }
        switch direction {
        case .previous:
            return firstFolderWithImage(in: siblings[..<index].reversed(), showHidden: showHidden)
        case .next:
            return firstFolderWithImage(in: siblings[(index + 1)...], showHidden: showHidden)
        }
    }

    /// True when `folder` directly contains at least one supported image.
    /// Stops at the first one; does not recurse.
    public static func containsImage(_ folder: URL, showHidden: Bool = false) -> Bool {
        let options: FileManager.DirectoryEnumerationOptions = showHidden
            ? [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
            : [.skipsSubdirectoryDescendants, .skipsPackageDescendants, .skipsHiddenFiles]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: options,
            errorHandler: { _, _ in true }
        ) else { return false }
        var seen = 0
        while let entry = enumerator.nextObject() as? URL {
            seen += 1
            if seen & 255 == 0, Task.isCancelled { return false }
            if ImageFormat.isSupported(entry), isFile(entry) { return true }
        }
        return false
    }

    // MARK: - Lookup helper

    /// Index of the group that holds `url` (as primary or companion),
    /// compared with `standardizedFileURL.resolvingSymlinksInPath()`.
    public static func index(of url: URL, in groups: [ImageGroup]) -> Int? {
        let targetName = url.lastPathComponent.lowercased()
        let target = canonicalPath(url)
        let targetLowered = target.lowercased()
        var caseOnlyMatch: Int?
        for (i, group) in groups.enumerated() {
            // Only same-named files are resolved on disk, so this stays
            // cheap for a 20,000-item folder.
            for candidate in group.allURLs where candidate.lastPathComponent.lowercased() == targetName {
                let path = canonicalPath(candidate)
                if path == target { return i }
                if caseOnlyMatch == nil, path.lowercased() == targetLowered { caseOnlyMatch = i }
            }
        }
        return caseOnlyMatch
    }

    // MARK: - Private

    /// `folder`'s parent's visible sub-folders, sorted, and `folder`'s
    /// place in them. Nil at a volume root or when the parent can't be read.
    private static func orderedSiblings(of folder: URL, showHidden: Bool) -> ([URL], Int)? {
        let base = folder.standardizedFileURL
        let parent = base.deletingLastPathComponent().standardizedFileURL
        guard parent.path != base.path else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return nil }

        var folders: [URL] = []
        var selfName: String?
        for entry in entries {
            let name = entry.lastPathComponent
            if name == base.lastPathComponent {
                selfName = name
                continue
            }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true,
                  values?.isPackage != true,
                  values?.isSymbolicLink != true
            else { continue }
            folders.append(parent.appendingPathComponent(name, isDirectory: true))
        }
        // `folder` typed with a different case than on disk.
        if selfName == nil, let i = folders.firstIndex(where: {
            $0.lastPathComponent.caseInsensitiveCompare(base.lastPathComponent) == .orderedSame
                && sameFile($0, base)
        }) {
            selfName = folders.remove(at: i).lastPathComponent
        }
        // The current folder may be hidden while showHidden is off; it is
        // still the anchor.
        let anchorName = selfName ?? base.lastPathComponent
        let anchor = parent.appendingPathComponent(anchorName, isDirectory: true)
        folders.append(anchor)
        folders.sort {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        guard let index = folders.firstIndex(of: anchor) else { return nil }
        return (folders, index)
    }

    private static func firstFolderWithImage<S: Sequence>(in candidates: S, showHidden: Bool) -> URL?
    where S.Element == URL {
        for candidate in candidates {
            if Task.isCancelled { return nil }
            if containsImage(candidate, showHidden: showHidden) { return candidate }
        }
        return nil
    }

    /// Regular file, or a symlink to one (the link itself is listed; its
    /// target is only stat-ed, never listed).
    private static func isFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values?.isRegularFile == true { return true }
        guard values?.isSymbolicLink == true else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }

    /// The on-disk name of `url` when it is a file directly inside
    /// `folder` (path match, then file-identity match for case / symlink
    /// differences), or nil.
    private static func matchingName(of url: URL, in folder: URL, listed: [String]) -> String? {
        let target = url.standardizedFileURL
        guard isFile(target) else { return nil }
        let parent = canonicalPath(target.deletingLastPathComponent())
        let folderPath = canonicalPath(folder)
        let name = target.lastPathComponent
        if parent == folderPath {
            return listed.first { $0 == name } ?? onDiskName(of: target) ?? name
        }
        // Parent differs only by case, or the file is reached by another
        // path: accept it when the same file sits in `folder`.
        guard parent.caseInsensitiveCompare(folderPath) == .orderedSame else { return nil }
        let candidate = folder.appendingPathComponent(name)
        guard sameFile(candidate, target) else { return nil }
        return onDiskName(of: candidate) ?? name
    }

    /// Name as stored on disk (fixes the case of a user-typed path).
    private static func onDiskName(of url: URL) -> String? {
        try? url.resourceValues(forKeys: [.nameKey]).name
    }

    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let ka = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let kb = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let ka, let kb { return ka.isEqual(kb) }
        return canonicalPath(a) == canonicalPath(b)
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func mapListingError(_ error: any Error, folder: URL) -> FolderScannerError {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileReadNoPermissionError:
                return .permissionDenied(folder)
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notADirectory(folder)
            default:
                break
            }
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(EACCES) || ns.code == Int(EPERM) {
            return .permissionDenied(folder)
        }
        return .unreadable(folder, reason: ns.localizedDescription)
    }
}

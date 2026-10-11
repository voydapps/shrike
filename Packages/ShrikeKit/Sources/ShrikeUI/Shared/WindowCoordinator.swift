//
//  WindowCoordinator.swift
//  ShrikeUI
//
//  Owns every Browser and Viewer window, routes open requests
// and pairs a Browser with its viewer.
//
//  * Windows are released in `willClose`: the arrays below are
//    the only strong references.
//  * Folder scans run off the main thread (`FolderScanner` is
//    `@concurrent`); the viewer opens once the list is known.
//

import AppKit
import ShrikeCore
import ShrikeIO
import ShrikeRendering

@MainActor
public final class WindowCoordinator {

    public static let shared = WindowCoordinator()

    public private(set) var viewers: [ViewerWindow] = []
    public private(set) var browsers: [BrowserWindowController] = []

    // MARK: - Quit (a pending rotate is written on quit)

    /// True while a rotate / flip write is waiting or running.
    public var hasPendingFileWrites: Bool {
        viewers.contains { $0.pendingOrientation != nil || $0.orientationWriteChain != nil }
            || browsers.contains { $0.hasPendingOrientationWrites }
    }

    /// True while a viewer is in edit mode (its exit alert runs on ⌘Q).
    public var hasViewersInEditMode: Bool {
        viewers.contains { $0.contentRoot.editModeController.isActive }
    }

    /// ⌘Q: shows the edit exit alert on each viewer with
    /// unsaved edits, one at a time. False when the user cancelled (or a
    /// save failed): the quit is cancelled.
    public func resolveUnsavedEditsBeforeQuit() async -> Bool {
        await Self.resolveUnsavedEdits(in: viewers)
    }

    static func resolveUnsavedEdits(in viewers: [ViewerWindow]) async -> Bool {
        for viewer in viewers where !(await viewer.resolveUnsavedEditsForQuit()) {
            return false
        }
        return true
    }

    /// Writes every pending rotate now and waits for the writes, but never
    /// longer than `timeout`, so quitting is not held up for long.
    public func flushPendingFileWrites(timeout: Duration = .seconds(2)) async {
        let viewers = viewers
        let browsers = browsers
        var done = false
        Task { @MainActor in
            for viewer in viewers { await viewer.waitForOrientationWrites() }
            for browser in browsers { await browser.waitForOrientationWrites() }
            done = true
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !done, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Called whenever a Browser or Viewer opens (the app closes Welcome).
    public var onWindowOpened: (() -> Void)?
    /// Called with copy for a toast when there is nowhere else to show it
    /// ("Shrike can't open “notes.txt”." with only Welcome open).
    public var onMessage: ((String) -> Void)?

    /// Most folders one drop opens.
    public static let maxFoldersPerOpen = 4

    public init() {}

    /// Services every window shares; set by the app at launch.
    public var services: ShrikeServices?
    /// Open requests still scanning their folder (Welcome waits for them).
    public private(set) var pendingOpens = 0
    /// Called when a pending open has finished (opened or failed).
    public var onOpenSettled: (() -> Void)?

    /// `open(_:services:)` with the shared services.
    public func open(_ urls: [URL]) {
        guard let services else { return }
        open(urls, services: services)
    }

    /// Open Folder…: a Browser per folder (max 4), from any window.
    public func openFolders(_ folders: [URL]) {
        guard let services else { return }
        for folder in folders.prefix(Self.maxFoldersPerOpen) {
            openBrowser(at: folder, selecting: nil, services: services).window?.makeKeyAndOrderFront(nil)
        }
    }

    /// File ▸ New Browser Window (⌘N).
    public func newBrowserWindow() {
        guard let services else { return }
        openBrowser(at: nil, selecting: nil, services: services).window?.makeKeyAndOrderFront(nil)
    }

    public var hasWindows: Bool { !viewers.isEmpty || !browsers.isEmpty }

    // MARK: - Open requests

    /// Classified open request.
    public struct Request: Equatable, Sendable {
        public var images: [URL] = []
        public var folders: [URL] = []
        public var unopenable: [URL] = []
    }

    /// Splits `urls` into images, folders and files Shrike can't open.
    nonisolated public static func classify(_ urls: [URL], fileManager: FileManager = .default) -> Request {
        var request = Request()
        for url in urls {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                request.folders.append(url)
            } else if ImageFormat.isSupported(url) {
                request.images.append(url)
            } else {
                request.unopenable.append(url)
            }
        }
        return request
    }

    /// The viewer list for the images of one request, and where to start.
    /// One image: its folder's groups. Several from one folder: only those,
    /// in the given order. Several folders: sorted by folder, then name.
    nonisolated public static func viewerList(for images: [URL], showHidden: Bool) async -> (groups: [ImageGroup], start: Int) {
        guard let first = images.first else { return ([], 0) }
        let options = ImageGroupingPreference.options
        if images.count == 1 {
            let folder = first.deletingLastPathComponent()
            let groups = (try? await FolderScanner.imageGroups(
                in: folder, including: first, showHidden: showHidden, grouping: options
            )) ?? []
            if let index = FolderScanner.index(of: first, in: groups) {
                return (groups, index)
            }
            // The scan failed or missed it: the opened file is always listed.
            return ([ImageGroup(primary: first)] + groups, 0)
        }
        let folders = Set(images.map { $0.deletingLastPathComponent().standardizedFileURL.path })
        var ordered = images
        if folders.count > 1 {
            ordered.sort { a, b in
                let fa = a.deletingLastPathComponent().path, fb = b.deletingLastPathComponent().path
                if fa != fb { return fa.localizedStandardCompare(fb) == .orderedAscending }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
        }
        let grouped = ImageGrouping.group(ordered, options: options)
        // Keep the requested order: position of each group's first given URL.
        let rank = Dictionary(ordered.enumerated().map { ($1.standardizedFileURL.path, $0) },
                              uniquingKeysWith: { a, _ in a })
        let sorted = grouped.sorted { a, b in
            let ra = a.allURLs.compactMap { rank[$0.standardizedFileURL.path] }.min() ?? Int.max
            let rb = b.allURLs.compactMap { rank[$0.standardizedFileURL.path] }.min() ?? Int.max
            return ra < rb
        }
        return (sorted, 0)
    }

    /// When `urls` is one photo,
    /// start its decode and texture now, in parallel with launch, the
    /// folder scan and the viewer window. The viewer's decode queue takes
    /// it over (`DecodeHandoff`). Safe to call before services exist.
    /// Decoded at the size the new viewer's queue will
    /// ask for (`ViewerWindow.initialTextureLongEdge`), not at the
    /// max-long-edge pref: a 2400 px texture for a 1200 x 800 pt window
    /// on a 2x screen instead of 4096 px (a third of the memory, and a
    /// subsampled, faster decode).
    /// `frame`: the frame the viewer will get, when it is not the saved
    /// one (a cascade from an open viewer).
    public static func startEarlyDecode(for urls: [URL], frame: NSRect? = nil) {
        guard urls.count == 1, let url = urls.first, url.isFileURL,
              ImageFormat.isSupported(url) else { return }
        DecodeHandoff.shared.start(
            url: url, targetLongEdge: ViewerWindow.initialTextureLongEdge(frame: frame),
            preparer: DisplayTextureFactory.preparer
        )
    }

    /// Open Recent is noted after the photo is up, not before the scan:
    /// `noteNewRecentDocumentURL` runs on the main thread.
    static let recentNoteDelay: TimeInterval = 1.0

    private func noteRecents(_ urls: [URL], after delay: TimeInterval) {
        guard !urls.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for url in urls { Self.noteRecent(url) }
        }
    }

    /// Open Recent. Tests open folders in scratch directories that are
    /// deleted at the end of the run; those must not reach the user's list.
    static func noteRecent(_ url: URL) {
        guard !ShrikeDataPaths.isRunningTests else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    /// Opens `urls` from Finder, the Dock, an Open panel or a drop.
    public func open(_ urls: [URL], services: ShrikeServices, noteRecent: Bool = true) {
        let request = Self.classify(urls)
        if let bad = request.unopenable.first, request.images.isEmpty, request.folders.isEmpty {
            report("Shrike can't open “\(bad.lastPathComponent)”.")
            return
        }
        // A photo already on screen in a viewer
        // brings that window forward (as Preview does) instead of a second
        // window 24 pt lower.
        if request.images.count == 1, request.folders.isEmpty,
           let viewer = viewerShowing(request.images[0]) {
            if noteRecent { noteRecents(request.images, after: 0) }
            bringForward(viewer)
            return
        }
        if request.images.count == 1 {
            Self.startEarlyDecode(for: request.images, frame: cascadeSourceFrame)
        }
        if noteRecent {
            noteRecents(request.images + request.folders.prefix(Self.maxFoldersPerOpen),
                        after: request.images.isEmpty ? 0 : Self.recentNoteDelay)
        }
        var lastBrowser: BrowserWindowController?
        for folder in request.folders.prefix(Self.maxFoldersPerOpen) {
            lastBrowser = openBrowser(at: folder, selecting: nil, services: services)
            lastBrowser?.window?.makeKeyAndOrderFront(nil)
        }
        if request.folders.count > Self.maxFoldersPerOpen {
            lastBrowser?.toast("Opened \(Self.maxFoldersPerOpen) folders. Drop fewer folders to open the rest.")
        }
        guard !request.images.isEmpty else { return }
        let images = request.images
        pendingOpens += 1
        let hidden = Prefs.showHiddenFiles
        // The folder scan starts now, off the main thread,
        // instead of first waiting for a main-actor task to start it (the
        // main thread is still busy finishing launch, ~20 ms). One hop
        // back to the main actor builds the viewer when the list is known.
        let state = ShrikeSignposts.launch.begin("scanOpenFolder")
        let scan = Task.detached(priority: .userInitiated) {
            await Self.viewerList(for: images, showHidden: hidden)
        }
        Task { @MainActor [weak self] in
            let (groups, start) = await scan.value
            ShrikeSignposts.launch.end("scanOpenFolder", state)
            guard let self else { return }
            self.pendingOpens -= 1
            defer { self.onOpenSettled?() }
            guard !groups.isEmpty else { return }
            let viewer = self.openViewer(groups: groups, startIndex: start, services: services)
            // A ready texture goes on the canvas first.
            let path = ShrikeSignposts.launch.begin("readyPhotoPath")
            await viewer.orderFrontWithReadyPhoto()
            ShrikeSignposts.launch.end("readyPhotoPath", path)
        }
    }

    /// The viewer on screen (or in the Dock) that shows `url`, or is
    /// about to show it as its first photo. Hidden viewers (a paired
    /// viewer the Browser put away) don't count.
    func viewerShowing(_ url: URL) -> ViewerWindow? {
        let key = Self.pathKey(url)
        return viewers.last { viewer in
            guard !viewer.didTearDown, viewer.isVisible || viewer.isMiniaturized else { return false }
            let shown: [URL]
            if let item = viewer.displayedItem {
                shown = item.group.allURLs
            } else if let file = viewer.intent.sourceAt(viewer.intent.currentIndex) as? FileImageSource {
                shown = [file.url]
            } else {
                shown = []
            }
            return shown.contains { Self.pathKey($0) == key }
        }
    }

    /// Same file, spelled with or without the `/private` of the temp and
    /// `/var` folders. No file-system call (this runs on the main thread).
    nonisolated static func pathKey(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        for alias in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(alias) {
            path.removeFirst("/private".count)
        }
        return path
    }

    /// Times an open request brought a viewer forward (tests).
    private(set) var broughtForwardCountForTesting = 0

    private func bringForward(_ viewer: ViewerWindow) {
        broughtForwardCountForTesting += 1
        if viewer.isMiniaturized { viewer.deminiaturize(nil) }
        viewer.makeKeyAndOrderFront(nil)
    }

    private func report(_ message: String) {
        if let window = NSApp.mainWindow as? ViewerWindow {
            window.contentRoot.toast(ToastContent(message, kind: .error))
        } else if let browser = browsers.first(where: { $0.window === NSApp.mainWindow }) {
            browser.toast(message)
        } else {
            onMessage?(message)
        }
    }

    // MARK: - Windows

    /// The viewer a new standalone viewer cascades from.
    private var cascadeSource: ViewerWindow? { viewers.last { $0.isVisible } }

    /// Frame of `cascadeSource`: the size the next Finder-opened viewer
    /// gets (nil: the saved "shrike.viewer" frame). For `startEarlyDecode`.
    public var cascadeSourceFrame: NSRect? { cascadeSource?.frame }

    /// Test seam: the frame a standalone viewer gets instead of the saved
    /// "shrike.viewer" frame (whose autosave writes the process defaults).
    var standaloneFrameForTesting: NSRect?

    /// A new viewer on `groups` (not paired).
    @discardableResult
    public func openViewer(
        groups: [ImageGroup], startIndex: Int, services: ShrikeServices, frame: NSRect? = nil
    ) -> ViewerWindow {
        let state = ShrikeSignposts.launch.begin("openViewerWindow")
        let initState = ShrikeSignposts.launch.begin("viewerInit")
        let frame = frame ?? standaloneFrameForTesting
        let cascadeFrom = frame == nil ? cascadeSource : nil
        ViewerWindow.nextFrameHint = frame ?? cascadeFrom?.frame
        let viewer = ViewerWindow(groups: groups, startIndex: startIndex, services: services)
        ShrikeSignposts.launch.end("viewerInit", initState)
        let frameState = ShrikeSignposts.launch.begin("viewerFrame")
        if let frame {
            viewer.setFrame(frame, display: false)
        } else {
            // The saved "shrike.viewer" frame; each further
            // window cascades from the last one.
            viewer.applyStandaloneFrame(cascadingFrom: cascadeFrom)
        }
        ShrikeSignposts.launch.end("viewerFrame", frameState)
        ShrikeSignposts.launch.end("openViewerWindow", state)
        let registerState = ShrikeSignposts.launch.begin("viewerRegister")
        defer { ShrikeSignposts.launch.end("viewerRegister", registerState) }
        viewers.append(viewer)
        track(viewer)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: viewer
        )
        onWindowOpened?()
        return viewer
    }

    /// Only the viewer the user works in
    /// keeps its prefetched neighbours. When one viewer becomes main, the
    /// other viewers drop theirs (their photo stays on screen); they
    /// prefetch again when they are main again. Other apps, Settings and
    /// popovers change nothing.
    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let main = note.object as? ViewerWindow else { return }
        for viewer in viewers {
            let navigation = viewer.navigation
            let background = viewer !== main
            Task { await navigation.decodeQueue.setBackground(background) }
        }
    }

    /// A new Browser at `folder`, with `selecting` selected once listed.
    @discardableResult
    public func openBrowser(
        at folder: URL?, selecting: URL?, services: ShrikeServices
    ) -> BrowserWindowController {
        // The saved Browser size; 24 pt down-right of an open one.
        let cascadeFrom = browsers.last { $0.window?.isVisible == true }?.window
        let controller = BrowserWindowController(services: services, initialFolder: folder, selecting: selecting)
        if let cascadeFrom { controller.cascade(from: cascadeFrom) }
        browsers.append(controller)
        track(controller.window)
        if let folder { Self.noteRecent(folder) }
        onWindowOpened?()
        return controller
    }

    /// Return / double-click / ⌘B in a Browser: reuse the
    /// paired viewer, or create one at the Browser's frame and pair it.
    @discardableResult
    public func openPairedViewer(
        from browser: BrowserWindowController, groups: [ImageGroup], startIndex: Int
    ) -> ViewerWindow? {
        guard !groups.isEmpty else { return nil }
        if let viewer = browser.pairedViewer {
            viewer.showFromBrowser(groups: groups, startIndex: startIndex)
            return viewer
        }
        let viewer = openViewer(
            groups: groups, startIndex: startIndex,
            services: browser.services,
            frame: browser.window.map { Self.pairedViewerFrame(over: $0.frame, visible: $0.screen?.visibleFrame) }
        )
        viewer.pair(with: browser)
        viewer.makeKeyAndOrderFront(nil)
        return viewer
    }

    /// The first paired viewer cascades from the Browser
    /// (24 pt right and down) instead of covering it exactly, so the
    /// Browser stays visible behind it. On a screen with no room to move,
    /// the viewer gives up those 24 pt of size instead.
    nonisolated static let pairedViewerOffset: CGFloat = 24

    /// A Browser smaller than this (a wide strip, a narrow column) does not
    /// give its frame to the viewer: the viewer opens at its default size,
    /// centred on the Browser (spec 19 s3.1 keeps the Browser's frame when
    /// it is a sensible viewer size).
    nonisolated static let pairedViewerMinimum = NSSize(width: 800, height: 500)
    nonisolated static let pairedViewerDefault = NSSize(width: 1200, height: 800)

    nonisolated static func pairedViewerFrame(over browser: NSRect, visible: NSRect?) -> NSRect {
        let step = pairedViewerOffset
        if browser.width < pairedViewerMinimum.width || browser.height < pairedViewerMinimum.height {
            var size = pairedViewerDefault
            if let visible {
                size.width = min(size.width, visible.width)
                size.height = min(size.height, visible.height)
            }
            var frame = NSRect(x: browser.midX - size.width / 2, y: browser.midY - size.height / 2,
                               width: size.width, height: size.height)
            if let visible {
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            return frame
        }
        var frame = browser.offsetBy(dx: step, dy: -step)
        guard let visible else { return frame }
        if frame.maxX > visible.maxX {
            frame.size.width = max(browser.width - step, visible.maxX - frame.minX)
        }
        if frame.minY < visible.minY {
            let top = frame.maxY
            frame.origin.y = max(visible.minY, top - (browser.height - step))
            frame.size.height = top - frame.origin.y
        }
        return frame
    }

    private func track(_ window: NSWindow?) {
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: window
        )
    }

    @objc private func windowWillClose(_ note: Notification) {
        guard let closed = note.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: closed)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeMainNotification, object: closed)
        // Closing either side drops the pairing; the other window stays.
        if let viewer = closed as? ViewerWindow {
            viewer.pairedBrowser?.pairedViewer = nil
            viewer.pairedBrowser = nil
        }
        if let browser = browsers.first(where: { $0.window === closed }) {
            browser.pairedViewer?.pairedBrowser = nil
            browser.pairedViewer = nil
        }
        viewers.removeAll { $0 === closed }
        browsers.removeAll { $0.window === closed }
    }
}

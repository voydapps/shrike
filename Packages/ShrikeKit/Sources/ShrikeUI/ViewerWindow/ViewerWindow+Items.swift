//
//  ViewerWindow+Items.swift
//  ShrikeUI
//
//  The viewer's list of groups, the displayed item, trash + undo, folder
//  navigation and the hand-off back to a paired Browser.
//
//  * displayed item, undo, groups, titles, paired windows, folder
//    navigation, Esc.
//

import AppKit
import ShrikeCore
import ShrikeIO

/// User-facing copy for file actions.
enum FileActionCopy {

    /// T1: "Moved “DSC_0042.jpg” to the Trash." / "… and its RAW file …".
    static func movedToTrash(_ groups: [ImageGroup]) -> String {
        guard groups.count == 1, let group = groups.first else {
            return "Moved \(groups.count) items to the Trash."
        }
        if group.hasRAW && !group.primaryIsRAW {
            return "Moved “\(FileNameFit.short(group.displayName))” and its RAW file to the Trash."
        }
        return "Moved “\(FileNameFit.short(group.displayName))” to the Trash."
    }

    /// T2: "Couldn't move “x.jpg” to the Trash — the volume is read-only."
    static func trashFailed(_ group: ImageGroup, error: any Error) -> String {
        let base = "Couldn't move “\(FileNameFit.short(group.displayName))” to the Trash"
        if let ops = error as? FileOpsError, let reason = reason(for: ops) {
            return "\(base) — \(reason)."
        }
        return "\(base)."
    }

    /// "Put back “DSC_0042.jpg”." or "Put back as “DSC_0042 2.jpg”."
    static func putBack(original: ImageGroup, restored: ImageGroup) -> String {
        if original.primary.lastPathComponent == restored.primary.lastPathComponent {
            return "Put back “\(FileNameFit.short(restored.displayName))”."
        }
        return "Put back as “\(FileNameFit.short(restored.displayName))”."
    }

    /// The permanent-delete alert for a volume without a Trash (spec 21b §4): one builder
    /// for the Browser, the viewer and Compare. Cancel is the default (Return and Esc).
    struct NoTrashDelete: Equatable {
        let message: String
        let information: String
        let deleteTitle: String
        var buttons: [ShrikeAlert.Button] {
            [ShrikeAlert.Button(deleteTitle, role: .destructive), .safeCancel()]
        }
    }

    static func noTrashDelete(_ groups: [ImageGroup]) -> NoTrashDelete {
        let one = groups.count == 1
        var info = one
            ? "This disk has no Trash, so the photo can't be moved there. Deleting it now is permanent. You can't undo this."
            : "This disk has no Trash, so these photos can't be moved there. Deleting them now is permanent. You can't undo this."
        if groups.contains(where: { $0.companions.contains { $0.kind == .raw || $0.kind == .sidecar } }) {
            info += one ? " Its RAW and sidecar files are deleted too." : " Their RAW and sidecar files are deleted too."
        }
        return NoTrashDelete(
            message: one ? "Delete “\(groups[0].displayName)” now?" : "Delete \(groups.count) photos now?",
            information: info,
            deleteTitle: one ? "Delete" : "Delete \(groups.count) Photos")
    }

    /// After the permanent-delete alert's Delete fails.
    static func deleteFailed(_ group: ImageGroup, error: any Error) -> String {
        let base = "Couldn't delete “\(FileNameFit.short(group.displayName))”"
        if let ops = error as? FileOpsError, let reason = reason(for: ops) {
            return "\(base) — \(reason)."
        }
        return "\(base)."
    }

    static func noLongerInTrash(_ name: String) -> String {
        "Couldn't undo — “\(FileNameFit.short(name))” is no longer in the Trash."
    }

    static func reason(for error: FileOpsError) -> String? {
        switch error {
        case .readOnlyVolume: return "the volume is read-only"
        case .permissionDenied: return "you don't have permission"
        case .notFound: return "the file no longer exists"
        default: return nil
        }
    }
}

/// End-of-folder cue state.
struct EndOfFolderCue {
    let direction: FolderScanner.Direction
    let deadline: Date
    /// The folder the second press opens; nil when there is none.
    var folder: URL?
}

extension ViewerWindow {

    // MARK: - Displayed item

    /// Records what is on screen. Called in the same main-actor turn that
    /// hands pixels (preview, stand-in or full) to the Metal view, or shows
    /// the error overlay for a file.
    func markDisplayed(_ index: Int) {
        defer {
            refreshReviewRecord()
            // The toolbar follows the displayed photo at once. AppKit re-validates it
            // only on mouse events, so after keyboard navigation it showed the PREVIOUS
            // photo's rating, Back and Edit state until the pointer moved (audit M2).
            toolbar?.validateVisibleItems()
        }
        guard let group = list[index] else { return }
        // A late paint from a list that has since changed must not label
        // the screen with the wrong file.
        // The source that painted is the shown file: the primary, or (spec 24
        // §4) the group's RAW after ⌥R.
        var shown = group.primary
        if let file = intent.sourceAt(index) as? FileImageSource {
            let painted = GroupList.canonical(file.url)
            guard let match = group.allURLs.first(where: { GroupList.canonical($0) == painted }) else { return }
            if group.rawURL == match, match != group.primary { shown = match }
        }
        let item = DisplayedItem(group: group, listIndex: index, generation: list.generation, shownURL: shown)
        guard item != displayedItem else { return }
        let newFile = displayedItem?.group.primary != group.primary
        let previousListIndex = displayedItem?.listIndex
        if newFile {
            cancelFullResolution()
            // Navigation writes a pending rotate now and drops the
            // view-only turn.
            flushPendingOrientation()
            contentRoot.imageView.resetOrientation()
            for url in viewOnlyTurnedURLs { headerPixelSizes[url] = nil }
            viewOnlyTurnedURLs.removeAll()
        }
        let previousShown = displayedItem?.shownURL
        displayedItem = item
        // The pill and the inspector show the marks of what is on screen. A list
        // swapped in from the Browser reads its records later and used to draw them
        // for the OLD item's index (stale rating / flag).
        if newFile || item.listIndex != previousListIndex {
            contentRoot.setPositionMarks(positionMarks(for: index))
        }
        // Edit is off while the RAW is shown (spec 24 §4.5); the Edit
        // button's tooltip says why.
        contentRoot.editBlockedByRAW = item.isRAWShown
        if displayedItem != nil, item.shownURL != previousShown {
            // The inspector reads the shown file (spec 24 §4.5): the RAW's
            // name, size, dimensions, type and EXIF while it is on screen.
            contentRoot.setCurrentURL(item.shownURL)
            refreshInspectorFileState()
        }
        // The LIVE badge follows the group; navigation stops
        // and frees any playing movie.
        contentRoot.setLivePhotoMovie(group.livePhotoMovie, newPhoto: newFile)
        watchFolder(of: group.primary)
        updateTitle()
        if newFile { scheduleLocationLookup() }
    }

    /// Title = file name, proxy icon, subtitle "43 of 180 · 6000 × 4000".
    func updateTitle() {
        guard let item = displayedItem else {
            title = "Shrike"
            subtitle = ""
            representedURL = nil
            return
        }
        let url = item.shownURL
        // The side panel's "n of N" follows the title when the list grows or
        // shrinks (Save Copy, a file added or removed) without a new photo.
        contentRoot.updateInspectorPosition(index: item.listIndex, total: list.count)
        title = url.lastPathComponent
        representedURL = url.isFileURL ? url : nil
        if contentRoot.isEditModeActive {
            subtitle = contentRoot.editModeController.chromeState.subtitle
            return
        }
        if let known = headerPixelSizes[url] {
            contentRoot.imageView.sourcePixelSize = known
            subtitle = WindowTitles.viewerSubtitle(index: item.listIndex, total: list.count, pixelSize: known)
            return
        }
        subtitle = WindowTitles.viewerSubtitle(index: item.listIndex, total: list.count, pixelSize: nil)
        let expected = item
        let sizeReader = headerPixelSizeReaderForTesting
        Task { @MainActor [weak self] in
            let size = await Task.detached(priority: .utility) {
                sizeReader?(url) ?? WindowTitles.headerPixelSize(of: url)
            }.value
            guard let self, self.displayedItem == expected,
                  !self.contentRoot.isEditModeActive else { return }
            // "100 %" comes from the file's pixel size.
            var drawn = size
            // A turn pressed before the read returned has nothing to swap
            // yet: apply the pending net turn here.
            if let s = drawn, let pending = self.pendingOrientation,
               GroupList.canonical(pending.url) == GroupList.canonical(url),
               pending.net.components.quarters % 2 != 0 {
                drawn = CGSize(width: s.height, height: s.width)
            }
            if let drawn { self.headerPixelSizes[url] = drawn }
            self.contentRoot.imageView.sourcePixelSize = drawn
            self.requestFullResolutionIfNeeded()
            self.subtitle = WindowTitles.viewerSubtitle(
                index: expected.listIndex, total: self.list.count, pixelSize: drawn
            )
        }
    }

    // MARK: - List

    /// The groups this window lists, in order.
    public var groups: [ImageGroup] { list.groups }

    /// Replaces the list (paired Browser hand-off, folder navigation) and
    /// shows `startIndex`.
    public func setGroups(_ groups: [ImageGroup], startIndex: Int) {
        endOfFolderCue = nil
        list.replace(with: groups)
        if !groups.isEmpty { hideEmptyState() }
        reloadList(showing: startIndex)
    }

    /// Pushes the current `list` into the decode queue and shows `index`.
    func reloadList(showing index: Int) {
        // A new list shows every primary again (spec 24 §4.1: the RAW view resets).
        let sources: [any ImageSource] = list.groups.map { FileImageSource(url: $0.primary) }
        guard !sources.isEmpty else {
            displayedItem = nil
            updateTitle()
            intent.setNavigation(list: [], currentIndex: 0)
            contentRoot.releaseImages()
            coalesceNav { [weak self] in
                await self?.navigation.setNavigation(list: [], currentIndex: 0)
            }
            return
        }
        let idx = min(max(0, index), sources.count - 1)
        intent.setNavigation(list: sources, currentIndex: idx)
        loadCullingRecords()
        coalesceNav { [weak self] in
            guard let self else { return }
            await self.navigation.setNavigation(list: sources, currentIndex: idx)
            if Task.isCancelled { return }
            await self.navigate(to: idx)
        }
    }

    // MARK: - Undo — trash lives in ViewerWindow+Trash.swift

    /// ⌘Z outside edit mode, and the toast's Undo button. In edit mode
    /// ⌘Z drives the recipe and never reaches file actions.
    func performUndo() {
        if contentRoot.isEditModeActive {
            contentRoot.editModeController.performUndo()
        } else if windowUndoManager.canUndo {
            windowUndoManager.undo()
        }
    }

    func performRedo() {
        if contentRoot.isEditModeActive {
            contentRoot.editModeController.performRedo()
        } else if windowUndoManager.canRedo {
            windowUndoManager.redo()
        }
    }

    /// Edit ▸ Undo / Redo.
    @objc public func undo(_ sender: Any?) { performUndo() }
    @objc public func redo(_ sender: Any?) { performRedo() }

    /// Test seam.
    var undoManagerForTesting: UndoManager { windowUndoManager }

    /// Test seam: marks `index` as displayed without a decode.
    func markDisplayedForTesting(_ index: Int) { markDisplayed(index) }

    // MARK: - Folder navigation

    /// The folder of the displayed item.
    var displayedFolder: URL? {
        displayedItem?.group.primary.deletingLastPathComponent()
    }

    /// Opens the previous / next sibling folder that has images. Next
    /// lands on the first image, Previous on the last. A paired Browser
    /// follows.
    func goToAdjacentFolder(_ direction: FolderScanner.Direction, knownTarget: URL? = nil) {
        guard let folder = displayedFolder, editExitTask == nil,
              !contentRoot.editModeController.isTransitioning else { return }
        let source = displayedItem?.group.primary
        endOfFolderCue = nil
        let hidden = Prefs.showHiddenFiles
        Task { @MainActor [weak self] in
            let target: URL?
            if let knownTarget {
                target = knownTarget
            } else {
                target = await FolderScanner.adjacentFolder(of: folder, direction, showHidden: hidden)
            }
            guard let self, let target else {
                self?.contentRoot.toast(ToastContent(
                    direction == .next ? "No next folder." : "No previous folder."
                ))
                return
            }
            let groups = (try? await FolderScanner.imageGroups(in: target, showHidden: hidden)) ?? []
            guard !groups.isEmpty, self.displayedItem?.group.primary == source, !self.didTearDown else { return }
            let start = direction == .next ? 0 : groups.count - 1
            let windowedEdit = self.contentRoot.isEditModeActive && self.contentRoot.windowMode == .windowed
            self.leaveEditModeThen(reason: .navigation) { [weak self] in
                guard let self else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      FileManager.default.fileExists(atPath: groups[start].primary.path) else {
                    self.contentRoot.toast(ToastContent("That photo is no longer available."))
                    return
                }
                self.setGroups(groups, startIndex: start)
                self.pairedBrowser?.follow(folder: target, selecting: groups[start].primary)
                if windowedEdit { self.reenterEditModeAfterNavigation() }
            }
        }
    }

    /// Next / previous image, with the end-of-folder cue instead of a
    /// silent stop or wrap. Returns true when the cue consumed
    /// the key press.
    /// `fromSwipe`: a trackpad swipe stretched past the end.
    /// It shows the same toast but never opens a folder and never
    /// nudges (the rubber band already moved the photo).
    func handleEdgeOfFolder(_ direction: FolderScanner.Direction, fromSwipe: Bool = false) -> Bool {
        let count = list.count
        guard count > 0 else { return false }
        let atEdge = direction == .next
            ? intent.currentIndex >= count - 1
            : intent.currentIndex <= 0
        guard atEdge else {
            if !fromSwipe { endOfFolderCue = nil }
            return false
        }
        // Second press within 3 s while the cue is showing: open the folder.
        if !fromSwipe, let cue = endOfFolderCue, cue.direction == direction,
           Date() < cue.deadline, contentRoot.toastHost.isShowing {
            endOfFolderCue = nil
            if let target = cue.folder {
                goToAdjacentFolder(direction, knownTarget: target)
            }
            return true
        }
        if !fromSwipe { nudgeImage(direction) }
        let folderName = displayedFolder?.lastPathComponent ?? ""
        let deadline = Date().addingTimeInterval(3)
        endOfFolderCue = EndOfFolderCue(direction: direction, deadline: deadline, folder: nil)
        guard let folder = displayedFolder else { return true }
        let hidden = Prefs.showHiddenFiles
        Task { @MainActor [weak self] in
            let target = await FolderScanner.adjacentFolder(of: folder, direction, showHidden: hidden)
            guard let self, self.endOfFolderCue?.deadline == deadline else { return }
            self.endOfFolderCue?.folder = target
            self.contentRoot.toast(ToastContent(
                Self.edgeCopy(direction, current: folderName, target: target?.lastPathComponent)
            ))
        }
        return true
    }

    /// "Last image. Press → again to open “Day 2”." / "Last image in “Day 1”."
    static func edgeCopy(_ direction: FolderScanner.Direction, current: String, target: String?) -> String {
        switch (direction, target) {
        case (.next, let name?):
            return "Last photo. Press → again to open “\(FileNameFit.short(name))”."
        case (.next, nil):
            return "Last photo in “\(FileNameFit.short(current))”."
        case (.previous, let name?):
            return "First photo. Press ← again to open “\(FileNameFit.short(name))”."
        case (.previous, nil):
            return "First photo in “\(FileNameFit.short(current))”."
        }
    }

    /// 12 pt nudge and back, `motion.quick`; skipped with Reduce Motion.
    private func nudgeImage(_ direction: FolderScanner.Direction) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = contentRoot.imageView.layer else { return }
        let offset: CGFloat = direction == .next ? -12 : 12
        let nudge = CAKeyframeAnimation(keyPath: "transform.translation.x")
        nudge.values = [0, offset, 0]
        nudge.keyTimes = [0, 0.5, 1]
        nudge.duration = 0.24
        nudge.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(nudge, forKey: "shrike.edgeNudge")
    }

    // MARK: - Paired Browser

    /// How long a hidden viewer keeps its decode cache.
    static var hiddenTrimDelay: Duration = .seconds(60)

    /// Esc outside edit mode and sheets: one layer per press.
    func handleEscape() {
        if styleMask.contains(.fullScreen) {
            // FastStone: exit full screen, then return to the Browser.
            returnToBrowserAfterFullScreenExit =
                Prefs.shortcutPreset == .fastStoneCompat && pairedBrowser != nil
            toggleFullScreen(nil)
            return
        }
        if pairedBrowser != nil {
            returnToBrowser()
        } else {
            // Finder-opened viewer: Esc closes it; the app stays open.
            performClose(nil)
        }
    }

    /// ⌘B / ⌘↑ in the viewer.
    func showInBrowser() {
        if pairedBrowser != nil {
            if styleMask.contains(.fullScreen) {
                returnToBrowserAfterFullScreenExit = true
                toggleFullScreen(nil)
            } else {
                returnToBrowser()
            }
            return
        }
        guard let url = displayedItem?.group.primary else { return }
        let browser = WindowCoordinator.shared.openBrowser(
            at: url.deletingLastPathComponent(), selecting: url, services: services
        )
        pair(with: browser)
        browser.window?.makeKeyAndOrderFront(nil)
    }

    /// Image ▸ Batch… ⌥⌘B: the current list goes to the
    /// Batch window (added to it when it is open). An in-place rename or
    /// rotate registers its undo here.
    func openBatch() {
        guard !list.isEmpty else { return }
        BatchWindowController.open(
            groups: list.groups, services: services, launcher: self,
            toast: { [weak self] message in self?.contentRoot.toast(ToastContent(message, kind: .error)) })
    }

    /// Go ▸ Go to Folder… ⇧⌘G: the sheet on this viewer;
    /// the paired Browser (or a new one) goes there and comes forward.
    func showGoToFolderSheet() {
        guard attachedSheet == nil, goToFolderSheet == nil else { return }
        let sheet = GoToFolderSheet(base: displayedFolder)
        goToFolderSheet = sheet
        Task { @MainActor [weak self] in
            guard let self else { return }
            let target = await sheet.run(on: self)
            self.goToFolderSheet = nil
            if let target { self.go(to: target) }
        }
    }

    /// Sends the paired Browser to `target`, or opens a Browser there
    /// and pairs it; then brings it forward.
    func go(to target: GoToFolderTarget) {
        let browser: BrowserWindowController
        if let paired = pairedBrowser {
            browser = paired
            paired.go(to: target)
        } else {
            browser = Self.openBrowserForGoTo(target, services)
            pair(with: browser)
        }
        if let window = browser.window { Self.bringBrowserForward(window) }
    }

    /// Test seam: tests record instead of showing a window on screen.
    static var bringBrowserForward: @MainActor (NSWindow) -> Void = { $0.makeKeyAndOrderFront(nil) }

    /// Test seam: the coordinator's Browser also goes into Open Recent,
    /// which tests must not write to.
    static var openBrowserForGoTo: @MainActor (GoToFolderTarget, ShrikeServices) -> BrowserWindowController = {
        WindowCoordinator.shared.openBrowser(at: $0.folder, selecting: $0.selecting, services: $1)
    }

    /// Pairs this viewer with `browser` (both sides, weakly).
    public func pair(with browser: BrowserWindowController) {
        pairedBrowser?.pairedViewer = nil
        pairedBrowser = browser
        browser.pairedViewer = self
        refreshBrowserReturnContext()
    }

    /// Persistent return context follows the live paired Browser, independently
    /// of the one-time successful-photo onboarding cue.
    func refreshBrowserReturnContext() {
        if toolbarController?.updateReturnTitle(pairedBrowser?.currentFolder?.lastPathComponent) == true {
            returnHintPopover?.close(); returnHintPopover = nil
        }
    }

    /// Hides the viewer (kept alive so the next Return is instant), brings
    /// the Browser forward with the displayed photo selected.
    func returnToBrowser() {
        reviewDecisionSerial &+= 1
        guard let browser = pairedBrowser else { return }
        returnHintPopover?.close(); returnHintPopover = nil
        let selected = displayedItem?.group.primary
        isParkedForBrowser = true
        orderOut(nil)
        browser.window?.makeKeyAndOrderFront(nil)
        if let selected {
            browser.select(url: selected)
        }
        scheduleHiddenTrim()
    }

    /// 60 s after `orderOut`, drop every cached decode and the full-resolution
    /// texture (up to ~180 MB for a 45 MP photo at 100 %). The fit-size
    /// texture stays, so the next Return shows the photo at once.
    func scheduleHiddenTrim() {
        hiddenTrimTask?.cancel()
        let navigation = self.navigation
        hiddenTrimTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hiddenTrimDelay)
            guard !Task.isCancelled, let self, !self.isVisible else { return }
            await navigation.trimToCurrent()
            self.dropFullResolutionWhileParked()
            self.parkCanvasWhileHidden()
        }
    }

    /// A parked (hidden) viewer gives back its full-resolution texture at
    /// any zoom; showing it again fetches the detail it needs (audit MP-04).
    /// Edit mode keeps its pixels.
    func dropFullResolutionWhileParked() {
        guard isParkedForBrowser, !isVisible, !didTearDown, !contentRoot.isEditModeActive else { return }
        let view = contentRoot.imageView
        guard view.isShowingFullResolution, !view.isZoomAnimating else { return }
        cancelFullResolution()
        view.dropFullResolution()
    }

    /// A parked viewer also gives back its window-sized drawables (audit
    /// MP-04). `showFromBrowser` and every order-front path restore them, with
    /// one frame drawn before the window appears (`MetalImageView.unparkCanvas`).
    func parkCanvasWhileHidden() {
        guard isParkedForBrowser, !isVisible, !didTearDown, !contentRoot.isEditModeActive else { return }
        contentRoot.imageView.parkCanvas()
    }

    /// Brings a hidden paired viewer back (Return / ⌘B in the Browser).
    public func showFromBrowser(groups: [ImageGroup], startIndex: Int) {
        refreshBrowserReturnContext()
        hiddenTrimTask?.cancel()
        hiddenTrimTask = nil
        isParkedForBrowser = false
        defer { requestFullResolutionIfNeeded() }
        if contentRoot.isEditModeActive, groups.indices.contains(startIndex),
           groups[startIndex].primary == displayedItem?.group.primary {
            makeKeyAndOrderFront(nil)
            return
        }
        guard !contentRoot.isEditModeActive else {
            // A hidden viewer still editing asks before it
            // shows another photo.
            makeKeyAndOrderFront(nil)
            leaveEditModeThen(reason: .navigation) { [weak self] in
                self?.setGroups(groups, startIndex: startIndex)
            }
            return
        }
        // The same photo is still on screen (also after the 60 s trim emptied the
        // decode cache): keep it. A new navigation would paint the low-resolution
        // stand-in over a picture that is already right. Only the list is brought
        // up to date.
        if groups.indices.contains(startIndex), !isShowingEmptyState, let shown = displayedItem,
           shown.group.primary == groups[startIndex].primary, shown.shownURL == shown.group.primary,
           contentRoot.imageView.showsPhotoNotStandIn {
            endOfFolderCue = nil
            list.replace(with: groups)
            syncListKeepingDisplayed()
            makeKeyAndOrderFront(nil)
            return
        }
        setGroups(groups, startIndex: startIndex)
        makeKeyAndOrderFront(nil)
    }
}

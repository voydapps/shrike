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

    /// The pinned folder. App-wide; tests swap it.
    public var workspaceStore: WorkspaceStore = .standard()

    /// What the app shows when it has nothing to open.
    public enum StartWindow: Equatable {
        /// Not yet (a window is open or opening, or launch has not settled).
        case wait
        case welcome(message: String?)
        case browser(URL)
    }

    /// The idle-launch rule. `settled` is false for the synchronous call in
    /// `didFinishLaunching`: a Finder open event can still arrive on the next
    /// turn, so with a Workspace set that call only waits (no Welcome flash,
    /// and no bookmark is resolved on the photo-open launch path).
    public static func startWindow(workspace: WorkspaceStore, idle: Bool, settled: Bool) -> StartWindow {
        guard idle else { return .wait }
        guard workspace.isSet else { return .welcome(message: nil) }
        guard settled else { return .wait }
        guard let row = workspace.row() else { return .welcome(message: nil) }
        if row.isMissing { return .welcome(message: SidebarCopy.workspaceNamedUnavailable(row.title)) }
        return .browser(row.url)
    }

    // MARK: - Quit (a pending rotate is written on quit)

    /// True while a rotate / flip write is waiting or running.
    public var hasPendingFileWrites: Bool {
        viewers.contains { $0.pendingOrientation != nil || $0.orientationWriteChain != nil }
            || browsers.contains { $0.hasPendingOrientationWrites }
            || Self.compareWindows.contains { $0.hasPendingOrientationWrites }
    }

    /// True while a viewer is in edit mode (its exit alert runs on ⌘Q).
    public var hasViewersInEditMode: Bool {
        viewers.contains { $0.contentRoot.editModeController.isActive }
    }

    /// ⌘Q: shows the edit exit alert on each viewer with
    /// unsaved edits, one at a time. False when the user cancelled (or a
    /// save failed): the quit is cancelled.
    public func resolveUnsavedEditsBeforeQuit() async -> Bool {
        if let unsavedEditsResolver { return await unsavedEditsResolver() }
        return await Self.resolveUnsavedEdits(in: viewers)
    }

    /// Test seams of the ⌘Q flow (nil in the app): they let window-free tests
    /// drive every path without viewers, a Batch or a slow disk.
    var unsavedEditsResolver: (() async -> Bool)?
    var runningWorkOverride: (() -> QuitWork)?
    var stoppedForQuitOverride: (() -> Bool)?
    var flushOverride: (() async -> Bool)?
    var unsavedEditsRecheck: (() async -> Bool)?

    /// The work question does not block the app, so a
    /// viewer can start editing while it is up. Asks the viewers editing
    /// NOW (the ones that answered before have left edit mode, so it is a
    /// no-op without new edits). False: the user cancelled.
    func recheckUnsavedEditsForQuit() async -> Bool {
        if let unsavedEditsRecheck { return await unsavedEditsRecheck() }
        return await Self.resolveUnsavedEdits(in: viewers)
    }

    /// Acts on the unsaved-edits answers once the quit really goes on.
    /// False: a save failed or was cancelled; the quit stops.
    typealias ApplyEditAnswers = @MainActor () async -> Bool

    /// Asks the unsaved-edits question in every editing viewer and acts on
    /// none of the answers yet. nil: the user cancelled.
    var unsavedEditsAsker: (() async -> ApplyEditAnswers?)?

    func askUnsavedEditsBeforeQuit() async -> ApplyEditAnswers? {
        if let unsavedEditsAsker { return await unsavedEditsAsker() }
        // The older seam acts at once; its tests have nothing to defer.
        if let unsavedEditsResolver {
            guard await unsavedEditsResolver() else { return nil }
            let nothingLeft: ApplyEditAnswers = { true }
            return nothingLeft
        }
        return await Self.askUnsavedEdits(in: viewers)
    }

    /// Shrike hidden or not active (Dock ▸ Quit): a quit question is
    /// shown where it is seen. Unhides and activates the app, then brings
    /// `window` (the window asking) forward. Never under XCTest.
    static var bringForward: @MainActor (NSWindow?) -> Void = { window in
        guard !ShrikeDataPaths.isRunningTests else { return }
        NSApp?.unhide(nil)
        NSApp?.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func askUnsavedEdits(in viewers: [ViewerWindow]) async -> ApplyEditAnswers? {
        var answers: [(ViewerWindow, ViewerWindow.QuitEditAnswer)] = []
        for viewer in viewers {
            if viewer.contentRoot.editModeController.isActive { bringForward(viewer) }
            guard let answer = await viewer.askUnsavedEditsForQuit() else { return nil }
            answers.append((viewer, answer))
        }
        return {
            for (viewer, answer) in answers where !(await viewer.applyQuitEditAnswer(answer)) { return false }
            return true
        }
    }

    static func resolveUnsavedEdits(in viewers: [ViewerWindow]) async -> Bool {
        for viewer in viewers {
            if viewer.contentRoot.editModeController.isActive { bringForward(viewer) }
            guard await viewer.resolveUnsavedEditsForQuit() else { return false }
        }
        return true
    }

    /// Writes every pending rotate now and waits for the writes, but never
    /// longer than `timeout`. False when a write was still running at the
    /// deadline (the caller tells the user; the write itself goes on).
    @discardableResult
    public func flushPendingFileWrites(timeout: Duration = .seconds(2)) async -> Bool {
        let viewers = viewers
        let browsers = browsers
        let compares = Self.compareWindows
        let state = FlushState()
        Task { @MainActor in
            for viewer in viewers { await viewer.waitForOrientationWrites() }
            for browser in browsers { await browser.waitForOrientationWrites() }
            for compare in compares { await compare.waitForOrientationWrites() }
            state.done = true
        }
        return await Self.waitUntil(timeout: timeout) { state.done }
    }

    @MainActor private final class FlushState { var done = false }

    /// Compare windows are owned by their origin, not here: found by type.
    static var compareWindows: [CompareWindow] {
        NSApp?.windows.compactMap { $0 as? CompareWindow } ?? []
    }

    /// Polls `isDone` every 20 ms until it is true or `timeout` passes.
    /// The main thread never blocks. True when `isDone` became true.
    static func waitUntil(timeout: Duration, _ isDone: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !isDone() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    // MARK: - Quit while work runs

    /// What runs right now: the Batch window (also when hidden), every
    /// window's copy / move, and the saves `ActiveWork` knows of.
    public func runningWork(_ snapshot: ActiveWork.Snapshot = ActiveWork.shared.snapshot()) -> QuitWork {
        if let runningWorkOverride { return runningWorkOverride() }
        var work = QuitWork()
        if let batch = BatchWindowController.current, batch.model.phase == .running {
            work.batch = QuitWork.Batch(completed: batch.model.completed, total: batch.model.total,
                                        isHidden: batch.isHiddenWhileRunning)
        }
        work.transfers = FileTransferCoordinator.runningWork
        work.shortWork = Self.hasShortWork(snapshot)
        // Text only: a running Batch registers its own writes as `.save`, so the
        // raw count said "still saving 6 photos" while only the Batch ran.
        // `stoppedForQuit` still waits on the raw ActiveWork count.
        work.savingPhotos = Self.savingLineCount(viewerSaves: ViewerSaveCounter.running,
                                                 allSaves: snapshot.count(of: .save),
                                                 batchRunning: work.batch != nil)
        return work
    }

    /// The photos the "still saving" line names: viewer saves (counted on the
    /// UI side). Without a Batch every `.save` is a viewer save, so the raw
    /// count is used then (a save the UI counter missed is still told).
    nonisolated static func savingLineCount(viewerSaves: Int, allSaves: Int, batchRunning: Bool) -> Int {
        batchRunning ? min(viewerSaves, allSaves) : allSaves
    }

    /// How long Quit Anyway waits for the photo being written to finish.
    static var stopWaitTimeout: Duration = .seconds(15)

    /// Quit Anyway: stops the Batch and the transfers as "Stop Batch" does
    /// (no new photo starts; the one being written finishes, and a stopped
    /// batch rename puts its temporary names back), then waits for them.
    @discardableResult
    func stopRunningWorkForQuit() async -> Bool {
        let batch = BatchWindowController.current
        if batch?.model.phase == .running { batch?.model.stop() }
        FileTransferCoordinator.stopAllRunning()
        return await waitForWorkForQuit()
    }

    /// The file work that is not a Batch or a copy / move (those hold
    /// these tokens too, and are stopped first): Undo Batch (`.batchRun`
    /// hold), Trash, Put Back, Rename and undos (`.transfer`), restores.
    nonisolated static func hasShortWork(_ snapshot: ActiveWork.Snapshot) -> Bool {
        snapshot.contains(.transfer) || snapshot.contains(.restore) || snapshot.contains(.batchRun)
    }

    /// Waits (bounded, with the timeout alert) until the work has ended.
    /// False: the user chose Quit Anyway at the timeout.
    @discardableResult
    func waitForWorkForQuit(afterStop: Bool = true) async -> Bool {
        let batch = BatchWindowController.current
        // Saves are waited for too: the alert says "It will finish them first".
        let stopped: @MainActor () -> Bool = { [stoppedForQuitOverride] in
            stoppedForQuitOverride?() ?? Self.stoppedForQuit(batch)
        }
        var settled = await Self.waitUntil(timeout: Self.stopWaitTimeout) { stopped() }
        while !settled {
            let answer: Int?
            if let writeTimeoutResponder {
                answer = writeTimeoutResponder()
            } else {
                // Work goes on behind it (Keep Waiting): never blocks the main actor.
                let text = QuitQuestion.stopTimeoutText(
                    stoppedWork: afterStop, saving: ActiveWork.shared.snapshot().count(of: .save) > 0)
                answer = await askQuitAlert(
                    message: text.title, information: text.information, buttons: QuitQuestion.timeoutButtons)
            }
            guard QuitQuestion.keepsWaiting(answer) else { return false }
            settled = await Self.waitUntil(timeout: Self.stopWaitTimeout) { stopped() }
        }
        return true
    }

    static func stoppedForQuit(_ batch: BatchWindowController?) -> Bool {
        let snapshot = ActiveWork.shared.snapshot()
        return batch?.model.phase != .running && FileTransferCoordinator.running.isEmpty
            && snapshot.count(of: .save) == 0 && !hasShortWork(snapshot)
    }

    /// The modal code of a quit alert closed because its work finished.
    static let workFinishedWhileAsking = NSApplication.ModalResponse(rawValue: 7_431)
    /// Seconds between two refreshes of the open quit alert.
    static var liveQuitAlertInterval: TimeInterval = 0.25

    /// Shows a quit-flow alert without blocking the main actor and returns
    /// the end function (tests replace it with one that just waits).
    typealias QuitAlertPresenter = @MainActor (NSAlert, @escaping @MainActor (NSApplication.ModalResponse) -> Void)
        -> @MainActor (NSApplication.ModalResponse) -> Void
    #if DEBUG
    var quitAlertPresenter: QuitAlertPresenter?
    #endif

    private func presentQuitAlert(_ alert: NSAlert,
                                  completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void)
        -> @MainActor (NSApplication.ModalResponse) -> Void {
        Self.bringForward(nil)
        #if DEBUG
        if let quitAlertPresenter { return quitAlertPresenter(alert, completion) }
        #endif
        let presentation = ShrikeAlert.present(alert, on: Self.quitHostWindow(), completion: completion)
        return { presentation.end($0) }
    }

    /// The window a quit-flow alert is a sheet on: the key or main window,
    /// else the frontmost visible one. Never a window that already carries
    /// a sheet (the question would wait unseen behind it), a panel, or a
    /// hidden Batch window. nil: the alert stands on its own.
    static func quitHostWindow() -> NSWindow? {
        guard let app = NSApp else { return nil }
        let candidates = [app.keyWindow, app.mainWindow].compactMap { $0 } + app.orderedWindows
        return candidates.first { window in
            window.isVisible && !window.isMiniaturized && window.attachedSheet == nil
                && window.sheetParent == nil && !(window is NSPanel) && window.canBecomeKey
        }
    }

    /// Asks the quit question and refreshes its text while it is up.
    /// It never blocks the main actor: the Batch, copies and
    /// saves go on behind it, so the refresh reads real numbers (a
    /// `runModal` inside this task froze them). Work that finishes
    /// meanwhile closes it as Quit Anyway (0), which then stops nothing,
    /// waits for saves and flushes the pending writes.
    private func askLiveQuitQuestion(information: String) async -> Int? {
        let alert = ShrikeAlert.make(message: QuitQuestion.title, information: information,
                                     buttons: QuitQuestion.quitButtons)
        let refresher = LiveQuitRefresher()
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            let end = presentQuitAlert(alert) { response in
                refresher.stop()
                continuation.resume(returning: response)
            }
            refresher.start(every: Self.liveQuitAlertInterval) { [weak self, weak alert] in
                guard let self, let alert else { return }
                self.tickLiveQuitAlert(alert, stop: end)
            }
        }
        if response == Self.workFinishedWhileAsking { return 0 }
        return ShrikeAlert.index(of: response, buttonCount: QuitQuestion.quitButtons.count)
    }

    /// The refresh loop of the open quit question (main actor, cancellable).
    @MainActor private final class LiveQuitRefresher {
        private var task: Task<Void, Never>?
        private var stopped = false
        func start(every interval: TimeInterval, _ tick: @escaping @MainActor () -> Void) {
            guard !stopped else { return }
            task = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard !Task.isCancelled else { return }
                    tick()
                }
            }
        }
        func stop() { stopped = true; task?.cancel(); task = nil }
    }

    /// A two-button quit-flow alert (the timeouts), shown as the question is.
    private func askQuitAlert(message: String, information: String, buttons: [ShrikeAlert.Button]) async -> Int? {
        let alert = ShrikeAlert.make(message: message, information: information, buttons: buttons)
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            _ = presentQuitAlert(alert) { continuation.resume(returning: $0) }
        }
        return ShrikeAlert.index(of: response, buttonCount: buttons.count)
    }

    /// One refresh of an open quit alert (tests call it on a built alert).
    /// Returns true when it closed the alert through `stop`.
    @discardableResult
    func tickLiveQuitAlert(_ alert: NSAlert, stop: (NSApplication.ModalResponse) -> Void) -> Bool {
        switch QuitQuestion.liveStep(shown: alert.informativeText, work: runningWork()) {
        case .keep:
            return false
        case .update(let text):
            alert.informativeText = text
            return false
        case .finished:
            stop(Self.workFinishedWhileAsking)
            return true
        }
    }

    /// Answers the quit alert (tests): 0 = Quit Anyway, 1 = Cancel.
    var quitAlertResponder: ((_ title: String, _ information: String) -> Int?)?
    /// Answers the write-timeout alerts (tests): 0 = Quit Anyway, 1 = Keep Waiting.
    var writeTimeoutResponder: (() -> Int?)?

    /// ⌘Q first ends the informational rename-recovery sheet as `Not Now`, so it
    /// never blocks quitting and no quit question waits behind it.
    public func endInformationalSheetsForQuit() {
        RenameRecoveryPresenter.endSheetForQuit()
    }

    /// The window writes first, then every rotate write or save still
    /// open, also one whose window is already closed. After the flush, so a
    /// window's own pending-rotate hold is gone by then. `tokens` false: the
    /// user already chose Quit Anyway at a timeout.
    private func flushForQuit(tokens: Bool) async -> Bool {
        let flushed = if let flushOverride { await flushOverride() } else { await flushPendingFileWrites() }
        guard flushed else { return false }
        guard tokens else { return true }
        return await Self.waitUntil(timeout: .seconds(2)) { !Self.hasFileWrites(ActiveWork.shared.snapshot()) }
    }

    /// A rotate write or a save is open (`ActiveWork`).
    nonisolated static func hasFileWrites(_ snapshot: ActiveWork.Snapshot) -> Bool {
        snapshot.contains(.rotateWrite) || snapshot.contains(.save)
    }

    /// What ⌘Q needs (pure decision, `QuitPlan`).
    public var quitPlan: QuitPlan {
        let pendingWrites = hasPendingFileWrites || Self.hasFileWrites(ActiveWork.shared.snapshot())
        return QuitPlan.decide(editing: hasViewersInEditMode, pendingWrites: pendingWrites, work: runningWork())
    }

    /// `applicationShouldTerminate`, with the answer behind a closure so the
    /// flow can be tested. Exactly one answer, always: either the returned
    /// `.terminateNow` (`reply` is never called), or `.terminateLater` and
    /// `reply` called once with the result of `prepareToQuit()`.
    public func terminateRequest(endSheets: (() -> Void)? = nil,
                                 reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        // The question no longer blocks the menu: a second ⌘Q while a flow
        // is running starts nothing and answers nothing more (the first
        // flow still replies once).
        guard !isQuitFlowRunning else { return .terminateCancel }
        if let endSheets { endSheets() } else { endInformationalSheetsForQuit() }
        guard quitPlan == .later else { return .terminateNow }
        isQuitFlowRunning = true
        Task { @MainActor [self] in
            let answer = await prepareToQuit()
            isQuitFlowRunning = false
            reply(answer)
        }
        return .terminateLater
    }

    /// True from a `.terminateLater` until its reply.
    public private(set) var isQuitFlowRunning = false

    /// The whole ⌘Q flow after `quitPlan` said `.later`: unsaved edits
    /// first, then one alert naming the running work, then the pending
    /// writes. False: the user cancelled; the app stays open.
    public func prepareToQuit() async -> Bool {
        // With work running, the edit answers wait for the work
        // question; a Cancel there leaves every edit as it was.
        var applyEdits: ApplyEditAnswers?
        if runningWork().needsQuestion {
            guard let apply = await askUnsavedEditsBeforeQuit() else { return false }
            applyEdits = apply
        } else {
            guard await resolveUnsavedEditsBeforeQuit() else { return false }
        }
        let work = runningWork()
        var waitForTokens = true
        if let information = QuitQuestion.information(for: work) {
            let choice: Int?
            if let quitAlertResponder {
                choice = quitAlertResponder(QuitQuestion.title, information)
            } else {
                // A sheet on the frontmost window; its lines
                // follow the work while it is up.
                choice = await askLiveQuitQuestion(information: information)
            }
            guard choice == 0 else { return false }
            // Saved before the work stops: a failed save cancels the quit
            // with the work still running.
            if let apply = applyEdits {
                applyEdits = nil
                guard await apply() else { return false }
            }
            // Edits begun while the question was up; asked before the
            // work stops, so a Cancel leaves everything running.
            guard await recheckUnsavedEditsForQuit() else { return false }
            waitForTokens = await stopRunningWorkForQuit()
        } else if QuitPlan.workStep(work) == .wait {
            // An Undo Batch, Trash, Put Back... nobody can stop: waited for, never cut in half.
            waitForTokens = await waitForWorkForQuit(afterStop: false)
        }
        // The work ended while the edit question was up.
        if let apply = applyEdits, !(await apply()) { return false }
        // A write that is still running at the deadline is told, never dropped silently.
        while !(await flushForQuit(tokens: waitForTokens)) {
            let answer: Int?
            if let writeTimeoutResponder {
                answer = writeTimeoutResponder()
            } else {
                answer = await askQuitAlert(
                    message: QuitQuestion.writeTimeoutTitle, information: QuitQuestion.writeTimeoutInformation,
                    buttons: QuitQuestion.timeoutButtons)
            }
            if !QuitQuestion.keepsWaiting(answer) { break }
        }
        // And edits begun during the stop / write-timeout alerts.
        return await recheckUnsavedEditsForQuit()
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

    /// The once-per-launch rename recovery, 10 s after launch and off
    /// the main thread. Costs one Task on the launch path.
    public func scheduleLaunchRecovery() {
        guard let services else { return }
        RenameRecoveryPresenter.schedule(services: services)
    }
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
        openFolderBrowsers(folders, services: services)
    }

    /// A Browser per folder; a folder that is already open is brought
    /// forward. The limit of 4 counts only the folders that need a new window.
    @discardableResult
    private func openFolderBrowsers(
        _ folders: [URL], services: ShrikeServices
    ) -> (last: BrowserWindowController?, skipped: Int) {
        var created = 0
        var skipped = 0
        var last: BrowserWindowController?
        for folder in folders {
            if browser(showing: folder) == nil {
                guard created < Self.maxFoldersPerOpen else { skipped += 1; continue }
                created += 1
            }
            last = openBrowser(at: folder, selecting: nil, services: services)
            last?.window?.makeKeyAndOrderFront(nil)
        }
        return (last, skipped)
    }

    /// File ▸ New Browser Window (⌘N).
    /// With a Workspace that is there, the new window shows its root (always
    /// a new window, never de-duplicated); else it has no folder.
    public func newBrowserWindow() {
        guard let services else { return }
        let root = workspaceStore.row().flatMap { $0.isMissing ? nil : $0.url }
        openBrowser(at: root, selecting: nil, services: services, reuseExisting: false)
            .window?.makeKeyAndOrderFront(nil)
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
        let opened = openFolderBrowsers(request.folders, services: services)
        let lastBrowser = opened.last
        if opened.skipped > 0 {
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

    private func report(_ message: String) { reportToFrontWindow(message) }

    /// A toast on the front Viewer or Browser, else on Welcome.
    func reportToFrontWindow(_ message: String, isError: Bool = true) {
        if let window = NSApp?.mainWindow as? ViewerWindow {
            window.contentRoot.toast(ToastContent(message, kind: isError ? .error : .text))
        } else if let browser = browsers.first(where: { $0.window === NSApp?.mainWindow }) {
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

    /// The open Browser that shows `folder` right now (same canonical path),
    /// or nil. A Browser that went into another folder does not count.
    /// Several matches: the key one, else the most recent.
    public func browser(showing folder: URL) -> BrowserWindowController? {
        let key = GroupList.canonical(folder)
        let matches = browsers.filter { browser in
            guard let current = browser.currentFolder, browser.window != nil else { return false }
            return GroupList.canonical(current) == key
        }
        return matches.first { $0.window?.isKeyWindow == true } ?? matches.last
    }

    /// A Browser at `folder`, with `selecting` selected once listed. A
    /// folder that is already open in a Browser brings that window forward
    /// instead of making a second one; no folder (⌘N) always
    /// makes a new window.
    @discardableResult
    public func openBrowser(
        at folder: URL?, selecting: URL?, services: ShrikeServices, reuseExisting: Bool = true
    ) -> BrowserWindowController {
        if reuseExisting, let folder, let existing = browser(showing: folder) {
            if let window = existing.window {
                if window.isMiniaturized { window.deminiaturize(nil) }
                window.makeKeyAndOrderFront(nil)
            }
            if let selecting { existing.select(url: selecting) }
            Self.noteRecent(folder)
            onWindowOpened?()
            return existing
        }
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
        // The first photo's facts now, the whole listing when its walk (off the
        // main thread) is done; the viewer opens without waiting for it.
        let content = browser.contentController
        let first = groups[min(max(0, startIndex), groups.count - 1)].primary
        let listing = content.listingFacts(for: first).map { [first: $0] } ?? [:]
        func fillListing(_ viewer: ViewerWindow) {
            let generation = viewer.contentRoot.inspectorPanel.setListingFacts(listing)
            Task { @MainActor [weak viewer] in
                let all = await content.listingFactsOffMain()
                viewer?.contentRoot.inspectorPanel.addListingFacts(all, generation: generation)
            }
        }
        if let viewer = browser.pairedViewer {
            fillListing(viewer)
            viewer.showFromBrowser(groups: groups, startIndex: startIndex)
            return viewer
        }
        let viewer = openViewer(
            groups: groups, startIndex: startIndex,
            services: browser.services,
            frame: browser.window.map { Self.pairedViewerFrame(over: $0.frame, visible: $0.screen?.visibleFrame) }
        )
        fillListing(viewer)
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
    /// centred on the Browser (it keeps the Browser's frame when
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
        let minimumWidth = min(CompareWindow.minimumWindowSize.width, visible.width)
        let minimumHeight = min(CompareWindow.minimumWindowSize.height, visible.height)

        // Keep the 24 pt cascade when possible. If it would run past the
        // right edge, use the width that actually remains; the previous max()
        // could select a larger width and push Compare offscreen.
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX)
        let availableWidth = max(0, visible.maxX - frame.minX)
        frame.size.width = min(browser.width, max(minimumWidth, min(availableWidth, browser.width)))
        if frame.maxX > visible.maxX {
            frame.origin.x = max(visible.minX, visible.maxX - frame.width)
        }

        // Preserve the cascaded top edge. If moving down by 24 pt would
        // cross the bottom edge, give up those 24 pt of height, as the
        // established paired-window behavior does.
        if frame.minY < visible.minY {
            let top = frame.maxY
            frame.origin.y = max(visible.minY, top - (browser.height - step))
            frame.size.height = top - frame.minY
        }
        // A source window that was already beyond the visible screen still
        // needs a final full containment clamp.
        frame.size.height = min(frame.height, visible.height)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame.height < minimumHeight {
            frame.size.height = minimumHeight
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
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
            let viewer = browser.pairedViewer
            viewer?.pairedBrowser = nil
            browser.pairedViewer = nil
            viewer?.refreshBrowserReturnContext()
        }
        viewers.removeAll { $0 === closed }
        browsers.removeAll { $0.window === closed }
        // Nothing on screen needs thumbnails any more: give the memory tier
        // back (up to 128 MB), or an idle app keeps it. The
        // disk tier stays, so reopening a folder is still quick. A hidden
        // paired viewer stays in `viewers`, which keeps the tier warm.
        if !hasWindows, let cache = services?.thumbnailCache {
            Task { await cache.evictMemory() }
        }
    }
}

/// Viewer saves running now (the quit alert's "still saving" line).
@MainActor enum ViewerSaveCounter {
    static var running = 0
}

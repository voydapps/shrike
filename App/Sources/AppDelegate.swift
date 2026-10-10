//
//  AppDelegate.swift
//  Shrike
//
//  NSApplicationDelegate entry point.
//
//  - Builds the menu bar (ShrikeMainMenu) before launch finishes.
//  - Builds the shared services once and hands them to WindowCoordinator,
//    which owns every Viewer and Browser window.
//  - Routes Finder / `open` / Dock requests through OpenRequestQueue into
//    WindowCoordinator.open(_:).
//  - Shows Welcome when nothing else is open: at launch, when a Dock click
//    finds no windows, or from Window ▸ Welcome to Shrike.
//  - Keeps the cold-launch signpost closing on the first Metal drawable.
//

import AppKit
import ShrikeCore
import ShrikeRendering
import ShrikeUI
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Launch signposts.
    private var launchSignpost: OSSignpostIntervalState
    private var willFinishSignpost: OSSignpostIntervalState?
    private var didFinishSignpost: OSSignpostIntervalState?
    private var launchSignpostClosed = false
    /// `NSApplication.run()` until `applicationWillFinishLaunching` (main.swift).
    static var appKitStartState: OSSignpostIntervalState?
    /// End of `applicationWillFinishLaunching` until the first open request
    /// or `applicationDidFinishLaunching`: AppKit's work between the two.
    private var appKitGapState: OSSignpostIntervalState?

    private let coordinator = WindowCoordinator.shared
    // Open requests that arrive before services exist (cold launch with a
    // file) wait here; see OpenRequestQueue.
    private let openQueue = OpenRequestQueue()
    private var appCommands: AppCommands?
    private var mainMenu: ShrikeMainMenu?
    private var welcome: WelcomeWindowController?
    // Kept for the app's lifetime so re-opens are instant.
    private var preferencesWindowController: PreferencesWindowController?
    private var launchFinished = false

    init(launchSignpost: OSSignpostIntervalState) {
        self.launchSignpost = launchSignpost
        super.init()
    }

    @available(*, unavailable)
    override init() {
        fatalError("use init(launchSignpost:)")
    }

    // MARK: - Launch lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if let state = Self.appKitStartState {
            ShrikeSignposts.launch.end("appKitStart", state)
            Self.appKitStartState = nil
        }
        willFinishSignpost = ShrikeSignposts.launch.begin("willFinishLaunching")
        // Before the first viewer is built (two defaults reads).
        Prefs.applyEditRailDefaultOnce()
        defer {
            if let willFinishSignpost {
                ShrikeSignposts.launch.end("willFinishLaunching", willFinishSignpost)
                self.willFinishSignpost = nil
            }
            appKitGapState = ShrikeSignposts.launch.begin("appKitGap")
        }
        let commandsState = ShrikeSignposts.launch.begin("appCommands")
        let commands = AppCommands(coordinator: coordinator)
        commands.onShowWelcome = { [weak self] in self?.showWelcome() }
        commands.onShowSettings = { [weak self] tab in self?.showSettings(tab: tab) }
        appCommands = commands
        ShrikeSignposts.launch.end("appCommands", commandsState)
        // The build runs inside the `mainMenu` signpost.
        let menu = ShrikeMainMenu(appCommands: commands)
        let installState = ShrikeSignposts.launch.begin("menuInstall")
        menu.install(in: NSApp)
        ShrikeSignposts.launch.end("menuInstall", installState)
        mainMenu = menu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        endAppKitGap()
        didFinishSignpost = ShrikeSignposts.launch.begin("didFinishLaunching")

        let servicesState = ShrikeSignposts.launch.begin("makeServices")
        // Stored values of removed keys go away.
        Prefs.removeRetiredKeys()
        var services = ShrikeServices.makeDefault()
        services.backupStore = .shared
        coordinator.services = services
        ShrikeSignposts.launch.end("makeServices", servicesState)

        coordinator.onWindowOpened = { [weak self] in self?.closeWelcome() }
        // A message with no Viewer or Browser in front (e.g. every opened
        // file was unreadable) shows on Welcome.
        coordinator.onMessage = { [weak self] message in self?.showWelcome(message: message) }
        // An open that produced no window leaves the app empty: show Welcome.
        coordinator.onOpenSettled = { [weak self] in self?.showWelcomeIfIdle() }

        // Replay files handed to us before services existed (Finder
        // double-click / `open` on a cold launch), then deliver every later
        // request directly.
        let replayState = ShrikeSignposts.launch.begin("replayOpenRequests")
        openQueue.activate { [weak self] urls in
            self?.coordinator.open(urls)
        }
        ShrikeSignposts.launch.end("replayOpenRequests", replayState)

        launchFinished = true
        showWelcomeIfIdle()

        if let didFinishSignpost {
            ShrikeSignposts.launch.end("didFinishLaunching", didFinishSignpost)
        }

        // Close the cold-launch signpost on a real paint.
        NotificationCenter.default.addObserver(
            forName: .shrikeFirstMetalDrawable,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeLaunchSignpost()
            }
        }

        // Safety: if no viewer ever opens, close the cold-launch signpost
        // at the first runloop turn so the interval isn't open-ended.
        // Requests AppKit delivers right after launch have arrived by now.
        DispatchQueue.main.async { [weak self] in
            self?.closeLaunchSignpost()
            self?.showWelcomeIfIdle()
        }
    }

    private func endAppKitGap() {
        guard let state = appKitGapState else { return }
        ShrikeSignposts.launch.end("appKitGap", state)
        appKitGapState = nil
    }

    private func closeLaunchSignpost() {
        guard !launchSignpostClosed else { return }
        launchSignpostClosed = true
        ShrikeSignposts.launch.event("firstDrawable")
        ShrikeSignposts.launch.end("coldLaunch", launchSignpost)
    }

    /// Unsaved edits get the edit exit alert first; Cancel
    /// cancels the quit. Then a rotate still waiting for its 500 ms write
    /// is written before the app quits; that wait is
    /// capped at 2 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard coordinator.hasViewersInEditMode || coordinator.hasPendingFileWrites else {
            return .terminateNow
        }
        let coordinator = coordinator
        Task { @MainActor in
            guard await coordinator.resolveUnsavedEditsBeforeQuit() else {
                sender.reply(toApplicationShouldTerminate: false)
                return
            }
            await coordinator.flushPendingFileWrites()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Closing the last window keeps Shrike running.
    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    /// Dock click with no Viewer or Browser open → Welcome.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard !coordinator.hasWindows else { return true }
        showWelcome()
        return false
    }

    // MARK: - File-open routing

    func application(_ application: NSApplication, open urls: [URL]) {
        // On a cold launch this arrives BEFORE applicationDidFinishLaunching
        // (services still nil) — the queue holds it until then.
        // One photo starts decoding now, while launch goes on
        // (the viewer's decode queue takes the result over).
        endAppKitGap()
        ShrikeSignposts.launch.event("openRequest")
        WindowCoordinator.startEarlyDecode(for: urls, frame: coordinator.cascadeSourceFrame)
        openQueue.submit(urls)
    }

    // MARK: - Welcome

    private func showWelcome(message: String? = nil) {
        let controller = welcome ?? makeWelcome()
        welcome = controller
        controller.show()
        if let message { controller.showMessage(message) }
    }

    private func makeWelcome() -> WelcomeWindowController {
        let controller = WelcomeWindowController()
        controller.onOpenURLs = { [weak self] urls in self?.coordinator.open(urls) }
        controller.onOpenFiles = { [weak self] in self?.appCommands?.openFiles(nil) }
        controller.onOpenFolder = { [weak self] in self?.appCommands?.openFolder(nil) }
        controller.onClose = { [weak self] in self?.welcome = nil }
        return controller
    }

    private func closeWelcome() {
        welcome?.close()
        welcome = nil
    }

    /// Welcome only when launch is done, nothing is open and nothing is
    /// still opening.
    private func showWelcomeIfIdle() {
        guard launchFinished, !coordinator.hasWindows,
              coordinator.pendingOpens == 0, !openQueue.hasPending else { return }
        showWelcome()
    }

    // MARK: - Settings

    private func showSettings(tab: PreferencesTab?) {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController(
                thumbnailCache: coordinator.services?.thumbnailCache,
                backupStore: coordinator.services?.backupStore
            )
        }
        if let tab {
            preferencesWindowController?.show(tab: tab)
        } else {
            preferencesWindowController?.show()
        }
    }
}

// MARK: - First-drawable notification

// Named notification so MetalImageView doesn't need a direct reference to
// AppDelegate. Declared in the app target so ShrikeKit stays framework-only.
public extension Notification.Name {
    static let shrikeFirstMetalDrawable = Notification.Name("shrike.firstMetalDrawable")
}

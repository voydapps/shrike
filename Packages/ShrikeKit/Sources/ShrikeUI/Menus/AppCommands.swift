//
//  AppCommands.swift
//  ShrikeUI
//
//  App-level menu commands that work with any window, or none:
//  New Browser Window, Open…, Open Folder…,
//  Open Recent, Welcome, Settings, Keyboard Shortcuts.
//
//  Menu items target this object directly, so they stay enabled when no
//  window is open. Open panels go through `OpenPanelRunning` so tests
//  never show a real panel.
//

import AppKit
import ShrikeCore
import UniformTypeIdentifiers

// MARK: - Open panels

/// What an open panel shows.
public struct OpenPanelRequest: Equatable, Sendable {
    /// False for Open Folder… (folders only).
    public var canChooseFiles: Bool
    public var prompt: String
    public var directoryURL: URL?

    public static func open(in directory: URL?) -> OpenPanelRequest {
        OpenPanelRequest(canChooseFiles: true, prompt: "Open", directoryURL: directory)
    }

    public static func openFolder(in directory: URL?) -> OpenPanelRequest {
        OpenPanelRequest(canChooseFiles: false, prompt: "Open Folder", directoryURL: directory)
    }
}

/// Runs an open panel; `completion` gets the chosen URLs (empty = cancel).
@MainActor
public protocol OpenPanelRunning {
    func run(_ request: OpenPanelRequest, sheetFor window: NSWindow?,
             completion: @escaping @MainActor ([URL]) -> Void)
}

/// The real `NSOpenPanel`: a sheet when a window is given, free-standing
/// otherwise (only Welcome open).
public struct SystemOpenPanelRunner: OpenPanelRunning {
    public init() {}

    public func run(_ request: OpenPanelRequest, sheetFor window: NSWindow?,
                    completion: @escaping @MainActor ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.canChooseFiles
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = request.prompt
        panel.directoryURL = request.directoryURL
        if request.canChooseFiles {
            panel.allowedContentTypes = [.image, .rawImage, .folder]
        }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            let urls = response == .OK ? panel.urls : []
            MainActor.assumeIsolated { completion(urls) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}

// MARK: - Commands

@MainActor
public final class AppCommands: NSObject, NSMenuItemValidation {

    /// Last folder an open panel used.
    public static let lastOpenFolderKey = "shrike.lastOpenFolder"

    public let coordinator: WindowCoordinator
    public var panelRunner: any OpenPanelRunning = SystemOpenPanelRunner()
    public var defaults: UserDefaults = ShrikeDefaults.store
    public var onShowWelcome: (() -> Void)?
    /// Opens Settings, on a tab when given.
    /// Also opens Settings ▸ External Editors for the editor menus, keys
    /// and toasts.
    public var onShowSettings: ((PreferencesTab?) -> Void)? {
        didSet {
            ExternalEditors.openSettingsTab = { [weak self] in self?.onShowSettings?(.externalEditors) }
        }
    }
    /// Where chosen items go. `asBrowsers` = Open Folder… (always a
    /// Browser). Defaults to the coordinator; a test seam.
    public lazy var route: ([URL], _ asBrowsers: Bool) -> Void = { [weak self] urls, asBrowsers in
        guard let self else { return }
        if asBrowsers {
            self.coordinator.openFolders(urls)
        } else {
            self.coordinator.open(urls)
        }
    }

    public init(coordinator: WindowCoordinator = .shared) {
        self.coordinator = coordinator
        super.init()
    }

    // MARK: Actions

    @objc public func newBrowserWindow(_ sender: Any?) {
        coordinator.newBrowserWindow()
    }

    @objc public func openFiles(_ sender: Any?) {
        runPanel(.open(in: startDirectory()), asBrowsers: false)
    }

    @objc public func openFolder(_ sender: Any?) {
        runPanel(.openFolder(in: startDirectory()), asBrowsers: true)
    }

    @objc public func openRecentItem(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        route([url], false)
    }

    @objc public func showWelcome(_ sender: Any?) {
        onShowWelcome?()
    }

    @objc public func showSettings(_ sender: Any?) {
        onShowSettings?(nil)
    }

    @objc public func showKeyboardShortcuts(_ sender: Any?) {
        ShortcutsWindowController.shared.openSettings = { [weak self] in self?.onShowSettings?(.shortcuts) }
        ShortcutsWindowController.shared.toggle()
    }

    /// Help ▸ Shrike Website / Report a Problem…: open the default browser. The app
    /// itself makes no connection.
    public static let websiteURL = URL(string: "https://voydapps.github.io/shrike")!
    public static let issuesURL = URL(string: "https://github.com/voydapps/shrike/issues")!
    var openURLForTesting: ((URL) -> Void)?

    @objc public func openWebsite(_ sender: Any?) { open(Self.websiteURL) }
    @objc public func reportProblem(_ sender: Any?) { open(Self.issuesURL) }
    private func open(_ url: URL) {
        if let openURLForTesting { openURLForTesting(url); return }
        NSWorkspace.shared.open(url)
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { true }

    // MARK: Panels

    private func runPanel(_ request: OpenPanelRequest, asBrowsers: Bool) {
        let sheetWindow = Self.target(of: NSApp?.keyWindow) != nil ? NSApp?.keyWindow : nil
        panelRunner.run(request, sheetFor: sheetWindow) { [weak self] urls in
            guard let self, let first = urls.first else { return }
            let folder = asBrowsers ? first : first.deletingLastPathComponent()
            self.defaults.set(folder, forKey: Self.lastOpenFolderKey)
            self.route(urls, asBrowsers)
        }
    }

    /// The folder of the displayed item, else the last-used folder, else
    /// Pictures.
    public func startDirectory(mainWindow: NSWindow? = NSApp?.mainWindow) -> URL? {
        if let browser = Self.target(of: mainWindow) as? BrowserWindowController,
           let folder = browser.displayedFolderURL {
            return folder
        }
        if let file = Self.target(of: mainWindow)?.commandFileURLs.first {
            return file.deletingLastPathComponent()
        }
        if let last = defaults.url(forKey: Self.lastOpenFolderKey) { return last }
        return FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
    }

    // MARK: Shared lookups

    /// The command target behind `window`: the viewer itself or the
    /// Browser's controller.
    public static func target(of window: NSWindow?) -> (any ShrikeCommandTarget)? {
        if let viewer = window as? ViewerWindow { return viewer }
        if let browser = window?.windowController as? BrowserWindowController { return browser }
        return nil
    }

    /// Open Recent's list: the document controller's
    /// recents, capped at `Prefs.recentFoldersLimit`.
    /// A Recent item whose file or folder is gone while its disk is still
    /// there (deleted or moved). An unmounted disk is not dead: that item
    /// stays, dimmed, and comes back with the disk. `volumeMounted` gets
    /// the `/Volumes/<name>` of an external disk.
    nonisolated static func isDeadRecent(
        _ url: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        let path = url.standardizedFileURL.path
        guard !fileExists(path) else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" {
            return fileExists("/Volumes/\(parts[1])")
        }
        return true
    }

    /// Takes dead items out of Open Recent. The document controller can
    /// only clear the whole list, so the live items go back in, oldest
    /// first, which keeps their order.
    @MainActor
    public static func forgetRecents(_ dead: [URL]) {
        guard !dead.isEmpty else { return }
        let controller = NSDocumentController.shared
        let gone = Set(dead.map(\.standardizedFileURL))
        let keep = controller.recentDocumentURLs.filter { !gone.contains($0.standardizedFileURL) }
        guard keep.count != controller.recentDocumentURLs.count else { return }
        controller.clearRecentDocuments(nil)
        for url in keep.reversed() { controller.noteNewRecentDocumentURL(url) }
    }

    public static func recentURLs() -> [URL] {
        let limit = max(0, Prefs.recentFoldersLimit)
        return Array(NSDocumentController.shared.recentDocumentURLs.prefix(limit))
    }
}

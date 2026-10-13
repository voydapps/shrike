//
//  BatchWindowController.swift
//  ShrikeUI
//
//  The Batch window. One window, made on first use; a second
//  Image ▸ Batch… (⌥⌘B) adds items to it. 880 × 600 pt, min 760 × 520,
//  titled "Batch — 42 images". No toolbar.
//
//  Closing while a batch runs asks "Stop the batch?". Keep Running (the
//  default) hides the window and shows the percent on the Dock icon; at
//  the end the badge clears, the Dock icon bounces once and the window
//  comes back (not key) with the Done view. An in-place rename or rotate
//  registers one undo on the window that opened the batch.
//
//  Files the batch writes are not hidden from the folder watchers
//  (`FileOps(watchers: nil)`), so open Browser and viewer windows list
//  the renamed and new files by themselves.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ShrikeCore
import ShrikeEdit
import ShrikeIO

@MainActor
public final class BatchWindowController: NSWindowController, NSWindowDelegate {

    /// The open Batch window, if any.
    public private(set) static var current: BatchWindowController?

    /// Tests set this to false: the window is built but never shown.
    static var presentsWindows = true

    public static let contentSize = NSSize(width: 880, height: 600)
    public static let minContentSize = NSSize(width: 760, height: 520)

    public enum Copy {
        public static let stopAlert = "Stop the batch?"
        public static let stop = "Stop"
        public static let keepRunning = "Keep Running"
        public static let undoFailed = "Couldn't undo — some files were moved or renamed since the batch."
        public static let savePresetTitle = "Save Preset"
        public static let savePresetInfo = "Name the preset. A saved preset with the same name is replaced."
        public static let presetFailed = "Shrike couldn't save the preset."
        /// "Delete the preset “Night JPEGs”?"
        public static func deletePresetTitle(_ name: String) -> String { "Delete the preset “\(name)”?" }
        public static let deletePresetInfo = "You can't undo this action."
        public static func builtIn(_ name: String) -> String {
            "“\(name)” is a built-in preset. Choose another name."
        }
    }

    public let model: BatchModel
    private let inserter = BatchTokenInserter()
    private var subs: Set<AnyCancellable> = []

    /// The window that opened the batch: it gets the undo.
    private(set) weak var launcher: NSWindow?
    private var launcherToast: (@MainActor @Sendable (String) -> Void)?

    /// Keep Running hid the window; the Dock badge shows the percent.
    public private(set) var isHiddenWhileRunning = false
    private var closeWhenStopped = false
    private var isAskingToStop = false

    // MARK: Seams (tests replace them)

    /// Answers the "Stop the batch?" alert: 0 = Stop, 1 = Keep Running.
    var closeAlertResponder: ((_ message: String, _ information: String) -> Int?)?
    /// Answers the Save Preset name sheet; nil = Cancel.
    var presetNameResponder: (() -> String?)?
    /// Answers "Delete the preset “Name”?": true = Delete.
    var deletePresetResponder: ((String) -> Bool)?
    var dockBadge: (String?) -> Void = { NSApplication.shared.dockTile.badgeLabel = $0 }
    var requestAttention: () -> Void = { _ = NSApplication.shared.requestUserAttention(.informationalRequest) }
    var announce: (String) -> Void
    var revealInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    var openInShrike: ([URL]) -> Void = { WindowCoordinator.shared.openFolders($0) }
    var pasteboard: NSPasteboard = .general

    // MARK: Opening

    /// Opens the Batch window with `groups` (or adds them to the open
    /// one). `renameOn` (F2 with several items) starts with Rename on.
    @discardableResult
    public static func open(
        groups: [ImageGroup],
        services: ShrikeServices,
        launcher: NSWindow?,
        renameOn: Bool = false,
        toast: (@MainActor @Sendable (String) -> Void)? = nil
    ) -> BatchWindowController {
        let isNew = current == nil
        let controller = current ?? BatchWindowController(model: BatchModel(runner: makeRunner(services)))
        current = controller
        controller.launcher = launcher
        controller.launcherToast = toast
        controller.receive(groups, renameOn: renameOn, isNew: isNew)
        controller.present()
        return controller
    }

    /// The runner for the app's services. The batch's own writes stay
    /// visible to folder watchers so open windows refresh.
    static func makeRunner(_ services: ShrikeServices) -> BatchRunner {
        let backups = services.backupStore ?? .shared
        let ops = FileOps(metadata: services.metadataStore, backups: services.backupStore, watchers: nil)
        return BatchRunner(fileOps: ops, backups: backups, metadata: services.metadataStore)
    }

    init(model: BatchModel) {
        self.model = model
        let window = BatchWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true)
        window.contentMinSize = Self.minContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = model.title
        window.center()
        announce = { text in
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        super.init(window: window)
        window.delegate = self
        window.escapeHandler = { [weak self] in self?.escapePressed() }

        // One accent, the system's.
        let host = NSHostingView(rootView: BatchRootView(model: model, actions: makeActions(), inserter: inserter)
            .tint(Color(nsColor: ShrikeAccent.fill)))
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(Self.contentSize)

        model.$queue
            .sink { [weak window] queue in window?.title = BatchModel.Copy.title(queue.count) }
            .store(in: &subs)
        model.onProgress = { [weak self] done, total in self?.progressed(done, total) }
        model.onFinished = { [weak self] result, _ in self?.runFinished(result) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func receive(_ groups: [ImageGroup], renameOn: Bool, isNew: Bool) {
        switch model.phase {
        case .form:
            if renameOn {
                if isNew, let byDate = BatchPresetStore.builtIns.first(where: { $0.renameTemplate != nil }) {
                    model.apply(byDate)
                } else {
                    model.form.renameOn = true
                }
            }
            model.add(groups)
        case .running:
            // A running batch can't take new items; the window comes up.
            break
        case .done:
            model.resetToForm()
            model.replaceQueue(with: groups)
            if renameOn { model.form.renameOn = true }
        }
    }

    private func present() {
        if isHiddenWhileRunning {
            isHiddenWhileRunning = false
            dockBadge(nil)
        }
        guard Self.presentsWindows else { return }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeActions() -> BatchViewActions {
        var a = BatchViewActions()
        a.addItems = { [weak self] in self?.chooseItems() }
        a.chooseOutput = { [weak self] in self?.chooseOutputFolder() }
        a.savePreset = { [weak self] in self?.savePreset() }
        a.deletePreset = { [weak self] name in self?.deletePreset(name) }
        a.cancel = { [weak self] in self?.close() }
        a.copyLog = { [weak self] in self?.copyLog() }
        a.showInFinder = { [weak self] in self?.showInFinder() }
        a.openInShrike = { [weak self] in self?.openResultInShrike() }
        a.done = { [weak self] in self?.close() }
        return a
    }

    // MARK: Closing

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.phase == .running else { return true }
        askStopOrKeepRunning()
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        if isHiddenWhileRunning { dockBadge(nil) }
        isHiddenWhileRunning = false
        if Self.current === self { Self.current = nil }
    }

    /// Esc: Cancel / close when not running.
    func escapePressed() {
        guard model.phase != .running else { return }
        close()
    }

    /// "Stop the batch?" — Stop · Keep Running (default).
    func askStopOrKeepRunning() {
        guard !isAskingToStop else { return }
        isAskingToStop = true
        let info = BatchModel.Copy.stopAlertInfo(model.completed, model.total)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let choice: Int?
            if let responder = self.closeAlertResponder {
                choice = responder(Copy.stopAlert, info)
            } else {
                choice = await ShrikeAlert.run(
                    message: Copy.stopAlert, information: info,
                    buttons: [ShrikeAlert.Button(Copy.stop), ShrikeAlert.Button(Copy.keepRunning, role: .default)],
                    on: self.window)
            }
            self.isAskingToStop = false
            guard self.model.phase == .running else {
                // The run ended while the alert was up.
                if choice == 0 { self.close() }
                return
            }
            if choice == 0 {
                self.closeWhenStopped = true
                self.model.stop()
            } else {
                self.keepRunningHidden()
            }
        }
    }

    private func keepRunningHidden() {
        isHiddenWhileRunning = true
        window?.orderOut(nil)
        progressed(model.completed, model.total)
    }

    // MARK: Progress and end

    /// "40%" on the Dock icon while the window is hidden.
    static func badge(completed: Int, total: Int) -> String {
        let percent = total > 0 ? Int((Double(completed) / Double(total) * 100).rounded(.down)) : 0
        return "\(percent)%"
    }

    private func progressed(_ completed: Int, _ total: Int) {
        guard isHiddenWhileRunning else { return }
        dockBadge(Self.badge(completed: completed, total: total))
    }

    private func runFinished(_ result: BatchResult?) {
        if result != nil {
            registerUndo()
            announce(model.summary)
        }
        if isHiddenWhileRunning {
            isHiddenWhileRunning = false
            dockBadge(nil)
            if !closeWhenStopped {
                requestAttention()
                if Self.presentsWindows { window?.orderFront(nil) }
            }
        }
        if closeWhenStopped {
            closeWhenStopped = false
            close()
        }
    }

    /// One undo on the launching window (in-place rename / rotate).
    private func registerUndo() {
        guard let name = model.undoActionName, let result = model.result,
              let launcher, let undo = launcher.undoManager else { return }
        let runner = model.runner
        let toast = launcherToast
        undo.registerUndo(withTarget: launcher) { _ in
            MainActor.assumeIsolated {
                BatchUndo.run(runner: runner, result: result, toast: toast)
            }
        }
        undo.setActionName(name)
    }

    // MARK: Done view actions

    func copyLog() {
        pasteboard.clearContents()
        pasteboard.setString(model.logText, forType: .string)
    }

    func showInFinder() {
        let urls = model.doneURLs
        guard !urls.isEmpty else { return }
        revealInFinder(urls)
    }

    func openResultInShrike() {
        let folders = model.doneFolders
        guard !folders.isEmpty else { return }
        openInShrike(folders)
    }

    // MARK: Panels

    private func chooseItems() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .folder]
        panel.prompt = "Add"
        panel.message = "Choose images or folders to add to the batch."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor [weak self] in
                let groups = await Self.groups(for: urls)
                self?.model.add(groups)
            }
        }
    }

    /// Chosen files and folders as groups (off main).
    @concurrent
    nonisolated static func groups(for urls: [URL]) async -> [ImageGroup] {
        var files: [URL] = []
        var groups: [ImageGroup] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                groups += (try? await FolderScanner.imageGroups(in: url)) ?? []
            } else {
                files.append(url)
            }
        }
        return groups + ImageGrouping.group(files, options: ImageGroupingPreference.options)
    }

    private func chooseOutputFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder for the new files."
        if let current = model.outputFolder?.deletingLastPathComponent() { panel.directoryURL = current }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.model.form.outputFolder = url }
        }
    }

    func savePreset() {
        if let responder = presetNameResponder {
            if let name = responder() { store(presetNamed: name) }
            return
        }
        guard let window else { return }
        let alert = ShrikeAlert.make(message: Copy.savePresetTitle, information: Copy.savePresetInfo,
                                    style: .informational,
                                    buttons: [.cancel(), ShrikeAlert.Button("Save", role: .default)])
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "Preset name"
        field.setAccessibilityLabel("Preset name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard ShrikeAlert.index(of: response, buttonCount: 2) == 1 else { return }
            MainActor.assumeIsolated { self?.store(presetNamed: field.stringValue) }
        }
    }

    private func store(presetNamed name: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.model.savePreset(named: name)
            } catch {
                let info: String?
                switch error as? BatchPresetError {
                case .builtInName(let n)?: info = Copy.builtIn(n)
                case .emptyName?: info = "Enter a name."
                default: info = nil
                }
                if self.presetNameResponder != nil { return }
                _ = await ShrikeAlert.run(message: Copy.presetFailed, information: info,
                                         buttons: [ShrikeAlert.Button("OK", role: .default)], on: self.window)
            }
        }
    }

    /// Presets ▸ Delete “Name”: asks first, as a sheet on this window.
    func deletePreset(_ name: String) {
        if let responder = deletePresetResponder {
            if responder(Copy.deletePresetTitle(name)) { removePreset(named: name) }
            return
        }
        guard let window else { return }
        let alert = ShrikeAlert.make(message: Copy.deletePresetTitle(name), information: Copy.deletePresetInfo,
                                    buttons: [ShrikeAlert.Button("Delete", role: .destructive), .cancel()])
        alert.beginSheetModal(for: window) { [weak self] response in
            guard ShrikeAlert.index(of: response, buttonCount: 2) == 0 else { return }
            MainActor.assumeIsolated { self?.removePreset(named: name) }
        }
    }

    private func removePreset(named name: String) {
        Task { @MainActor [weak self] in
            try? await self?.model.deletePreset(named: name)
        }
    }
}

/// The Batch window: Esc closes it when no batch runs.
final class BatchWindow: NSWindow {
    var escapeHandler: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }
}

/// Undo of an in-place batch (`BatchRunner.undo`), with a toast when some
/// files can't go back.
@MainActor
enum BatchUndo {
    /// The last undo's work (tests wait on it).
    static var lastTask: Task<Void, Never>?

    static func run(runner: BatchRunner, result: BatchResult, toast: (@MainActor @Sendable (String) -> Void)?) {
        let previous = lastTask
        lastTask = Task { @MainActor in
            await previous?.value
            do {
                try await runner.undo(result)
            } catch {
                toast?(BatchWindowController.Copy.undoFailed)
            }
        }
    }
}

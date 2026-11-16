//
//  RenameRecoveryNotice.swift
//  ShrikeUI
//
//  Once per launch, late and off
//  the main thread, `FileOps.recoverRenames()` puts cut-off renames back.
//  What it could not fix is told: a sheet for photos still under a temporary
//  name, else one toast for the counts. The texts are pure (tested); the
//  presenter only waits for a window and shows them. Nothing runs on the
//  launch path: the work starts 10 s after launch.
//

import AppKit
import ShrikeCore
import ShrikeIO

/// The texts of the rename-recovery notice. Pure.
public enum RenameRecoveryNotice: Equatable, Sendable {

    /// One photo still under a temporary name, read off the main thread.
    public struct Item: Equatable, Sendable {
        public var originalName: String
        public var temporaryName: String
        /// The folder as the user reads it ("~/Pictures/Trips").
        public var folder: String
        /// The old name is free: the move back failed (no collision).
        public var oldNameFree: Bool
        public init(originalName: String, temporaryName: String, folder: String, oldNameFree: Bool) {
            self.originalName = originalName
            self.temporaryName = temporaryName
            self.folder = folder
            self.oldNameFree = oldNameFree
        }
    }

    case sheet(title: String, information: String)
    case toast(String)

    public static let notNow = "Not Now"
    public static let showInFinder = "Show in Finder"
    static let maxListed = 3

    /// nil: nothing to say (only `restored`, or nothing at all).
    public static func make(items: [Item], backupsNotSaved: Int, historyNotRestored: Int) -> RenameRecoveryNotice? {
        if items.isEmpty {
            let sentences = [backupsSentence(backupsNotSaved, inSheet: false),
                             historySentence(historyNotRestored, inSheet: false)].compactMap { $0 }
            guard !sentences.isEmpty else { return nil }
            if backupsNotSaved > 0, historyNotRestored > 0 {
                // Both counts in one shorter toast; each names its own number.
                let first = backupsNotSaved == 1 ? "the backup of 1 photo" : "the backups of \(backupsNotSaved) photos"
                let second = historyNotRestored == 1 ? "for 1 photo, could not tell which backup belongs to it"
                    : "for \(historyNotRestored) photos, could not tell which backup belongs to which"
                return .toast("A rename was cut off. Shrike lost track of \(first) and, \(second). "
                    + "Revert to Original, ratings or tags may be missing. Nothing was deleted.")
            }
            return .toast("A rename was cut off. " + sentences.joined(separator: " "))
        }
        var paragraphs: [String] = []
        if items.count == 1, let item = items.first {
            let why = item.oldNameFree
                ? "Shrike could not put the old name back."
                : "Shrike could not put the old name back, because a file with that name is already there."
            paragraphs.append("Shrike was closed while it was renaming “\(item.originalName)”. "
                + "It is still in “\(item.folder)”, now called “\(item.temporaryName)”. " + why)
        } else {
            // All in one folder: the folder is named once, in the lead.
            let oneFolder = Set(items.map(\.folder)).count == 1 ? items.first?.folder : nil
            let place = oneFolder.map { " in “\($0)”" } ?? ""
            let lead = items.allSatisfy({ !$0.oldNameFree })
                ? "Shrike was closed while it was renaming these photos\(place), and could not put the old names back, because files with those names are already there."
                : "Shrike was closed while it was renaming these photos\(place), and could not put the old names back."
            var lines = [lead]
            for item in items.prefix(maxListed) {
                lines.append("“\(item.originalName)” is now\n    “\(item.temporaryName)”" + (oneFolder == nil ? " in “\(item.folder)”" : ""))
            }
            if items.count > maxListed { lines.append("and \(items.count - maxListed) more") }
            paragraphs.append(lines.joined(separator: "\n"))
        }
        if let line = backupsSentence(backupsNotSaved, inSheet: true) { paragraphs.append(line) }
        if let line = historySentence(historyNotRestored, inSheet: true) { paragraphs.append(line) }
        if items.contains(where: { $0.temporaryName.hasPrefix(".") }) {
            paragraphs.append("Names that start with a period are hidden in Finder. In Finder, press Command-Shift-Period to show them.")
        }
        let title = items.count == 1 ? "A photo has a temporary name" : "\(items.count) photos have temporary names"
        return .sheet(title: title, information: paragraphs.joined(separator: "\n\n"))
    }

    static func backupsSentence(_ n: Int, inSheet: Bool) -> String? {
        guard n > 0 else { return nil }
        let from = inSheet ? " from that rename" : ""
        return n == 1
            ? "Shrike lost track of the backup of 1 photo\(from), so Revert to Original may be missing for it."
            : "Shrike lost track of the backups of \(n) photos\(from), so Revert to Original may be missing for them."
    }

    static func historySentence(_ n: Int, inSheet: Bool) -> String? {
        guard n > 0 else { return nil }
        let from = inSheet ? " from that rename" : ""
        return n == 1
            ? "For 1 photo\(from), Shrike could not tell which backup belongs to it, so Revert to Original, its rating or tags may be missing. Nothing was deleted."
            : "For \(n) photos\(from), Shrike could not tell which backup belongs to which photo, so Revert to Original, ratings or tags may be missing for them. Nothing was deleted."
    }

    /// The folder for the text: `~` for home; a long path is shortened in
    /// the middle with `…` (never a file name).
    public static func folderText(_ folder: URL, limit: Int = 48) -> String {
        let full = UserFacingPath.string(folder)
        guard full.count > limit, limit > 8 else { return full }
        let keep = limit - 1
        let head = full.prefix(keep / 2)
        let tail = full.suffix(keep - keep / 2)
        return head + "…" + tail
    }

    /// The items still stuck, with file checks (off the main thread). A
    /// temporary file that is gone is dropped (the next launch closes it).
    public static func items(from recovery: RenameRecovery, fileManager: FileManager = .default) -> (items: [Item], temporaries: [URL]) {
        var items: [Item] = []
        var temporaries: [URL] = []
        for entry in recovery.needsAttention where fileManager.fileExists(atPath: entry.temporary.path) {
            temporaries.append(entry.temporary)
            items.append(Item(originalName: entry.original.lastPathComponent,
                              temporaryName: entry.temporary.lastPathComponent,
                              folder: folderText(entry.temporary.deletingLastPathComponent()),
                              oldNameFree: !fileManager.fileExists(atPath: entry.original.path)))
        }
        return (items, temporaries)
    }
}

/// Where the notice may go. Pure: only a Browser, viewer or Welcome
/// window hosts it (never Settings, Batch, Compare, Slideshow or a panel); the
/// first such window on screen is used, and if it shows a sheet the notice waits.
enum RenameRecoveryHost {
    enum Kind: Equatable, Sendable { case browser, viewer, welcome, other }
    struct Candidate: Equatable, Sendable {
        var kind: Kind
        var isOnScreen: Bool
        var hasSheet: Bool
    }
    enum Choice: Equatable, Sendable { case use(Int), wait }

    /// `candidates` in key, main, front-to-back order.
    static func choose(_ candidates: [Candidate]) -> Choice {
        guard let index = candidates.firstIndex(where: { $0.kind != .other && $0.isOnScreen }) else { return .wait }
        return candidates[index].hasSheet ? .wait : .use(index)
    }
}

/// Runs the recovery once per launch and shows its notice on the first
/// Browser, viewer or Welcome window on screen.
@MainActor
enum RenameRecoveryPresenter {

    /// How long after launch the recovery starts (off the launch path).
    static var delay: Duration = .seconds(10)
    private static var started = false

    #if DEBUG
    /// How many times a `-ShrikeDebugAlertPreview` alert is shown.
    static let debugAlertPreviewShows = 1
    /// The window a debug preview sheet is on; ⌘Q ends that sheet too.
    static weak var debugPreviewWindow: NSWindow?
    #endif

    static func schedule(services: ShrikeServices) {
        guard !started else { return }
        started = true
        #if DEBUG
        // Look check only: `-ShrikeDebugAlertPreview quit|writeTimeout|stopTimeout|conflict` shows that
        // alert, built by its real builder with fake data, on the key window 4 s after launch.
        if let i = CommandLine.arguments.firstIndex(of: "-ShrikeDebugAlertPreview"), i + 1 < CommandLine.arguments.count {
            let which = CommandLine.arguments[i + 1]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                // Once: it used to come back after Esc and block Quit.
                for round in 0..<debugAlertPreviewShows {
                let window = NSApp?.keyWindow ?? NSApp?.windows.first { $0.isVisible }
                debugPreviewWindow = window
                let answer: String
                switch which {
                case "quit":
                    let work = QuitWork(batch: .init(completed: 12, total: 40, isHidden: false))
                    let index = await ShrikeAlert.run(message: QuitQuestion.title, information: QuitQuestion.information(for: work),
                                                      buttons: QuitQuestion.quitButtons, on: window)
                    answer = String(describing: index)
                case "writeTimeout", "stopTimeout":
                    let write = which == "writeTimeout"
                    let index = await ShrikeAlert.run(message: write ? QuitQuestion.writeTimeoutTitle : QuitQuestion.stopTimeoutTitle,
                                                      information: write ? QuitQuestion.writeTimeoutInformation : QuitQuestion.stopTimeoutInformation,
                                                      buttons: QuitQuestion.timeoutButtons, on: window)
                    answer = String(describing: index)
                case "toolSwitch", "unsavedEdit":
                    let choice: String = await withCheckedContinuation { done in
                        if which == "toolSwitch" {
                            EditToolTransitionModal.show(on: window, content: .init(outgoing: .crop, destination: .rotate)) {
                                done.resume(returning: "\($0)")
                            }
                        } else if let window {
                            EditExitModal.show(on: window, fileName: "p1.jpg", writable: true) { done.resume(returning: "\($0)") }
                        } else { done.resume(returning: "no window") }
                    }
                    answer = choice
                case "delete":
                    let copy = FileActionCopy.noTrashDelete([ImageGroup(primary: URL(fileURLWithPath: "/tmp/p1.jpg"))])
                    let index = await ShrikeAlert.run(message: copy.message, information: copy.information,
                                                      buttons: copy.buttons, on: window)
                    answer = String(describing: index)
                default:
                    // `conflict` (M = 1 of 3), `conflictSome` (3 of 8), `conflictAll` (8 of 8), `conflictOne` (1 of 1).
                    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
                    let file = folder.appendingPathComponent("IMG_0001.jpg")
                    // A real small photo, so the alert's Existing: / New: lines are filled.
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8,
                                               samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                    try? rep?.representation(using: .jpeg, properties: [:])?.write(to: file)
                    let (n, m) = which == "conflictSome" ? (8, 3) : which == "conflictAll" ? (8, 8) : which == "conflictOne" ? (1, 1) : (3, 1)
                    let conflict = FileConflict(incoming: ImageGroup(primary: file), existing: [file],
                                                destinationFolder: folder, remainingConflicts: n, remainingWithExtraFiles: m)
                    let reply = await FileTransferCoordinator(window: window).askConflict(conflict)
                    answer = String(describing: reply)
                }
                NSLog("ShrikeDebugAlertPreview %@ round %d answer %@", which, round, answer)
                }
            }
        }
        // Look check only: `-ShrikeDebugRecoveryPreview sheet|sheetOneFolder|toast` shows fake notices 3 s after launch.
        if let i = CommandLine.arguments.firstIndex(of: "-ShrikeDebugRecoveryPreview"), i + 1 < CommandLine.arguments.count {
            let kind = CommandLine.arguments[i + 1]
            let sheet = kind.hasPrefix("sheet")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                debugPreview(items: sheet ? (kind == "sheetOneFolder" ? 36 : 5) : 0, hidden: true, backupsNotSaved: 12,
                             historyNotRestored: 12, oneFolder: kind == "sheetOneFolder")
            }
            return
        }
        #endif
        let metadata = services.metadataStore
        let backups = services.backupStore ?? .shared
        let delay = delay
        Task.detached(priority: .utility) {
            try? await Task.sleep(for: delay)
            // The real stores: with nil stores the name comes back but its backups, rating and tags do not.
            let recovery = await FileOps(metadata: metadata, backups: backups).recoverRenames()
            let (items, temporaries) = RenameRecoveryNotice.items(from: recovery)
            guard let notice = RenameRecoveryNotice.make(items: items, backupsNotSaved: recovery.backupsNotSaved,
                                                         historyNotRestored: recovery.historyNotRestored) else { return }
            await MainActor.run { present(notice, temporaries: temporaries) }
        }
    }

    /// How long the counts-only toast stays: four sentences.
    static let toastDuration: TimeInterval = 8.0

    /// The notice waiting for a host window, and the observers that wake it.
    private static var pending: (notice: RenameRecoveryNotice, temporaries: [URL])?
    private static var observers: [any NSObjectProtocol] = []

    /// The windows in the order the rule reads them: key, main, then front to back.
    private static func orderedCandidates() -> [NSWindow] {
        var seen = Set<ObjectIdentifier>()
        let all = [NSApp?.keyWindow, NSApp?.mainWindow].compactMap { $0 } + (NSApp?.orderedWindows ?? [])
        return all.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    static func kind(of window: NSWindow) -> RenameRecoveryHost.Kind {
        if window is BrowserWindow { return .browser }
        if window is ViewerWindow { return .viewer }
        if window is WelcomeWindow { return .welcome }
        return .other
    }

    /// The host by that rule, or nil (wait).
    static func hostWindow() -> NSWindow? {
        let windows = orderedCandidates()
        let facts = windows.map {
            RenameRecoveryHost.Candidate(kind: kind(of: $0), isOnScreen: $0.isVisible && !$0.isMiniaturized,
                                         hasSheet: $0.attachedSheet != nil)
        }
        guard case .use(let index) = RenameRecoveryHost.choose(facts) else { return nil }
        return windows[index]
    }

    /// Shows the notice now if a host is on screen, else waits for a window
    /// to become key or main, or for a sheet to end. No timer.
    static func present(_ notice: RenameRecoveryNotice, temporaries: [URL]) {
        pending = (notice, temporaries)
        tryPresent()
        guard pending != nil, observers.isEmpty else { return }
        let names: [Notification.Name] = [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                                          NSWindow.didEndSheetNotification, NSWindow.didDeminiaturizeNotification]
        observers = names.map {
            NotificationCenter.default.addObserver(forName: $0, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { scheduleTry() }
            }
        }
    }

    /// One run-loop turn later, so a window that just appeared has drawn and a
    /// sheet that is ending is gone.
    private static func scheduleTry() {
        DispatchQueue.main.async { MainActor.assumeIsolated { tryPresent() } }
    }

    private static func tryPresent() {
        guard let waiting = pending, let window = hostWindow() else { return }
        pending = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        show(waiting.notice, temporaries: waiting.temporaries, on: window)
    }

    private static func show(_ notice: RenameRecoveryNotice, temporaries: [URL], on window: NSWindow) {
        switch notice {
        case .toast(let text):
            var content = ToastContent(text, kind: .error)
            content.customDuration = toastDuration
            toastHost(in: window)?.show(content)
        case .sheet(let title, let information):
            let alert = makeSheetAlert(title: title, information: information)
            shownSheet = alert.window
            alert.beginSheetModal(for: window) { response in
                shownSheet = nil
                guard ShrikeAlert.index(of: response, buttonCount: 2) == 1 else { return }
                NSWorkspace.shared.activateFileViewerSelecting(temporaries)
            }
        }
    }

    /// The sheet while it is on screen (ended as `Not Now` at quit).
    private static weak var shownSheet: NSWindow?

    /// The sheet. Informational: it never blocks ⌘Q. An `NSAlert`
    /// window prevents app termination while it is modal by default, and a
    /// sheet counts, so ⌘Q and Quit Shrike did nothing while it was up.
    /// Esc = `Not Now`, Return = `Show in Finder`. The body sits in a
    /// left-aligned, selectable accessory label, so each entry can put the
    /// temporary name on its own indented line (the plain informative text
    /// has no indent).
    static func makeSheetAlert(title: String, information: String) -> NSAlert {
        let alert = ShrikeAlert.make(
            message: title, information: nil, style: .critical,
            buttons: [.cancel(RenameRecoveryNotice.notNow),
                      ShrikeAlert.Button(RenameRecoveryNotice.showInFinder, role: .default)])
        alert.window.preventsApplicationTerminationWhenModal = false
        let label = NSTextField(labelWithAttributedString: bodyText(information))
        label.isSelectable = true
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = bodyWidth
        label.setAccessibilityLabel(information)
        let size = label.sizeThatFits(NSSize(width: bodyWidth, height: .greatestFiniteMagnitude))
        label.frame = NSRect(x: 0, y: 0, width: bodyWidth, height: ceil(size.height))
        alert.accessoryView = label
        return alert
    }

    static let bodyWidth: CGFloat = 400
    static let entryIndent: CGFloat = 14

    /// `information` as the sheet shows it: lines that start with spaces
    /// (the temporary names) are indented, wrapped lines stay indented.
    static func bodyText(_ information: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let lines = information.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let indented = line.hasPrefix(" ")
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            if indented { style.firstLineHeadIndent = entryIndent; style.headIndent = entryIndent }
            let text = (indented ? line.trimmingCharacters(in: .whitespaces) : line) + (i < lines.count - 1 ? "\n" : "")
            out.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]))
        }
        return out
    }

    /// ⌘Q with the sheet up: end it as `Not Now` (nothing changes; the
    /// items come back at the next launch), so no quit
    /// question queues behind it on the same window.
    static func endSheetForQuit() {
        #if DEBUG
        // A look-check preview sheet never blocks Quit.
        if let window = debugPreviewWindow, let preview = window.attachedSheet, preview !== shownSheet {
            window.endSheet(preview, returnCode: .abort)
            debugPreviewWindow = nil
        }
        #endif
        guard let sheet = shownSheet, let parent = sheet.sheetParent else { return }
        // Buttons are added right to left: `Not Now` (left) is the second button.
        parent.endSheet(sheet, returnCode: .alertSecondButtonReturn)
    }

    #if DEBUG
    /// Look check: the sheet (or the toast) with fake
    /// names, no journal, no file checks. Call from the debugger:
    /// `expr ShrikeUI.RenameRecoveryPresenter.debugPreview(items: 3, hidden: true)`.
    static func debugPreview(items count: Int = 1, hidden: Bool = true, backupsNotSaved: Int = 0,
                             historyNotRestored: Int = 0, oneFolder: Bool = false) {
        let items = (0..<count).map { i in
            RenameRecoveryNotice.Item(
                originalName: "IMG_00\(42 + i).jpg",
                temporaryName: hidden ? ".shrike-rename-8F2A91C3-5B0E-4D7A-9C21-6E4F0A3B7D15-IMG_00\(42 + i).jpg"
                                      : "IMG_00\(42 + i).jpg shrike-tmp-8F2A91C3",
                folder: oneFolder || i.isMultiple(of: 2) ? "~/Pictures/Trips" : "~/Pictures/Family",
                oldNameFree: false)
        }
        guard let notice = RenameRecoveryNotice.make(items: items, backupsNotSaved: backupsNotSaved,
                                                     historyNotRestored: historyNotRestored) else { return }
        present(notice, temporaries: [])
    }
    #endif

    /// The window's toast host (viewer, browser, Welcome); one is added when none is installed yet.
    static func toastHost(in window: NSWindow) -> ToastHostView? {
        guard let root = window.contentView else { return nil }
        func find(_ view: NSView) -> ToastHostView? {
            if let host = view as? ToastHostView { return host }
            for sub in view.subviews { if let host = find(sub) { return host } }
            return nil
        }
        if let host = find(root) { return host }
        let host = ToastHostView(placement: .browser)
        host.install(in: root)
        return host
    }
}

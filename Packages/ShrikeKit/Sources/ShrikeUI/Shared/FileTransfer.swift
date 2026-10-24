//
//  FileTransfer.swift
//  ShrikeUI
//
//  Copy and Move to folder, shared by the viewer and the
//  Browser: the `C` / `M` chord follow-ups, destination slots, the folder
//  panel, the missing-slot alert, the name-clash sheet, the progress
//  toast and the copy lines. The file work itself is `FileOps`.
//

import AppKit
import ShrikeCore
import ShrikeIO

/// Which folder a Copy / Move chord asked for.
public enum DestinationChoice: Sendable, Hashable {
    /// `1`–`9`: the slot's folder (an empty slot opens the panel first).
    case slot(Int)
    /// `⌥1`–`⌥9`: choose the slot's folder again, then run.
    case rechoose(Int)
    /// `C C` / `M M`: the last folder for this verb (panel if none).
    case last
    /// `0`: the panel; the folder is used once, not saved in a slot.
    case choose
}

/// The second key of a `C` / `M` chord. Pure — safe for unit tests.
public enum FileChord {

    public enum Followup: Sendable, Hashable {
        case run(FileVerb, DestinationChoice)
        /// Esc: cancel the chord and do nothing else.
        case cancel
        /// Any other key: cancel the chord, then handle the key normally.
        case passThrough
    }

    public static func verb(for prefix: Character) -> FileVerb? {
        switch prefix {
        case "c": return .copy
        case "m": return .move
        default: return nil
        }
    }

    public static func letter(for verb: FileVerb) -> String {
        verb == .copy ? "C" : "M"
    }

    /// nil when `prefix` is not a Copy / Move chord.
    public static func followup(prefix: Character, snapshot: KeyEventSnapshot) -> Followup? {
        guard let verb = verb(for: prefix) else { return nil }
        let mods = snapshot.flags.intersection([.command, .option, .control, .shift])
        if snapshot.key == "\u{1b}" || snapshot.keyCode == 53 { return .cancel }
        if mods.isEmpty, snapshot.key == String(prefix) { return .run(verb, .last) }
        guard snapshot.key.count == 1, let char = snapshot.key.first, char.isASCII,
              let digit = char.wholeNumberValue else { return .passThrough }
        if mods.isEmpty { return .run(verb, digit == 0 ? .choose : .slot(digit)) }
        if mods == .option, digit != 0 { return .run(verb, .rechoose(digit)) }
        return .passThrough
    }
}

// MARK: - Copy

enum FileTransferCopy {

    static func done(_ verb: FileVerb, _ groups: [ImageGroup], folder: URL) -> String {
        let past = verb == .copy ? "Copied" : "Moved"
        let target = "“\(folder.lastPathComponent)”"
        if groups.count == 1, let group = groups.first {
            return "\(past) “\(group.displayName)” to \(target)."
        }
        return "\(past) \(groups.count) items to \(target)."
    }

    static func alreadyIn(_ groups: [ImageGroup], folder: URL) -> String {
        if groups.count == 1, let group = groups.first {
            return "“\(group.displayName)” is already in “\(folder.lastPathComponent)”."
        }
        return "These items are already in “\(folder.lastPathComponent)”."
    }

    /// "Copying 3 of 12…" — `completed` files are done, so the one in
    /// flight is `completed + 1`.
    static func progress(_ verb: FileVerb, completed: Int, total: Int) -> String {
        let activity = verb == .copy ? "Copying" : "Moving"
        if total == 1 { return "\(activity) 1 item…" }
        let current = min(total, completed + 1)
        return "\(activity) \(current) of \(total)…"
    }

    static func cancelled(_ verb: FileVerb, done: Int, total: Int) -> String {
        "\(verb == .copy ? "Copied" : "Moved") \(done) of \(total) items. The rest were cancelled."
    }

    static func failed(_ verb: FileVerb, _ group: ImageGroup, folder: URL, error: any Error) -> String {
        let base = "Couldn't \(verb == .copy ? "copy" : "move") “\(group.displayName)” to “\(folder.lastPathComponent)”"
        if let ops = error as? FileOpsError {
            if case .destinationUnavailable = ops { return "\(base) — the folder no longer exists." }
            if let reason = FileActionCopy.reason(for: ops) { return "\(base) — \(reason)." }
        }
        return "\(base)."
    }

    /// "Couldn't undo — “Selects” no longer exists."
    static func undoFailed(_ error: any Error, folder: URL) -> String {
        switch error as? FileOpsError {
        case .notFound(let url)?, .destinationUnavailable(let url)?:
            return "Couldn't undo — “\(url.lastPathComponent)” no longer exists."
        default:
            return "Couldn't undo — “\(folder.lastPathComponent)” no longer exists."
        }
    }

    static func slotPanelTitle(_ slot: Int) -> String { "Choose a folder for slot \(slot)" }

    static func choosePanelTitle(_ verb: FileVerb) -> String {
        verb == .copy ? "Choose a folder to copy to" : "Choose a folder to move to"
    }

    static func slotUnavailableTitle(_ name: String) -> String { "“\(name)” is not available." }
    static let slotUnavailableMessage = "The folder may be on a disconnected disk."

    static func conflictTitle(_ name: String, folder: URL) -> String {
        "“\(name)” already exists in “\(folder.lastPathComponent)”."
    }
    static let conflictMessage = "Replacing it moves the existing file to the Trash."

    /// The same line, naming the other files of the same photo that Replace
    /// also moves to the Trash (a RAW or sidecar with the same name). Undo
    /// puts them back.
    static func conflictMessage(alsoReplacing extra: [String]) -> String {
        guard !extra.isEmpty else { return conflictMessage }
        let shown = extra.prefix(4).map { "“\($0)”" }.joined(separator: ", ")
        let more = extra.count > 4 ? " and \(extra.count - 4) more" : ""
        return conflictMessage + " Replace also moves \(shown)\(more) to the Trash, because "
            + (extra.count == 1 ? "it belongs" : "they belong") + " to the same photo."
    }

    static func applyToRemaining(_ remaining: Int) -> String {
        remaining == 1 ? "Do this for the remaining conflict"
                       : "Do this for the remaining \(remaining) conflicts"
    }

    /// "Existing: 6000 × 4000, 12.4 MB, 25 Sep 2026 14:02". Reads the disk.
    static func detailsLine(_ label: String, url: URL) -> String {
        var parts: [String] = []
        if let size = WindowTitles.headerPixelSize(of: url) {
            parts.append("\(Int(size.width)) × \(Int(size.height))")
        }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        if let bytes = values?.fileSize {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if let date = values?.contentModificationDate {
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("dMMMyyyyHHmm")
            parts.append(formatter.string(from: date))
        }
        return "\(label): " + parts.joined(separator: ", ")
    }
}

// MARK: - Coordinator

/// One per window. Resolves destinations (slots, panel, the missing-destination alert), asks
/// about name clashes (the name-clash sheet), runs a transfer with its progress toast,
/// and shows the chord HUD.
@MainActor
final class FileTransferCoordinator {

    /// How long a lone `C` / `M` waits before the HUD appears.
    static var hudDelay: Duration = .milliseconds(250)
    /// Transfers longer than this show the progress toast.
    static var progressDelay: Duration = .seconds(1)

    weak var window: NSWindow?
    var slots: DestinationSlots = .standard
    /// Presents an alert on the owning window; returns the button index.
    var presentAlert: @MainActor (String, String, [ShrikeAlert.Button]) async -> Int? = { _, _, _ in nil }
    /// Window callbacks are weak; each run keeps only its latest presentation ticket.
    var showProgressToast: @MainActor (ToastContent) -> ToastHostView.ProgressTicket? = { _ in nil }
    var updateProgressToast: @MainActor (ToastContent, ToastHostView.ProgressTicket) -> ToastHostView.ProgressTicket? = { _, _ in nil }
    var dismissProgressToast: @MainActor (ToastHostView.ProgressTicket) -> Void = { _ in }

    /// Test seams: the folder panel (title → folder, nil = Cancel) and
    /// the name-clash sheet.
    var panelResponder: ((String) -> URL?)?
    var conflictResponder: ((FileConflict) async -> ConflictAnswer)?
    /// Every conflict asked this session (tests).
    private(set) var conflictsAsked = 0

    /// Esc sets this: the file in flight finishes and is counted (cancelling
    /// the reading task would drop it from the receipt).
    private var runningStop: TransferStop?
    private(set) var isShowingProgress = false

    // HUD
    private(set) var hud: DestinationHUDView?
    private var hudTask: Task<Void, Never>?
    /// How many times a HUD was drawn (tests: `M 1` fast draws none).
    private(set) var hudShownCount = 0
    var onHUDPick: ((FileVerb, DestinationChoice) -> Void)?
    var onHUDCancel: (() -> Void)?

    init(window: NSWindow?) {
        self.window = window
    }

    // MARK: Destinations

    enum Resolution: Equatable {
        case folder(URL)
        case needsPanel(title: String, saveSlot: Int?)
        case unavailable(slot: Int, name: String)
    }

    /// What `choice` means right now, without any UI. `.folder` lets the
    /// caller act in the same main-actor turn as the key press.
    func resolveNow(_ choice: DestinationChoice, verb: FileVerb) -> Resolution {
        switch choice {
        case .slot(let number):
            do {
                return .folder(try slots.resolve(number))
            } catch {
                switch error {
                case .empty:
                    return .needsPanel(title: FileTransferCopy.slotPanelTitle(number), saveSlot: number)
                case .unavailable(let name):
                    return .unavailable(slot: number, name: name)
                }
            }
        case .rechoose(let number):
            return .needsPanel(title: FileTransferCopy.slotPanelTitle(number), saveSlot: number)
        case .last:
            if let url = slots.last(verb) { return .folder(url) }
            return .needsPanel(title: FileTransferCopy.choosePanelTitle(verb), saveSlot: nil)
        case .choose:
            return .needsPanel(title: FileTransferCopy.choosePanelTitle(verb), saveSlot: nil)
        }
    }

    /// Runs the UI a resolution needs (panel, the missing-destination alert). nil = cancelled.
    func resolve(_ resolution: Resolution) async -> URL? {
        switch resolution {
        case .folder(let url):
            return url
        case .needsPanel(let title, let slot):
            guard let url = await chooseFolder(title: title) else { return nil }
            if let slot { slots.set(slot, folder: url) }
            return url
        case .unavailable(let slot, let name):
            let choice = await presentAlert(
                FileTransferCopy.slotUnavailableTitle(name),
                FileTransferCopy.slotUnavailableMessage,
                [.cancel(), ShrikeAlert.Button("Clear Slot"),
                 ShrikeAlert.Button("Choose New Folder…", role: .default)]
            )
            switch choice {
            case 1:
                slots.clear(slot)
                return nil
            case 2:
                return await resolve(.needsPanel(title: FileTransferCopy.slotPanelTitle(slot), saveSlot: slot))
            default:
                return nil
            }
        }
    }

    func chooseFolder(title: String) async -> URL? {
        if let panelResponder { return panelResponder(title) }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = title
        panel.message = title
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        return await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    // MARK: Conflicts (A3)

    func askConflict(_ conflict: FileConflict) async -> ConflictAnswer {
        conflictsAsked += 1
        if let conflictResponder { return await conflictResponder(conflict) }
        let incoming = conflict.incoming.primary
        let existing = conflict.existingPrimary ?? conflict.existing.first ?? incoming
        let details = await Task.detached(priority: .userInitiated) {
            [FileTransferCopy.detailsLine("Existing", url: existing),
             FileTransferCopy.detailsLine("New", url: incoming)].joined(separator: "\n")
        }.value
        let alert = ShrikeAlert.make(
            message: FileTransferCopy.conflictTitle(existing.lastPathComponent, folder: conflict.destinationFolder),
            information: FileTransferCopy.conflictMessage(alsoReplacing: conflict.allOtherFilesReplaced.map(\.lastPathComponent)),
            buttons: [.cancel("Skip"), ShrikeAlert.Button("Replace"), ShrikeAlert.Button("Keep Both", role: .default)]
        )
        let label = NSTextField(wrappingLabelWithString: details)
        label.font = ChromeTypography.font(11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 0, y: 0, width: 300, height: 32)
        alert.accessoryView = label
        if conflict.remainingConflicts > 0 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = FileTransferCopy.applyToRemaining(conflict.remainingConflicts)
            alert.suppressionButton?.state = .off
        }
        let index: Int?
        if let window {
            index = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: ShrikeAlert.index(of: response, buttonCount: 3))
                }
            }
        } else {
            index = ShrikeAlert.index(of: alert.runModal(), buttonCount: 3)
        }
        let all = alert.suppressionButton?.state == .on && conflict.remainingConflicts > 0
        switch index {
        case 1: return ConflictAnswer(.replace, applyToRemaining: all)
        case 2: return ConflictAnswer(.keepBoth, applyToRemaining: all)
        default: return ConflictAnswer(.skip, applyToRemaining: all)
        }
    }

    // MARK: Running

    struct Outcome {
        /// nil when nothing ran (e.g. the folder was unavailable).
        let receipt: FileOpReceipt?
        let skipped: [FileOpSkip]
        let failures: [FileOpFailure]
        let error: (any Error)?
        let cancelled: Bool
        let total: Int

        /// What landed (empty when nothing did).
        var items: [FileOpReceipt.Item] { receipt?.items ?? [] }
    }

    /// Runs one copy / move and returns what happened. Shows the progress
    /// toast when it takes longer than `progressDelay`. Cancel the calling
    /// task to stop it: finished files stay and are in the receipt.
    func run(_ verb: FileVerb, _ groups: [ImageGroup], to folder: URL, ops: FileOps) async -> Outcome {
        let policy = ConflictPolicy.ask { [weak self] conflict in
            await self?.askConflict(conflict) ?? .skip
        }
        let stop = TransferStop()
        runningStop = stop
        defer { runningStop = nil }
        let stream = verb == .copy
            ? ops.copy(groups, to: folder, conflicts: policy, stop: stop)
            : ops.move(groups, to: folder, conflicts: policy, stop: stop)
        let box = ProgressBox()
        let progressTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.progressDelay)
            guard !Task.isCancelled, let self, let last = box.last, !last.isFinished else { return }
            box.visible = true
            box.ticket = self.showProgress(verb, last)
        }
        var failure: (any Error)?
        do {
            for try await progress in stream {
                box.last = progress
                if box.visible, !progress.isFinished, let ticket = box.ticket {
                    box.ticket = updateProgressToast(progressContent(verb, progress), ticket)
                }
            }
        } catch {
            failure = error
        }
        progressTimer.cancel()
        isShowingProgress = false
        if let ticket = box.ticket { dismissProgressToast(ticket) }
        let last = box.last
        let cancelled = Task.isCancelled || (last?.wasCancelled ?? false)
        return Outcome(
            receipt: last?.receipt,
            skipped: last?.skipped ?? [], failures: last?.failures ?? [],
            error: failure, cancelled: cancelled, total: groups.count)
    }

    private func showProgress(_ verb: FileVerb, _ progress: FileOpProgress) -> ToastHostView.ProgressTicket? {
        isShowingProgress = true
        return showProgressToast(progressContent(verb, progress))
    }

    private func progressContent(_ verb: FileVerb, _ progress: FileOpProgress) -> ToastContent {
        var content = ToastContent(FileTransferCopy.progress(verb, completed: progress.completed, total: progress.total))
        content.progress = progress.fractionCompleted
        content.progressIsIndeterminate = !progress.isFinished
            && (progress.total == 1 || progress.fractionCompleted <= 0)
        return content
    }

    /// Esc while the progress toast shows: stop the rest.
    func cancelRunning() -> Bool {
        guard isShowingProgress, let stop = runningStop else { return false }
        stop.stop()
        return true
    }

    // MARK: HUD

    /// `C` / `M` pressed: the HUD shows if no second key comes in time.
    func armHUD(_ verb: FileVerb) {
        dismissHUD()
        hudTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.hudDelay)
            guard !Task.isCancelled, let self else { return }
            self.showHUD(verb)
        }
    }

    private static func splitView(in view: NSView?) -> NSSplitView? {
        guard let view else { return nil }
        if let split = view as? NSSplitView { return split }
        for sub in view.subviews { if let found = splitView(in: sub) { return found } }
        return nil
    }

    func dismissHUD() {
        hudTask?.cancel()
        hudTask = nil
        hud?.removeFromSuperview()
        hud = nil
    }

    var isHUDVisible: Bool { hud != nil }

    private func showHUD(_ verb: FileVerb) {
        // A viewer's content view is its split view; the
        // HUD goes on the canvas, never in as a split pane.
        // The content view can be a plain wrapper around the split view (it is on
        // macOS 26), so look for the split view inside it.
        let content = window?.contentView
        guard let container = Self.splitView(in: content)?.arrangedSubviews.first ?? content else { return }
        let view = DestinationHUDView(verb: verb, slots: slots.slots(), last: slots.last(verb))
        view.onPick = { [weak self] choice in self?.onHUDPick?(verb, choice) }
        view.onCancel = { [weak self] in self?.onHUDCancel?() }
        view.onChangeSlot = { [weak self] number in
            Task { @MainActor [weak self] in
                guard let self,
                      let url = await self.chooseFolder(title: FileTransferCopy.slotPanelTitle(number))
                else { return }
                self.slots.set(number, folder: url)
                self.hud?.reload(slots: self.slots.slots(), last: self.slots.last(verb))
            }
        }
        view.onClearSlot = { [weak self] number in
            guard let self else { return }
            self.slots.clear(number)
            self.hud?.reload(slots: self.slots.slots(), last: self.slots.last(verb))
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hud = view
        hudShownCount += 1
        NSAccessibility.post(element: view, notification: .announcementRequested, userInfo: [
            .announcement: verb == .copy ? "Copy to…" : "Move to…",
            .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }
}

/// Latest progress, shared between the stream loop and the 1 s timer.
@MainActor
private final class ProgressBox {
    var last: FileOpProgress?
    var visible = false
    var ticket: ToastHostView.ProgressTicket?
}

// MARK: - HUD view

/// The chord HUD: a full-window catcher (a click outside the panel
/// cancels) holding the 360 pt solid HUD panel, 20 % above centre.
final class DestinationHUDView: NSView {

    var onPick: ((DestinationChoice) -> Void)?
    var onCancel: (() -> Void)?
    var onChangeSlot: ((Int) -> Void)?
    var onClearSlot: ((Int) -> Void)?

    let verb: FileVerb
    private let panel = HUDSurfaceView()
    private let stack = NSStackView()
    private(set) var rowTitles: [String] = []

    init(verb: FileVerb, slots: [DestinationSlot?], last: URL?) {
        self.verb = verb
        super.init(frame: .zero)
        // The solid panel over the canvas (`hud.surface.opaque`).
        panel.usesOpaqueFill = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.group)
        panel.setAccessibilityLabel(verb == .copy ? "Copy to…" : "Move to…")
        addSubview(panel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The rows scroll when the card is taller than the canvas (spec 21b §6).
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = stack
        panel.addSubview(scroll)
        let fullHeight = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        fullHeight.priority = NSLayoutConstraint.Priority(rawValue: 460)   // above the centring (450), below both clamps

        // centerY at 0.6 × half the height = 20 % of the height above
        // centre. Only preferred: the clamps below win in a short window.
        // Every placement rule loses to the window's size
        // (`windowSizeStayPut` = 500): the HUD never grows the window.
        let preferred = NSLayoutConstraint(item: panel, attribute: .centerY, relatedBy: .equal,
                                           toItem: self, attribute: .centerY, multiplier: 0.6, constant: 0)
        preferred.priority = Self.preferredPriority
        let insideBottom = panel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.margin)
        insideBottom.priority = Self.bottomClampPriority
        let insideTop = panel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Self.margin)
        insideTop.priority = Self.topClampPriority
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.nominalWidth),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            panel.centerXAnchor.constraint(equalTo: centerXAnchor),
            preferred,
            insideTop,
            insideBottom,
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            fullHeight,
        ])
        // Spec 21b §6: min(360, canvas − 24), never below 216. A narrow viewer
        // (480 pt window + inspector = 240 pt canvas) must not cut the card off.
        let nominal = panel.widthAnchor.constraint(equalToConstant: Self.nominalWidth)
        nominal.priority = NSLayoutConstraint.Priority(rawValue: 490)   // never grows the window
        let left = panel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Self.sideMargin)
        let right = panel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Self.sideMargin)
        left.priority = NSLayoutConstraint.Priority(rawValue: 495); right.priority = left.priority
        NSLayoutConstraint.activate([nominal, left, right])
        reload(slots: slots, last: last)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static let nominalWidth: CGFloat = 360
    static let minimumWidth: CGFloat = 216
    static let sideMargin: CGFloat = 12
    var panelFrameForTesting: NSRect { layoutSubtreeIfNeeded(); return panel.frame }

    /// Gap between the HUD and the edges it is clamped to.
    static let margin: CGFloat = 12
    /// The top clamp wins over the bottom one; both lose to the window.
    static let topClampPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 10)
    static let bottomClampPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 20)
    static let preferredPriority = NSLayoutConstraint.Priority(rawValue: NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 50)
    private var layoutRectClamps: [NSLayoutConstraint] = []

    /// In a short window the HUD was clipped (its 20 %-above-centre
    /// spot put the top under the title bar / toolbar). It is clamped
    /// inside the window's `contentLayoutRect` (the part no chrome
    /// covers); the top wins if it cannot fit at all.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NSLayoutConstraint.deactivate(layoutRectClamps)
        layoutRectClamps = []
        guard let guide = window?.contentLayoutGuide as? NSLayoutGuide else { return }
        let bottom = panel.bottomAnchor.constraint(lessThanOrEqualTo: guide.bottomAnchor, constant: -Self.margin)
        bottom.priority = Self.bottomClampPriority
        let top = panel.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: Self.margin)
        top.priority = Self.topClampPriority
        layoutRectClamps = [top, bottom]
        NSLayoutConstraint.activate(layoutRectClamps)
    }

    /// Test seam: the panel's frame in window coordinates.
    var panelFrameInWindowForTesting: NSRect { panel.convert(panel.bounds, to: nil) }

    func reload(slots: [DestinationSlot?], last: URL?) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rowTitles = []

        let title = NSTextField(labelWithString: verb == .copy ? "Copy to…" : "Move to…")
        title.font = ChromeTypography.font(13, weight: .semibold)
        title.textColor = .labelColor
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(8, after: title)

        for (offset, slot) in slots.prefix(DestinationSlots.count).enumerated() {
            let number = offset + 1
            let row: DestinationHUDRow
            if let slot {
                row = DestinationHUDRow(key: "\(number)", name: slot.name,
                                        path: UserFacingPath.string(slot.url))
                row.slotNumber = number
            } else {
                row = DestinationHUDRow(key: "\(number)", emptyText: "Empty — press \(number) to choose a folder")
            }
            row.onClick = { [weak self] in self?.onPick?(.slot(number)) }
            row.onChange = { [weak self] in self?.onChangeSlot?(number) }
            row.onClear = { [weak self] in self?.onClearSlot?(number) }
            add(row)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if let previous = stack.arrangedSubviews.dropLast().last {
            stack.setCustomSpacing(8, after: previous)
        }
        stack.setCustomSpacing(8, after: separator)

        if let last {
            let row = DestinationHUDRow(key: FileChord.letter(for: verb),
                                        name: "Same as last time: \(last.lastPathComponent)", path: nil)
            row.onClick = { [weak self] in self?.onPick?(.last) }
            add(row)
        }
        let choose = DestinationHUDRow(key: "0", name: "Choose Folder…", path: nil)
        choose.onClick = { [weak self] in self?.onPick?(.choose) }
        add(choose)
        let cancel = DestinationHUDRow(key: "esc", name: "Cancel", path: nil)
        cancel.onClick = { [weak self] in self?.onCancel?() }
        add(cancel)
    }

    private func add(_ row: DestinationHUDRow) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rowTitles.append(row.accessibilityLabel() ?? "")
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !panel.frame.contains(point) { onCancel?() }
    }
}

/// One HUD row, 24 pt: key (SF Mono 13 semibold), name (13), path (11,
/// secondary, middle-truncated). Empty slots: one 13 pt tertiary line.
final class DestinationHUDRow: NSView {

    var slotNumber: Int?
    var onClick: (() -> Void)?
    var onChange: (() -> Void)?
    var onClear: (() -> Void)?

    init(key: String, name: String, path: String?) {
        super.init(frame: .zero)
        let name = Self.label(name, font: ChromeTypography.font(13), color: .labelColor)
        // Folder names lose their middle on a narrow canvas; the slot digit keeps its column.
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [Self.keyLabel(key), name]
        if let path {
            let pathLabel = Self.label(path, font: ChromeTypography.font(11), color: .secondaryLabelColor)
            pathLabel.alignment = .right
            pathLabel.lineBreakMode = .byTruncatingMiddle
            pathLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
            views.append(pathLabel)
        }
        build(views)
        setAccessibilityLabel([name.stringValue, path].compactMap { $0 }.joined(separator: ", "))
    }

    init(key: String, emptyText: String) {
        super.init(frame: .zero)
        build([Self.keyLabel(key), Self.label(emptyText, font: ChromeTypography.font(13), color: .tertiaryLabelColor)])
        setAccessibilityLabel(emptyText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ views: [NSView]) {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    private static func keyLabel(_ key: String) -> NSTextField {
        let label = self.label(key, font: .monospacedSystemFont(ofSize: 13, weight: .semibold), color: .labelColor)
        label.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return label
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // A narrow canvas shortens the text; the text never widens the card (or the window).
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// Right-click a slot row: "Change Folder…", "Clear Slot".
    override func menu(for event: NSEvent) -> NSMenu? {
        guard slotNumber != nil else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: "Change Folder…", action: #selector(changeFolder(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Clear Slot", action: #selector(clearSlot(_:)), keyEquivalent: "").target = self
        return menu
    }

    @objc private func changeFolder(_ sender: Any?) { onChange?() }
    @objc private func clearSlot(_ sender: Any?) { onClear?() }
}

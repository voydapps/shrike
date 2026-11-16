//
//  Alerts.swift
//  ShrikeUI
//
//  Alert helpers. Every alert is a sheet on the window that
//  raised it (never app-modal). Buttons follow HIG order: the default
//  button is rightmost, a destructive button is never the default, and
//  Esc means Cancel. Each alert's exact copy lives in the section that
//  raises it.
//

import AppKit

public enum ShrikeAlert {

    public struct Button: Equatable, Sendable {
        public enum Role: Sendable, Equatable {
            /// Return triggers it. At most one per alert.
            case `default`
            /// Esc triggers it.
            case cancel
            /// Red, never the default.
            case destructive
            /// Neither Return nor Esc.
            case normal
            /// Cancel that is also the default: Return and Esc both fire it
            /// (for alerts where the other choice changes or deletes files).
            case safeCancel
        }
        public let title: String
        public let role: Role

        public init(_ title: String, role: Role = .normal) {
            self.title = title
            self.role = role
        }

        public static func cancel(_ title: String = "Cancel") -> Button { Button(title, role: .cancel) }
        public static func safeCancel(_ title: String = "Cancel") -> Button { Button(title, role: .safeCancel) }
    }

    /// At every layout AppKit moves a button titled exactly "Cancel" to the
    /// left and gives it Esc, whatever order and keys we set (seen on screen
    /// 2026-11-13: Quit Anyway ended up right of Cancel). An invisible
    /// separator after the word ends that match; VoiceOver still gets the
    /// clean title from the accessibility label.
    static func displayTitle(_ title: String) -> String {
        title == "Cancel" ? title + "\u{2063}" : title
    }

    /// Builds the alert. `buttons` are in visual order, left to right.
    /// NSAlert lays buttons out right to left, so they are added reversed;
    /// use `index(of:buttonCount:)` to map a response back to `buttons`.
    @MainActor
    public static func make(
        message: String,
        information: String? = nil,
        style: NSAlert.Style = .warning,
        buttons: [Button]
    ) -> NSAlert {
        let alert = NSAlert()
        var safeCancelButton: NSButton?
        alert.messageText = message
        alert.informativeText = information ?? ""
        alert.alertStyle = style
        for spec in buttons.reversed() {
            let button = alert.addButton(withTitle: displayTitle(spec.title))
            // The visible title without the invisible U+2063:
            // both the title and the label name the button.
            button.setAccessibilityTitle(spec.title)
            button.setAccessibilityLabel(spec.title)
            switch spec.role {
            case .default:
                button.keyEquivalent = "\r"
                button.useAccentFill()   // one accent
            case .cancel:
                button.keyEquivalent = "\u{1b}"
            case .destructive:
                button.keyEquivalent = ""
                button.hasDestructiveAction = true
            case .normal:
                button.keyEquivalent = ""
            case .safeCancel:
                button.keyEquivalent = ""
                safeCancelButton = button
            }
        }
        if let safeCancelButton { installSafeCancel(on: alert, button: safeCancelButton) }
        return alert
    }

    /// Makes `button` the Cancel that Return AND Esc both fire. One button
    /// holds one key equivalent, so Return sits on the button (also the
    /// window's default cell) and Esc on an invisible 1 pt twin that clicks it.
    /// The caller clears the key equivalent of every other button.
    @MainActor
    public static func installSafeCancel(on alert: NSAlert, button: NSButton) {
        button.keyEquivalent = "\r"
        button.useAccentFill()
        guard let content = alert.window.contentView else { return }
        alert.window.defaultButtonCell = button.cell as? NSButtonCell
        // A plain view, not a button: VoiceOver met an unnamed empty button
        // here. A plain NSView is no accessibility element.
        let twin = SafeCancelEscTwin(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        twin.target = button
        twin.alphaValue = 0
        twin.identifier = NSUserInterfaceItemIdentifier("safeCancelEscTwin")
        content.addSubview(twin)
    }

    /// Maps a response from an alert built by `make` back to the index in
    /// the `buttons` array the caller passed.
    public static func index(of response: NSApplication.ModalResponse, buttonCount: Int) -> Int? {
        let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard offset >= 0, offset < buttonCount else { return nil }
        return buttonCount - 1 - offset
    }

    /// Presents the alert as a sheet on `window` (free-standing and
    /// non-blocking only when there is no window) and returns the index of the chosen button in
    /// `buttons`. Esc returns the cancel button's index.
    @MainActor
    public static func run(
        message: String,
        information: String? = nil,
        style: NSAlert.Style = .warning,
        buttons: [Button],
        on window: NSWindow?
    ) async -> Int? {
        await withCheckedContinuation { continuation in
            begin(message: message, information: information, style: style, buttons: buttons, on: window) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// As `run`, but `completion` is called synchronously inside the sheet's
    /// own completion (or the free-standing alert's button), before any task resumes: work
    /// the answer starts is visible to the next event at once (⌘Q right after
    /// `Change Originals`).
    @MainActor
    public static func begin(
        message: String,
        information: String? = nil,
        style: NSAlert.Style = .warning,
        buttons: [Button],
        on window: NSWindow?,
        completion: @escaping @MainActor (Int?) -> Void
    ) {
        let alert = make(message: message, information: information, style: style, buttons: buttons)
        let count = buttons.count
        present(alert, on: window) { completion(index(of: $0, buttonCount: count)) }
    }

    /// Shows `alert` without blocking the main actor: a sheet on `window`,
    /// or (no window) the alert's own panel, in front, with its buttons
    /// answering through `completion`. Never `runModal`: called from an
    /// async main-actor task, `runModal` stops every other main-actor job
    /// until the alert closes (the quit question froze
    /// the Batch). `completion` runs once, synchronously inside the sheet's
    /// (or the button's) handler. The returned presentation can end the
    /// alert itself with a code of the caller's choice.
    @MainActor
    @discardableResult
    public static func present(
        _ alert: NSAlert,
        on window: NSWindow?,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> AlertPresentation {
        let presentation = AlertPresentation(alert: alert, parent: window, completion: completion)
        guard let window else {
            presentation.showFreeStanding()
            return presentation
        }
        // An alert on the always-dark viewer is dark (nil on other windows: follows the app).
        alert.window.appearance = window.appearance
        alert.beginSheetModal(for: window) { [presentation] response in
            onMain { presentation.finish(response) }
        }
        return presentation
    }

    /// AppKit calls sheet handlers on the main thread; if one ever is not,
    /// the work hops there instead of trapping (Swift 6 isolation traps).
    nonisolated static func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            Task { @MainActor in work() }
        }
    }
}

/// One alert on screen, shown by `ShrikeAlert.present`.
@MainActor
public final class AlertPresentation {
    public let alert: NSAlert
    /// The window the alert is a sheet on; nil for a free-standing alert.
    public private(set) weak var parent: NSWindow?
    private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?
    private var buttonTarget: AlertButtonTarget?
    private let isSheet: Bool

    init(alert: NSAlert, parent: NSWindow?, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.parent = parent
        self.isSheet = parent != nil
        self.completion = completion
    }

    /// True until the alert has answered (by a button or by `end`).
    public var isOpen: Bool { completion != nil }

    /// Closes the alert as if a button returned `code` (a sheet through
    /// `endSheet(_:returnCode:)`, whose handler then answers).
    public func end(_ code: NSApplication.ModalResponse) {
        guard isOpen else { return }
        if let parent, parent.attachedSheet === alert.window {
            parent.endSheet(alert.window, returnCode: code)
        } else {
            finish(code)
        }
    }

    /// No window to hold a sheet: the alert's own panel in front, not modal.
    /// Its buttons answer here (the first button added is
    /// `alertFirstButtonReturn`, as `runModal` would return).
    func showFreeStanding() {
        alert.layout()
        // Strong on purpose: callers may drop the presentation (`run`,
        // `begin`); the panel's buttons keep it alive until `finish` clears
        // `buttonTarget` (NSControl.target is weak).
        let target = AlertButtonTarget { [self] index in
            self.finish(NSApplication.ModalResponse(
                rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
        }
        buttonTarget = target
        for (index, button) in alert.buttons.enumerated() {
            button.tag = index
            button.target = target
            button.action = #selector(AlertButtonTarget.pressed(_:))
        }
        let panel = alert.window
        panel.level = .modalPanel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

    func finish(_ response: NSApplication.ModalResponse) {
        guard let completion else { return }
        self.completion = nil
        if !isSheet { alert.window.orderOut(nil) }
        buttonTarget = nil
        completion(response)
    }
}

/// The buttons of a free-standing alert (their target is otherwise the
/// alert, which would stop a modal loop that is not running).
@MainActor
final class AlertButtonTarget: NSObject {
    private let answer: (Int) -> Void
    init(_ answer: @escaping (Int) -> Void) { self.answer = answer }
    @objc func pressed(_ sender: NSButton) { answer(sender.tag) }
}

/// Esc (no modifiers) clicks `target`, the safe Cancel of an alert. Not an
/// accessibility element and never drawn.
@MainActor
final class SafeCancelEscTwin: NSView {
    weak var target: NSButton?
    let keyEquivalent = "\u{1b}"

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.charactersIgnoringModifiers == keyEquivalent,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),   // Caps Lock still answers
              let target, target.isEnabled else { return super.performKeyEquivalent(with: event) }
        target.performClick(nil)
        return true
    }

    override func isAccessibilityElement() -> Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

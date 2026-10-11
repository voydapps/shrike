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
        }
        public let title: String
        public let role: Role

        public init(_ title: String, role: Role = .normal) {
            self.title = title
            self.role = role
        }

        public static func cancel(_ title: String = "Cancel") -> Button { Button(title, role: .cancel) }
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
        alert.messageText = message
        alert.informativeText = information ?? ""
        alert.alertStyle = style
        for spec in buttons.reversed() {
            let button = alert.addButton(withTitle: spec.title)
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
            }
        }
        return alert
    }

    /// Maps a response from an alert built by `make` back to the index in
    /// the `buttons` array the caller passed.
    public static func index(of response: NSApplication.ModalResponse, buttonCount: Int) -> Int? {
        let offset = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard offset >= 0, offset < buttonCount else { return nil }
        return buttonCount - 1 - offset
    }

    /// Presents the alert as a sheet on `window` (free-standing only when
    /// there is no window) and returns the index of the chosen button in
    /// `buttons`. Esc returns the cancel button's index.
    @MainActor
    public static func run(
        message: String,
        information: String? = nil,
        style: NSAlert.Style = .warning,
        buttons: [Button],
        on window: NSWindow?
    ) async -> Int? {
        let alert = make(message: message, information: information, style: style, buttons: buttons)
        let count = buttons.count
        guard let window else {
            return index(of: alert.runModal(), buttonCount: count)
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: index(of: response, buttonCount: count))
            }
        }
    }
}

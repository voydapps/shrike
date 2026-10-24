//
//  EditExitModal.swift
//  ShrikeUI
//
//  Exit alert for edit mode. Shown when the user leaves edit mode with unsaved
//  changes. One sheet on the viewer window.
//
//  | File                     | Message                                   | Buttons (addButton order)             |
//  |--------------------------|-------------------------------------------|---------------------------------------|
//  | Writable in place        | Save changes to “x.jpg”?                  | Save · Cancel (default) · Don't Save  |
//  | RAW / not writable       | Save changes to “x.ORF” as a new file?    | Save Copy… · Cancel (default) · Don't Save |
//
//  Exactly one Save / Save Copy… button. Cancel is the safe default: Return
//  AND Esc both keep editing (ShrikeAlert.installSafeCancel); Save is never the
//  default. ⌘S = Save (in place only), ⇧⌘S = Save Copy…, ⌘D = Don't Save.
//

import AppKit

@MainActor
enum EditExitModal {

    enum Choice: Sendable, Equatable {
        case save
        case saveAs
        case discard
        case cancel
    }

    /// The alert's copy and buttons for one file.
    struct Content: Equatable {
        let message: String
        let information: String
        /// In `addButton` order: the default first.
        let buttons: [String]
        /// What the first (default) button does.
        let primary: Choice
    }

    static func content(fileName: String, writable: Bool, reason: EditExitReason = .userToggled,
                        savePolicy: String = "") -> Content {
        if reason == .navigation {
            return Content(
                message: writable ? "Save changes to “\(fileName)” before leaving this photo?"
                    : "Save “\(fileName)” as a new file before leaving this photo?",
                information: (writable
                    ? "Save your edits before opening the other photo. Don't Save removes all unsaved edits to this photo."
                    : "Save your edits as a separate file. The original will stay unchanged. Don't Save removes all unsaved edits to this photo.")
                    + (savePolicy.isEmpty ? "" : "\n\n" + savePolicy),
                buttons: [writable ? "Save" : "Save Copy…", "Cancel", "Don't Save"],
                primary: writable ? .save : .saveAs)
        }
        if writable {
            return Content(
                message: "Save changes to “\(fileName)”?",
                information: "Shrike keeps a copy of the original. You can go back with File › Revert to Original.",
                buttons: ["Save", "Cancel", "Don't Save"],
                primary: .save
            )
        }
        return Content(
            message: "Save changes to “\(fileName)” as a new file?",
            information: "Shrike can't change this file. It saves a copy next to it.",
            buttons: ["Save Copy…", "Cancel", "Don't Save"],
            primary: .saveAs
        )
    }

    /// Maps a response (first / second / third button) to a choice.
    static func choice(for response: NSApplication.ModalResponse, content: Content) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return content.primary
        case .alertThirdButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// The alert, not shown. Buttons in `addButton` order:
    /// Save / Save Copy… (⌘S / ⇧⌘S) · Cancel (Return and Esc) · Don't Save
    /// (⌘D). On macOS 26 NSAlert stacks three buttons: the first on top,
    /// then Don't Save, with Cancel at the bottom (checked offscreen).
    /// That is the system's own save-alert layout.
    static func makeAlert(_ content: Content) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = content.message
        alert.informativeText = content.information
        alert.alertStyle = .warning
        for title in content.buttons { alert.addButton(withTitle: title) }
        let save = alert.buttons[0]
        if content.primary == .save {
            save.keyEquivalent = "s"
            save.keyEquivalentModifierMask = [.command]
        } else {
            save.keyEquivalent = "S"
            save.keyEquivalentModifierMask = [.command, .shift]
        }
        ShrikeAlert.installSafeCancel(on: alert, button: alert.buttons[1])
        let dontSave = alert.buttons[2]
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = [.command]
        return alert
    }

    /// Tests answer here instead of a sheet.
    static var responderForTesting: ((Content) -> Choice)?

    /// Show the exit alert attached to `window`. Completion receives the
    /// user's choice on the main actor.
    static var presenterForTesting: ((Content, @escaping @MainActor (Choice) -> Void) -> Void)?

    static func show(on window: NSWindow, fileName: String, writable: Bool,
                     completion: @escaping @MainActor (Choice) -> Void) {
        _ = show(on: window, content: content(fileName: fileName, writable: writable), completion: completion)
    }

    @discardableResult
    static func show(on window: NSWindow, content: Content,
                     completion: @escaping @MainActor (Choice) -> Void) -> NSAlert? {
        if let presenterForTesting { presenterForTesting(content, completion); return nil }
        if let responder = responderForTesting { completion(responder(content)); return nil }
        let alert = makeAlert(content)
        alert.beginSheetModal(for: window) { response in
            let choice = Self.choice(for: response, content: content)
            Task { @MainActor in completion(choice) }
        }
        return alert
    }
}

//
//  TrashKeyHint.swift
//  ShrikeUI
//
//  Mac preset: only ⌘⌫ trashes (spec 25 §5.2). A plain ⌫ or ⌦ trashes
//  nothing and shows one hint per app run, so a learned habit does not
//  break silently and a held key does not nag.
//

import AppKit
import ShrikeCore

@MainActor
public enum TrashKeyHint {

    public static let message = "Press ⌘⌫ to move to the Trash."

    /// Shown at most once per app run.
    public private(set) static var wasShown = false

    /// Test seam: forget that the hint was shown.
    static func resetForTesting() { wasShown = false }

    /// True for a plain ⌫ / ⌦ in the Mac preset (no ⌘ ⌥ ⌃; ⇧ and fn do not count).
    public static func isPlainDelete(_ snapshot: KeyEventSnapshot, preset: ShortcutPreset) -> Bool {
        guard preset == .macNative, !snapshot.isKeyUp else { return false }
        guard snapshot.flags.intersection([.command, .option, .control]).isEmpty else { return false }
        return snapshot.key == SpecialKey.backspace || snapshot.key == SpecialKey.forwardDelete
    }

    /// The toast for a plain delete key: the first call returns it, later
    /// calls return nil (the key is swallowed silently).
    public static func claimToast() -> ToastContent? {
        guard !wasShown else { return nil }
        wasShown = true
        return ToastContent(message, kind: .text)
    }

    /// Decides a key for a window keymap that found no command for it.
    /// Returns true when the key is a plain delete in the Mac preset (the
    /// caller swallows it), and shows the hint through `toast` the first time.
    /// A text field in `responder` keeps its ⌫.
    @discardableResult
    public static func handle(
        _ snapshot: KeyEventSnapshot, preset: ShortcutPreset, responder: NSResponder?,
        toast: (ToastContent) -> Void
    ) -> Bool {
        guard isPlainDelete(snapshot, preset: preset), !(responder is NSText) else { return false }
        if let content = claimToast() { toast(content) }
        return true
    }
}

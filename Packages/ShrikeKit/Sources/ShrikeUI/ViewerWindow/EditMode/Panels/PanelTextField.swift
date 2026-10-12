//
//  PanelTextField.swift
//  ShrikeUI
//
//  The number fields of the edit tool panels (spec 25 §3.1). Return commits
//  the field (its action runs), then the field gives up focus, so the NEXT
//  Return is the window's default button: Done. Without this the field kept
//  focus and every Return only committed it again.
//

import AppKit

@MainActor
final class PanelTextField: NSTextField {

    /// AppKit exposes a text field to VoiceOver through its CELL; a label set only on the
    /// view never reached it (the cell's own label was empty). Set both.
    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        guard notification.userInfo?["NSTextMovement"] as? Int == NSTextMovement.return.rawValue else { return }
        // AppKit selects the text again right after a Return (the field keeps
        // the focus), so let go one turn later. Tab and click-away move focus themselves.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentEditor() != nil else { return }
            self.window?.makeFirstResponder(nil)
        }
    }
}

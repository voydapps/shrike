//
//  PanelTextField.swift
//  ShrikeUI
//
//  The number fields of the edit tool panels. Return commits
//  the field (its action runs), then the field gives up focus, so the NEXT
//  Return is the window's default button: Done. Without this the field kept
//  focus and every Return only committed it again.
//

import AppKit

@MainActor
final class PanelTextField: NSTextField {

    /// Return uses AppKit's normal action route. Crop/Resize opt into one
    /// separate commit when ordinary focus movement ends editing.
    var commitsOnFocusLoss = false {
        didSet { cell?.sendsActionOnEndEditing = false }
    }
    private var resigningAfterReturn = false
    private var completingExplicitly = false
    private var processingReturn = false
    private var hasUncommittedChanges = false
    private var committedReturn = false
    private var editSessionRevision: UInt64 = 0
    /// What the field showed when typing began (after any rewrite by the panel); Esc puts it back.
    private var committedString = ""
    private var endEditingRevision: UInt64 = 0

    /// Typed text not committed yet, in the field editor now.
    var isTyping: Bool { hasUncommittedChanges && currentEditor() != nil }
    /// The number shown before the typing began (the shown number when not typing).
    var shownIntegerBeforeTyping: Int { isTyping ? Int(committedString) ?? 0 : integerValue }
    /// The panel shows a new value; while the user types, the typing stays and Esc returns to it.
    func showValue(_ string: String) {
        if isTyping { committedString = string } else { stringValue = string }
    }

    enum Completion: Equatable {
        case committed, alreadyCommitted, refused, staleOwnership
        var mayContinue: Bool { self == .committed || self == .alreadyCommitted }
    }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { committedString = stringValue }
        return took
    }

    /// Esc (the panel's `control(_:textView:doCommandBy:)` calls this): a
    /// typed value goes and the last committed one comes back; with nothing
    /// typed the field keeps what it shows (the panel may have changed it).
    /// Either way the keyboard goes to the photo, as Esc on the crop frame.
    /// Left alone, the field editor runs its completion list, which does nothing here.
    func cancelTyping(_ textView: NSTextView, _ command: Selector) -> Bool {
        guard command == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText(),
              currentEditor() === textView, window != nil else { return false }
        endTyping(textView, restore: hasUncommittedChanges)
        return true
    }

    /// Edit ▸ Undo / Redo of an edit while typing: the typed text goes, as with
    /// Esc, so the undo's new values land in a field that is not being edited.
    /// Nothing typed: the field keeps the keyboard and what it shows.
    /// Returns whether typing was discarded (the panel then refreshes Apply).
    @discardableResult
    func discardTyping() -> Bool {
        guard isTyping, let editor = currentEditor() as? NSTextView, window != nil else { return false }
        if editor.hasMarkedText() { editor.unmarkText() }
        endTyping(editor, restore: true)
        return true
    }

    private func endTyping(_ textView: NSTextView, restore: Bool) {
        guard let window else { return }
        if restore { textView.string = committedString }
        // Cleared before the focus moves, so ending the edit does not commit the typed value.
        hasUncommittedChanges = false
        if !window.makeFirstResponder((window as? ViewerWindow)?.contentRoot.imageView) { window.makeFirstResponder(nil) }
        if restore { stringValue = committedString }
    }

    override func textDidBeginEditing(_ notification: Notification) {
        editSessionRevision &+= 1
        hasUncommittedChanges = false
        // The cell still holds the shown value; the panel may have rewritten it since focus (Undo).
        committedString = cell?.stringValue ?? committedString
        if !processingReturn { committedReturn = false }
        super.textDidBeginEditing(notification)
    }

    override func textDidChange(_ notification: Notification) {
        editSessionRevision &+= 1
        hasUncommittedChanges = true
        committedReturn = false
        super.textDidChange(notification)
    }

    /// Own a controller-requested flush, including an untouched focused field.
    /// Ordinary resignation is suppressed while this explicit owner resolves it.
    func completeEditing(in owner: NSWindow) -> Completion {
        guard commitsOnFocusLoss, !completingExplicitly,
              window === owner, let editor = currentEditor() as? NSTextView,
              owner.firstResponder === editor, editor.delegate === self,
              let originalCell = cell else { return .staleOwnership }
        let originalDelegate = delegate, originalTarget = target, originalAction = action
        let revision = editSessionRevision
        let alreadyCommitted = committedReturn && !hasUncommittedChanges
        completingExplicitly = true
        defer { completingExplicitly = false }
        guard owner.makeFirstResponder(nil) else { return .refused }
        guard window === owner, cell === originalCell, delegate === originalDelegate,
              target === originalTarget, action == originalAction,
              editSessionRevision == revision, currentEditor() == nil else { return .staleOwnership }
        if alreadyCommitted { return .alreadyCommitted }
        _ = sendAction(originalAction, to: originalTarget)
        return .committed
    }

    /// AppKit exposes a text field to VoiceOver through its CELL; a label set only on the
    /// view never reached it (the cell's own label was empty). Set both.
    override func setAccessibilityLabel(_ label: String?) {
        super.setAccessibilityLabel(label)
        cell?.setAccessibilityLabel(label)
    }

    override func textDidEndEditing(_ notification: Notification) {
        let originalWindow = window
        let originalEditor = currentEditor() as? NSTextView
        let originalCell = cell
        let originalDelegate = delegate
        let originalTarget = target
        let originalAction = action
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        let isReturn = movement == NSTextMovement.return.rawValue
        let revision = editSessionRevision
        endEditingRevision &+= 1
        let commitsOrdinaryEnd = commitsOnFocusLoss && hasUncommittedChanges
            && !resigningAfterReturn && !completingExplicitly
            && !isReturn && movement != NSTextMovement.cancel.rawValue
        hasUncommittedChanges = false
        committedReturn = isReturn
        let wasProcessingReturn = processingReturn
        processingReturn = isReturn
        defer { processingReturn = wasProcessingReturn }
        super.textDidEndEditing(notification)
        if isReturn { committedString = stringValue }
        guard isReturn else {
            // This notification follows native validation. Refused edits never
            // reach it; cancellation and our own Return resignation do not commit.
            guard commitsOrdinaryEnd, let originalWindow, let originalCell,
                  window === originalWindow, cell === originalCell,
                  delegate === originalDelegate, target === originalTarget,
                  action == originalAction, editSessionRevision == revision else { return }
            _ = sendAction(originalAction, to: originalTarget)
            return
        }
        // AppKit selects the text again right after a Return (the field keeps
        // the focus), so let go one turn later. Tab and click-away move focus themselves.
        let returnRevision = editSessionRevision, returnEndRevision = endEditingRevision
        DispatchQueue.main.async { [weak self, weak originalWindow, weak originalEditor, weak originalCell] in
            guard let self, let originalWindow, let originalEditor, let originalCell,
                  self.window === originalWindow, self.cell === originalCell,
                  self.currentEditor() === originalEditor, originalWindow.firstResponder === originalEditor,
                  originalEditor.delegate === self,
                  self.editSessionRevision == returnRevision,
                  self.endEditingRevision == returnEndRevision,
                  !self.hasUncommittedChanges, self.committedReturn else { return }
            // The Return action already ran through super. Its owned deferred
            // resignation must not take the separate ordinary-focus commit route.
            self.resigningAfterReturn = true
            defer { self.resigningAfterReturn = false }
            originalWindow.makeFirstResponder(nil)
        }
    }
}

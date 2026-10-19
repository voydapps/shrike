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
    private var endEditingRevision: UInt64 = 0

    enum Completion: Equatable {
        case committed, alreadyCommitted, refused, staleOwnership
        var mayContinue: Bool { self == .committed || self == .alreadyCommitted }
    }

    override func textDidBeginEditing(_ notification: Notification) {
        editSessionRevision &+= 1
        hasUncommittedChanges = false
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

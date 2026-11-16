//
//  UndoTopMark.swift
//  ShrikeUI
//
//  The "Undo" button of a notice undoes ITS action, never whatever was
//  registered after it. `stamp` right after the notice's
//  `registerUndo`; any later change of the undo stack (a new undo group
//  opens, an undo, a redo) makes `isTop` false. Names are not compared: two
//  copies of 3 photos have the same action name.
//

import AppKit

@MainActor
final class UndoTopMark: NSObject {
    private weak var manager: UndoManager?
    private var generation = 0

    /// The mark of the action just registered on `manager`.
    func stamp(_ manager: UndoManager) -> Int {
        if manager !== self.manager {
            let center = NotificationCenter.default
            if let old = self.manager {
                center.removeObserver(self, name: nil, object: old)
            }
            self.manager = manager
            for name: Notification.Name in [.NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidUndoChange,
                         .NSUndoManagerDidRedoChange] {
                center.addObserver(self, selector: #selector(stackChanged(_:)), name: name, object: manager)
            }
            generation += 1
        }
        return generation
    }

    /// True while the stamped action is still the one Undo would undo.
    func isTop(_ stamp: Int, on manager: UndoManager?) -> Bool {
        manager != nil && manager === self.manager && generation == stamp && manager?.canUndo == true
    }

    /// Undoes the stamped action only if it is still on top. True: undone.
    @discardableResult
    func undo(_ stamp: Int, on manager: UndoManager?) -> Bool {
        guard isTop(stamp, on: manager) else { return false }
        manager?.undo()
        return true
    }

    /// Called after every change of the stack (the notice disables its button).
    var onChange: (() -> Void)?

    @objc private func stackChanged(_ note: Notification) { invalidate() }

    /// Ends every stamp taken so far (also when the viewer enters edit mode,
    /// where ⌘Z undoes edit steps, not file actions).
    func invalidate() {
        generation += 1
        onChange?()
    }
}

extension ToastHostView {
    /// An Undo toast for the action just registered on `manager`: its button
    /// undoes that action only, and the toast goes away as soon as anything
    /// else changes the undo stack (Edit ▸ Undo still names the action).
    /// Call it right after `registerUndo`.
    func showUndo(_ content: ToastContent, mark: UndoTopMark, manager: UndoManager?) {
        guard let manager else { return show(content) }
        let stamp = mark.stamp(manager)
        show(content) { [weak manager] in mark.undo(stamp, on: manager) }
        let shown = shownGeneration
        mark.onChange = { [weak self, weak mark] in
            self?.dismiss(ifShowing: shown)
            mark?.onChange = nil
        }
    }
}

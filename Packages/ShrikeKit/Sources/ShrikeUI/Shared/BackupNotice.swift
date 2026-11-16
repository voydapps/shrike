//
//  BackupNotice.swift
//  ShrikeUI
//
//  When Shrike moved or renamed
//  a photo fine but could not save where its backup now is, the window's
//  own result message gets one more sentence. Pure texts; the count is read
//  from exactly one place per action and never added to another.
//

import Foundation
import ShrikeCore
import ShrikeIO

public enum BackupNotice {

    /// "Renamed." — the only new success text (rename has no toast otherwise).
    public static let renamed = "Renamed."

    /// The lead of an Undo that has no message of its own.
    public static let undone = "Undone."
    /// Revert to Original is not possible (browser and viewer toasts).
    public static let revertNotPossible = "Couldn't revert. The file changed after Shrike saved it, or its backup can't be read."

    /// The sentence for `notSaved` (k) of `total` (N) photos; nil when 0.
    /// `leadNamesPhotos`: the message before it names the photos ("Renamed.",
    /// "Moved 8 items to “Trips”.") and so takes the "them" forms; a lead that
    /// names none (a failure text, "Batch undone.", "Undone.", or no lead) takes
    /// the forms with their own noun.
    public static func sentence(notSaved: Int, of total: Int, leadNamesPhotos: Bool = true) -> String? {
        guard notSaved > 0 else { return nil }
        let tail = ", so Revert to Original may be missing"
        guard leadNamesPhotos else {
            return notSaved == 1
                ? "Shrike lost track of the backup of 1 photo" + tail + " for it after you quit."
                : "Shrike lost track of the backups of \(notSaved) photos" + tail + " for them after you quit."
        }
        if total <= 1 {
            return "Shrike lost track of this photo's backup" + tail + " after you quit."
        }
        if notSaved >= total {
            return "Shrike lost track of their backups" + tail + " after you quit."
        }
        if notSaved == 1 {
            return "Shrike lost track of the backup of 1 of them" + tail + " for it after you quit."
        }
        return "Shrike lost track of the backups of \(notSaved) of them" + tail + " for those after you quit."
    }

    /// The short form, only for a toast over its budget.
    public static func shortSentence(notSaved: Int) -> String? {
        guard notSaved > 0 else { return nil }
        return notSaved == 1 ? "Revert to Original may be missing for 1 photo."
                             : "Revert to Original may be missing for \(notSaved) photos."
    }
    /// The shortest form.
    public static let shortestSentence = "Revert to Original may be missing."

    /// `message` with the sentence added (unchanged when the count is 0).
    public static func appending(to message: String, notSaved: Int, of total: Int, leadNamesPhotos: Bool = true) -> String {
        guard let extra = sentence(notSaved: notSaved, of: total, leadNamesPhotos: leadNamesPhotos) else { return message }
        return message + " " + extra
    }

    /// A toast for an action whose message (naming its photos) gets the sentence:
    /// `.error` with the warning icon and 6 s when the count is above 0, else `base` as is.
    public static func toast(_ base: ToastContent, notSaved: Int, of total: Int) -> ToastContent {
        guard notSaved > 0 else { return base }
        var content = base
        content.message = appending(to: base.message, notSaved: notSaved, of: total)
        content.kind = .error
        content.customDuration = 6.0
        return content
    }

    /// The own toast of a rename (lead `Renamed.`, it names the photo) or of an
    /// Undo that has no message (lead nil: `Undone.` and the own-noun forms).
    /// nil when the count is 0.
    public static func standaloneToast(lead: String?, notSaved: Int, of total: Int) -> ToastContent? {
        guard let extra = sentence(notSaved: notSaved, of: total, leadNamesPhotos: lead != nil) else { return nil }
        var content = ToastContent((lead ?? undone) + " " + extra, kind: .error)
        content.customDuration = 6.0
        return content
    }
}

/// Batch Undo's toasts. Pure: the fit checks are
/// injected (`ToastTextFit` measures them in the app).
public enum BatchUndoToast {
    public static let lead = "Batch undone."
    static func name(_ n: String) -> String { FileNameFit.short(n, limit: 20) }

    /// Undo did not throw. nil = nothing to say.
    /// `fitsTwoLines`: for the plain toast; `fitsFourLines`: for the error kind.
    public static func success(restoredAs: [(old: String, new: String)], notSaved: Int,
                               fitsTwoLines: (String) -> Bool, fitsFourLines: (String) -> Bool) -> ToastContent? {
        var back: (withReason: String, plain: String)?
        if let one = restoredAs.first {
            back = restoredAs.count == 1
                ? ("“\(name(one.old))” is back as “\(name(one.new))”, because its name was taken.",
                   "“\(name(one.old))” is back as “\(name(one.new))”.")
                : ("\(restoredAs.count) replaced photos are back under new names, because their names were taken.",
                   "\(restoredAs.count) replaced photos are back under new names.")
        }
        if notSaved == 0 {
            guard let back else { return nil }
            let full = lead + " " + back.withReason
            var content = ToastContent(fitsTwoLines(full) ? full : lead + " " + back.plain)
            content.customDuration = 6.0
            return content
        }
        // With a lost backup: the error kind; the parts join without the reason clause.
        let head = [lead, back?.plain].compactMap { $0 }.joined(separator: " ")
        let options = [BackupNotice.sentence(notSaved: notSaved, of: notSaved, leadNamesPhotos: false),
                       BackupNotice.shortSentence(notSaved: notSaved), BackupNotice.shortestSentence]
            .compactMap { $0 }.map { head + " " + $0 }
        var content = ToastContent(options.first(where: fitsFourLines) ?? options.last ?? head, kind: .error)
        content.customDuration = 6.0
        return content
    }

    /// Undo threw. `pieces` from `BatchVictimNotRestoredError.pieces`, `alsoFailed`
    /// its likely cause, `notSaved` the count when known (0 on the throw path).
    /// Parts are dropped in a fixed order until it fits in four lines; the main text never goes.
    public static func failure(main: String, restoredAs: String?, alsoFailed: String?, notSaved: Int,
                               fitsFourLines: (String) -> Bool) -> ToastContent {
        func join(_ parts: [String?]) -> String { parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ") }
        let full = BackupNotice.sentence(notSaved: notSaved, of: notSaved, leadNamesPhotos: false)
        let short = BackupNotice.shortSentence(notSaved: notSaved)
        let shortest = notSaved > 0 ? BackupNotice.shortestSentence : nil
        let steps = [join([main, restoredAs, alsoFailed, full]),
                     join([main, restoredAs, full]),              // 1. drop the likely cause
                     join([main, restoredAs, short]),             // 2. short backup sentence
                     join([main, short]),                         // 3. drop the new-name sentence
                     join([main, shortest])]                      // 4. shortest backup sentence
        var content = ToastContent(steps.first(where: fitsFourLines) ?? steps[steps.count - 1], kind: .error)
        content.customDuration = 6.0
        return content
    }
}

/// One rename step for Undo / Redo: filled when the queued rename finishes;
/// nil when it failed (the next step then does nothing).
@MainActor
final class RenameStep {
    var result: RenameResult?
    /// The step this one undoes: its name is the one on disk if this step failed.
    private let source: RenameStep?
    init(_ result: RenameResult?, source: RenameStep? = nil) { self.result = result; self.source = source }
    /// The photo as it is named now, for the list and the failure toast.
    var shownGroup: ImageGroup? { result?.group ?? source?.shownGroup }
}

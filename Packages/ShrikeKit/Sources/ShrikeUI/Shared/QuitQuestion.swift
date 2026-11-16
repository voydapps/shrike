//
//  QuitQuestion.swift
//  ShrikeUI
//
//  What ⌘Q asks
//  while a Batch or a copy / move runs, as pure values: the app delegate
//  only forwards, so the decision and every text are tested without a
//  window.
//

import Foundation
import ShrikeCore

/// What is running when the user quits (read from the Batch window, the
/// windows' transfers and `ActiveWork`).
public struct QuitWork: Equatable, Sendable {

    public struct Batch: Equatable, Sendable {
        public var completed: Int
        public var total: Int
        /// Hidden with "Keep Running".
        public var isHidden: Bool
        public init(completed: Int, total: Int, isHidden: Bool) {
            self.completed = completed
            self.total = total
            self.isHidden = isHidden
        }
    }

    public struct Transfer: Equatable, Sendable {
        public var verb: FileVerb
        public var completed: Int
        public var total: Int
        public init(verb: FileVerb, completed: Int, total: Int) {
            self.verb = verb
            self.completed = completed
            self.total = total
        }
    }

    public var batch: Batch?
    public var transfers: [Transfer]
    /// Photos being saved from edit mode (`ActiveWork` `.save`).
    public var savingPhotos: Int
    /// Short work nobody can stop (Undo Batch, an undo of a copy / move,
    /// Trash, Put Back, Rename, a restore): ⌘Q waits for it without a question.
    public var shortWork: Bool

    public init(batch: Batch? = nil, transfers: [Transfer] = [], savingPhotos: Int = 0, shortWork: Bool = false) {
        self.batch = batch
        self.transfers = transfers
        self.savingPhotos = savingPhotos
        self.shortWork = shortWork
    }

    /// Only a Batch or a copy / move makes ⌘Q ask; a save
    /// alone finishes before the app quits, as before.
    public var needsQuestion: Bool { batch != nil || !transfers.isEmpty }
}

/// The texts of the quit alert. Pure.
public enum QuitQuestion {

    public static let title = "Quit while work is running?"
    public static let quitAnyway = "Quit Anyway"
    public static let cancel = "Cancel"
    /// The quit alert: Quit Anyway left and destructive,
    /// Cancel right, default on Return and Esc. Answer 0 = Quit Anyway.
    public static let quitButtons: [ShrikeAlert.Button] = [
        ShrikeAlert.Button(quitAnyway, role: .destructive), .safeCancel(cancel)]

    /// What the open quit alert does on one refresh tick.
    public enum LiveStep: Equatable {
        /// The text is still right.
        case keep
        /// New numbers: show this text.
        case update(String)
        /// Everything it named has finished: close it and go on with the
        /// quit (⌘Q was the user's intent and nothing is at risk any more;
        /// pending writes are still flushed).
        case finished
    }

    /// Pure: the step for the alert showing `shown` while `work` runs.
    public static func liveStep(shown: String, work: QuitWork) -> LiveStep {
        guard let text = information(for: work) else { return .finished }
        return text == shown ? .keep : .update(text)
    }

    /// nil when nothing needs the question.
    public static func information(for work: QuitWork) -> String? {
        guard work.needsQuestion else { return nil }
        var lines: [String] = []
        if let batch = work.batch {
            var line = "A batch is running: \(batch.completed) of \(batch.total) photos done."
            if batch.isHidden { line += " Its window is hidden." }
            lines.append(line)
        }
        if let line = transferLine(work.transfers) { lines.append(line) }
        if work.savingPhotos > 0 {
            lines.append(work.savingPhotos == 1
                ? "Shrike is still saving 1 photo. It will finish it first."
                : "Shrike is still saving \(work.savingPhotos) photos. It will finish them first.")
        }
        lines.append(lastParagraph(work))
        return lines.joined(separator: "\n\n")
    }

    static func transferLine(_ transfers: [QuitWork.Transfer]) -> String? {
        guard let first = transfers.first else { return nil }
        if transfers.count == 1 {
            let noun = first.verb == .copy ? "copy" : "move"
            return "A \(noun) is running: \(first.completed) of \(first.total) photos done."
        }
        let done = transfers.reduce(0) { $0 + $1.completed }
        let total = transfers.reduce(0) { $0 + $1.total }
        return "\(transfers.count) copy or move jobs are running: \(done) of \(total) photos done."
    }

    static func lastParagraph(_ work: QuitWork) -> String {
        let lead = "Photos that are already done stay done."
        if work.batch != nil {
            // One text for every batch (`QuitWork.Batch` has no kind).
            return lead + " A rename may finish more photos first, so that none is left with a temporary name."
                + " The rest are not processed, and you won't be able to undo a stopped batch after you quit."
        }
        let verbs = Set(work.transfers.map(\.verb))
        if verbs == [.copy] { return lead + " The rest are not copied." }
        if verbs == [.move] { return lead + " The rest are not moved." }
        // Copy and move at once.
        return lead + " The rest are not copied or moved."
    }

    // MARK: A pending write that does not finish in time

    public static let writeTimeoutTitle = "Shrike is still saving a change"
    public static let writeTimeoutInformation =
        "A rotated or flipped photo is still being saved. The disk is slow to answer. If you quit now, that change may be lost."
    public static let keepWaiting = "Keep Waiting"

    /// Quit Anyway, then the photo being written is still not done after
    /// the wait (slow disk).
    public static let stopTimeoutTitle = "Shrike is still finishing a photo"
    public static let stopTimeoutInformation =
        "The photo being saved is not done yet. The disk is slow to answer. If you quit now, that photo may not be saved, copied or moved. A batch rename may also leave a photo under a temporary name. Shrike tries to put the name back the next time you open it."

    /// ⌘Q waits for an Undo Batch, a Trash, a Put Back or a rename (nothing
    /// was stopped, no photo is being saved) and it is not done in time.
    public static let shortWorkTimeoutTitle = "Shrike is still finishing an undo or a file move"
    public static let shortWorkTimeoutInformation =
        "An undo, a rename, a restore or a move to or from the Trash is not done yet. If you quit now, it may stop halfway: some photos may be done and others not. A photo left under a temporary name gets its name back the next time you open Shrike."

    /// The text of the wait alert: the photo text after Quit Anyway stopped a
    /// Batch or a copy / move, or while a photo is still being saved.
    public static func stopTimeoutText(stoppedWork: Bool, saving: Bool) -> (title: String, information: String) {
        stoppedWork || saving ? (stopTimeoutTitle, stopTimeoutInformation)
            : (shortWorkTimeoutTitle, shortWorkTimeoutInformation)
    }

    /// Both timeout alerts: Quit Anyway left and destructive,
    /// Keep Waiting right, default on Return and Esc. Answer 0 = Quit Anyway.
    public static let timeoutButtons: [ShrikeAlert.Button] = [
        ShrikeAlert.Button(quitAnyway, role: .destructive), .safeCancel(keepWaiting)]
    /// Keep waiting only on an explicit Keep Waiting (1); anything else quits, as before.
    public static func keepsWaiting(_ answer: Int?) -> Bool { answer == 1 }
}

/// The order of the ⌘Q steps. Pure: the coordinator runs it.
public enum QuitPlan: Equatable, Sendable {
    /// Nothing to ask and nothing to write: quit at once.
    case now
    /// Ask about unsaved edits / running work, write pending rotates, then quit.
    case later

    public static func decide(editing: Bool, pendingWrites: Bool, work: QuitWork) -> QuitPlan {
        editing || pendingWrites || workStep(work) != .none ? .later : .now
    }

    /// What the running work needs at ⌘Q. Stoppable work (a Batch, a
    /// copy / move) is asked about, then stopped and waited for; short work
    /// alone is waited for without a question.
    public enum WorkStep: Equatable, Sendable { case ask, wait, none }

    public static func workStep(_ work: QuitWork) -> WorkStep {
        work.needsQuestion ? .ask : (work.shortWork ? .wait : .none)
    }
}

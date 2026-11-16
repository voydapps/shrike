//
//  Section19TextTests.swift
//  ShrikeUITests
//
//  Spec 28 §19: the texts written while building, the backup-sentence matrix,
//  Batch Undo toasts with the §19.8 drop order, the measured toast budget,
//  the timeout alerts' buttons. Window-free (text measuring needs no window).
//

import XCTest
@testable import ShrikeEdit
@testable import ShrikeUI

@MainActor
final class Section19TextTests: XCTestCase {

    // 19.2 — Quit Anyway left and destructive, Keep Waiting the safe default; 0 = quit.
    func testTimeoutAlerts() {
        XCTAssertEqual(QuitQuestion.writeTimeoutTitle, "Shrike is still saving a change")
        XCTAssertEqual(QuitQuestion.writeTimeoutInformation, "A rotated or flipped photo is still being saved. The disk is slow to answer. If you quit now, that change may be lost.")
        XCTAssertEqual(QuitQuestion.stopTimeoutTitle, "Shrike is still finishing a photo")
        XCTAssertEqual(QuitQuestion.stopTimeoutInformation, "The photo being saved is not done yet. The disk is slow to answer. If you quit now, that photo may not be saved, copied or moved. A batch rename may also leave a photo under a temporary name. Shrike tries to put the name back the next time you open it.")
        XCTAssertEqual(QuitQuestion.shortWorkTimeoutTitle, "Shrike is still finishing an undo or a file move")
        XCTAssertEqual(QuitQuestion.shortWorkTimeoutInformation, "An undo, a rename, a restore or a move to or from the Trash is not done yet. If you quit now, it may stop halfway: some photos may be done and others not. A photo left under a temporary name gets its name back the next time you open Shrike.")
        // Which text: by the work waited for.
        XCTAssertEqual(QuitQuestion.stopTimeoutText(stoppedWork: true, saving: false).title, QuitQuestion.stopTimeoutTitle)
        XCTAssertEqual(QuitQuestion.stopTimeoutText(stoppedWork: false, saving: true).title, QuitQuestion.stopTimeoutTitle)
        XCTAssertEqual(QuitQuestion.stopTimeoutText(stoppedWork: true, saving: true).information, QuitQuestion.stopTimeoutInformation)
        XCTAssertEqual(QuitQuestion.stopTimeoutText(stoppedWork: false, saving: false).title, QuitQuestion.shortWorkTimeoutTitle)
        XCTAssertEqual(QuitQuestion.stopTimeoutText(stoppedWork: false, saving: false).information, QuitQuestion.shortWorkTimeoutInformation)
        XCTAssertEqual(QuitQuestion.timeoutButtons.map(\.title), ["Quit Anyway", "Keep Waiting"])
        XCTAssertEqual(QuitQuestion.timeoutButtons.map(\.role), [.destructive, .safeCancel])
        XCTAssertFalse(QuitQuestion.keepsWaiting(0), "Quit Anyway quits")
        XCTAssertTrue(QuitQuestion.keepsWaiting(1), "Keep Waiting waits")
        XCTAssertFalse(QuitQuestion.keepsWaiting(nil), "no answer quits, as before")
    }

    // 19.3 — every row.
    func testBackupSentenceMatrix() {
        let s = { (k: Int, n: Int, lead: Bool) in BackupNotice.sentence(notSaved: k, of: n, leadNamesPhotos: lead) }
        XCTAssertEqual(s(1, 1, true), "Shrike lost track of this photo's backup, so Revert to Original may be missing after you quit.")
        XCTAssertEqual(s(1, 8, true), "Shrike lost track of the backup of 1 of them, so Revert to Original may be missing for it after you quit.")
        XCTAssertEqual(s(3, 8, true), "Shrike lost track of the backups of 3 of them, so Revert to Original may be missing for those after you quit.")
        XCTAssertEqual(s(8, 8, true), "Shrike lost track of their backups, so Revert to Original may be missing after you quit.")
        XCTAssertEqual(s(1, 8, false), "Shrike lost track of the backup of 1 photo, so Revert to Original may be missing for it after you quit.")
        XCTAssertEqual(s(3, 3, false), "Shrike lost track of the backups of 3 photos, so Revert to Original may be missing for them after you quit.")
        XCTAssertNil(s(0, 3, false))
        XCTAssertEqual(BackupNotice.shortSentence(notSaved: 1), "Revert to Original may be missing for 1 photo.")
        XCTAssertEqual(BackupNotice.shortSentence(notSaved: 3), "Revert to Original may be missing for 3 photos.")
        // An Undo with no message of its own: "Undone." and the own-noun form.
        XCTAssertEqual(BackupNotice.standaloneToast(lead: nil, notSaved: 2, of: 5)?.message,
                       "Undone. Shrike lost track of the backups of 2 photos, so Revert to Original may be missing for them after you quit.")
        XCTAssertEqual(BackupNotice.standaloneToast(lead: BackupNotice.renamed, notSaved: 1, of: 1)?.message,
                       "Renamed. Shrike lost track of this photo's backup, so Revert to Original may be missing after you quit.")
        XCTAssertEqual(BackupNotice.appending(to: "Couldn't undo the move.", notSaved: 1, of: 4, leadNamesPhotos: false),
                       "Couldn't undo the move. Shrike lost track of the backup of 1 photo, so Revert to Original may be missing for it after you quit.")
    }

    // 19.4
    func testRevertText() {
        XCTAssertEqual(BackupNotice.revertNotPossible, "Couldn't revert. The file changed after Shrike saved it, or its backup can't be read.")
    }

    // 19.7 — item 12.
    func testBatchUndoneToasts() throws {
        let yes: (String) -> Bool = { _ in true }, no: (String) -> Bool = { _ in false }
        let one = try XCTUnwrap(BatchUndoToast.success(restoredAs: [("a.jpg", "a 2.jpg")], notSaved: 0, fitsTwoLines: yes, fitsFourLines: yes))
        XCTAssertEqual(one.message, "Batch undone. “a.jpg” is back as “a 2.jpg”, because its name was taken.")
        XCTAssertEqual(one.kind, .text, "not an error")
        XCTAssertEqual(one.duration, 6.0)
        XCTAssertNil(one.actionTitle)
        XCTAssertEqual(BatchUndoToast.success(restoredAs: [("a.jpg", "a 2.jpg")], notSaved: 0, fitsTwoLines: no, fitsFourLines: yes)?.message,
                       "Batch undone. “a.jpg” is back as “a 2.jpg”.", "the reason clause goes when it needs a third line")
        let several = [("a.jpg", "a 2.jpg"), ("b.jpg", "b 2.jpg"), ("c.jpg", "c 2.jpg")]
        XCTAssertEqual(BatchUndoToast.success(restoredAs: several, notSaved: 0, fitsTwoLines: yes, fitsFourLines: yes)?.message,
                       "Batch undone. 3 replaced photos are back under new names, because their names were taken.")
        let lost = try XCTUnwrap(BatchUndoToast.success(restoredAs: [("a.jpg", "a 2.jpg")], notSaved: 1, fitsTwoLines: yes, fitsFourLines: yes))
        XCTAssertEqual(lost.message, "Batch undone. “a.jpg” is back as “a 2.jpg”. Shrike lost track of the backup of 1 photo, so Revert to Original may be missing for it after you quit.")
        XCTAssertEqual(lost.kind, .error)
        XCTAssertEqual(BatchUndoToast.success(restoredAs: [], notSaved: 3, fitsTwoLines: yes, fitsFourLines: yes)?.message,
                       "Batch undone. Shrike lost track of the backups of 3 photos, so Revert to Original may be missing for them after you quit.")
        XCTAssertNil(BatchUndoToast.success(restoredAs: [], notSaved: 0, fitsTwoLines: yes, fitsFourLines: yes))
        XCTAssertEqual(BatchUndoToast.success(restoredAs: [("averyveryverylongcameraname.jpg", "averyveryverylongcameraname 2.jpg")],
                                              notSaved: 0, fitsTwoLines: yes, fitsFourLines: yes)?.message.contains("averyveryverylongcameraname.jpg"), false,
                       "names are fitted to 20 characters")
    }

    // 19.8 — the drop order, one step at a time; the main text never goes.
    func testFailureDropOrder() {
        let main = "“a.jpg” was not put back: another file has its name, and a new name could not be saved. A copy is kept in Shrike's backups for a while (Settings → Editing)."
        let back = "“b.jpg” is back as “b 2.jpg”."
        let cause = "The disk is full."
        var budget = Int.max
        let fits: (String) -> Bool = { $0.count <= budget }
        func text() -> String { BatchUndoToast.failure(main: main, restoredAs: back, alsoFailed: cause, notSaved: 3, fitsFourLines: fits).message }
        let full = text()
        XCTAssertTrue(full.contains(cause) && full.contains(back) && full.hasSuffix("for them after you quit."))
        budget = full.count - 1
        XCTAssertFalse(text().contains(cause), "1. the likely cause goes first"); XCTAssertTrue(text().contains(back))
        let short = "Revert to Original may be missing for 3 photos."
        budget = (main + " " + back + " " + short).count
        XCTAssertTrue(text().hasSuffix("Revert to Original may be missing for 3 photos."), "2. the short sentence")
        XCTAssertTrue(text().contains(back))
        budget = (main + " " + short).count
        XCTAssertEqual(text(), main + " Revert to Original may be missing for 3 photos.", "3. the new-name sentence goes")
        budget = (main + " Revert to Original may be missing.").count
        XCTAssertEqual(text(), main + " Revert to Original may be missing.", "4. the shortest form")
        budget = 10
        XCTAssertTrue(text().hasPrefix(main), "the main text never goes")
        let content = BatchUndoToast.failure(main: main, restoredAs: nil, alsoFailed: nil, notSaved: 0, fitsFourLines: { _ in true })
        XCTAssertEqual(content.message, main); XCTAssertEqual(content.kind, .error)
    }

    // 19.8 — measured, not estimated: report the real number, check the texts against it.
    func testMeasuredBudgetAndSpecTextsFit() {
        let four = ToastTextFit.characterBudget(lines: 4), two = ToastTextFit.characterBudget(lines: 2)
        print("Section19TextTests: measured error-toast budget = \(four) characters in 4 lines, \(two) in 2")
        XCTAssertGreaterThan(four, two)
        XCTAssertGreaterThan(four, 150)
        guard case .toast(let both)? = RenameRecoveryNotice.make(items: [], backupsNotSaved: 12, historyNotRestored: 12) else { return XCTFail() }
        XCTAssertTrue(ToastTextFit.fits(both, lines: 4, kind: .error), "8c fits in 4 lines")
        XCTAssertTrue(ToastTextFit.fits(BackupNotice.revertNotPossible, lines: 2, kind: .error))
        XCTAssertEqual(ToastTextFit.lineCount("Renamed.", width: ToastTextFit.wrapWidth(actionWidth: nil, showsIcon: false)), 1)
    }

    // Item 2 of the round: an error toast over two lines stays 6 s.
    func testLongErrorToastDuration() {
        let error = ToastContent("x", kind: .error)
        XCTAssertEqual(error.duration(measuredLines: 2), 2.5)
        XCTAssertEqual(error.duration(measuredLines: 3), 6.0)
        XCTAssertEqual(ToastContent("x").duration(measuredLines: 4), 2.5, "only errors")
        var custom = ToastContent("x", kind: .error); custom.customDuration = 8
        XCTAssertEqual(custom.duration(measuredLines: 4), 8, "customDuration wins")
        let threeSentences = "The photo on screen no longer matches this edit. Your edits are still open. No file was changed."
        let lines = ToastTextFit.lineCount(threeSentences, width: ToastTextFit.wrapWidth(actionWidth: nil, showsIcon: true))
        print("Section19TextTests: ViewerWindow+Save:240 toast = \(lines) lines")
    }

    // 19.6 — names fitted to 20 characters in the UI.
    func testVictimToastFitsNames() {
        let error = BatchVictimNotRestoredError(inTrash: [], inBackups: ["a-very-long-camera-file-name-0001.jpg"], restoredAs: [], alsoFailed: nil)
        let toast = BatchUndo.failureToast(error, fitsFourLines: { _ in true })
        XCTAssertFalse(toast.message.contains("a-very-long-camera-file-name-0001.jpg"))
        XCTAssertTrue(toast.message.contains("Shrike's backups for a while (Settings → Editing)."))
        XCTAssertEqual(toast.kind, .error)
    }
}

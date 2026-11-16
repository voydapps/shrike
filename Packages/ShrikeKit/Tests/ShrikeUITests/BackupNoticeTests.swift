//
//  BackupNoticeTests.swift
//  ShrikeUITests
//
//  B-8 (spec 28 §18.2), L-3 scope texts (spec 28 §3) and the Batch Undo
//  failure text. Window-free.
//

import XCTest
@testable import ShrikeEdit
@testable import ShrikeUI

final class BackupNoticeTests: XCTestCase {

    private let moved8 = "Moved 8 items to “Trips”."

    func testZeroAddsNothing() {
        XCTAssertNil(BackupNotice.sentence(notSaved: 0, of: 8))
        XCTAssertEqual(BackupNotice.appending(to: moved8, notSaved: 0, of: 8), moved8)
        XCTAssertNil(BackupNotice.standaloneToast(lead: BackupNotice.renamed, notSaved: 0, of: 1))
        let base = ToastContent.trashed("Moved 2 items to the Trash.")
        XCTAssertEqual(BackupNotice.toast(base, notSaved: 0, of: 2), base)
    }

    func testOnePhoto() {
        XCTAssertEqual(BackupNotice.appending(to: "Moved “DSC_0042.jpg” to “Trips”.", notSaved: 1, of: 1),
                       "Moved “DSC_0042.jpg” to “Trips”. Shrike lost track of this photo's backup, so Revert to Original may be missing after you quit.")
    }

    func testSomeOfSeveral() {
        XCTAssertEqual(BackupNotice.appending(to: moved8, notSaved: 3, of: 8),
                       moved8 + " Shrike lost track of the backups of 3 of them, so Revert to Original may be missing for those after you quit.")
    }

    func testAllOfSeveral() {
        XCTAssertEqual(BackupNotice.appending(to: moved8, notSaved: 8, of: 8),
                       moved8 + " Shrike lost track of their backups, so Revert to Original may be missing after you quit.")
    }

    func testRenameToast() throws {
        let toast = try XCTUnwrap(BackupNotice.standaloneToast(lead: BackupNotice.renamed, notSaved: 1, of: 1))
        XCTAssertEqual(toast.message,
                       "Renamed. Shrike lost track of this photo's backup, so Revert to Original may be missing after you quit.")
        XCTAssertEqual(toast.kind, .error)
        XCTAssertEqual(toast.customDuration, 6.0)
        XCTAssertNil(toast.actionTitle)
    }

    func testToastKeepsUndoAndBecomesError() {
        let base = ToastContent.trashed("Moved 2 items to the Trash.")
        let toast = BackupNotice.toast(base, notSaved: 1, of: 2)
        XCTAssertEqual(toast.kind, .error)
        XCTAssertEqual(toast.actionTitle, "Undo", "the Undo button stays")
        XCTAssertEqual(toast.customDuration, 6.0)
        XCTAssertTrue(toast.message.hasPrefix("Moved 2 items to the Trash. Shrike lost track of the backup of 1 of them, so Revert to Original may be missing for it after you quit."))
    }

    func testRecordAndRekeyNeverAppear() {
        for (n, total) in [(1, 1), (2, 5), (5, 5)] {
            let text = BackupNotice.sentence(notSaved: n, of: total)!
            XCTAssertFalse(text.contains("record"))
            XCTAssertFalse(text.contains("rekey"))
        }
    }
}

final class BatchScopeTests: XCTestCase {

    func testScopeTexts() {
        XCTAssertEqual(BatchScope.browser(selectedAny: true, folderName: "audit-photos"), "Selected in “audit-photos”")
        XCTAssertEqual(BatchScope.browser(selectedAny: false, folderName: "audit-photos"), "All shown in “audit-photos”")
        XCTAssertEqual(BatchScope.viewer(folderName: "audit-photos"), "Shown in “audit-photos”")
        XCTAssertEqual(BatchScope.viewer(folderName: nil), "Shown in this folder")
        XCTAssertEqual(BatchScope.browser(selectedAny: true, folderName: ""), "Selected in this folder")
        XCTAssertEqual(BatchScope.pickedByHand, "Picked by hand")
    }
}

final class BatchUndoTextTests: XCTestCase {

    private struct Other: Error {}

    func testVictimErrorShowsItsOwnText() {
        let error = BatchVictimNotRestoredError(inTrash: ["IMG_1.jpg"], inBackups: [], restoredAs: [], alsoFailed: nil)
        let text = BatchUndo.failureText(error)
        XCTAssertEqual(text, error.localizedDescription)
        XCTAssertNotEqual(text, BatchWindowController.Copy.undoFailed)
        XCTAssertTrue(text.contains("IMG_1.jpg"))
    }

    func testOtherErrorsKeepTheGenericLine() {
        XCTAssertEqual(BatchUndo.failureText(Other()), BatchWindowController.Copy.undoFailed)
    }
}

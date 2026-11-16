//
//  ReplaceForAllNoteTests.swift
//  ShrikeUITests
//
//  B-5, spec 28 §17.2: the note about other same-name files in the
//  conflict alert, and the sentence after the run. Window-free.
//

import XCTest
@testable import ShrikeUI

final class ReplaceForAllNoteTests: XCTestCase {

    // Spec 28 §20.7 (replaces §17.2): the four forms of the note above the checkbox.
    func testAlertNoteForms() {
        XCTAssertNil(FileTransferCopy.remainingExtraFilesNote(0, of: 8))
        XCTAssertEqual(FileTransferCopy.remainingExtraFilesNote(1, of: 1),
                       "The remaining conflict also has another file with the same name. Replace removes that file too. Undo brings it back.")
        XCTAssertEqual(FileTransferCopy.remainingExtraFilesNote(1, of: 8),
                       "Of the remaining 8 conflicts, 1 also has another file with the same name. Replace removes that file too. Undo brings it back.")
        XCTAssertEqual(FileTransferCopy.remainingExtraFilesNote(3, of: 8),
                       "Of the remaining 8 conflicts, 3 also have other files with the same name. Replace removes those files too. Undo brings them back.")
        XCTAssertEqual(FileTransferCopy.remainingExtraFilesNote(8, of: 8),
                       "All 8 remaining conflicts also have other files with the same name. Replace removes those files too. Undo brings them back.")
        XCTAssertFalse(FileTransferCopy.remainingExtraFilesNote(3, of: 8)!.contains("Trash"))
    }

    func testResultSentenceSingularPluralAndNone() {
        XCTAssertNil(FileTransferCopy.extraFilesTrashed(0))
        XCTAssertEqual(FileTransferCopy.extraFilesTrashed(1), "1 other file with the same name was removed. Undo brings it back.")
        XCTAssertEqual(FileTransferCopy.extraFilesTrashed(5), "5 other files with the same name were removed. Undo brings them back.")
    }

    func testResultLineWithoutExtrasIsUnchanged() {
        XCTAssertEqual(FileTransferCopy.resultLine("Moved 8 items to “Trips”.", backupsNotSaved: 0, of: 8, extraFilesTrashed: 0),
                       "Moved 8 items to “Trips”.")
    }

    func testResultLineAddsTheExtrasSentenceLast() {
        XCTAssertEqual(FileTransferCopy.resultLine("Moved 8 items to “Trips”.", backupsNotSaved: 0, of: 8, extraFilesTrashed: 5),
                       "Moved 8 items to “Trips”. 5 other files with the same name were removed. Undo brings them back.")
    }

    /// The backup sentence says "of them" about the moved photos, so it comes
    /// right after the done text; the extras sentence follows it.
    func testResultLineWithBothSentencesKeepsTheBackupSentenceNextToItsPhotos() {
        let line = FileTransferCopy.resultLine("Moved 8 items to “Trips”.", backupsNotSaved: 3, of: 8, extraFilesTrashed: 1)
        XCTAssertTrue(line.hasPrefix("Moved 8 items to “Trips”. Shrike lost track of the backups of 3 of them"), line)
        XCTAssertTrue(line.hasSuffix(" 1 other file with the same name was removed. Undo brings it back."), line)
    }

    /// §20.7: the toast opens with `Replaced N photos.` when Replace also removed other files.
    func testOpeningSaysReplacedPhotosOnlyWhenOtherFilesWereRemoved() {
        let done = "Copied 5 items to “dest”."
        let opening = FileTransferCopy.opening(done, cancelled: false, replacedPhotos: 8, extraFilesTrashed: 5)
        XCTAssertEqual(opening, "Replaced 8 photos.")
        XCTAssertEqual(FileTransferCopy.resultLine(opening, backupsNotSaved: 0, of: 8, extraFilesTrashed: 5),
                       "Replaced 8 photos. 5 other files with the same name were removed. Undo brings them back.")
        XCTAssertEqual(FileTransferCopy.opening(done, cancelled: false, replacedPhotos: 1, extraFilesTrashed: 1), "Replaced 1 photo.")
        XCTAssertEqual(FileTransferCopy.opening(done, cancelled: false, replacedPhotos: 3, extraFilesTrashed: 0), done,
                       "no other file removed: the done text stays")
        XCTAssertEqual(FileTransferCopy.opening(done, cancelled: true, replacedPhotos: 3, extraFilesTrashed: 2), done,
                       "a cancelled run keeps its own text")
    }

    func testCancelledTextAlsoGetsTheSentence() {
        let text = FileTransferCopy.cancelled(.move, done: 2, total: 8)
        XCTAssertEqual(FileTransferCopy.resultLine(text, backupsNotSaved: 0, of: 2, extraFilesTrashed: 2),
                       text + " 2 other files with the same name were removed. Undo brings them back.")
    }
}

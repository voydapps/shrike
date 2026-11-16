//
//  OnScreenFindingsTests.swift
//  ShrikeUITests
//
//  Problems seen on screen on 2026-11-13 (frontend pass 1 check). Window-free.
//

import XCTest
import ShrikeEdit
@testable import ShrikeUI

final class OnScreenFindingsTests: XCTestCase {

    // 2a / 2b: "What Will Happen" with every photo skipped, and the skip lines in that block.

    func testEveryPhotoSkippedDropsTheSummaryAndKeepsTheSkipLines() {
        let lines = BatchModel.whatWillHappen(summary: "Create 0 new photos in /x. Original stays unchanged.",
                                              queued: 1, processable: 0, reviewing: false,
                                              skipLines: ["1 photo can't be read and will be skipped."])
        XCTAssertEqual(lines, ["1 photo can't be read and will be skipped."])
    }

    func testInPlaceWithEveryPhotoSkippedSaysNoZeroEither() {
        let lines = BatchModel.whatWillHappen(summary: "Rename 0 original files. …", queued: 3, processable: 0,
                                              reviewing: false,
                                              skipLines: ["3 photos would get a name Shrike can't use and will be skipped."])
        XCTAssertFalse(lines.contains { $0.contains(" 0 ") })
    }

    func testSomeSkippedKeepsSummaryFirstThenUnreadableThenName() {
        let lines = BatchModel.whatWillHappen(summary: "S", queued: 4, processable: 2, reviewing: false,
                                              skipLines: ["unreadable", "name"])
        XCTAssertEqual(lines, ["S", "unreadable", "name"])
    }

    func testHeadingIsHiddenWhenNothingIsUnderIt() {
        XCTAssertFalse(BatchModel.showsWhatWillHappenHeading(lines: [], disclosures: []))
        XCTAssertTrue(BatchModel.showsWhatWillHappenHeading(lines: ["S"], disclosures: []))
        XCTAssertTrue(BatchModel.showsWhatWillHappenHeading(lines: [], disclosures: ["Converted to JPEG."]))
        // Every photo skipped and a validation line up: the skip lines are
        // dropped by the model, so the block is empty and so is the heading.
        let lines = BatchModel.whatWillHappen(summary: "Create 0 new photos.", queued: 2, processable: 0,
                                              reviewing: false, skipLines: [])
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(BatchModel.showsWhatWillHappenHeading(lines: lines, disclosures: []))
    }

    func testEmptyQueueAndReviewKeepTheSummary() {
        XCTAssertEqual(BatchModel.whatWillHappen(summary: "S", queued: 0, processable: 0, reviewing: false, skipLines: []), ["S"])
        XCTAssertEqual(BatchModel.whatWillHappen(summary: "S", queued: 2, processable: 0, reviewing: true, skipLines: []), ["S"])
    }

    // 2c: the quit alert's "still saving" line during a Batch.

    func testBatchWritesAreNotCountedAsSaving() {
        XCTAssertEqual(WindowCoordinator.savingLineCount(viewerSaves: 0, allSaves: 6, batchRunning: true), 0)
        let info = QuitQuestion.information(for: QuitWork(batch: QuitWork.Batch(completed: 46, total: 400, isHidden: false),
                                                          savingPhotos: WindowCoordinator.savingLineCount(viewerSaves: 0, allSaves: 6, batchRunning: true)))
        XCTAssertNotNil(info)
        XCTAssertFalse(info?.contains("still saving") ?? true, info ?? "")
    }

    func testAViewerSaveDuringABatchIsStillTold() {
        XCTAssertEqual(WindowCoordinator.savingLineCount(viewerSaves: 1, allSaves: 7, batchRunning: true), 1)
    }

    func testWithoutABatchEverySaveIsTold() {
        XCTAssertEqual(WindowCoordinator.savingLineCount(viewerSaves: 0, allSaves: 2, batchRunning: false), 2)
    }

    // 2d: "precision could not be verified … keep the original unchanged" only where originals change.

    func testUnverifiedPrecisionNoticeOnlyForInPlaceJobs() {
        let text = EditSaveCapability.unverifiedPrecision
        XCTAssertTrue(BatchModel.includesDisclosure(text, output: .inPlace))
        XCTAssertFalse(BatchModel.includesDisclosure(text, output: .folder(URL(fileURLWithPath: "/tmp/out"))))
        XCTAssertTrue(BatchModel.includesDisclosure("An HDR photo becomes SDR.", output: .folder(URL(fileURLWithPath: "/tmp/out"))),
                      "other notices stay true for an export")
    }
}

// Task 8: three sentences or more stay 6 s.
final class ToastSentenceDurationTests: XCTestCase {
    func testSentenceCount() {
        XCTAssertEqual(ToastContent.sentenceCount("Moved “a.jpg” to “Trips”."), 1)
        XCTAssertEqual(ToastContent.sentenceCount("Use Save Copy… to keep it. Then go."), 2)
        XCTAssertEqual(ToastContent.sentenceCount("The photo on screen no longer matches this edit. Your edits are still open. No file was changed."), 3)
    }

    func testThreeSentencesGetSixSeconds() {
        let saveError = ToastContent("The photo on screen no longer matches this edit. Your edits are still open. No file was changed.", kind: .error)
        XCTAssertEqual(saveError.duration(measuredLines: 2), 6.0)
        XCTAssertEqual(ToastContent("One. Two. Three.").duration(measuredLines: 1), 6.0)
    }

    func testShorterAndCustomUnchanged() {
        XCTAssertEqual(ToastContent("Copied.").duration(measuredLines: 1), 2.5)
        XCTAssertEqual(ToastContent("One. Two.", actionTitle: "Undo").duration(measuredLines: 1), 4.0)
        var custom = ToastContent("One. Two. Three.")
        custom.customDuration = 8
        XCTAssertEqual(custom.duration(measuredLines: 1), 8)
    }
}

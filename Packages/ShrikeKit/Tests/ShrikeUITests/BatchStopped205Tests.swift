//
//  BatchStopped205Tests.swift
//  ShrikeUITests
//
//  Spec 28 §20.5: a stopped rename-only Batch says which names the photos have now.
//  Window-free text functions.
//

import XCTest
@testable import ShrikeEdit
@testable import ShrikeUI

final class BatchStopped205Tests: XCTestCase {

    private func lines(_ t: Int, _ d: Int, _ k: Int, w: [(String, String)] = [], issues: String? = nil,
                       after: Bool = false) -> [String] {
        BatchModel.stoppedRenameLines(total: t, newNames: d, oldNames: k, putBack: w.map { (old: $0.0, now: $0.1) },
                                      issuesLine: issues, finishedAfterStop: after)
    }

    func testTheSpecExample() {
        XCTAssertEqual(lines(60, 38, 22), ["38 of 60 photos have their new names. The other 22 kept their old names."])
    }

    func testOneLeftOverAndNoneLeftOver() {
        XCTAssertEqual(lines(60, 59, 1), ["59 of 60 photos have their new names. The other photo kept its old name."])
        XCTAssertEqual(lines(60, 60, 0), ["60 of 60 photos have their new names."])
    }

    func testOneDone() {
        XCTAssertEqual(lines(60, 1, 59), ["1 of 60 photos has its new name. The other 59 kept their old names."])
    }

    func testNoneDone() {
        XCTAssertEqual(lines(60, 0, 60), ["No photo was renamed. All 60 kept their old names."])
        // Not every photo at its old name: no false "All 60".
        XCTAssertEqual(lines(60, 0, 58, w: [("IMG_12.jpg", "IMG_12 2.jpg")]).first,
                       "No photo was renamed. 58 kept their old names.")
    }

    func testIssuesLineComesSecond() {
        XCTAssertEqual(lines(60, 38, 22, issues: "2 failed"),
                       ["38 of 60 photos have their new names. The other 22 kept their old names.", "2 failed"])
    }

    func testExplainingLineOnlyWhenMoreFinishedAndNothingLeftTemporary() {
        let explain = "Shrike finished the photos whose names it was swapping, so none is left under a temporary name."
        XCTAssertEqual(lines(60, 40, 20, after: true).last, explain)
        XCTAssertFalse(lines(60, 40, 20, after: false).contains(explain))
        // A row in none of the three counts (still temporary): no promise.
        XCTAssertFalse(lines(60, 40, 19, after: true).contains(explain))
    }

    func testPutBackOneAndSeveral() {
        XCTAssertEqual(BatchModel.putBackLine([(old: "IMG_12.jpg", now: "IMG_12 2.jpg")]),
                       "“IMG_12.jpg” could not get its old name back, because another photo has it now. It is called “IMG_12 2.jpg”.")
        XCTAssertEqual(BatchModel.putBackLine([(old: "IMG_12.jpg", now: "IMG_12 2.jpg"), (old: "a.jpg", now: "a 2.jpg"),
                                               (old: "b.jpg", now: "b 2.jpg")]),
                       "3 photos could not get their old names back, because other photos have those names now. For example, “IMG_12.jpg” is called “IMG_12 2.jpg”.")
        XCTAssertNil(BatchModel.putBackLine([]))
        XCTAssertEqual(lines(60, 38, 21, w: [("IMG_12.jpg", "IMG_12 2.jpg")], after: true).count, 3, "summary, explaining, put-back")
    }

    func testLongNamesAreShortened() {
        let line = BatchModel.putBackLine([(old: "A very long holiday photo name 2026.jpg", now: "A very long holiday photo name 2026 2.jpg")]) ?? ""
        XCTAssertFalse(line.contains("A very long holiday photo name 2026.jpg"), line)
    }

    func testIssuesLineDropsDoneAndNotProcessedParts() {
        // Built from `summary`'s parts; with no failures there is no line.
        XCTAssertNil(BatchModel.issuesLine(BatchResult()))
    }
}


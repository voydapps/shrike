//
//  QuitEditsDuringWorkQuestionTests.swift
//  ShrikeUITests
//
//  Review R1 (pass 2p): edits started while the work question is up are
//  asked about again before the work stops, and once more after the
//  pending writes; Cancel there cancels the quit with the work still going.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class QuitEditsDuringWorkQuestionTests: XCTestCase {

    @MainActor private final class Log { var events: [String] = []; var replies: [Bool] = [] }

    private func quit(_ c: WindowCoordinator, _ log: Log) async {
        _ = c.terminateRequest(endSheets: {}) { log.replies.append($0) }
        for _ in 0..<200 where log.replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testEditsStartedWhileTheWorkQuestionIsUpAreAskedBeforeTheWorkStops() async {
        let c = WindowCoordinator(); let log = Log()
        let reservation = FileTransferCoordinator.reserve(.copy, total: 4)
        defer { FileTransferCoordinator.release(reservation) }
        c.unsavedEditsAsker = { log.events.append("edits"); return { log.events.append("apply"); return true } }
        // While the question is up the user enters edit mode and crops.
        var editing = false
        c.quitAlertResponder = { _, _ in log.events.append("work"); editing = true; return 0 }
        c.unsavedEditsRecheck = {
            log.events.append(editing ? "recheck-asks" : "recheck")
            return !editing   // Cancel at the new edit question
        }
        c.flushOverride = { true }
        await quit(c, log)
        XCTAssertEqual(log.events, ["edits", "work", "apply", "recheck-asks"])
        XCTAssertEqual(log.replies, [false], "Cancel at the new edit question cancels the quit")
        XCTAssertFalse(reservation.stop.isStopped, "asked before the work stops: the copy goes on")
    }

    func testNoNewEditsQuitsAndRechecksAfterTheFlushToo() async {
        let c = WindowCoordinator(); let log = Log()
        let reservation = FileTransferCoordinator.reserve(.copy, total: 4)
        defer { FileTransferCoordinator.release(reservation) }
        c.unsavedEditsAsker = { log.events.append("edits"); return { true } }
        c.quitAlertResponder = { _, _ in log.events.append("work"); return 0 }
        c.unsavedEditsRecheck = { log.events.append("recheck"); return true }
        c.stoppedForQuitOverride = { true }
        c.flushOverride = { log.events.append("flush"); return true }
        await quit(c, log)
        XCTAssertEqual(log.events, ["edits", "work", "recheck", "flush", "recheck"])
        XCTAssertEqual(log.replies, [true])
        XCTAssertTrue(reservation.stop.isStopped)
    }
}

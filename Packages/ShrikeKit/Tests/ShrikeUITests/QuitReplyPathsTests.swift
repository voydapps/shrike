//
//  QuitReplyPathsTests.swift
//  ShrikeUITests
//
//  ⌘Q: every path of `WindowCoordinator.terminateRequest` ends with exactly
//  one answer to AppKit: the returned `.terminateNow`, or `.terminateLater`
//  followed by ONE reply. Window-free: the steps are injected.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

@MainActor
final class QuitReplyPathsTests: XCTestCase {

    private final class Log { var events: [String] = []; var replies: [Bool] = [] }

    private func runningBatch() -> QuitWork {
        var work = QuitWork()
        work.batch = QuitWork.Batch(completed: 2, total: 9, isHidden: false)
        return work
    }

    /// Runs one ⌘Q and returns the immediate reply; the replies seen after
    /// the flow had every chance to finish are in `log.replies`.
    private func quit(_ c: WindowCoordinator, _ log: Log, endSheets: (() -> Void)? = nil)
        async -> NSApplication.TerminateReply {
        let reply = c.terminateRequest(endSheets: endSheets) { log.replies.append($0) }
        if reply == .terminateLater {
            for _ in 0..<200 where log.replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
            try? await Task.sleep(for: .milliseconds(60))   // a second reply would show up here
        }
        return reply
    }

    func testNothingRunningAnswersTerminateNowAndNeverReplies() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { QuitWork() }
        let reply = await quit(c, log)
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertTrue(log.replies.isEmpty, "no second answer after terminateNow")
    }

    func testUnsavedEditsCancelRepliesFalseOnce() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { self.runningBatch() }   // makes the plan `.later`
        c.unsavedEditsResolver = { false }
        c.quitAlertResponder = { _, _ in XCTFail("no work alert after a cancelled edit"); return 0 }
        let reply = await quit(c, log)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(log.replies, [false])
    }

    func testWorkAlertCancelRepliesFalseOnce() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsResolver = { true }
        c.quitAlertResponder = { _, _ in 1 }
        c.stoppedForQuitOverride = { XCTFail("nothing is stopped after Cancel"); return true }
        let reply = await quit(c, log)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(log.replies, [false])
    }

    func testQuitAnywayStopsThenRepliesTrueOnce() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsResolver = { true }
        c.quitAlertResponder = { _, _ in 0 }
        c.stoppedForQuitOverride = { true }
        c.flushOverride = { true }
        let reply = await quit(c, log)
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(log.replies, [true])
    }

    func testStopTimeoutBothButtons() async {
        let saved = WindowCoordinator.stopWaitTimeout
        WindowCoordinator.stopWaitTimeout = .milliseconds(40)
        defer { WindowCoordinator.stopWaitTimeout = saved }
        // Quit Anyway (0) at the timeout: the quit goes on and replies true once.
        do {
            let c = WindowCoordinator(), log = Log()
            c.runningWorkOverride = { self.runningBatch() }
            c.unsavedEditsResolver = { true }
            c.quitAlertResponder = { _, _ in 0 }
            c.stoppedForQuitOverride = { false }
            c.flushOverride = { true }
            var asked = 0
            c.writeTimeoutResponder = { asked += 1; return 0 }
            _ = await quit(c, log)
            XCTAssertEqual(asked, 1)
            XCTAssertEqual(log.replies, [true])
        }
        // Keep Waiting (1) once, then the work settles: asked once, replies true once.
        do {
            let c = WindowCoordinator(), log = Log()
            c.runningWorkOverride = { self.runningBatch() }
            c.unsavedEditsResolver = { true }
            c.quitAlertResponder = { _, _ in 0 }
            var asked = 0
            c.stoppedForQuitOverride = { asked >= 1 }   // settles once the user chose Keep Waiting
            c.flushOverride = { true }
            c.writeTimeoutResponder = { asked += 1; return 1 }
            _ = await quit(c, log)
            XCTAssertEqual(asked, 1)
            XCTAssertEqual(log.replies, [true])
        }
    }

    func testWriteTimeoutBothButtons() async {
        // Keep Waiting (1) first, the write finishes on the second flush.
        do {
            let c = WindowCoordinator(), log = Log()
            c.runningWorkOverride = { self.runningBatch() }
            c.unsavedEditsResolver = { true }
            c.quitAlertResponder = { _, _ in 0 }
            c.stoppedForQuitOverride = { true }
            var flushes = 0
            c.flushOverride = { flushes += 1; return flushes > 1 }
            var asked = 0
            c.writeTimeoutResponder = { asked += 1; return 1 }
            _ = await quit(c, log)
            XCTAssertEqual(flushes, 2)
            XCTAssertEqual(asked, 1)
            XCTAssertEqual(log.replies, [true])
        }
        // Quit Anyway (0): leaves the loop at once and replies true once.
        do {
            let c = WindowCoordinator(), log = Log()
            c.runningWorkOverride = { self.runningBatch() }
            c.unsavedEditsResolver = { true }
            c.quitAlertResponder = { _, _ in 0 }
            c.stoppedForQuitOverride = { true }
            c.flushOverride = { false }
            c.writeTimeoutResponder = { 0 }
            _ = await quit(c, log)
            XCTAssertEqual(log.replies, [true])
        }
        // A dismissed alert (nil) is not "keep waiting": it quits too.
        do {
            let c = WindowCoordinator(), log = Log()
            c.runningWorkOverride = { self.runningBatch() }
            c.unsavedEditsResolver = { true }
            c.quitAlertResponder = { _, _ in 0 }
            c.stoppedForQuitOverride = { true }
            c.flushOverride = { false }
            c.writeTimeoutResponder = { nil }
            _ = await quit(c, log)
            XCTAssertEqual(log.replies, [true])
        }
    }

    func testInformationalSheetIsClosedBeforeTheQuitQuestion() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsResolver = { true }
        c.quitAlertResponder = { _, _ in log.events.append("alert"); return 1 }
        _ = await quit(c, log, endSheets: { log.events.append("sheet") })
        XCTAssertEqual(log.events, ["sheet", "alert"])
        XCTAssertEqual(log.replies, [false])
    }

    func testSheetIsClosedEvenWhenQuitIsImmediate() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { QuitWork() }
        let reply = await quit(c, log, endSheets: { log.events.append("sheet") })
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(log.events, ["sheet"])
    }

    /// `prepareToQuit` cannot throw: a failed save inside a viewer surfaces
    /// as `false` from the resolver (the quit is cancelled), which is the
    /// one cancel answer.
    func testAFailedSaveIsACancelNotASilentHang() async {
        let c = WindowCoordinator(), log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsResolver = { false }
        _ = await quit(c, log)
        XCTAssertEqual(log.replies, [false])
    }

    // MARK: Pass 2k Q2: the edit answers wait for the work question

    private func deferredEdits(_ log: Log, applies: Bool = true) -> () async -> WindowCoordinator.ApplyEditAnswers? {
        {
            log.events.append("edits")
            return { log.events.append("apply"); return applies }
        }
    }

    func testCancelAtTheWorkQuestionNeverAppliesTheEditAnswers() async {
        let c = WindowCoordinator(); let log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsAsker = deferredEdits(log)
        c.quitAlertResponder = { _, _ in log.events.append("work"); return 1 }
        _ = await quit(c, log)
        XCTAssertEqual(log.events, ["edits", "work"])
        XCTAssertEqual(log.replies, [false])
    }

    func testQuitAnywayAppliesTheEditAnswersOnceBeforeStopping() async {
        let c = WindowCoordinator(); let log = Log()
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsAsker = deferredEdits(log)
        c.quitAlertResponder = { _, _ in log.events.append("work"); return 0 }
        c.stoppedForQuitOverride = { log.events.append("stopped?"); return true }
        c.flushOverride = { true }
        _ = await quit(c, log)
        XCTAssertEqual(log.events.prefix(3), ["edits", "work", "apply"])
        XCTAssertEqual(log.events.filter { $0 == "apply" }.count, 1)
        XCTAssertEqual(log.replies, [true])
    }

    func testAFailedApplyCancelsTheQuitAndStopsNothing() async {
        let c = WindowCoordinator(); let log = Log()
        let reservation = FileTransferCoordinator.reserve(.copy, total: 4)
        defer { FileTransferCoordinator.release(reservation) }
        c.unsavedEditsAsker = deferredEdits(log, applies: false)
        c.quitAlertResponder = { _, _ in log.events.append("work"); return 0 }
        _ = await quit(c, log)
        XCTAssertEqual(log.events, ["edits", "work", "apply"])
        XCTAssertEqual(log.replies, [false])
        XCTAssertFalse(reservation.stop.isStopped, "the copy goes on")
    }

    /// R3: a running undo (Trash, Put Back, Undo Batch...) holds the quit
    /// without a question, then the quit goes on once it ends.
    func testRunningUndoMakesTheQuitWaitThenProceed() async {
        let c = WindowCoordinator(); let log = Log()
        c.quitAlertResponder = { _, _ in XCTFail("short work is not asked about"); return 1 }
        c.writeTimeoutResponder = { XCTFail("no timeout"); return 0 }
        c.flushOverride = { true }
        let token = ActiveWork.shared.begin(kind: .transfer, detail: "Undo")
        var ended = false
        defer { if !ended { ActiveWork.shared.end(token) } }
        XCTAssertEqual(c.terminateRequest { log.replies.append($0) }, .terminateLater)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(log.replies.isEmpty, "waits while the undo runs")
        ActiveWork.shared.end(token); ended = true
        for _ in 0..<200 where log.replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.replies, [true])
    }

    /// R3: Undo Batch holds an ActiveWork token from the click to its end.
    func testUndoBatchHoldsActiveWorkForItsDuration() async throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-undo-hold-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = BackupStore(root: dir.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        await BatchUndo.lastTask?.value
        let before = ActiveWork.shared.snapshot().count(of: .batchRun)
        BatchUndo.run(runner: runner, result: BatchResult(), toast: nil)
        XCTAssertEqual(ActiveWork.shared.snapshot().count(of: .batchRun), before + 1)
        await BatchUndo.lastTask?.value
        XCTAssertEqual(ActiveWork.shared.snapshot().count(of: .batchRun), before)
    }

    func testWorkThatEndsDuringTheEditQuestionAppliesWithoutTheWorkQuestion() async {
        let c = WindowCoordinator(); let log = Log()
        var running = true
        c.runningWorkOverride = { running ? self.runningBatch() : QuitWork() }
        c.unsavedEditsAsker = {
            log.events.append("edits"); running = false
            return { log.events.append("apply"); return true }
        }
        c.quitAlertResponder = { _, _ in log.events.append("work"); return 0 }
        c.flushOverride = { true }
        _ = await quit(c, log)
        XCTAssertEqual(log.events, ["edits", "apply"])
        XCTAssertEqual(log.replies, [true])
    }

    /// S3: a rotate write whose window is already closed (no window lists
    /// it) still makes ⌘Q wait, after the flush, then the quit goes on.
    func testRotateWriteWithNoWindowMakesTheQuitWaitThenProceed() async {
        let c = WindowCoordinator(); let log = Log()
        c.quitAlertResponder = { _, _ in XCTFail("a write is not asked about"); return 1 }
        c.writeTimeoutResponder = { XCTFail("no timeout"); return 0 }
        let token = ActiveWork.shared.begin(kind: .rotateWrite, detail: "closed.jpg")
        var ended = false
        defer { if !ended { ActiveWork.shared.end(token) } }
        XCTAssertEqual(c.terminateRequest { log.replies.append($0) }, .terminateLater)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(log.replies.isEmpty, "waits while the write runs")
        ActiveWork.shared.end(token); ended = true
        for _ in 0..<200 where log.replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.replies, [true])
    }

    /// S3: a window's own pending-rotate hold (same kind) is written by the
    /// flush first, so it never holds the quit before the flush.
    func testWindowPendingRotateHoldIsFlushedBeforeTheTokenWait() async {
        let c = WindowCoordinator(); let log = Log()
        let hold = ActiveWorkHold(kind: .rotateWrite)
        hold.set(true)
        defer { hold.set(false) }
        c.quitAlertResponder = { _, _ in XCTFail("no question"); return 1 }
        c.writeTimeoutResponder = { XCTFail("no timeout: the hold is flushed first"); return 0 }
        c.flushOverride = { log.events.append("flush"); hold.set(false); return true }
        XCTAssertEqual(c.terminateRequest { log.replies.append($0) }, .terminateLater)
        for _ in 0..<200 where log.replies.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.events, ["flush"])
        XCTAssertEqual(log.replies, [true])
    }

    /// R5b: the quit question first unhides / activates Shrike (Dock ▸ Quit
    /// with Shrike hidden), then is presented.
    func testQuitQuestionBringsTheAppForwardBeforePresenting() async {
        let c = WindowCoordinator(); let log = Log()
        let saved = WindowCoordinator.bringForward
        defer { WindowCoordinator.bringForward = saved }
        WindowCoordinator.bringForward = { _ in log.events.append("forward") }
        c.runningWorkOverride = { self.runningBatch() }
        c.unsavedEditsResolver = { true }
        c.quitAlertPresenter = { _, completion in
            log.events.append("present")
            Task { @MainActor in completion(.alertFirstButtonReturn) }   // Cancel (buttons are added right to left)
            return { _ in }
        }
        _ = await quit(c, log)
        XCTAssertEqual(log.events, ["forward", "present"])
        XCTAssertEqual(log.replies, [false])
    }
}

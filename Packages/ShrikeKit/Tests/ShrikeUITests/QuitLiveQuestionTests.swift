//
//  QuitLiveQuestionTests.swift
//  ShrikeUITests
//
//  28a round 5, FAIL 1: the quit question froze the app. `prepareToQuit`
//  is an async main-actor task; it called `runModal`, and a run loop nested
//  inside a main-queue job does not run other main-queue jobs, so the
//  Batch's progress (main actor) stopped and the refresh read the same
//  numbers for ever. The question is now a sheet (or a free-standing,
//  non-blocking alert) whose answer is awaited.
//

import XCTest
@testable import ShrikeUI
import ShrikeCore
import ShrikeEdit
import ShrikeIO

@MainActor
final class QuitLiveQuestionTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-quit-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        BatchWindowController.setCurrentForTesting(nil)
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        try? FileManager.default.removeItem(at: dir)
    }

    /// The cause, pinned: a run loop spun inside a main-actor job (what
    /// `runModal` does) never lets another main-actor job run meanwhile.
    func testARunLoopInsideAMainActorJobStopsOtherMainActorJobs() async {
        var counter = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                counter += 1
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        let seenDuringSpin: Int = await Task { @MainActor in
            let before = counter
            Self.spinNestedRunLoop(seconds: 0.3)   // what runModal does
            return counter - before
        }.value
        try? await Task.sleep(for: .milliseconds(60))
        let after = counter
        ticker.cancel()
        XCTAssertEqual(seenDuringSpin, 0, "no main-actor job ran while the nested run loop spun")
        XCTAssertGreaterThan(after, 0)
    }

    /// Spins the main run loop in the modal-panel mode, as `runModal` does.
    private static func spinNestedRunLoop(seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .modalPanel, before: end) }
    }

    /// A real Batch with `photos` photos, resize into a folder of its own.
    private func makeRunningBatch(photos: Int) async throws -> BatchWindowController {
        var groups: [ImageGroup] = []
        for i in 0..<photos {
            let url = dir.appendingPathComponent(String(format: "p%03d.jpg", i))
            _ = try SaveFlowTests.writeImage(url, type: .jpeg)
            groups.append(ImageGroup(primary: url))
        }
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let backups = BackupStore(root: dir.appendingPathComponent("backups"))
        let model = BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                                   backups: backups))
        model.form.convertOn = false
        model.form.resizeOn = true; model.form.resizeValue = 40
        model.form.outputFolder = out
        model.add(groups)
        await model.waitForPreview()
        let batch = BatchWindowController(model: model, launcher: nil)
        BatchWindowController.setCurrentForTesting(batch)
        model.run()
        XCTAssertEqual(model.phase, .running)
        return batch
    }

    private final class Seen {
        var texts: [String] = []
        var completedAtPresent: Int?
        var ends: [NSApplication.ModalResponse] = []
        var replies: [Bool] = []
        var answer: (@MainActor (NSApplication.ModalResponse) -> Void)?
    }

    /// The REAL flow (no `runningWorkOverride`): while the question is up the
    /// Batch goes on, the refresh shows its new count, and when it finishes
    /// the question closes itself and the quit goes on (one reply, true).
    func testBatchKeepsRunningWhileTheQuestionIsUpAndFinishingClosesIt() async throws {
        let batch = try await makeRunningBatch(photos: 60)
        defer { batch.close() }
        let model = batch.model
        let c = WindowCoordinator(), seen = Seen()
        c.unsavedEditsResolver = { true }
        c.flushOverride = { true }
        c.quitAlertPresenter = { alert, completion in
            seen.completedAtPresent = model.completed
            seen.texts.append(alert.informativeText)
            seen.answer = completion
            return { code in seen.ends.append(code); completion(code) }
        }
        XCTAssertEqual(c.quitPlan, .later)
        let reply = c.terminateRequest(endSheets: {}) { seen.replies.append($0) }
        XCTAssertEqual(reply, .terminateLater)
        for _ in 0..<1500 where seen.replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(seen.replies, [true], "the question closed by itself and the quit went on, once")
        XCTAssertEqual(seen.ends, [WindowCoordinator.workFinishedWhileAsking])
        XCTAssertNotEqual(model.phase, .running)
        XCTAssertEqual(model.completed, 60)
        let atPresent = try XCTUnwrap(seen.completedAtPresent)
        XCTAssertLessThan(atPresent, 60, "the Batch made progress (main actor) while the question was up")
        XCTAssertTrue(seen.texts.first?.contains("of 60 photos done.") ?? false, seen.texts.first ?? "")
    }

    /// The refresh reads the real model while the question is up: the shown
    /// count moves (it stayed at "99 of 300" before the fix).
    func testRefreshShowsTheBatchCountMoving() async throws {
        let savedInterval = WindowCoordinator.liveQuitAlertInterval
        WindowCoordinator.liveQuitAlertInterval = 0.005   // small test photos finish fast
        defer { WindowCoordinator.liveQuitAlertInterval = savedInterval }
        let batch = try await makeRunningBatch(photos: 120)
        defer { batch.close() }
        let c = WindowCoordinator(), seen = Seen()
        c.unsavedEditsResolver = { true }
        c.flushOverride = { true }
        var shown: NSAlert?
        c.quitAlertPresenter = { alert, completion in
            shown = alert
            seen.answer = completion
            return { code in seen.ends.append(code); completion(code) }
        }
        _ = c.terminateRequest(endSheets: {}) { seen.replies.append($0) }
        var texts: [String] = []
        for _ in 0..<1500 where seen.replies.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            if let text = shown?.informativeText, texts.last != text { texts.append(text) }
        }
        XCTAssertEqual(seen.replies, [true])
        XCTAssertGreaterThanOrEqual(texts.count, 2, "the text followed the Batch: \(texts)")
    }

    /// ⌘Q again while the question is up starts nothing and answers nothing;
    /// the first flow still answers once (Cancel → false).
    func testSecondQuitWhileAskingDoesNothing() async throws {
        let c = WindowCoordinator(), seen = Seen()
        c.runningWorkOverride = { QuitWork(batch: .init(completed: 2, total: 9, isHidden: false)) }
        c.unsavedEditsResolver = { true }
        var presented = 0
        c.quitAlertPresenter = { _, completion in
            presented += 1
            seen.answer = completion
            return { completion($0) }
        }
        var secondReplies: [Bool] = []
        XCTAssertEqual(c.terminateRequest(endSheets: {}) { seen.replies.append($0) }, .terminateLater)
        for _ in 0..<200 where seen.answer == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(c.isQuitFlowRunning)
        var endedSheets = false
        XCTAssertEqual(c.terminateRequest(endSheets: { endedSheets = true }) { secondReplies.append($0) },
                       .terminateCancel)
        XCTAssertFalse(endedSheets)
        seen.answer?(.alertFirstButtonReturn)   // added reversed: Cancel (index 1) is added first
        for _ in 0..<200 where seen.replies.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(presented, 1)
        XCTAssertEqual(seen.replies, [false])
        XCTAssertTrue(secondReplies.isEmpty)
        XCTAssertFalse(c.isQuitFlowRunning)
    }

    /// Keep Waiting: the stop-timeout alert is up while the work it waits for
    /// goes on (main-actor jobs run), and that work settling lets the quit end.
    func testStopTimeoutAlertDoesNotBlockTheWorkItWaitsFor() async throws {
        let saved = WindowCoordinator.stopWaitTimeout
        WindowCoordinator.stopWaitTimeout = .milliseconds(40)
        defer { WindowCoordinator.stopWaitTimeout = saved }
        let c = WindowCoordinator(), seen = Seen()
        c.runningWorkOverride = { QuitWork(batch: .init(completed: 2, total: 9, isHidden: false)) }
        c.unsavedEditsResolver = { true }
        c.quitAlertResponder = { _, _ in 0 }
        c.flushOverride = { true }
        var settled = false
        c.stoppedForQuitOverride = { settled }
        var timeoutTitles: [String] = []
        c.quitAlertPresenter = { alert, completion in
            timeoutTitles.append(alert.messageText)
            // Keep Waiting, after a main-actor job has settled the work.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(30))
                settled = true
                completion(.alertFirstButtonReturn)   // reversed: Keep Waiting (index 1) is added first
            }
            return { completion($0) }
        }
        _ = c.terminateRequest(endSheets: {}) { seen.replies.append($0) }
        for _ in 0..<300 where seen.replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(seen.replies, [true])
        XCTAssertEqual(timeoutTitles, [QuitQuestion.stopTimeoutTitle])
    }

    /// ⌘Q with only an Undo Batch / Trash / Put Back running: the wait alert
    /// names that work, not a photo being saved on a slow disk.
    func testShortWorkWaitAlertNamesTheUndoOrMove() async throws {
        let saved = WindowCoordinator.stopWaitTimeout
        WindowCoordinator.stopWaitTimeout = .milliseconds(40)
        defer { WindowCoordinator.stopWaitTimeout = saved }
        let c = WindowCoordinator(), seen = Seen()
        c.runningWorkOverride = { var work = QuitWork(); work.shortWork = true; return work }
        c.unsavedEditsResolver = { true }
        c.flushOverride = { true }
        var settled = false
        c.stoppedForQuitOverride = { settled }
        var timeouts: [(String, String)] = []
        c.quitAlertPresenter = { alert, completion in
            timeouts.append((alert.messageText, alert.informativeText))
            Task { @MainActor in
                settled = true
                completion(.alertFirstButtonReturn)   // Keep Waiting
            }
            return { completion($0) }
        }
        _ = c.terminateRequest(endSheets: {}) { seen.replies.append($0) }
        for _ in 0..<300 where seen.replies.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(seen.replies, [true])
        XCTAssertEqual(timeouts.map(\.0), [QuitQuestion.shortWorkTimeoutTitle])
        XCTAssertEqual(timeouts.map(\.1), [QuitQuestion.shortWorkTimeoutInformation])
    }

    /// The real presenter: a sheet on the frontmost window, never `runModal`.
    /// The Batch goes on behind it, the sheet's text follows, and finishing
    /// ends the sheet (`endSheet`) and lets the quit go on.
    func testRealSheetFollowsTheBatchAndEndsItself() async throws {
        let savedInterval = WindowCoordinator.liveQuitAlertInterval
        WindowCoordinator.liveQuitAlertInterval = 0.005
        defer { WindowCoordinator.liveQuitAlertInterval = savedInterval }
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 600, height: 400),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.makeKeyAndOrderFront(nil)
        defer { host.orderOut(nil) }
        let batch = try await makeRunningBatch(photos: 120)
        defer { batch.close() }
        let c = WindowCoordinator(), seen = Seen()
        c.unsavedEditsResolver = { true }
        c.flushOverride = { true }
        XCTAssertNotNil(WindowCoordinator.quitHostWindow())
        // The real sheet, on this test's window (another test's window may be in front).
        c.quitAlertPresenter = { alert, completion in
            let shown = ShrikeAlert.present(alert, on: host, completion: completion)
            return { shown.end($0) }
        }
        _ = c.terminateRequest(endSheets: {}) { seen.replies.append($0) }
        var sheetSeen: NSWindow?
        var texts: [String] = []
        for _ in 0..<1500 where seen.replies.isEmpty {
            try await Task.sleep(for: .milliseconds(5))
            if let sheet = host.attachedSheet {
                sheetSeen = sheet
                let text = Self.texts(in: sheet.contentView).first { $0.contains("photos done") } ?? ""
                if !text.isEmpty, texts.last != text { texts.append(text) }
            }
        }
        XCTAssertNotNil(sheetSeen, "the question was a sheet on the frontmost window")
        XCTAssertEqual(seen.replies, [true], "finishing ended the sheet and the quit went on, once")
        XCTAssertNil(host.attachedSheet)
        XCTAssertGreaterThanOrEqual(texts.count, 2, "the sheet followed the Batch: \(texts)")
    }

    private static func texts(in view: NSView?) -> [String] {
        guard let view else { return [] }
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { texts(in: $0) }
    }

    /// No window: the alert stands on its own, not modal; its buttons answer
    /// (as `runModal` would number them) and `end` closes it once.
    func testFreeStandingAlertAnswersThroughItsButtonsAndEnd() {
        let alert = ShrikeAlert.make(message: QuitQuestion.title, information: "x", buttons: QuitQuestion.quitButtons)
        var answers: [NSApplication.ModalResponse] = []
        let shown = ShrikeAlert.present(alert, on: nil) { answers.append($0) }
        XCTAssertTrue(alert.window.isVisible)
        XCTAssertNil(NSApp.modalWindow, "never app-modal: main-actor work goes on")
        alert.buttons[1].performClick(nil)   // Quit Anyway (added second)
        XCTAssertEqual(answers, [.alertSecondButtonReturn])
        XCTAssertEqual(ShrikeAlert.index(of: answers[0], buttonCount: 2), 0)
        XCTAssertFalse(alert.window.isVisible)
        shown.end(WindowCoordinator.workFinishedWhileAsking)
        XCTAssertEqual(answers.count, 1, "answers once")

        let second = ShrikeAlert.make(message: "m", buttons: QuitQuestion.timeoutButtons)
        let shown2 = ShrikeAlert.present(second, on: nil) { answers.append($0) }
        shown2.end(WindowCoordinator.workFinishedWhileAsking)
        XCTAssertEqual(answers.last, WindowCoordinator.workFinishedWhileAsking)
        XCTAssertFalse(second.window.isVisible)
    }

    /// No window, handle dropped (as `run` and the timeout alerts do): the
    /// free-standing alert keeps itself alive and its buttons still answer.
    func testFreeStandingAlertAnswersWhenNobodyKeepsIt() async throws {
        let task = Task { @MainActor in
            await ShrikeAlert.run(message: "Quit-test alert", information: "x",
                                  buttons: QuitQuestion.timeoutButtons, on: nil)
        }
        var panel: NSWindow?
        for _ in 0..<100 where panel == nil {
            try await Task.sleep(for: .milliseconds(10))
            panel = NSApp.windows.first { window in
                window.isVisible && Self.texts(in: window.contentView).contains("Quit-test alert")
            }
        }
        let shown = try XCTUnwrap(panel, "the alert is on screen without a window to hold it")
        let keepWaiting = try XCTUnwrap(Self.buttons(in: shown.contentView).first {
            $0.accessibilityLabel() == QuitQuestion.keepWaiting })
        keepWaiting.performClick(nil)
        let answer = await task.value
        XCTAssertEqual(answer, 1, "Keep Waiting answered")
        XCTAssertFalse(shown.isVisible)
    }

    private static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons(in: $0) }
    }
}

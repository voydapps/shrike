//
//  QuitQuestionTests.swift
//  ShrikeUITests
//
//  A-2 / B-1 / A-3 / I-2: the quit decision and texts (spec 28 §17.1).
//  Window-free.
//

import XCTest
import os
@testable import ShrikeCore
@testable import ShrikeUI

final class QuitQuestionTests: XCTestCase {

    private let tail = "Photos that are already done stay done."

    func testNothingRunningAsksNothing() {
        XCTAssertNil(QuitQuestion.information(for: QuitWork()))
        // A save alone does not ask (it finishes first, as before).
        XCTAssertNil(QuitQuestion.information(for: QuitWork(savingPhotos: 2)))
    }

    func testBatchLineAndUndoParagraph() {
        let work = QuitWork(batch: .init(completed: 12, total: 40, isHidden: false))
        XCTAssertEqual(QuitQuestion.information(for: work),
                       "A batch is running: 12 of 40 photos done.\n\n" + tail
                       + " A rename may finish more photos first, so that none is left with a temporary name. The rest are not processed, and you won't be able to undo a stopped batch after you quit.")
    }

    func testHiddenBatchSaysSo() {
        let work = QuitWork(batch: .init(completed: 1, total: 3, isHidden: true))
        XCTAssertTrue(QuitQuestion.information(for: work)!
            .hasPrefix("A batch is running: 1 of 3 photos done. Its window is hidden.\n\n"))
    }

    func testOneCopyAndOneMove() {
        XCTAssertEqual(QuitQuestion.information(for: QuitWork(transfers: [.init(verb: .copy, completed: 3, total: 8)])),
                       "A copy is running: 3 of 8 photos done.\n\n" + tail + " The rest are not copied.")
        XCTAssertEqual(QuitQuestion.information(for: QuitWork(transfers: [.init(verb: .move, completed: 3, total: 8)])),
                       "A move is running: 3 of 8 photos done.\n\n" + tail + " The rest are not moved.")
    }

    func testSeveralTransfersAreSummed() {
        let work = QuitWork(transfers: [.init(verb: .copy, completed: 2, total: 12),
                                        .init(verb: .copy, completed: 3, total: 8)])
        XCTAssertEqual(QuitQuestion.information(for: work),
                       "2 copy or move jobs are running: 5 of 20 photos done.\n\n" + tail + " The rest are not copied.")
        let mixed = QuitWork(transfers: [.init(verb: .copy, completed: 0, total: 1),
                                         .init(verb: .move, completed: 0, total: 1)])
        XCTAssertTrue(QuitQuestion.information(for: mixed)!.hasSuffix(" The rest are not copied or moved."))
    }

    func testBatchWithTransferAndSaves() {
        let work = QuitWork(batch: .init(completed: 12, total: 40, isHidden: false),
                            transfers: [.init(verb: .move, completed: 3, total: 8)], savingPhotos: 2)
        let lines = QuitQuestion.information(for: work)!.components(separatedBy: "\n\n")
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], "A batch is running: 12 of 40 photos done.")
        XCTAssertEqual(lines[1], "A move is running: 3 of 8 photos done.")
        XCTAssertEqual(lines[2], "Shrike is still saving 2 photos. It will finish them first.")
        XCTAssertTrue(lines[3].contains("undo a stopped batch"))
    }

    func testOneSave() {
        let work = QuitWork(transfers: [.init(verb: .copy, completed: 0, total: 2)], savingPhotos: 1)
        XCTAssertTrue(QuitQuestion.information(for: work)!.contains("Shrike is still saving 1 photo. It will finish it first."))
    }

    func testTitleAndButtons() {
        XCTAssertEqual(QuitQuestion.title, "Quit while work is running?")
        XCTAssertEqual(QuitQuestion.quitAnyway, "Quit Anyway")
        XCTAssertEqual(QuitQuestion.cancel, "Cancel")
    }

    func testPlan() {
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: false, work: QuitWork()), .now)
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: false, work: QuitWork(savingPhotos: 1)), .now)
        XCTAssertEqual(QuitPlan.decide(editing: true, pendingWrites: false, work: QuitWork()), .later)
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: true, work: QuitWork()), .later)
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: false,
                                       work: QuitWork(batch: .init(completed: 0, total: 1, isHidden: true))), .later)
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: false,
                                       work: QuitWork(transfers: [.init(verb: .copy, completed: 0, total: 1)])), .later)
    }

    /// R3: ask for stoppable work, wait for short work alone, else nothing.
    func testWorkStepForEachCombination() {
        let batch = QuitWork.Batch(completed: 0, total: 1, isHidden: false)
        let copy = QuitWork.Transfer(verb: .copy, completed: 0, total: 1)
        XCTAssertEqual(QuitPlan.workStep(QuitWork()), .none)
        XCTAssertEqual(QuitPlan.workStep(QuitWork(savingPhotos: 2)), .none)
        XCTAssertEqual(QuitPlan.workStep(QuitWork(shortWork: true)), .wait)
        XCTAssertEqual(QuitPlan.workStep(QuitWork(batch: batch)), .ask)
        XCTAssertEqual(QuitPlan.workStep(QuitWork(batch: batch, shortWork: true)), .ask)
        XCTAssertEqual(QuitPlan.workStep(QuitWork(transfers: [copy], shortWork: true)), .ask)
        XCTAssertEqual(QuitPlan.decide(editing: false, pendingWrites: false, work: QuitWork(shortWork: true)), .later)
        XCTAssertNil(QuitQuestion.information(for: QuitWork(shortWork: true)), "short work alone: no question")
        let snapshot = { (kind: ActiveWork.Kind) -> ActiveWork.Snapshot in .init(counts: [kind: 1], details: []) }
        XCTAssertTrue(WindowCoordinator.hasShortWork(snapshot(.transfer)))
        XCTAssertTrue(WindowCoordinator.hasShortWork(snapshot(.restore)))
        XCTAssertTrue(WindowCoordinator.hasShortWork(snapshot(.batchRun)))
        XCTAssertFalse(WindowCoordinator.hasShortWork(snapshot(.save)))
        XCTAssertFalse(WindowCoordinator.hasShortWork(snapshot(.unsavedEdit)))
        XCTAssertFalse(WindowCoordinator.hasShortWork(snapshot(.rotateWrite)))
    }
}

final class ActiveWorkHoldTests: XCTestCase {

    private final class Counter: Sendable {
        let counts = OSAllocatedUnfairLock(initialState: (disabled: 0, enabled: 0))
        var disabled: Int { counts.withLock { $0.disabled } }
        var enabled: Int { counts.withLock { $0.enabled } }
    }

    func testSetIsIdempotentAndDeinitEnds() {
        let counter = Counter()
        let registry = ActiveWork(hooks: .init(disable: { counter.counts.withLock { $0.disabled += 1 } }, enable: { counter.counts.withLock { $0.enabled += 1 } }))
        var hold: ActiveWorkHold? = ActiveWorkHold(kind: .unsavedEdit, registry: registry)
        hold?.set(true, detail: "a.jpg")
        hold?.set(true)
        XCTAssertEqual(registry.snapshot().count(of: .unsavedEdit), 1)
        XCTAssertEqual(registry.snapshot().details, ["a.jpg"])
        hold?.set(false)
        hold?.set(false)
        XCTAssertTrue(registry.snapshot().isIdle)
        hold?.set(true)
        XCTAssertTrue(hold!.isHeld)
        hold = nil
        XCTAssertTrue(registry.snapshot().isIdle, "a holder that goes away never blocks quit")
        XCTAssertEqual(counter.disabled, 2)
        XCTAssertEqual(counter.enabled, 2)
    }
}

@MainActor
final class QuitFlowTests: XCTestCase {

    func testWaitUntilTimesOutWithoutBlocking() async {
        let ok = await WindowCoordinator.waitUntil(timeout: .milliseconds(60)) { false }
        XCTAssertFalse(ok)
        let done = await WindowCoordinator.waitUntil(timeout: .seconds(1)) { true }
        XCTAssertTrue(done)
    }

    func testIdleCoordinatorQuitsAtOnce() async {
        let coordinator = WindowCoordinator()
        XCTAssertEqual(coordinator.runningWork(ActiveWork.Snapshot(counts: [:], details: [])), QuitWork())
        XCTAssertEqual(coordinator.quitPlan, .now)
        var asked = false
        coordinator.quitAlertResponder = { _, _ in asked = true; return 1 }
        let quits = await coordinator.prepareToQuit()
        XCTAssertTrue(quits)
        XCTAssertFalse(asked, "no running work: no question")
    }

    func testSavesComeFromTheSnapshot() {
        let coordinator = WindowCoordinator()
        let work = coordinator.runningWork(ActiveWork.Snapshot(counts: [.save: 2, .rotateWrite: 3], details: []))
        XCTAssertEqual(work.savingPhotos, 2, "rotate writes are flushed on their own and not counted as saves")
    }

    /// B.6: the open quit alert follows the work; when it all finished, the
    /// alert closes as Quit Anyway (the quit goes on, writes still flushed).
    func testLiveStep() {
        let running = QuitWork(batch: .init(completed: 0, total: 300, isHidden: false))
        let shown = QuitQuestion.information(for: running)!
        XCTAssertEqual(QuitQuestion.liveStep(shown: shown, work: running), .keep)
        let later = QuitWork(batch: .init(completed: 40, total: 300, isHidden: false))
        XCTAssertEqual(QuitQuestion.liveStep(shown: shown, work: later), .update(QuitQuestion.information(for: later)!))
        XCTAssertEqual(QuitQuestion.liveStep(shown: shown, work: QuitWork()), .finished)
        XCTAssertEqual(QuitQuestion.liveStep(shown: shown, work: QuitWork(savingPhotos: 1)), .finished,
                       "saves are waited for after the alert, not asked about")
    }

    func testLiveQuitAlertTickUpdatesThenCloses() {
        let coordinator = WindowCoordinator()
        var work = QuitWork(batch: .init(completed: 0, total: 300, isHidden: false))
        coordinator.runningWorkOverride = { work }
        let alert = ShrikeAlert.make(message: QuitQuestion.title, information: QuitQuestion.information(for: work),
                                     buttons: QuitQuestion.quitButtons)
        var codes: [NSApplication.ModalResponse] = []
        XCTAssertFalse(coordinator.tickLiveQuitAlert(alert) { codes.append($0) })
        work.batch?.completed = 120
        XCTAssertFalse(coordinator.tickLiveQuitAlert(alert) { codes.append($0) })
        XCTAssertTrue(alert.informativeText.contains("120 of 300 photos done."), alert.informativeText)
        work = QuitWork()
        XCTAssertTrue(coordinator.tickLiveQuitAlert(alert) { codes.append($0) })
        XCTAssertEqual(codes, [WindowCoordinator.workFinishedWhileAsking])
        XCTAssertNil(ShrikeAlert.index(of: WindowCoordinator.workFinishedWhileAsking, buttonCount: 2),
                     "a code of its own, mapped to Quit Anyway by the alert's runner, not by index(of:)")
    }
}

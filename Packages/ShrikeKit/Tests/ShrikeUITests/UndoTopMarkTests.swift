//
//  UndoTopMarkTests.swift
//  ShrikeUITests
//
//  R5d (pass 2r): a notice's Undo button undoes its own action only.
//

import XCTest
@testable import ShrikeUI

@MainActor
final class UndoTopMarkTests: XCTestCase {

    private final class Log { var undone: [String] = [] }

    private func register(_ name: String, on undo: UndoManager, log: Log) {
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: log) { $0.undone.append(name) }
        undo.setActionName("Copy")   // same name for both: names are not compared
        undo.endUndoGrouping()
    }

    private func manager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    func testANoticeUndoDoesNotUndoALaterAction() {
        let undo = manager(), log = Log(), mark = UndoTopMark()
        register("A", on: undo, log: log)
        let a = mark.stamp(undo)
        register("B", on: undo, log: log)
        XCTAssertFalse(mark.undo(a, on: undo), "A is no longer the latest")
        XCTAssertEqual(log.undone, [], "B is not undone")
        XCTAssertTrue(undo.canUndo)
    }

    func testANoticeUndoUndoesItsOwnActionWhenOnTop() {
        let undo = manager(), log = Log(), mark = UndoTopMark()
        register("B0", on: undo, log: log)
        _ = mark.stamp(undo)
        register("A", on: undo, log: log)
        let a = mark.stamp(undo)
        XCTAssertTrue(mark.undo(a, on: undo))
        XCTAssertEqual(log.undone, ["A"])
        XCTAssertFalse(mark.undo(a, on: undo), "a second press undoes nothing more")
        XCTAssertEqual(log.undone, ["A"])
    }

    func testAnUndoFromTheMenuEndsTheNoticeUndo() {
        let undo = manager(), log = Log(), mark = UndoTopMark()
        register("A", on: undo, log: log)
        let a = mark.stamp(undo)
        undo.undo()   // Edit ▸ Undo
        XCTAssertFalse(mark.undo(a, on: undo))
        XCTAssertEqual(log.undone, ["A"])
    }

    /// The app's undo managers group by event: one group per run-loop turn.
    func testGroupsByEventLaterActionIsNotUndoneByTheNotice() {
        let undo = UndoManager(), log = Log(), mark = UndoTopMark()
        var changes = 0
        mark.onChange = { changes += 1 }
        undo.registerUndo(withTarget: log) { $0.undone.append("A") }
        let a = mark.stamp(undo)
        XCTAssertTrue(mark.isTop(a, on: undo), "positive control: A is on top")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(mark.isTop(a, on: undo), "closing A's group changes nothing")
        undo.registerUndo(withTarget: log) { $0.undone.append("B") }
        XCTAssertGreaterThan(changes, 0, "the notice hears of B")
        XCTAssertFalse(mark.undo(a, on: undo))
        XCTAssertEqual(log.undone, [])
    }
}

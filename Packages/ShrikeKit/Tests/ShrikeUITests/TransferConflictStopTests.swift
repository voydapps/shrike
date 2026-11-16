//
//  TransferConflictStopTests.swift
//  ShrikeUITests
//
//  R5a (pass 2r): Quit Anyway with a conflict question up ends the question
//  as "stop" (a Skip that applies to nothing more), exactly once.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeIO
@testable import ShrikeCore

@MainActor
final class TransferConflictStopTests: XCTestCase {

    private func conflict() -> FileConflict {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shrike-r5a-\(UUID().uuidString)")
        return FileConflict(incoming: ImageGroup(primary: dir.appendingPathComponent("in/IMG_1.jpg")),
                            existing: [dir.appendingPathComponent("out/IMG_1.jpg")],
                            destinationFolder: dir.appendingPathComponent("out"), remainingConflicts: 3)
    }

    func testStopWhileTheQuestionIsUpAnswersStopOnce() async {
        let transfer = FileTransferCoordinator(window: nil)
        var ends: [NSApplication.ModalResponse] = []
        var answer: (@MainActor (NSApplication.ModalResponse) -> Void)?
        transfer.conflictAlertPresenter = { alert, completion in
            alert.suppressionButton?.state = .on   // "apply to remaining" ticked: must not stick
            answer = completion
            return { ends.append($0) }
        }
        let stop = TransferStop()
        var results: [ConflictAnswer] = []
        let task = Task { @MainActor in results.append(await transfer.askConflict(self.conflict(), stop: stop)) }
        for _ in 0..<100 where answer == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(answer, "the question is up")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(results.isEmpty, "waits for an answer while not stopped")
        stop.stop()
        await task.value
        XCTAssertEqual(results, [ConflictAnswer(.skip, applyToRemaining: false)])
        XCTAssertEqual(ends.count, 1, "the sheet is closed once")
        answer?(.alertSecondButtonReturn)   // a late click (sheet end): no second resume
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(results.count, 1)
    }

    func testAnAnswerWithoutAStopIsTheButton() async {
        let transfer = FileTransferCoordinator(window: nil)
        transfer.conflictAlertPresenter = { _, completion in
            Task { @MainActor in completion(.alertSecondButtonReturn) }
            return { _ in XCTFail("not ended by a stop") }
        }
        let result = await transfer.askConflict(conflict(), stop: TransferStop())
        XCTAssertEqual(result, ConflictAnswer(.replace))
    }
}

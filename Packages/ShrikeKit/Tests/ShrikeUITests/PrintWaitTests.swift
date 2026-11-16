//
//  PrintWaitTests.swift
//  ShrikeUITests
//
//  E-1, spec 28 §17.6: the wait before the print panel. Window-free.
//

import XCTest
@testable import ShrikeUI

final class PrintWaitTests: XCTestCase {

    func testNothingShowsUnder300ms() {
        XCTAssertEqual(PrintWait.decide(elapsed: .milliseconds(299), sinceProgress: .milliseconds(299), done: 0, total: 12, sheetShown: false, cancelled: false), .wait)
        XCTAssertEqual(PrintWait.decide(elapsed: .milliseconds(100), sinceProgress: .milliseconds(100), done: 12, total: 12, sheetShown: false, cancelled: false), .ready)
    }

    func testSheetAfter300msOnlyOnce() {
        XCTAssertEqual(PrintWait.decide(elapsed: .milliseconds(300), sinceProgress: .milliseconds(300), done: 3, total: 12, sheetShown: false, cancelled: false), .showSheet)
        XCTAssertEqual(PrintWait.decide(elapsed: .seconds(2), sinceProgress: .seconds(2), done: 3, total: 12, sheetShown: true, cancelled: false), .wait)
    }

    func testCancelWinsAndTimeoutPrintsTheRest() {
        XCTAssertEqual(PrintWait.decide(elapsed: .seconds(2), sinceProgress: .seconds(2), done: 3, total: 12, sheetShown: true, cancelled: true), .cancel)
        XCTAssertEqual(PrintWait.decide(elapsed: .seconds(60), sinceProgress: .seconds(60), done: 11, total: 12, sheetShown: true, cancelled: false), .timedOut)
    }

    /// The 60 s limit is per photo: a long selection that keeps loading never
    /// times out, a stall of 60 s does.
    func testTimeoutRestartsWhenAPhotoFinishes() {
        let start = ContinuousClock.now
        var clock = PrintWait.Clock(start: start)
        func step(_ seconds: Int, done: Int) -> PrintWait.Step {
            let now = start.advanced(by: .seconds(seconds))
            return PrintWait.decide(elapsed: now - start, sinceProgress: clock.sinceProgress(done: done, now: now),
                                    done: done, total: 12, sheetShown: true, cancelled: false)
        }
        XCTAssertEqual(step(50, done: 0), .wait)
        XCTAssertEqual(step(100, done: 1), .wait, "a photo finished at 100 s: 100 s overall is fine")
        XCTAssertEqual(step(150, done: 2), .wait)
        XCTAssertEqual(step(209, done: 2), .wait, "59 s since the last photo")
        XCTAssertEqual(step(210, done: 2), .timedOut, "60 s since the last photo")
    }

    func testTexts() {
        XCTAssertEqual(PrintWait.title, "Getting photos ready")
        XCTAssertEqual(PrintWait.progress(done: 3, total: 12), "3 of 12 photos")
        XCTAssertEqual(PrintWait.progress(done: 0, total: 1), "0 of 1 photo")
        XCTAssertNil(PrintWait.notLoadedLine(0))
        XCTAssertEqual(PrintWait.notLoadedLine(1), "1 photo couldn't be loaded.")
        XCTAssertEqual(PrintWait.notLoadedLine(2), "2 photos couldn't be loaded.")
    }

    /// The real wait: an unreadable file is done (failed) at once, so the
    /// panel would open without waiting and the page prints as a frame.
    @MainActor
    func testPrepareFinishesWithAnUnreadablePhotoAndCountsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("print-wait-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not a jpeg".utf8).write(to: broken)
        let controller = PrintController(pages: [PrintPage.read(broken)], printInfo: NSPrintInfo())
        controller.decodeAll()
        let ready = await controller.prepare(on: nil)
        XCTAssertTrue(ready)
        XCTAssertEqual(controller.notLoadedCount, 1)
        XCTAssertEqual(PrintWait.notLoadedLine(controller.notLoadedCount), "1 photo couldn't be loaded.")
        controller.finish()
    }

    /// The loading sheet: the alert's empty informative text is not a VoiceOver stop; the count line stays.
    @MainActor
    func testEmptyTextsLeaveTheAccessibilityTree() throws {
        let alert = ShrikeAlert.make(message: PrintWait.title, style: .informational, buttons: [.cancel()])
        let line = NSTextField(labelWithString: "")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 40))
        box.addSubview(line)
        alert.accessoryView = box
        alert.layout()
        let content = try XCTUnwrap(alert.window.contentView)
        PrintPrepSheet.hideEmptyTexts(in: content, keeping: line)
        func fields(_ view: NSView) -> [NSTextField] {
            view.subviews.flatMap { sub in ((sub as? NSTextField).map { [$0] } ?? []) + fields(sub) }
        }
        let empty = fields(content).filter { $0 !== line && $0.stringValue.isEmpty && !$0.isEditable }
        XCTAssertTrue(empty.allSatisfy(\.isHidden))
        XCTAssertFalse(line.isHidden, "the count line stays")
        XCTAssertTrue(fields(content).contains { $0.stringValue == PrintWait.title && !$0.isHidden })
    }
}

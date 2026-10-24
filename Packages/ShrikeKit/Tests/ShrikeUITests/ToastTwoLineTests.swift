//
//  ToastTwoLineTests.swift
//  ShrikeUITests
//
//  Spec 21b §5 (audit M4): a toast shows at most 2 lines and loses its tail,
//  never its middle. Every known message must fit in 2 lines at 448 pt, at 13
//  and 15 pt, even with a 255-character file name.
//

import XCTest
import AppKit
import ShrikeCore
import ShrikeIO
@testable import ShrikeUI

@MainActor
final class ToastTwoLineTests: XCTestCase {

    private let longName = String(repeating: "x", count: 251) + ".jpg"

    private func lines(_ text: String, size: CGFloat) -> Int {
        let font = NSFont.systemFont(ofSize: size)
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: 448, height: 10_000), options: [.usesLineFragmentOrigin],
            attributes: [.font: font])
        return Int((rect.height / NSLayoutManager().defaultLineHeight(for: font)).rounded())
    }

    private var messages: [String] {
        let group = ImageGroup(primary: URL(fileURLWithPath: "/Volumes/X/" + longName),
                               companions: [.init(url: URL(fileURLWithPath: "/Volumes/X/a.CR2"), kind: .raw)])
        let restored = ImageGroup(primary: URL(fileURLWithPath: "/Volumes/X/" + longName + "2"))
        let err = FileOpsError.readOnlyVolume(URL(fileURLWithPath: "/Volumes/X"))
        return [
            RotateCopy.viewOnlyRotate, RotateCopy.viewOnlyFlip,
            RotateCopy.browserSkipped, RotateCopy.browserSkippedFlip, RotateCopy.failed(longName),
            SaveCopy.saved(longName), SaveCopy.savedCopy(longName), SaveCopy.saveUndone(longName),
            SaveCopy.reverted(longName), SaveCopy.revertUndone(longName), SaveCopy.saveFailed(longName),
            SaveCopy.undoFailed(longName),
            FileActionCopy.movedToTrash([group]), FileActionCopy.movedToTrash([group, restored]),
            FileActionCopy.trashFailed(group, error: err), FileActionCopy.deleteFailed(group, error: err),
            FileActionCopy.putBack(original: group, restored: restored),
            FileActionCopy.noLongerInTrash(longName),
            ViewerWindow.edgeCopy(.next, current: longName, target: longName),
            ViewerWindow.edgeCopy(.previous, current: longName, target: nil),
            CompareSources.truncatedToast,
            "Uncheck Keep Photo to change this photo.",
            "The photo on screen no longer matches this edit. Your edits are still open. No file was changed.",
            "Opened 12 folders. Drop fewer folders to open the rest.",
            "Can’t open “\(FileNameFit.short(longName))”. Continuing after the interval.",
        ]
    }

    func testEveryKnownToastFitsInTwoLines() {
        for message in messages {
            for size in [CGFloat(13), 15] {
                XCTAssertLessThanOrEqual(lines(message, size: size), 2, "\(size) pt: \(message)")
            }
        }
    }

    func testToastWrapsToTwoLinesAndCutsTheTail() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let host = ToastHostView(placement: .viewer)
        host.install(in: container)
        let long = RotateCopy.viewOnlyRotate + " Use the Browser to rotate it."
        host.show(long)
        container.layoutSubtreeIfNeeded()
        let oneLine = ToastHostView.height
        XCTAssertGreaterThan(host.frame.height, oneLine, "two lines grow the pill")
        XCTAssertLessThanOrEqual(host.frame.height, oneLine + 20)
        XCTAssertLessThanOrEqual(lines(long, size: 13), 2, "the test string really is a two-line toast")
        XCTAssertLessThanOrEqual(host.frame.width, ToastHostView.maxWidth)
        func find(_ v: NSView) -> NSTextField? {
            if let f = v as? NSTextField, f.stringValue == long { return f }
            for s in v.subviews { if let f = find(s) { return f } }
            return nil
        }
        let label = try XCTUnwrap(find(host))
        XCTAssertEqual(label.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(label.cell?.truncatesLastVisibleLine, true, "the last line gets the ellipsis, never the middle")
        XCTAssertEqual(label.maximumNumberOfLines, 2)
        XCTAssertEqual(label.toolTip, long, "the full text stays in the tooltip")

        host.show("Short one.")
        container.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.height, oneLine, accuracy: 0.5, "one line keeps the 32 pt pill")

        // The 255-character name is shortened inside the sentence.
        let nameMessage = SaveCopy.saved(longName)
        XCTAssertLessThan(nameMessage.count, 110)
        XCTAssertTrue(nameMessage.contains("…") && nameMessage.contains(".jpg”"), nameMessage)
    }

    func testWorstCaseWithAnActionButtonStaysTwoLines() throws {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        let host = ToastHostView(placement: .viewer)
        host.install(in: container)
        host.show(ToastContent(FileActionCopy.movedToTrash(
            [ImageGroup(primary: URL(fileURLWithPath: "/x/" + longName))]),
            actionTitle: "Undo"), action: {})
        container.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(host.frame.height, ToastHostView.height + 20)
    }
}

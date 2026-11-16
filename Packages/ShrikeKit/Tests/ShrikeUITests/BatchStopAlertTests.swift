//
//  BatchStopAlertTests.swift
//  ShrikeUITests
//
//  Pass 2k Q3: an accessibility read reported `Keep Running` and `Stop`
//  at the same x. The built alert, laid out: the two buttons never
//  overlap, Keep Running (the safe choice) is the default, Stop is not.
//

import XCTest
import AppKit
@testable import ShrikeUI

@MainActor
final class BatchStopAlertTests: XCTestCase {

    func testStopAlertButtonsDoNotOverlapAndKeepRunningIsDefault() throws {
        let alert = ShrikeAlert.make(message: BatchWindowController.Copy.stopAlert,
                                     information: BatchModel.Copy.stopAlertInfo,
                                     buttons: BatchWindowController.stopAlertButtons)
        alert.layout()
        let buttons = alert.buttons
        XCTAssertEqual(buttons.count, 2)
        let keep = try XCTUnwrap(buttons.first { $0.title == BatchWindowController.Copy.keepRunning })
        let stop = try XCTUnwrap(buttons.first { $0.title == BatchWindowController.Copy.stop })
        let keepFrame = keep.convert(keep.bounds, to: nil)
        let stopFrame = stop.convert(stop.bounds, to: nil)
        XCTAssertGreaterThan(keepFrame.width, 0)
        XCTAssertGreaterThan(stopFrame.width, 0)
        // Side by side or stacked (long titles): never on top of each other.
        XCTAssertFalse(keepFrame.intersects(stopFrame), "\(keepFrame) vs \(stopFrame)")
        if abs(keepFrame.midY - stopFrame.midY) < 1 {
            XCTAssertLessThan(stopFrame.maxX, keepFrame.minX + 0.5, "Stop left, Keep Running right")
        }
        XCTAssertEqual(keep.keyEquivalent, "\r", "the safe choice is the default")
        XCTAssertNotEqual(stop.keyEquivalent, "\r")
        XCTAssertEqual(alert.window.defaultButtonCell, keep.cell as? NSButtonCell)
        // The accessibility frames follow the laid-out buttons.
        XCTAssertFalse(keep.accessibilityFrame().intersects(stop.accessibilityFrame()) && keep.accessibilityFrame().width > 0)
    }
}

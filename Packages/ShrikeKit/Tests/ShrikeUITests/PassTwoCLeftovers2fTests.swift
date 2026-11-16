//
//  PassTwoCLeftovers2fTests.swift
//  ShrikeUITests
//
//  The four leftovers of pass 2c: the edit-entry wait vs the unsaved-edits question, the
//  temporary sort column re-fit, grid menu parents with nothing selected, histogram tooltip rects.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PassTwoCLeftovers2fTests: XCTestCase {

    // (a)
    func testEditReentryWaitHoldsTheClockWhileTheQuestionIsUp() {
        XCTAssertEqual(EditReentryWait.step(questionOpen: true), .holdClock)
        XCTAssertEqual(EditReentryWait.step(questionOpen: false), .proceed)
        // Pass 2f2 task 7: Cancel of the question the wait saw drops the request at once;
        // Save / Discard (no Cancel counted) keep waiting.
        XCTAssertEqual(EditReentryWait.step(questionOpen: false, cancelledSinceAsked: true), .drop)
        XCTAssertEqual(EditReentryWait.step(questionOpen: true, cancelledSinceAsked: true), .drop)
        XCTAssertEqual(EditReentryWait.step(questionOpen: false, cancelledSinceAsked: false), .proceed)
    }

    // (b)
    func testTemporarySortColumnFitsTheListWidth() {
        let savedSort = BrowserSort.saved
        let savedHidden = Prefs.browserListHiddenColumns
        defer { savedSort.save(); Prefs.browserListHiddenColumns = savedHidden }
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.contentViewController = content
        window.setContentSize(NSSize(width: 1100, height: 400))
        content.setMode(.list)
        content.sort = BrowserSort(key: .name, direction: .ascending)
        window.contentView?.layoutSubtreeIfNeeded()
        let table = content.tableViewForTesting
        let clip = table.enclosingScrollView!.contentView.bounds.width
        content.sort = BrowserSort(key: .dateCaptured, direction: .ascending)
        XCTAssertEqual(table.frame.width, clip, accuracy: 2, "added: fits")
        content.sort = BrowserSort(key: .name, direction: .ascending)
        XCTAssertEqual(table.frame.width, clip, accuracy: 2, "removed: fits")
    }

    // (c)
    func testSubmenuParentsFollowTheModelWithNothingSelected() {
        let rows = GridContextMenuModel.rows(for: GridMenuState(selectedCount: 0, visibleCount: 3))
        for id in [GridMenuRow.ID.copyToFolder, .moveToFolder, .share, .externalEditor, .openWith, .rating] {
            XCTAssertEqual(rows.first { $0.id == id }?.enabled, false, id.rawValue)
        }
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        let menu = content.collectionContextMenuForTesting
        content.menuNeedsUpdate(menu)
        menu.update()   // AppKit's own validation runs too; it must not re-enable a parent
        for item in menu.items where item.submenu != nil {
            guard let id = BrowserContentViewController.gridRowID(of: item) else { continue }
            XCTAssertFalse(item.isEnabled, "\(id.rawValue) disabled with nothing selected")
        }
    }

    // (d)
    func testHistogramTooltipHasOneRectPerCorner() {
        let rects = HistogramPlotView.cornerTooltipRects(in: NSRect(x: 0, y: 0, width: 201, height: 80))
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].width + rects[1].width, 201)
        XCTAssertEqual(rects[0].maxX, rects[1].minX)
    }
}

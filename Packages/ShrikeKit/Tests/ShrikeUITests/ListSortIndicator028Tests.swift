//
//  ListSortIndicator028Tests.swift
//  ShrikeUITests
//
//  Spec 28 §13 (L-14): the sort arrow in the list view, the temporary column
//  for a sort with no column, and the header's accessibility value.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

final class ListSortIndicatorPlanTests: XCTestCase {

    func testSortsWithAColumnPutTheArrowOnIt() {
        let cases: [(BrowserSortKey, String)] = [
            (.name, "name"), (.dateModified, "date"), (.size, "size"), (.rating, "rating"), (.dimensions, "dim"),
        ]
        for (key, arrow) in cases {
            let plan = ListSortIndicator.plan(key: key, direction: .descending, hiddenColumnIDs: [])
            XCTAssertEqual(plan, ListSortIndicator(arrowKey: arrow, ascending: false, extraColumnTitle: nil), "\(key)")
        }
    }

    func testSortsWithoutAColumnAddOneNamedAfterTheSort() {
        let captured = ListSortIndicator.plan(key: .dateCaptured, direction: .ascending, hiddenColumnIDs: [])
        XCTAssertEqual(captured, ListSortIndicator(arrowKey: "sortvalue", ascending: true, extraColumnTitle: "Date Captured"))
        let kind = ListSortIndicator.plan(key: .kind, direction: .descending, hiddenColumnIDs: [])
        XCTAssertEqual(kind.extraColumnTitle, "Kind")
        XCTAssertFalse(kind.ascending)
    }

    func testAHiddenColumnCountsAsNoColumn() {
        let plan = ListSortIndicator.plan(key: .dimensions, direction: .ascending, hiddenColumnIDs: ["col.dim"])
        XCTAssertEqual(plan.extraColumnTitle, "Dimensions")
        XCTAssertEqual(plan.arrowKey, "sortvalue")
        let other = ListSortIndicator.plan(key: .dimensions, direction: .ascending, hiddenColumnIDs: ["col.rating"])
        XCTAssertNil(other.extraColumnTitle)
    }

    func testAccessibilityValueFollowsTheDirection() {
        XCTAssertEqual(ListSortIndicator.plan(key: .name, direction: .ascending, hiddenColumnIDs: []).accessibilityValue,
                       "ascending")
        XCTAssertEqual(ListSortIndicator.plan(key: .name, direction: .descending, hiddenColumnIDs: []).accessibilityValue,
                       "descending")
    }

    func testTitlesMatchTheSortByMenu() {
        let pairs: [(BrowserSortKey, ShrikeCommand)] = [
            (.name, .sortByName), (.dateCaptured, .sortByDateCaptured), (.dateModified, .sortByDateModified),
            (.size, .sortBySize), (.rating, .sortByRating), (.kind, .sortByKind), (.dimensions, .sortByDimensions),
        ]
        for (key, command) in pairs { XCTAssertEqual(ListSortIndicator.title(of: key), command.title) }
    }
}

@MainActor
final class ListSortIndicatorWindowTests: XCTestCase {

    private var savedSort = BrowserSort.saved
    private var savedHidden: [String] = []

    override func setUp() {
        super.setUp()
        savedSort = BrowserSort.saved
        savedHidden = Prefs.browserListHiddenColumns
    }

    /// The sort and the hidden columns are saved settings: later Browser tests must not see these.
    override func tearDown() {
        savedSort.save()
        Prefs.browserListHiddenColumns = savedHidden
        super.tearDown()
    }

    private func makeList() -> (BrowserContentViewController, NSTableView) {
        let content = BrowserContentViewController(services: ShrikeServices.makeDefault())
        _ = content.view
        content.setMode(.list)
        content.sort = BrowserSort(key: .name, direction: .ascending)
        return (content, content.tableViewForTesting)
    }

    private func extraColumn(_ table: NSTableView) -> NSTableColumn? {
        table.tableColumns.first { $0.identifier.rawValue == ListSortIndicator.extraColumnID }
    }

    func testTheExtraColumnComesAndGoesWithTheSort() throws {
        let (content, table) = makeList()
        let base = table.tableColumns.count
        XCTAssertNil(extraColumn(table))

        content.sort = BrowserSort(key: .dateCaptured, direction: .ascending)
        let extra = try XCTUnwrap(extraColumn(table))
        XCTAssertEqual(extra.title, "Date Captured")
        XCTAssertTrue(table.tableColumns.last === extra, "the column is the last one")
        XCTAssertEqual(table.tableColumns.count, base + 1)
        XCTAssertNotNil(table.indicatorImage(in: extra))

        content.sort = BrowserSort(key: .kind, direction: .ascending)
        XCTAssertEqual(table.tableColumns.count, base + 1, "one temporary column, renamed")
        XCTAssertEqual(try XCTUnwrap(extraColumn(table)).title, "Kind")

        content.sort = BrowserSort(key: .name, direction: .ascending)
        XCTAssertNil(extraColumn(table))
        XCTAssertEqual(table.tableColumns.count, base)
    }

    func testASecondClickOnTheHeaderFlipsTheDirectionAndTheMenuState() throws {
        let (content, table) = makeList()
        content.sort = BrowserSort(key: .dateCaptured, direction: .ascending)
        // AppKit flips the arrow of the clicked sorted column; the table reports it here.
        table.sortDescriptors = [NSSortDescriptor(key: ListSortIndicator.extraKey, ascending: false)]
        XCTAssertEqual(content.sort, BrowserSort(key: .dateCaptured, direction: .descending),
                       "the key stays, the direction flips (Sort By ▸ Descending reads this)")
        XCTAssertEqual(table.sortDescriptors.first?.ascending, false)
        // A click on another header sorts by that column.
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: true)]
        XCTAssertEqual(content.sort, BrowserSort(key: .size, direction: .ascending))
        XCTAssertNil(extraColumn(table))
    }

    func testTheSortedHeaderReadsAscendingOrDescending() throws {
        let (content, table) = makeList()
        let name = try XCTUnwrap(table.tableColumns.first { $0.sortDescriptorPrototype?.key == "name" })
        XCTAssertEqual(name.headerCell.accessibilityValue() as? String, "ascending")
        content.sort = BrowserSort(key: .name, direction: .descending)
        XCTAssertEqual(name.headerCell.accessibilityValue() as? String, "descending")
        content.sort = BrowserSort(key: .size, direction: .descending)
        XCTAssertNil(name.headerCell.accessibilityValue(), "only the sorted header has a value")
    }

    func testTheExtraColumnIsNotInTheColumnsMenuOrTheSavedLayout() throws {
        let (content, _) = makeList()
        content.sort = BrowserSort(key: .kind, direction: .ascending)
        let menu = try XCTUnwrap(content.headerMenuForTesting)
        XCTAssertFalse(menu.items.contains { $0.title == "Kind" })
        XCTAssertFalse(Prefs.browserListHiddenColumns.contains(ListSortIndicator.extraColumnID))
        content.sort = BrowserSort(key: .name, direction: .ascending)
    }

    func testAHiddenSortedColumnMovesTheArrowToTheExtraColumn() throws {
        let (content, table) = makeList()
        let saved = Prefs.browserListHiddenColumns
        defer { Prefs.browserListHiddenColumns = saved; content.sort = BrowserSort(key: .name, direction: .ascending) }
        Prefs.browserListHiddenColumns = []
        content.sort = BrowserSort(key: .rating, direction: .descending)
        XCTAssertNil(extraColumn(table))
        let item = try XCTUnwrap(content.headerMenuForTesting?.items.first { $0.title == "Rating" })
        content.toggleListColumn(item)   // hide Rating
        XCTAssertEqual(extraColumn(table)?.title, "Rating")
        content.toggleListColumn(item)   // show it again
        XCTAssertNil(extraColumn(table))
    }

    /// 28a B.10: after the re-fit, and after Kind → Date Captured, the date
    /// column is at least as wide as a formatted date needs.
    func testDateColumnKeepsTheWidthItsDateNeeds() throws {
        let (content, table) = makeList()
        let needed = BrowserContentViewController.sortColumnWidth(
            sample: BrowserContentViewController.sortColumnSample(.dateCaptured), font: BrowserContentViewController.listFont)
        content.sort = BrowserSort(key: .dateCaptured, direction: .ascending)
        table.sizeToFit()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(extraColumn(table)).width, needed)
        content.sort = BrowserSort(key: .kind, direction: .ascending)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(extraColumn(table)).width, 100)
        content.sort = BrowserSort(key: .dateCaptured, direction: .ascending)
        table.sizeToFit()
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(extraColumn(table)).width, needed, "after Kind → Date Captured")
    }
}

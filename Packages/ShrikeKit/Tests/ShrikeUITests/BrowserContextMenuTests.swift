//
//  BrowserContextMenuTests.swift
//  ShrikeUITests
//
//  Spec 25 §12: the Browser's right-click menu has Copy to Folder, Move to
//  Folder and Rename….
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class BrowserContextMenuTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-ctxmenu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMenuEndsWithTheNewRowsInOrder() {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let titles = browser.contentController.contextMenuTitlesForTesting
        XCTAssertEqual(Array(titles.suffix(8)),
                       ["Rating", "Flag", "—", "Copy to Folder", "Move to Folder", "Rename…", "—",
                        "Move to Trash"])
        XCTAssertEqual(titles.first, "Open")
    }

    func testDestinationSubmenusFillFromTheBrowserSlots() throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy to Folder" })
        let move = try XCTUnwrap(menu.items.first { $0.title == "Move to Folder" })
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" })
        XCTAssertEqual(copy.representedObject as? String, ShrikeCommand.copyToFolder.rawValue)
        XCTAssertEqual(move.representedObject as? String, ShrikeCommand.moveToFolder.rawValue)
        XCTAssertEqual(rename.representedObject as? String, ShrikeCommand.rename.rawValue)
        for parent in [copy, move] {
            let submenu = try XCTUnwrap(parent.submenu)
            content.menuNeedsUpdate(submenu)
            XCTAssertEqual(submenu.items.last?.title, "Choose Folder…")
            XCTAssertEqual(submenu.items.last?.representedObject as? String,
                           parent === copy ? ShrikeCommand.copyToFolder.rawValue : ShrikeCommand.moveToFolder.rawValue)
        }
    }
    /// §12.1: Rename… is enabled for one photo and disabled for two (Batch…
    /// is the route for several); Copy / Move stay enabled.
    func testRenameIsEnabledForOnePhotoAndDisabledForTwo() async throws {
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        for url in [a, b] { try Data([0xFF, 0xD8, 0xFF]).write(to: url) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        await browser.listingTask?.value
        XCTAssertEqual(content.visibleItems.count, 2)
        let menu = try XCTUnwrap(content.collectionViewForTesting.menu)
        let rename = try XCTUnwrap(menu.items.first { $0.title == "Rename…" })
        let move = try XCTUnwrap(menu.items.first { $0.title == "Move to Folder" })

        XCTAssertTrue(content.select(url: a))
        XCTAssertTrue(browser.validateMenuItem(rename), "one selected: Rename… works")
        XCTAssertTrue(browser.canPerform(.moveToFolder))

        content.selectAll()
        XCTAssertEqual(content.selectedItems.count, 2)
        XCTAssertFalse(browser.validateMenuItem(rename), "two selected: Rename… is disabled")
        XCTAssertTrue(browser.canPerform(.moveToFolder), "Move to Folder acts on the whole selection")
        XCTAssertNotNil(move.submenu)
        // F2 and the File menu's Rename… still reach the batch rename.
        XCTAssertTrue(browser.canPerform(.rename))
    }
}

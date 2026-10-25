//
//  ContextMenuOrder028Tests.swift
//  ShrikeUITests
//
//  Spec 27 P3-12: the viewer's and the Browser's right-click menus share
//  one order and one set of words for what they share.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ContextMenuOrder028Tests: XCTestCase {

    func testSharedRowsAreInTheSameOrderWithTheSameWords() throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-ctxorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)

        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()

        let browserTitles = browser.contentController.contextMenuTitlesForTesting.filter { $0 != "—" }
        let viewerTitles = viewer.contextMenu.menu.items.filter { !$0.isSeparatorItem }
            .map { MenuKeyHints.baseTitle(of: $0) }

        let shared = ["Open in External Editor", "Reveal in Finder", "Share",
                      ShrikeCommand.slideshow.title, ShrikeCommand.batch.title, ShrikeCommand.compare.title,
                      "Rating", ShrikeCommand.toggleFlag.title,
                      ShrikeCommand.copyToFolder.title, ShrikeCommand.moveToFolder.title,
                      ShrikeCommand.rename.title, ShrikeCommand.moveToTrash.title]
        XCTAssertEqual(browserTitles.filter(shared.contains), shared)
        XCTAssertEqual(viewerTitles.filter(shared.contains), shared)
        XCTAssertTrue(viewerTitles.contains(ShrikeCommand.slideshow.title))
        XCTAssertTrue(viewerTitles.contains(ShrikeCommand.batch.title))
    }
}

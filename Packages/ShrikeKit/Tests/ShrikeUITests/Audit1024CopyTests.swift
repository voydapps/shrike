//
//  Audit1024CopyTests.swift
//  ShrikeUITests
//
//  Wording and menu decisions from spec 21b (audit 2026-10-24).
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class Audit1024CopyTests: XCTestCase {

    func testHelpMenuOpensTheWebsiteAndTheIssuesPage() throws {
        let commands = AppCommands(coordinator: WindowCoordinator())
        let bar = ShrikeMainMenu(appCommands: commands)
        let titles = bar.helpMenu.items.map(\.title)
        XCTAssertTrue(titles.contains("Shrike Website"), "\(titles)")
        XCTAssertTrue(titles.contains("Report a Problem…"), "\(titles)")
        var opened: [URL] = []
        commands.openURLForTesting = { opened.append($0) }
        for title in ["Shrike Website", "Report a Problem…"] {
            let item = try XCTUnwrap(bar.helpMenu.items.first { $0.title == title })
            _ = (item.target as AnyObject?)?.perform(item.action, with: item)
        }
        XCTAssertEqual(opened.map(\.absoluteString),
                       ["https://voydapps.github.io/shrike", "https://github.com/voydapps/shrike/issues"])
    }

    func testCompareOptionsSubmenuIsCompareOnlyAndNamedOnce() {
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        let view = bar.menu.items.first { $0.submenu?.title == "View" }!.submenu!
        XCTAssertNil(view.items.first { $0.title == "Compare Window" })
        let options = view.items.first { $0.title == "Compare Options" }
        XCTAssertNotNil(options)
        XCTAssertEqual(options?.submenu?.items.map(\.title), ["Keep Focused Photo", "Sync Zoom and Pan", "Fit All"])
        XCTAssertTrue(options!.isHidden, "no Compare items unless a Compare window is main")
        bar.apply(surface: .browser)
        XCTAssertTrue(options!.isHidden, "no Compare items in the Browser menu bar")
        bar.apply(surface: .viewer)
        XCTAssertTrue(options!.isHidden, "none in a viewer either")
        XCTAssertTrue(bar.compareOptionsRow === options)
        let edit = bar.menu.items.first { $0.submenu?.title == "Edit" }!.submenu!
        XCTAssertNil(edit.items.first { $0.submenu?.title == "Find" }, "Find… sits directly in Edit")
        XCTAssertNotNil(edit.items.first { $0.title == "Find…" })
    }

    func testBigCountsGetThousandsSeparators() {
        let f = 12000.formatted(.number)
        XCTAssertTrue(f != "12000", "locale groups digits")
        XCTAssertEqual(WindowTitles.viewerSubtitle(index: 9, total: 12000, pixelSize: nil), "10 of \(f)")
        XCTAssertEqual(WindowTitles.browserSubtitle(visible: 12000, total: 12000), "\(f) photos")
    }

    func testWordPhotoNotImage() {
        XCTAssertEqual(ShrikeCommand.nextImage.title, "Next Photo")
        XCTAssertEqual(ShrikeCommand.editImage.title, "Edit Photo")
        XCTAssertEqual(ShrikeCommand.saveAs.title, "Save Copy…")
        XCTAssertEqual(ShrikeCommand.compareFitAll.title, "Fit All")
    }
}

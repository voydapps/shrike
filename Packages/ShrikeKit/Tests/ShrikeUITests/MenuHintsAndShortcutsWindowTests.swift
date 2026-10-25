//
//  MenuHintsAndShortcutsWindowTests.swift
//  ShrikeUITests
//
//  Spec 25 §13 (bare-key hints in menus, the searchable shortcuts window)
//  and §14 (⌘W on a Browser after its viewer closed: run and report).
//

import AppKit
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class MenuHintsAndShortcutsWindowTests: XCTestCase {

    private var savedPreset: ShortcutPreset!

    override func setUp() async throws {
        savedPreset = Prefs.shortcutPreset
        Prefs.shortcutPreset = .macNative
    }

    override func tearDown() async throws {
        Prefs.shortcutPreset = savedPreset
    }

    private func bar() -> ShrikeMainMenu {
        ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
    }

    // MARK: Hints (§13.4 vectors 1, 2, 6)

    func testHintsFollowThePresetAndNoMenuHasABareKeyEquivalent() throws {
        let bar = bar()
        bar.applyKeyHints()   // drawn when a menu opens, not at launch
        let rate3 = try XCTUnwrap(bar.items(for: .rate3).first)
        let flag = try XCTUnwrap(bar.items(for: .toggleFlag).first)
        XCTAssertEqual(rate3.badge?.stringValue, "3")
        XCTAssertEqual(flag.badge?.stringValue, "Q")
        XCTAssertEqual(MenuKeyHints.baseTitle(of: flag), ShrikeCommand.toggleFlag.title)

        func bareKeys(_ menu: NSMenu) -> [String] {
            menu.items.flatMap { item -> [String] in
                var found = (item.keyEquivalent.count == 1 && item.keyEquivalentModifierMask.intersection([.command, .option, .control]).isEmpty
                             && !item.keyEquivalent.unicodeScalars.contains { $0.value >= 0xF700 }) ? [item.title] : []
                if let sub = item.submenu { found += bareKeys(sub) }
                return found
            }
        }
        XCTAssertEqual(bareKeys(bar.menu), [], "no bare-key keyEquivalent in any menu")

        // FastStone: the rating keys are ⌃1…⌃5 (modified), so no hint; the hint set follows the preset.
        MenuKeyHints.apply(to: bar.menu, context: .viewer, preset: .fastStoneCompat)
        XCTAssertNil(rate3.badge, "no hint for a modified key")
        MenuKeyHints.apply(to: bar.menu, context: .viewer, preset: .macNative)
        XCTAssertEqual(rate3.badge?.stringValue, "3")
    }

    func testRenameAndSlideshowShowAsRealFunctionKeys() throws {
        let bar = bar()
        XCTAssertEqual(bar.items(for: .rename).first?.keyEquivalent, SpecialKey.f2, "F2 is a real key equivalent")
        XCTAssertEqual(bar.items(for: .slideshow).first?.keyEquivalent, SpecialKey.f5, "F5 is a real key equivalent")
    }

    // MARK: Viewer context menu (§12.3 vector 4)

    func testViewerMenuOrderIsUnchanged() {
        let viewer = ViewerWindow(groups: [ImageGroup(primary: URL(fileURLWithPath: "/tmp/a.jpg"))],
                                  startIndex: 0, services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let commands = viewer.contextMenu.menu.items.compactMap { $0.shrikeCommand }
        XCTAssertEqual(commands, [.toggleRAWFile, .revealInFinder, .showInBrowser, .share, .slideshow, .batch, .compare, .rotateLeft, .rotateRight, .editImage,
                                  .toggleFlag, .tags, .copyToFolder, .moveToFolder, .rename, .revertToOriginal,
                                  .copy, .copyPath, .moveToTrash])
    }

    // MARK: Shortcuts window (§13.4 vectors 4, 5)

    func testSectionsHaveCompareWithPaneKeys() {
        let compare = ShortcutsTab.sections(for: .macNative).first { $0.title == "Compare" }
        XCTAssertTrue(compare?.rows.contains(ShortcutsTab.Row(action: "Next Pane", keys: "⇥")) ?? false)
        XCTAssertTrue(compare?.rows.contains(ShortcutsTab.Row(action: "Previous Pane", keys: "⇧⇥")) ?? false)
    }

    func testSearchFindsByTitleKeyAndSection() {
        let all = ShortcutsTab.sections(for: .macNative)
        let flag = ShortcutsFilter.filter(all, query: "flag")
        XCTAssertTrue(flag.count >= 2, "Flag exists in more than one context")
        XCTAssertTrue(flag.allSatisfy { $0.rows.contains { $0.action.localizedCaseInsensitiveContains("flag") } })
        let trash = ShortcutsFilter.filter(all, query: "⌘⌫")
        XCTAssertTrue(trash.flatMap(\.rows).contains { $0.action == "Move to Trash" })
        XCTAssertTrue(ShortcutsFilter.filter(all, query: "zzz").isEmpty)
        XCTAssertEqual(ShortcutsFilter.filter(all, query: "").count, all.count)
        XCTAssertTrue(ShortcutsFilter.filter(all, query: "compare").contains { $0.title == "Compare" }, "section title matches")
    }

    func testWindowOpensAndRefreshesWithThePreset() {
        let controller = ShortcutsWindowController.shared
        controller.show()
        defer { controller.window?.close() }
        XCTAssertTrue(controller.isOpen)
        XCTAssertEqual(controller.window?.title, "Keyboard Shortcuts")
        XCTAssertEqual(controller.modelForTesting.presetLine, "Mac preset")
        Prefs.shortcutPreset = .fastStoneCompat
        controller.modelForTesting.refresh()
        XCTAssertEqual(controller.modelForTesting.presetLine, "FastStone preset")
    }

    // MARK: §14 — ⌘W after the viewer closed (run and report; nothing is fixed here)
    //
    // Result, 2026-10-11: a ⌘W built as a real NSEvent and sent with NSApp.sendEvent does NOT reach
    // the main menu's Close item in the XCTest process for ANY window (the first ⌘W on the paired
    // viewer fails the same way as the second on the Browser), so that path is a synthetic-key
    // artefact and says nothing about the Browser. The test below runs what the Close item does
    // (`performClose` on the key window) and asserts the spec's outcome. A real key press needs the
    // app to be launched; that was not done here.

    private func closeBrowserAfterViewerClosed(searchFieldFocused: Bool) async throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-cmdw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<30 { try Data([0xFF, 0xD8, 0xFF]).write(to: dir.appendingPathComponent(String(format: "p%03d.jpg", i))) }

        let coordinator = WindowCoordinator()
        coordinator.services = ShrikeServices.makeDefault()
        let browser = coordinator.openBrowser(at: dir, selecting: nil, services: coordinator.services!)
        let window = try XCTUnwrap(browser.window)
        window.makeKeyAndOrderFront(nil)
        await browser.listingTask?.value
        XCTAssertEqual(browser.contentController.visibleItems.count, 30, "the listing finished with all 30 photos")

        browser.dispatch(.openInViewer)
        let viewer = try XCTUnwrap(browser.pairedViewer, "the paired viewer opened")
        viewer.makeKeyAndOrderFront(nil)
        viewer.performClose(nil)
        try await Task.sleep(for: .milliseconds(200))

        window.makeKeyAndOrderFront(nil)
        if searchFieldFocused { browser.focusSearch() } else { window.makeFirstResponder(browser.contentController.view) }
        window.performClose(nil)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(coordinator.browsers.contains { $0 === browser }, "the Browser closed and left the coordinator")
        XCTAssertFalse(NSApp.keyWindow === window, "the key window is another window or none")
    }

    func testCloseReachesTheBrowserAfterItsViewerClosed_gridFocused() async throws {
        try await closeBrowserAfterViewerClosed(searchFieldFocused: false)
    }

    func testCloseReachesTheBrowserAfterItsViewerClosed_searchFieldFocused() async throws {
        try await closeBrowserAfterViewerClosed(searchFieldFocused: true)
    }
}

//
//  MainMenuTests.swift
//  ShrikeUITests
//
//  The menu bar: keys come from the shortcut
//  table, no two visible items share a key on any surface, hidden items
//  carry no key, and validation follows the main window's kind.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
private func makeBar() -> ShrikeMainMenu {
    ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
}

/// Visible items, skipping hidden items and everything under them.
@MainActor
private func visibleItems(_ menu: NSMenu) -> [NSMenuItem] {
    var out: [NSMenuItem] = []
    for item in menu.items where !item.isHidden && !item.isSeparatorItem {
        out.append(item)
        if let sub = item.submenu { out += visibleItems(sub) }
    }
    return out
}

@MainActor
final class MenuKeyUniquenessTests: XCTestCase {

    func testNoTwoVisibleItemsShareAKeyOnAnySurface() {
        let bar = makeBar()
        bar.fillEditors()
        bar.fillDestinations(bar.copyToMenu, command: .copyToFolder)
        bar.fillDestinations(bar.moveToMenu, command: .moveToFolder)
        for surface in [MenuSurface.browser, .viewer, .viewerEditMode, .other] {
            bar.apply(surface: surface)
            var seen: [String: String] = [:]
            for item in visibleItems(bar.menu) where !item.keyEquivalent.isEmpty {
                let mods = item.keyEquivalentModifierMask.intersection(KeyBinding.relevantModifiers)
                let id = "\(mods.rawValue)|\(item.keyEquivalent.lowercased())"
                XCTAssertNil(seen[id], "\(surface): “\(item.title)” and “\(seen[id] ?? "")” share a key")
                seen[id] = item.title
                if mods.intersection([.command, .option, .control]).isEmpty {
                    XCTAssertTrue(SpecialKey.isFunctionKey(item.keyEquivalent),
                                  "\(surface): bare key on “\(item.title)”")
                }
            }
        }
    }

    func testHiddenItemsCarryNoKey() {
        let bar = makeBar()
        for surface in [MenuSurface.browser, .viewer] {
            bar.apply(surface: surface)
            for item in bar.allItems where item.isHidden {
                XCTAssertEqual(item.keyEquivalent, "", "\(surface): hidden “\(item.title)” keeps a key")
            }
        }
        // Shared keys: the other surface's item is hidden.
        bar.apply(surface: .browser)
        XCTAssertFalse(bar.items(for: .viewAsGrid)[0].isHidden)
        XCTAssertTrue(bar.items(for: .actualSize)[0].isHidden)
        XCTAssertFalse(bar.items(for: .enclosingFolder)[0].isHidden)
        bar.apply(surface: .viewer)
        XCTAssertEqual(bar.items(for: .actualSize)[0].keyEquivalent, "1")
        XCTAssertEqual(bar.items(for: .zoomIn)[0].keyEquivalent, "+")
        XCTAssertTrue(bar.items(for: .largerThumbnails)[0].isHidden)
        XCTAssertTrue(bar.items(for: .enclosingFolder)[0].isHidden)
        // Neither main (Settings, Welcome): the last set stays.
        bar.apply(surface: .other)
        XCTAssertEqual(bar.surface, .viewer)
        XCTAssertFalse(bar.items(for: .actualSize)[0].isHidden)
    }

    func testEveryKeyComesFromTheShortcutTable() {
        let bar = makeBar()
        bar.apply(surface: .viewer)
        for command in ShrikeCommand.allCases {
            for item in bar.items(for: command) where !item.isHidden && !item.keyEquivalent.isEmpty {
                let binding = ShortcutTable.menuBinding(for: command)
                XCTAssertEqual(item.keyEquivalent, binding?.menuKeyEquivalent, "\(command)")
                XCTAssertEqual(item.keyEquivalentModifierMask, binding?.modifiers, "\(command)")
            }
        }
        XCTAssertEqual(bar.items(for: .editImage).first?.keyEquivalent, "e")
        XCTAssertEqual(bar.items(for: .moveToTrash).first?.keyEquivalent, "\u{8}")
        XCTAssertEqual(bar.items(for: .rename).first?.keyEquivalent, SpecialKey.f2)
        // Bare-key commands carry no key.
        XCTAssertEqual(bar.items(for: .nextImage).first?.keyEquivalent, "")
        XCTAssertEqual(bar.items(for: .toggleFlag).first?.keyEquivalent, "")
    }

    func testMenuItemsExistForEveryCommand() {
        let bar = makeBar()
        let commands: [ShrikeCommand] = [.levels, .autoContrast, .autoColor, .compare, .batch,
                                     .showInMaps, .pageSetup, .print, .exportContactSheet,
                                     .openExternalEditor1]
        for command in commands {
            XCTAssertFalse(bar.items(for: command).isEmpty, "\(command) missing")
        }
        let titles = Set(bar.menu.items.map(\.title))
        XCTAssertEqual(titles, ["Shrike", "File", "Edit", "View", "Image", "Go", "Window", "Help"])
        XCTAssertFalse(bar.allItems.contains { $0.title == "Shrike Help" }, "no Help item named after the app")
        XCTAssertEqual(bar.items(for: .keyboardShortcuts).first?.keyEquivalent, "/")
        XCTAssertFalse(bar.items(for: .welcome).isEmpty)
    }

    func testLazySubmenusFillOnDemand() {
        let bar = makeBar()
        XCTAssertTrue(bar.openRecentMenu.items.isEmpty, "Open Recent is empty until opened")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shrike-recent")
        bar.recentURLs = { [dir, dir.appendingPathComponent("x.jpg")] }
        bar.menuNeedsUpdate(bar.openRecentMenu)
        let titles = bar.openRecentMenu.items.map(\.title)
        XCTAssertEqual(titles.last, "Clear Menu")
        XCTAssertEqual(bar.openRecentMenu.items.first?.representedObject as? URL, dir)
        bar.menuNeedsUpdate(bar.copyToMenu)
        XCTAssertEqual(bar.copyToMenu.items.last?.title, "Choose Folder…")
        bar.menuNeedsUpdate(bar.fileMenu)
        XCTAssertEqual(bar.items(for: .share).first?.isEnabled, false, "nothing to share")
    }
}

@MainActor
final class MenuValidationTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["a.jpg", "b.jpg"] { try Data([0]).write(to: dir.appendingPathComponent(name)) }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func item(_ bar: ShrikeMainMenu, _ command: ShrikeCommand) -> NSMenuItem {
        bar.items(for: command)[0]
    }

    func testViewerValidation() {
        let bar = makeBar()
        let urls = ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) }
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        XCTAssertEqual(MenuSurface.of(viewer), .viewer)
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .moveToTrash)), "no displayed item")
        viewer.markDisplayedForTesting(0)
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .moveToTrash)))
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .copy)))
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .copyPath)))
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .nextImage)))
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .previousImage)), "at the start")
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .save)), "not in edit mode")
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .resetEdits)))
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .toggleInspector)))
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .showInBrowser)))
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .viewAsGrid)), "Browser command")
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .levels)), "Levels needs edit mode")
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .compare)), "the shown photo and the next")
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .batch)), "the current list")
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .rename)), "rename")
        XCTAssertTrue(viewer.validateMenuItem(item(bar, .tags)), "tags")
        XCTAssertFalse(viewer.validateMenuItem(item(bar, .undo)), "nothing to undo")
    }

    func testBrowserValidation() {
        let bar = makeBar()
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        XCTAssertEqual(MenuSurface.of(browser.window), .browser)
        let grid = item(bar, .viewAsGrid)
        XCTAssertTrue(browser.validateMenuItem(grid))
        XCTAssertEqual(grid.state, .on)
        XCTAssertTrue(browser.validateMenuItem(item(bar, .sortByName)))
        XCTAssertTrue(browser.validateMenuItem(item(bar, .filter)))
        XCTAssertTrue(browser.validateMenuItem(item(bar, .enclosingFolder)))
        XCTAssertFalse(browser.validateMenuItem(item(bar, .back)), "no history")
        XCTAssertFalse(browser.validateMenuItem(item(bar, .moveToTrash)), "nothing selected")
        XCTAssertFalse(browser.validateMenuItem(item(bar, .deselectAll)), "nothing selected")
        XCTAssertFalse(browser.validateMenuItem(item(bar, .save)), "Viewer command")
        XCTAssertEqual(browser.validateMenuItem(item(bar, .exportContactSheet)),
                       !browser.contentController.visibleItems.isEmpty, "needs listed items")
        XCTAssertEqual(browser.validateMenuItem(item(bar, .batch)),
                       !browser.contentController.visibleItems.isEmpty, "needs listed items")
    }

    func testNoWindowLeavesOnlyAppCommandsEnabled() {
        let commands = AppCommands(coordinator: WindowCoordinator())
        let bar = ShrikeMainMenu(appCommands: commands)
        let appLevel: Set<ShrikeCommand> = [.newBrowserWindow, .open, .openFolder, .welcome,
                                           .settings, .keyboardShortcuts]
        for item in bar.allItems where item.submenu == nil {
            guard let command = item.shrikeCommand, let action = item.action else { continue }
            if appLevel.contains(command) {
                XCTAssertTrue(item.target === commands, "\(command) targets the app")
                XCTAssertTrue(commands.validateMenuItem(item))
            } else {
                XCTAssertNil(item.target, "\(command) goes to the responder chain")
                // Nothing outside a Browser or Viewer answers, so AppKit greys it.
                XCTAssertFalse(commands.responds(to: action), "\(command)")
                if action == ShrikeMainMenu.commandAction {
                    XCTAssertFalse(NSApplication.shared.responds(to: action))
                }
            }
        }
    }

    func testMenuCommandsReachTheSameActionsAsKeys() {
        XCTAssertEqual(ViewerKeyMap.action(for: .actualSize, context: .viewer), .zoomActualSize)
        XCTAssertEqual(BrowserKeyMap.action(for: .viewAsList), .viewModeList)
        XCTAssertEqual(BrowserWindowController.sortKey(for: .sortByKind), .kind)
    }
}

/// Cold build time of the whole bar. Run alone for a cold number:
/// `swift test --filter MainMenuBuildTimingTests`.
@MainActor
final class MainMenuBuildTimingTests: XCTestCase {
    func testMenuBuildIsCheap() {
        let clock = ContinuousClock()
        let start = clock.now
        let bar = makeBar()
        let cold = clock.now - start
        let warmStart = clock.now
        _ = makeBar()
        let warm = clock.now - warmStart
        print("SHRIKE_MENU_BUILD cold=\(cold) warm=\(warm) items=\(bar.allItems.count)")
        XCTAssertLessThan(cold, .milliseconds(100))
    }
}

/// No empty groups. On every surface, no menu starts or
/// ends on a visible separator or shows two in a row (the viewer's Edit
/// menu used to end on one, and AppKit adds its own before AutoFill).
@MainActor
final class MenuSeparatorTests: XCTestCase {

    private func check(_ menu: NSMenu, _ path: String, surface: MenuSurface, skip: [NSMenu]) {
        guard !skip.contains(where: { $0 === menu }) else { return }
        let shown = menu.items.filter { !$0.isHidden }
        if let first = shown.first {
            XCTAssertFalse(first.isSeparatorItem, "\(surface) \(path): starts with a separator")
        }
        if let last = shown.last {
            XCTAssertFalse(last.isSeparatorItem, "\(surface) \(path): ends with a separator")
        }
        for (a, b) in zip(shown, shown.dropFirst()) {
            XCTAssertFalse(a.isSeparatorItem && b.isSeparatorItem, "\(surface) \(path): two separators in a row")
        }
        for item in shown {
            if let sub = item.submenu { check(sub, path + " › " + item.title, surface: surface, skip: skip) }
        }
    }

    func testNoEmptyGroupsOnAnySurface() {
        let bar = makeBar()
        for surface in [MenuSurface.browser, .viewer, .viewerEditMode] {
            bar.apply(surface: surface)
            check(bar.menu, "bar", surface: surface, skip: [bar.windowMenu, bar.helpMenu, bar.servicesMenu])
        }
        // The viewer's Edit menu ends on Select All.
        bar.apply(surface: .viewer)
        let edit = bar.menu.items.first { $0.title == "Edit" }?.submenu
        XCTAssertEqual(edit?.items.last { !$0.isHidden }?.title, ShrikeCommand.selectAll.title)
    }

    func testViewerRightClickMenuHasNoEmptyGroups() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-sep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        viewer.contextMenu.menuNeedsUpdate(viewer.contextMenu.menu)
        check(viewer.contextMenu.menu, "context", surface: .viewer, skip: [])
    }
}

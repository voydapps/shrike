//
//  ExternalEditorsUITests.swift
//  ShrikeUITests
//
//  The Open in External Editor ▸ menus and
//  keys (both presets), the Settings tab's model (reads and writes the
//  registry only), the launch files (JPEG, RAW+JPEG with Send RAW on and
//  off, a Browser multi-selection) and the missing-app toast.
//
//  No app is ever launched: a fake workspace records every "open". The
//  editor apps are read-only system apps; no `.app` bundle is created.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
private final class RecordingWorkspace: ApplicationWorkspace {
    var appsByBundleID: [String: URL] = [:]
    private(set) var opened: [(urls: [URL], app: URL)] = []

    func urlForApplication(withBundleIdentifier bundleIdentifier: String) -> URL? {
        appsByBundleID[bundleIdentifier]
    }
    func urlsForApplications(toOpen url: URL) -> [URL] { [] }
    func urlForApplication(toOpen url: URL) -> URL? { nil }
    func open(_ urls: [URL], withApplicationAt applicationURL: URL) async throws {
        opened.append((urls, applicationURL))
    }
}

@MainActor
final class ExternalEditorsUITests: XCTestCase {

    private var dir: URL!
    private var workspace: RecordingWorkspace!
    private var registry: ExternalEditorRegistry!
    private var settingsOpened = 0
    private var savedOpenSettings: (() -> Void)!

    private let preview = URL(fileURLWithPath: "/System/Applications/Preview.app", isDirectory: true)
    private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app", isDirectory: true)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-editors-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspace = RecordingWorkspace()
        registry = ExternalEditorRegistry(defaults: makeTestDefaults(), workspace: workspace)
        ExternalEditors.registry = registry
        savedOpenSettings = ExternalEditors.openSettingsTab
        settingsOpened = 0
        ExternalEditors.openSettingsTab = { [weak self] in self?.settingsOpened += 1 }
    }

    override func tearDown() async throws {
        ExternalEditors.resetRegistryForTesting()
        ExternalEditors.openSettingsTab = savedOpenSettings
        Prefs.shortcutPreset = .macNative
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    private func writeJPEG(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func writeRAW(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0x49, 0x49, 0x2A, 0x00]).write(to: url)
        return url
    }

    @discardableResult
    private func addEditor(_ app: URL, sendRAW: Bool = false) throws -> ExternalEditor {
        var editor = ExternalEditor(applicationAt: app)
        editor.sendRAW = sendRAW
        try registry.add(editor)
        return editor
    }

    private func viewer(_ groups: [ShrikeCore.ImageGroup]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Menus and keys

    func testSubmenuListsEditorsWithOptionCommandKeysThenEditRow() throws {
        try addEditor(preview)
        try addEditor(textEdit)
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            Prefs.shortcutPreset = preset
            let menu = NSMenu()
            ExternalEditors.fill(menu, target: nil)
            let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
            XCTAssertEqual(titles, [registry.editors[0].displayName, registry.editors[1].displayName,
                                    "—", "Edit External Editors…"], "\(preset)")
            // Menus show ⌥⌘N in both presets (menu keys are
            // the same in both); the E / ⌥N preset keys work through the keymap.
            for (slot, item) in menu.items.prefix(2).enumerated() {
                XCTAssertEqual(item.keyEquivalent, "\(slot + 1)")
                XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
                XCTAssertEqual(item.shrikeCommand, ShrikeCommand.externalEditorCommands[slot])
            }
        }
    }

    func testEmptyRegistryShowsOnlySetUpRow() {
        let menu = NSMenu()
        ExternalEditors.fill(menu, target: nil)
        XCTAssertEqual(menu.items.map(\.title), ["Set Up External Editors…"])
        _ = (menu.items[0].target as? NSObject)?.perform(menu.items[0].action, with: menu.items[0])
        XCTAssertEqual(settingsOpened, 1, "the row opens Settings ▸ External Editors")
    }

    func testMenuBarSubmenuUsesTheRegistry() throws {
        try addEditor(preview)
        let bar = ShrikeMainMenu(appCommands: AppCommands(coordinator: WindowCoordinator()))
        bar.fillEditors()
        XCTAssertEqual(bar.editorsMenu.items.first?.title, registry.editors[0].displayName)
        XCTAssertEqual(bar.editorsMenu.items.last?.title, "Edit External Editors…")
    }

    func testKeysForBothPresetsInViewerAndBrowser() {
        for context in [ShrikeUI.ShortcutContext.viewer, ShrikeUI.ShortcutContext.browser] {
            for slot in 0..<9 {
                let command = ShrikeCommand.externalEditorCommands[slot]
                let mac = ShortcutTable.command(for: KeyEventSnapshot(key: "\(slot + 1)", modifiers: [.command, .option]),
                                                context: context, preset: .macNative)
                XCTAssertEqual(mac, command, "⌥⌘\(slot + 1) in \(context)")
                let fsKey = slot == 0 ? KeyEventSnapshot(key: "e")
                                      : KeyEventSnapshot(key: "\(slot + 1)", modifiers: [.option])
                XCTAssertEqual(ShortcutTable.command(for: fsKey, context: context, preset: .fastStoneCompat),
                               command, "FastStone slot \(slot + 1) in \(context)")
            }
        }
        XCTAssertEqual(ViewerKeyMap.action(for: KeyEventSnapshot(key: "e"), context: .viewer,
                                           preset: .fastStoneCompat),
                       .openExternalEditor(slot: 0))
        XCTAssertEqual(ViewerKeyMap.action(for: .openExternalEditor9, context: .viewer),
                       .openExternalEditor(slot: 8))
        XCTAssertEqual(BrowserKeyMap.action(for: .openExternalEditor3), .openExternalEditor(slot: 2))
    }

    func testContextMenusHaveTheSubmenu() throws {
        try addEditor(preview)
        let jpeg = try writeJPEG("a.jpg")
        let viewer = viewer([ImageGroup(primary: jpeg)])
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let row = try XCTUnwrap(viewer.contextMenu.menu.items.first { $0.title == "Open in External Editor" })
        let submenu = try XCTUnwrap(row.submenu)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        XCTAssertEqual(submenu.items.first?.title, registry.editors[0].displayName)
        XCTAssertTrue(submenu.items.first?.target === viewer, "rows go to the viewer")
    }

    // MARK: Settings tab model

    func testSettingsModelReadsAndWritesTheRegistry() throws {
        try addEditor(preview)
        let model = ExternalEditorsModel(registry: registry)
        XCTAssertEqual(model.editors.map(\.displayName), [registry.editors[0].displayName])
        XCTAssertEqual(model.keys(forSlot: 0), "⌥⌘1")
        XCTAssertEqual(model.keys(forSlot: 8), "⌥⌘9")

        XCTAssertTrue(model.addApplication(at: textEdit))
        XCTAssertEqual(registry.editors.count, 2)
        XCTAssertEqual(model.editors.count, 2, "the model follows the registry")
        XCTAssertFalse(model.addApplication(at: dir), "a folder is not an app")

        model.setSendRAW(true, slot: 1)
        XCTAssertTrue(registry.editors[1].sendRAW)

        let second = registry.editors[1].id
        model.move(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(registry.editors.first?.id, second, "drag to reorder moves the registry slot")
        XCTAssertEqual(model.editors.first?.id, second)

        model.selection = second
        model.removeSelected()
        XCTAssertEqual(registry.editors.count, 1)
        XCTAssertNil(model.selection)

        // Nothing is written to the old 3-slot list.
        XCTAssertTrue(Prefs.externalEditors.isEmpty)

        Prefs.shortcutPreset = .fastStoneCompat
        XCTAssertEqual(model.keys(forSlot: 0), "⌥⌘1, E")
    }

    // MARK: Launch

    func testViewerOpensTheDisplayedJPEG() async throws {
        try addEditor(preview)
        let jpeg = try writeJPEG("a.jpg")
        let viewer = viewer([ImageGroup(primary: jpeg)])
        defer { viewer.close() }
        XCTAssertTrue(viewer.canPerform(.openExternalEditor1))
        viewer.perform(.openExternalEditor1)
        await viewer.externalEditorLaunch?.value
        XCTAssertEqual(workspace.opened.count, 1)
        XCTAssertEqual(workspace.opened.first?.urls, [jpeg])
        XCTAssertEqual(workspace.opened.first?.app.standardizedFileURL, preview.standardizedFileURL)
    }

    func testRAWPairFollowsSendRAW() async throws {
        let jpeg = try writeJPEG("P1.JPG")
        let raw = try writeRAW("P1.ORF")
        let group = ImageGroup(primary: jpeg, companions: [.init(url: raw, kind: .raw)])
        try addEditor(preview, sendRAW: false)
        try addEditor(textEdit, sendRAW: true)
        let viewer = viewer([group])
        defer { viewer.close() }

        viewer.perform(.openExternalEditor1)
        await viewer.externalEditorLaunch?.value
        viewer.perform(.openExternalEditor2)
        await viewer.externalEditorLaunch?.value

        XCTAssertEqual(workspace.opened.map(\.urls), [[jpeg], [raw]],
                       "Send RAW off opens the JPEG; on opens the RAW")
    }

    func testBrowserOpensEverySelectedItem() async throws {
        try addEditor(preview)
        let urls = try ["a.jpg", "b.jpg", "c.jpg"].map { try writeJPEG($0) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 3 }
        XCTAssertFalse(browser.canPerform(.openExternalEditor1), "nothing selected")
        XCTAssertTrue(browser.contentController.select(urls: [urls[0], urls[2]]))
        XCTAssertTrue(browser.canPerform(.openExternalEditor1))
        browser.perform(.openExternalEditor1)
        await browser.externalEditorLaunch?.value
        XCTAssertEqual(workspace.opened.count, 1, "one launch for the whole selection")
        XCTAssertEqual(Set(workspace.opened.first?.urls.map(\.standardizedFileURL) ?? []),
                       Set([urls[0], urls[2]].map(\.standardizedFileURL)))
    }

    func testEmptySlotKeyOpensSettings() {
        let viewer = viewer([ImageGroup(primary: dir.appendingPathComponent("x.jpg"))])
        defer { viewer.close() }
        viewer.perform(.openExternalEditor3)
        XCTAssertNil(viewer.externalEditorLaunch)
        XCTAssertEqual(settingsOpened, 1, "an empty slot's key is never dead")
        XCTAssertTrue(workspace.opened.isEmpty)
    }

    func testMissingAppShowsToastAndSlotStays() async throws {
        let gone = dir.appendingPathComponent("Pixelmator Pro.app", isDirectory: true)
        try registry.add(ExternalEditor(displayName: "Pixelmator Pro", bundleIdentifier: "com.example.gone",
                                        applicationURL: gone))
        let jpeg = try writeJPEG("a.jpg")
        let viewer = viewer([ImageGroup(primary: jpeg)])
        defer { viewer.close() }

        viewer.perform(.openExternalEditor1)
        await viewer.externalEditorLaunch?.value

        let toast = try XCTUnwrap(viewer.contentRootForTesting.toastHost.content)
        XCTAssertEqual(toast.message, "Couldn't open “Pixelmator Pro”. It may have been moved or deleted.")
        XCTAssertEqual(toast.actionTitle, "Settings")
        XCTAssertEqual(registry.editors.count, 1, "the slot stays")
        XCTAssertTrue(workspace.opened.isEmpty)
    }
}

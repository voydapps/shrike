//
//  AppLifecycleTests.swift
//  ShrikeUITests
//
//  Open panels (with a fake runner, never a real NSOpenPanel) and the
//  Welcome window (built, never shown).
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class FakeOpenPanelRunner: OpenPanelRunning {
    var requests: [OpenPanelRequest] = []
    var answer: [URL] = []

    func run(_ request: OpenPanelRequest, sheetFor window: NSWindow?,
             completion: @escaping @MainActor ([URL]) -> Void) {
        requests.append(request)
        completion(answer)
    }
}

@MainActor
final class AppCommandsTests: XCTestCase {

    private var defaults: UserDefaults!

    // Async overrides run on the main actor, like the tests; sync ones are
    // nonisolated and fail to compile with `swift test -c release`.
    override func setUp() async throws {
        try await super.setUp()
        defaults = makeTestDefaults()
    }

    override func tearDown() async throws {
        try await super.tearDown()
    }

    func testOpenFolderPanelRoutesAsBrowsersAndRemembersFolder() {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-open-\(UUID().uuidString)", isDirectory: true)
        let runner = FakeOpenPanelRunner()
        runner.answer = [folder]
        let commands = AppCommands(coordinator: .shared)
        commands.panelRunner = runner
        commands.defaults = defaults
        var routed: [(urls: [URL], asBrowsers: Bool)] = []
        commands.route = { urls, asBrowsers in routed.append((urls, asBrowsers)) }

        commands.openFolder(nil)

        XCTAssertEqual(runner.requests.first?.canChooseFiles, false)
        XCTAssertEqual(runner.requests.first?.prompt, "Open Folder")
        XCTAssertEqual(routed.count, 1)
        XCTAssertEqual(routed.first?.asBrowsers, true)
        XCTAssertEqual(routed.first?.urls.first?.lastPathComponent, folder.lastPathComponent)
        XCTAssertEqual(defaults.url(forKey: AppCommands.lastOpenFolderKey)?.lastPathComponent,
                       folder.lastPathComponent)

        // The next Open… panel starts in the folder used last.
        runner.answer = []
        commands.openFiles(nil)
        XCTAssertEqual(runner.requests.last?.canChooseFiles, true)
        XCTAssertEqual(runner.requests.last?.prompt, "Open")
        XCTAssertEqual(runner.requests.last?.directoryURL?.lastPathComponent, folder.lastPathComponent)
        // Cancel routes nothing.
        XCTAssertEqual(routed.count, 1)
    }

    func testOpenFilesRoutesToViewerAndRemembersParentFolder() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-pick-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("photo.jpg")
        let runner = FakeOpenPanelRunner()
        runner.answer = [file]
        let commands = AppCommands(coordinator: .shared)
        commands.panelRunner = runner
        commands.defaults = defaults
        var routed: [(urls: [URL], asBrowsers: Bool)] = []
        commands.route = { urls, asBrowsers in routed.append((urls, asBrowsers)) }

        commands.openFiles(nil)

        XCTAssertEqual(routed.first?.asBrowsers, false)
        XCTAssertEqual(defaults.url(forKey: AppCommands.lastOpenFolderKey)?.lastPathComponent,
                       file.deletingLastPathComponent().lastPathComponent)
    }

    func testRecentItemRoutesToOpen() {
        let commands = AppCommands(coordinator: .shared)
        var routed: [URL] = []
        commands.route = { urls, _ in routed += urls }
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        let url = URL(fileURLWithPath: "/nonexistent-shrike/folder")
        item.representedObject = url
        commands.openRecentItem(item)
        XCTAssertEqual(routed, [url])
    }
}

@MainActor
final class WelcomeWindowTests: XCTestCase {

    func testLayoutCopyAndButtons() {
        let controller = WelcomeWindowController(recentURLs: { [] })
        defer { controller.close() }
        let window = try? XCTUnwrap(controller.window)
        XCTAssertEqual(window?.title, "Welcome to Shrike")
        XCTAssertEqual(window?.contentView?.frame.size, NSSize(width: 640, height: 440))
        XCTAssertEqual(window?.isReleasedWhenClosed, false)
        XCTAssertEqual(window?.styleMask.contains(.resizable), false)
        XCTAssertEqual(controller.openButton.title, "Open…")
        XCTAssertEqual(controller.openButton.keyEquivalent, "", "not the accent default button (contrast)")
        XCTAssertEqual(controller.openFolderButton.title, "Open Folder…")
        XCTAssertEqual(controller.dropZone.accessibilityLabel(), "Drop photos or folders here")
    }

    func testEmptyRecents() {
        let controller = WelcomeWindowController(recentURLs: { [] })
        defer { controller.close() }
        controller.reloadRecents()
        XCTAssertTrue(controller.recentRows.isEmpty)
        XCTAssertFalse(controller.emptyLabel.isHidden)
        XCTAssertEqual(controller.emptyLabel.stringValue, "No recent items")
    }

    func testRecentRowsOpenAndMissingItemsExplain() {
        let present = FileManager.default.temporaryDirectory
        let missing = URL(fileURLWithPath: "/nonexistent-shrike-\(UUID().uuidString)/Trip")
        let controller = WelcomeWindowController(recentURLs: { [present, missing] })
        defer { controller.close() }
        var opened: [URL] = []
        controller.onOpenURLs = { opened += $0 }
        controller.reloadRecents()
        XCTAssertEqual(controller.recentRows.count, 2)
        XCTAssertTrue(controller.emptyLabel.isHidden)

        controller.markMissing([missing])
        XCTAssertEqual(controller.recentRows[1].alphaValue, 0.5, accuracy: 0.001)
        controller.openRecent(missing)
        XCTAssertTrue(opened.isEmpty)
        // A toast, not an inline line.
        XCTAssertEqual(controller.toastHost.content?.message,
                       "“Trip” is not available. The disk may be disconnected.")
        XCTAssertTrue(controller.messageLabel.isHidden)

        controller.openRecent(present)
        XCTAssertEqual(opened, [present])
    }

    func testDropZoneAcceptsOnlyOpenableItems() {
        let folder = FileManager.default.temporaryDirectory
        XCTAssertTrue(WelcomeDropZone.openable([folder]))
        XCTAssertFalse(WelcomeDropZone.openable([URL(fileURLWithPath: "/nonexistent-shrike/readme.txt")]))
    }
}

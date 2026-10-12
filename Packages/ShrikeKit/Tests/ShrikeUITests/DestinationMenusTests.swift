//
//  DestinationMenusTests.swift
//  ShrikeUITests
//
//  The viewer's right-click menu (with
//  the destination slot rows) and the Browser sidebar's
//  "Set as Destination ▸ 1 … 9". Temp folders and a throwaway defaults
//  suite only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class DestinationMenusTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var selects: URL!
    private var slots: DestinationSlots!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-destmenus-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Italy 2026", isDirectory: true)
        selects = root.appendingPathComponent("Selects", isDirectory: true)
        for folder in [dir!, selects!] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        slots = DestinationSlots(defaults: makeTestDefaults())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func viewer(_ urls: [URL]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
                                  services: services)
        viewer.fileOps = FileOps(metadata: nil, backups: nil, watchers: nil)
        viewer.transfers.slots = slots
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Viewer context menu

    func testViewerContextMenuOrderMatchesSpec() throws {
        let url = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        let viewer = viewer([url])
        defer { viewer.close() }
        XCTAssertTrue(viewer.contentRoot.menu === viewer.contextMenu.menu)
        viewer.contextMenu.prepareForTesting()
        let titles = viewer.contextMenu.menu.items.map { $0.isSeparatorItem ? "—" : MenuKeyHints.baseTitle(of: $0) }
        XCTAssertEqual(titles, [
            "Open With", "Open in External Editor", ShrikeCommand.toggleRAWFile.title, "Reveal in Finder", "Show in Browser", titles[5], "—",
            "Rotate Left", "Rotate Right", ShrikeCommand.editImage.title, "—",
            "Rating", ShrikeCommand.toggleFlag.title, ShrikeCommand.tags.title, "—",
            ShrikeCommand.copyToFolder.title, ShrikeCommand.moveToFolder.title,
            ShrikeCommand.rename.title, ShrikeCommand.revertToOriginal.title, "—",
            "Copy", ShrikeCommand.copyPath.title, "—", ShrikeCommand.moveToTrash.title,
        ])
        let revert = viewer.contextMenu.menu.items.first { $0.shrikeCommand == .revertToOriginal }
        XCTAssertEqual(revert?.isHidden, true, "Revert shows only when the file was edited")
    }

    func testViewerContextMenuSlotRowCopiesToSlot() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        slots.set(1, folder: selects)
        let viewer = viewer([url])
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let rows = viewer.contextMenu.copyToMenuForTesting.items
        XCTAssertEqual(rows.map(\.title), ["1  Selects", "", "Choose Folder…"])
        let row = try XCTUnwrap(rows.first)
        XCTAssertTrue(row.target === viewer)
        XCTAssertTrue(viewer.validateMenuItem(row))
        viewer.performShrikeCommand(row)
        let copied = await waitUntil {
            FileManager.default.fileExists(atPath: self.selects.appendingPathComponent("a.jpg").path)
        }
        XCTAssertTrue(copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a copy keeps the source")
        XCTAssertEqual(viewer.contextMenu.moveToMenuForTesting.items.first?.title, "1  Selects")
    }

    // MARK: Browser sidebar "Set as Destination ▸"

    func testSidebarSetAsDestinationShowsSlotNamesAndSetsSlot() {
        let tree = FolderTreeViewController()
        tree.destinationSlots = slots
        slots.set(2, folder: selects)
        tree.fillDestinationMenu(for: selects)
        let rows = tree.destinationMenu.items
        XCTAssertEqual(rows.count, 9)
        XCTAssertEqual(rows[0].title, "1  Empty")
        XCTAssertEqual(rows[1].title, "2  Selects")
        XCTAssertEqual(rows[1].state, .on, "the slot that already points here is checked")
        XCTAssertEqual(rows[0].state, .off)

        tree.fillDestinationMenu(for: dir)
        tree.menuSetDestination(tree.destinationMenu.items[3])
        XCTAssertEqual(slots.slot(4)?.name, "Italy 2026")
        tree.fillDestinationMenu(for: dir)
        XCTAssertEqual(tree.destinationMenu.items[3].title, "4  Italy 2026")
        XCTAssertEqual(tree.destinationMenu.items[3].state, .on)
    }

    func testSidebarDestinationRowsDisabledWithoutAFolder() {
        let tree = FolderTreeViewController()
        tree.destinationSlots = slots
        tree.fillDestinationMenu(for: nil)
        XCTAssertTrue(tree.destinationMenu.items.allSatisfy { !$0.isEnabled })
    }
}

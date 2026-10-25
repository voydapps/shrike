//
//  RenameFlowTests.swift
//  ShrikeUITests
//
//  The Rename sheet's live check and
//  a group rename (JPEG + RAW) with one undo step. Temp folders only.
//

import XCTest
import AppKit
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class RenameFlowTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func make(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0xFF]).write(to: url)
        return url
    }

    private func ops() -> FileOps {
        FileOps(metadata: nil, backups: nil, watchers: nil, trashItem: { _ in
            throw CocoaError(.featureUnsupported)
        })
    }

    private func pair() throws -> ImageGroup {
        let jpg = try make("DSC_0042.jpg")
        let raw = try make("DSC_0042.ORF")
        return ImageGroup(primary: jpg, companions: [.init(url: raw, kind: .raw)])
    }

    private func viewer(_ groups: [ImageGroup]) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: groups, startIndex: 0, services: services)
        viewer.fileOps = ops()
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: "a/b" shows the rule and disables Rename.

    func testSlashShowsRuleAndDisablesRename() throws {
        let group = try pair()
        let fileOps = ops()
        let model = RenameSheetModel(group: group, validate: { fileOps.validate(stem: $0, for: group) })
        let state = model.state(for: "a/b")
        XCTAssertEqual(state.message, "⚠ Names can't contain “/” or “:”.")
        XCTAssertFalse(state.canRename)
        XCTAssertTrue(model.state(for: "Venice").canRename)
        XCTAssertNil(model.state(for: "Venice").message)
        XCTAssertEqual(model.oldStem, "DSC_0042")
        XCTAssertEqual(model.fileExtension, ".jpg")
        XCTAssertEqual(model.companionsLine, "Also renames “DSC_0042.ORF”.")
    }

    func testF2MapsToRenameInBothWindows() {
        let f2 = ShrikeUI.KeyEventSnapshot(key: "\u{F705}", modifiers: [])
        XCTAssertEqual(ViewerKeyMap.action(for: f2, context: .viewer, preset: .macNative), .rename)
        XCTAssertEqual(BrowserKeyMap.action(for: f2), .rename)
    }

    // MARK: A pair renames together; ⌘Z restores both.

    func testPairRenamesTogetherAndUndoRestoresBoth() async throws {
        let group = try pair()
        let viewer = viewer([group])
        defer { viewer.close() }
        var asked: RenameSheetModel?
        viewer.renameResponderForTesting = { model in
            asked = model
            return "Venice"
        }

        viewer.renameDisplayed()
        try await Task.sleep(for: .milliseconds(20))
        await viewer.waitForPendingFileWork()
        XCTAssertEqual(asked?.oldStem, "DSC_0042")
        XCTAssertTrue(exists("Venice.jpg"))
        XCTAssertTrue(exists("Venice.ORF"))
        XCTAssertFalse(exists("DSC_0042.jpg"))
        XCTAssertFalse(exists("DSC_0042.ORF"))
        XCTAssertEqual(viewer.groups.count, 1, "the item keeps its place")
        XCTAssertEqual(viewer.groups.first?.primary.lastPathComponent, "Venice.jpg")
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Rename")

        viewer.performUndo()
        await viewer.waitForPendingFileWork()
        XCTAssertTrue(exists("DSC_0042.jpg"))
        XCTAssertTrue(exists("DSC_0042.ORF"))
        XCTAssertFalse(exists("Venice.jpg"))
        XCTAssertEqual(viewer.groups.first?.primary.lastPathComponent, "DSC_0042.jpg")
        XCTAssertTrue(viewer.undoManagerForTesting.canRedo, "redo renames again")
    }

    func testCancelOrSameNameDoesNothing() async throws {
        let group = try pair()
        let viewer = viewer([group])
        defer { viewer.close() }
        viewer.renameResponderForTesting = { _ in nil }
        viewer.renameDisplayed()
        try await Task.sleep(for: .milliseconds(20))
        await viewer.waitForPendingFileWork()
        viewer.renameResponderForTesting = { $0.oldStem }
        viewer.renameDisplayed()
        try await Task.sleep(for: .milliseconds(20))
        await viewer.waitForPendingFileWork()
        XCTAssertTrue(exists("DSC_0042.jpg"))
        XCTAssertFalse(viewer.undoManagerForTesting.canUndo)
    }

    func testFailureCopy() throws {
        let group = try pair()
        let text = RenameCopy.failed(group, error: FileOpsError.invalidName(.invalidCharacters))
        XCTAssertEqual(text, "Couldn't rename “\(group.displayName)”. Names can't contain “/” or “:”.")
    }
}

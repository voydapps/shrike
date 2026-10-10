//
//  SaveFlowTests.swift
//  ShrikeUITests
//
//  Save routing, backups, Undo /
//  Redo Save, Revert to Original. Temp folders and a temp `BackupStore`
//  only — never the user's Application Support.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO

@MainActor
final class SaveFlowTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-save-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    static func image(width: Int = 16, height: Int = 8, red: CGFloat = 1) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0.2, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    @discardableResult
    static func writeImage(_ url: URL, type: UTType, orientation: Int? = nil) throws -> Data {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(dest, image(), props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try Data(contentsOf: url)
    }

    private func viewer(_ url: URL, store: BackupStore?) -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    /// Opens edit mode on `url` with one 90° turn in the recipe.
    private func enterEditWithRotate(_ viewer: ViewerWindow, url: URL) async throws {
        viewer.contentRootForTesting.enterEditMode(image: Self.image(), url: url, landOn: .rotate)
        viewer.contentRootForTesting.editModeController.appendSnapped90(quarters: 1)
        let recipe = try XCTUnwrap(viewer.contentRootForTesting.editModeController.recipe)
        let deadline = Date().addingTimeInterval(2)
        while await recipe.operations.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // ⌘S backs up, pencil shows; ⌘Z restores; ⇧⌘Z re-saves.
    func testSaveInPlaceBacksUpAndUndoRedoSwapTheBytes() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)

        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        let after = try Data(contentsOf: url)
        XCTAssertNotEqual(after, before)
        let records = await store.records(for: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try Data(contentsOf: records[0].backupURL), before)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message,
                       "Saved “a.jpg”. The original is kept.")
        let edited = await waitUntil { viewer.isDisplayedEdited }
        XCTAssertTrue(edited)
        XCTAssertTrue(viewer.canPerform(.revertToOriginal))
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Save")

        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message,
                       "Save undone. “a.jpg” is back to how it was.")
        XCTAssertTrue(viewer.undoManagerForTesting.canRedo)

        viewer.undoManagerForTesting.redo()
        await viewer.waitForFileVersionSwap()
        XCTAssertEqual(try Data(contentsOf: url), after)
    }

    // GIF → Save panel with M3 and "-edited" name; file untouched.
    func testSaveOnGIFAsksForACopy() async throws {
        let url = dir.appendingPathComponent("party.gif")
        let before = try Self.writeImage(url, type: .gif)
        let viewer = viewer(url, store: store)
        defer { viewer.close() }
        var asked: (URL, String?)?
        viewer.savePanelResponderForTesting = { suggested, message in
            asked = (suggested, message)
            return nil
        }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(asked?.1, "“party.gif” can't be saved in place without losing data. Save an edited copy instead.")
        XCTAssertTrue(["party-edited.jpg", "party-edited.png"].contains(asked?.0.lastPathComponent ?? ""))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
    }

    // RAW → Save panel with M1; the RAW is unchanged.
    func testSaveOnRAWShowsM1() async throws {
        let url = dir.appendingPathComponent("P1.ORF")
        let bytes = Data([0x49, 0x49, 0x52, 0x4F, 0x08, 0, 0, 0])
        try bytes.write(to: url)
        let viewer = viewer(url, store: store)
        defer { viewer.close() }
        var message: String?
        viewer.savePanelResponderForTesting = { _, m in message = m; return nil }
        try await enterEditWithRotate(viewer, url: url)
        await viewer.saveEditedFile(asPanel: false)
        XCTAssertEqual(message, "RAW files are never changed. Save an edited copy instead.")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // Save As: the viewer stays on the original; the copy joins the list.
    func testSaveAsKeepsTheOriginalAndListsTheCopy() async throws {
        let url = dir.appendingPathComponent("b.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = viewer(url, store: store)
        defer { viewer.close() }
        let copy = dir.appendingPathComponent("b-edited.jpg")
        viewer.savePanelResponderForTesting = { _, _ in copy }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertEqual(viewer.groups.map(\.primary.lastPathComponent), ["b.jpg", "b-edited.jpg"])
        XCTAssertEqual(viewer.displayedItem?.group.primary, url)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, "Saved a copy as “b-edited.jpg”.")
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.actionTitle, "Show")
    }

    // Revert after 2 saves → the first bytes; ⌘Z → the second save.
    func testRevertToOriginalAndUndo() async throws {
        let url = dir.appendingPathComponent("c.jpg")
        let original = try Self.writeImage(url, type: .jpeg)
        let viewer = viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        await viewer.saveEditedFile(asPanel: false)
        try await enterEditWithRotate(viewer, url: url)
        await viewer.saveEditedFile(asPanel: false)
        let secondSave = try Data(contentsOf: url)
        _ = await waitUntil { viewer.isDisplayedEdited }

        var alert: String?
        viewer.alertResponderForTesting = { message in alert = message; return 1 }
        viewer.revertDisplayedToOriginal()
        let reverted = await waitUntil { (try? Data(contentsOf: url)) == original }
        XCTAssertTrue(reverted)
        XCTAssertEqual(alert, "Revert “c.jpg” to the original?")
        let pencilGone = await waitUntil { !viewer.isDisplayedEdited }
        XCTAssertTrue(pencilGone)
        XCTAssertEqual(viewer.undoManagerForTesting.undoActionName, "Revert to Original")

        viewer.undoManagerForTesting.undo()
        await viewer.waitForFileVersionSwap()
        XCTAssertEqual(try Data(contentsOf: url), secondSave)
    }

    // The backup fails → the backup-failed alert; the file is unchanged.
    func testBackupFailureShowsA5AndKeepsTheFile() async throws {
        let url = dir.appendingPathComponent("d.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let failing = BackupStore(root: root.appendingPathComponent("Bad", isDirectory: true),
                                  retentionDays: { 30 }, maxBytes: { 1 << 30 }, 
                                  now: { Date() }, copier: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let viewer = viewer(url, store: failing)
        defer { viewer.close() }
        var alert: String?
        viewer.alertResponderForTesting = { message in alert = message; return 0 }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(alert, "Shrike didn't save “d.jpg”.")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
    }

    func testA5CopyNamesTheVolume() {
        XCTAssertEqual(SaveCopy.volumeName(inBackupError: "insufficientSpace(volumeName: \"Macintosh HD\")"),
                       "Macintosh HD")
        XCTAssertNil(SaveCopy.volumeName(inBackupError: "copyFailed(underlying: \"x\")"))
        XCTAssertTrue(SaveCopy.backupFailedMessage(volume: "Macintosh HD")
            .contains("There isn't enough space on “Macintosh HD”."))
    }

    // ⌘Q with unsaved edits shows the edit
    // exit alert; Cancel cancels the quit, Save writes, Don't Save quits.
    func testQuitWithUnsavedEditsAsksFirst() async throws {
        let url = dir.appendingPathComponent("q.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = viewer(url, store: store)
        defer { viewer.close(); EditExitModal.responderForTesting = nil }
        let idle = await WindowCoordinator.resolveUnsavedEdits(in: [viewer])
        XCTAssertTrue(idle, "no edit mode: quit at once")
        try await enterEditWithRotate(viewer, url: url)

        var asked: [String] = []
        EditExitModal.responderForTesting = { asked.append($0.message); return .cancel }
        let cancelled = await WindowCoordinator.resolveUnsavedEdits(in: [viewer])
        XCTAssertFalse(cancelled, "Cancel cancels the quit")
        XCTAssertEqual(asked, ["Save changes to “q.jpg”?"])
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(try Data(contentsOf: url), before)

        EditExitModal.responderForTesting = { _ in .save }
        let saved = await WindowCoordinator.resolveUnsavedEdits(in: [viewer])
        XCTAssertTrue(saved)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertNotEqual(try Data(contentsOf: url), before)

        try await enterEditWithRotate(viewer, url: url)
        let written = try Data(contentsOf: url)
        EditExitModal.responderForTesting = { _ in .discard }
        let discarded = await WindowCoordinator.resolveUnsavedEdits(in: [viewer])
        XCTAssertTrue(discarded)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(try Data(contentsOf: url), written, "Don't Save leaves the file")
    }
}

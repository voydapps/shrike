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
        EditToolTransitionModal.responderForTesting = { _ in .keep }
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-save-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
    }

    override func tearDown() async throws {
        EditToolTransitionModal.responderForTesting = nil
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

    private func viewer(_ url: URL, store: BackupStore?) async throws -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready, "The file target is accepted before installing the unit-test recipe")
        return viewer
    }

    /// Opens edit mode on `url` with one 90° turn in the recipe.
    private func enterEditWithRotate(_ viewer: ViewerWindow, url: URL) async throws {
        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready, "A save/refetch has settled before the next edit session")
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

    func testDirectSaveIncludesUnappliedCropAfterToolSwitch() async throws {
        let url = dir.appendingPathComponent("pending.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: Self.image(width: 16, height: 8), url: url, landOn: .crop)
        let controller = content.editModeController
        controller.cropOverlay.imageFrame = CGRect(x: 0, y: 0, width: 16, height: 8)
        controller.cropOverlay.setRectFromImageSpace(CGRect(x: 0, y: 0, width: 8, height: 4))
        controller.selectTool(.color)
        await controller.settleForTesting()
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
    }

    func testSaveAsIncludesPendingResizeWithoutChangingOriginal() async throws {
        let url = dir.appendingPathComponent("resize.jpg"), copy = dir.appendingPathComponent("resize-copy.jpg")
        let original = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        viewer.savePanelResponderForTesting = { _, _ in copy }
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: Self.image(width: 16, height: 8), url: url, landOn: .resize)
        let panel = try XCTUnwrap(content.editModeController._installedToolForTesting as? ResizePanel)
        panel._widthField.stringValue = "8"
        _ = panel._widthField.sendAction(panel._widthField.action, to: panel._widthField.target)
        content.editModeController.selectTool(.color)
        await content.editModeController.settleForTesting()
        let saved = await viewer.saveEditedFile(asPanel: true)
        XCTAssertTrue(saved)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(copy as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 8)
        XCTAssertEqual(image.height, 4)
    }

    // ⌘S backs up, pencil shows; ⌘Z restores; ⇧⌘Z re-saves.
    func testSaveInPlaceBacksUpAndUndoRedoSwapTheBytes() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
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
                       "Saved “a.jpg”. Original backup available.")
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

    /// FS-7: another program rewrites the file while it is open in edit mode.
    private func rewriteBehindTheEditorsBack(_ url: URL) throws -> Data {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, Self.image(width: 48, height: 24, red: 0.2), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try Data(contentsOf: url)
    }

    func testSaveAsksWhenTheFileChangedWhileEditing_cancelKeepsTheFile() async throws {
        let url = dir.appendingPathComponent("changed.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let other = try rewriteBehindTheEditorsBack(url)
        var asked: String?
        viewer.alertResponderForTesting = { message in asked = message; return 0 }   // Cancel
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(asked, "“changed.jpg” changed while you were editing it.")
        XCTAssertEqual(try Data(contentsOf: url), other, "Cancel changes nothing on disk")
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive, "edits stay open")
    }

    func testSaveAnywayAppliesTheEditsAndBacksUpTheNewVersion() async throws {
        let url = dir.appendingPathComponent("changed2.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let other = try rewriteBehindTheEditorsBack(url)
        viewer.alertResponderForTesting = { _ in 1 }   // Save Anyway
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertNotEqual(try Data(contentsOf: url), other)
        let records = await store.records(for: url)
        XCTAssertEqual(try Data(contentsOf: records[0].backupURL), other, "the version on disk was backed up first")
    }

    func testSaveDoesNotAskWhenNothingChanged() async throws {
        let url = dir.appendingPathComponent("same.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        var asked = false
        viewer.alertResponderForTesting = { _ in asked = true; return 0 }
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertFalse(asked)
    }

    // GIF → Save panel with M3 and "-edited" name; file untouched.
    func testSaveOnGIFAsksForACopy() async throws {
        let url = dir.appendingPathComponent("party.gif")
        let before = try Self.writeImage(url, type: .gif)
        let viewer = try await viewer(url, store: store)
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
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        var message: String?
        viewer.savePanelResponderForTesting = { _, m in message = m; return nil }
        try await enterEditWithRotate(viewer, url: url)
        await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(message?.hasPrefix("RAW files are never changed. Save an edited copy instead.") == true)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    // Save As: the viewer stays on the original; the copy joins the list.
    func testSaveAsKeepsTheOriginalAndListsTheCopy() async throws {
        let url = dir.appendingPathComponent("b.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
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
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, "Saved copy “b-edited.jpg”. Original unchanged.")
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.actionTitle, "Show")
    }

    // Save Copy into a folder another window shows (the Browser): that
    // window's watcher must report the new file. The viewer used to tell
    // every watcher to ignore it, so the Browser stayed at the old count.
    func testSaveAsIsSeenByAnotherWatcherOfTheFolder() async throws {
        let url = dir.appendingPathComponent("w.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let browserSide = try FolderWatcher(folder: dir)
        defer { browserSide.stop() }
        let copy = dir.appendingPathComponent("w-edited.jpg")
        viewer.savePanelResponderForTesting = { _, _ in copy }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: true)
        XCTAssertTrue(saved)

        let seen = Task { () -> [URL] in
            var added: [URL] = []
            for await change in browserSide.changes {
                added += change.added
                if !added.isEmpty { break }
            }
            return added
        }
        let timeout = Task { try await Task.sleep(for: .seconds(8)); browserSide.stop() }
        let added = await seen.value
        timeout.cancel()
        XCTAssertEqual(added.map(\.lastPathComponent), ["w-edited.jpg"])
    }

    // Revert after 2 saves → the first bytes; ⌘Z → the second save.
    func testRevertToOriginalAndUndo() async throws {
        let url = dir.appendingPathComponent("c.jpg")
        let original = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
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
        let viewer = try await viewer(url, store: failing)
        defer { viewer.close() }
        var alert: String?
        viewer.alertResponderForTesting = { message in alert = message; return 1 }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(alert, "Shrike didn't save “d.jpg”.")
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive)
    }

    func testBackupFailureSaveCopyRecoveryKeepsOriginalAndWritesCopy() async throws {
        let url = dir.appendingPathComponent("recover.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let destination = dir.appendingPathComponent("recovered-copy.jpg")
        let failing = BackupStore(root: root.appendingPathComponent("FailRecovery"), retentionDays: { 30 }, maxBytes: { 1 << 30 }, now: { Date() }, copier: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let viewer = try await viewer(url, store: failing); defer { viewer.close() }
        viewer.alertResponderForTesting = { _ in 0 }
        var panels = 0
        viewer.savePanelResponderForTesting = { _, _ in panels += 1; return destination }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved); XCTAssertEqual(panels, 1)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
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
        let viewer = try await viewer(url, store: store)
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

    /// COR-7: ⌘Q while a save runs waits for it (and says so) instead of silently cancelling.
    func testQuitDuringASaveWaitsForTheSave() async throws {
        let url = dir.appendingPathComponent("qs.jpg")
        _ = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close(); EditExitModal.responderForTesting = nil }
        try await enterEditWithRotate(viewer, url: url)
        let editor = viewer.contentRootForTesting.editModeController
        editor.setSaving(true)
        var asked = 0
        EditExitModal.responderForTesting = { _ in asked += 1; return .discard }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            editor.setSaving(false)
        }
        let started = Date()
        let mayQuit = await viewer.resolveUnsavedEditsForQuit()
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "it waited for the save")
        XCTAssertTrue(mayQuit, "after the save, the normal exit flow ran (Don't Save)")
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, ViewerWindow.quitWaitsForSave)
    }
}

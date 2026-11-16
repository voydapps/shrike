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
        root = TestScratch.directory
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

    /// The Save toast's Undo undoes the save only: once anything else is on the
    /// undo stack the toast goes away, and its button would not undo that other action.
    func testSaveToastUndoUndoesOnlyTheSave() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let host = viewer.contentRootForTesting.toastHost
        XCTAssertEqual(host.content?.actionTitle, "Undo", "positive control")

        // Something else lands on the stack after the save.
        final class Box { var undone = false }
        let other = Box()
        let manager = viewer.undoManagerForTesting
        // A later event: the run loop closes the save's own undo group first.
        try await Task.sleep(for: .milliseconds(50))
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: other) { $0.undone = true }
        manager.setActionName("Other")
        manager.endUndoGrouping()
        XCTAssertNotEqual(host.content?.message, "Saved “a.jpg”. Original backup available.",
                          "the save toast is gone")
        XCTAssertNotEqual(try Data(contentsOf: url), before, "the save stays")
        XCTAssertFalse(other.undone)
        XCTAssertEqual(manager.undoActionName, "Other")
    }

    func testSaveToastUndoUndoesTheSaveWhenNothingCameAfter() async throws {
        let url = dir.appendingPathComponent("a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        let host = viewer.contentRootForTesting.toastHost
        XCTAssertEqual(host.content?.actionTitle, "Undo")
        host.beginPressForTesting()
        host.performToastAction(nil)
        await viewer.waitForFileVersionSwap()
        XCTAssertEqual(try Data(contentsOf: url), before, "the save is undone")
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

// MARK: - Pass 2k Q2: edit answers wait for the work question

extension SaveFlowTests {

    /// Runs `prepareToQuit` with a copy "running", a real editing viewer,
    /// `edit` as the edit answer and `work` as the work answer (0 Quit
    /// Anyway, 1 Cancel). Returns the quit result and the question order.
    private func quitWithWork(_ viewer: ViewerWindow, edit: EditExitModal.Choice, work: Int)
        async -> (quits: Bool, asked: [String]) {
        var asked: [String] = []
        EditExitModal.responderForTesting = { _ in asked.append("edits"); return edit }
        let c = WindowCoordinator()
        c.runningWorkOverride = { QuitWork(transfers: [.init(verb: .copy, completed: 1, total: 9)]) }
        c.unsavedEditsAsker = { await WindowCoordinator.askUnsavedEdits(in: [viewer]) }
        c.quitAlertResponder = { _, _ in asked.append("work"); return work }
        c.stoppedForQuitOverride = { true }
        c.flushOverride = { true }
        let quits = await c.prepareToQuit()
        EditExitModal.responderForTesting = nil
        return (quits, asked)
    }

    private func hasPendingEdits(_ viewer: ViewerWindow) async -> Bool {
        let editor = viewer.contentRootForTesting.editModeController
        guard editor.isActive, let recipe = editor.recipe else { return false }
        return !(await recipe.operations.isEmpty)
    }

    func testDontSaveThenCancelKeepsTheEdits() async throws {
        let url = dir.appendingPathComponent("q2a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let result = await quitWithWork(viewer, edit: .discard, work: 1)
        XCTAssertFalse(result.quits)
        XCTAssertEqual(result.asked, ["edits", "work"], "edits first, then work; each once")
        let pending = await hasPendingEdits(viewer)
        XCTAssertTrue(pending, "Cancel at the work question: the edits are still there")
        XCTAssertFalse(viewer.contentRootForTesting.editModeController.isTransitioning)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSaveThenCancelLeavesTheFileAndTheEdits() async throws {
        let url = dir.appendingPathComponent("q2b.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let result = await quitWithWork(viewer, edit: .save, work: 1)
        XCTAssertFalse(result.quits)
        XCTAssertEqual(try Data(contentsOf: url), before, "nothing was saved")
        let pending = await hasPendingEdits(viewer)
        XCTAssertTrue(pending)
    }

    func testDontSaveThenQuitAnywayDiscardsAndQuits() async throws {
        let url = dir.appendingPathComponent("q2c.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let result = await quitWithWork(viewer, edit: .discard, work: 0)
        XCTAssertTrue(result.quits)
        XCTAssertEqual(result.asked, ["edits", "work"], "the answer is not asked again")
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSaveThenQuitAnywaySavesAndQuits() async throws {
        let url = dir.appendingPathComponent("q2d.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let result = await quitWithWork(viewer, edit: .save, work: 0)
        XCTAssertTrue(result.quits)
        XCTAssertEqual(result.asked, ["edits", "work"])
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertNotEqual(try Data(contentsOf: url), before, "saved")
    }

    func testFailedSaveAfterQuitAnywayCancelsTheQuit() async throws {
        let url = dir.appendingPathComponent("q2e.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let failing = BackupStore(root: root.appendingPathComponent("Bad", isDirectory: true),
                                  retentionDays: { 30 }, maxBytes: { 1 << 30 },
                                  now: { Date() }, copier: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        let viewer = try await viewer(url, store: failing)
        defer { viewer.close() }
        viewer.alertResponderForTesting = { _ in 1 }
        try await enterEditWithRotate(viewer, url: url)
        let result = await quitWithWork(viewer, edit: .save, work: 0)
        XCTAssertFalse(result.quits, "a failed save cancels the quit")
        XCTAssertEqual(try Data(contentsOf: url), before)
        let pending = await hasPendingEdits(viewer)
        XCTAssertTrue(pending)
    }

    /// R1 follow-up: a REAL viewer starts editing while the work question
    /// is up. Quit Anyway asks about those edits once; Don't Save quits;
    /// Cancel keeps the app, the edits and the work. The viewer list is
    /// injected (a fresh coordinator has none registered); the ask and the
    /// re-check are the real functions.
    private func editsDuringWorkQuestion(_ viewer: ViewerWindow, url: URL, edit: EditExitModal.Choice)
        async -> (quits: Bool, edits: Int, stops: Int) {
        var edits = 0, stops = 0
        EditExitModal.responderForTesting = { _ in edits += 1; return edit }
        defer { EditExitModal.responderForTesting = nil }
        let c = WindowCoordinator()
        c.runningWorkOverride = { QuitWork(transfers: [.init(verb: .copy, completed: 1, total: 9)]) }
        c.unsavedEditsAsker = { await WindowCoordinator.askUnsavedEdits(in: [viewer]) }
        c.unsavedEditsRecheck = { await WindowCoordinator.resolveUnsavedEdits(in: [viewer]) }
        c.stoppedForQuitOverride = { stops += 1; return true }
        c.flushOverride = { true }
        c.quitAlertPresenter = { _, completion in
            Task { @MainActor in
                try? await self.enterEditWithRotate(viewer, url: url)   // edits begun while the question is up
                // Quit Anyway is button index 0 of two (the right-to-left order of `ShrikeAlert.index`).
                completion(NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + 1))
            }
            return { _ in }
        }
        let quits = await c.prepareToQuit()
        return (quits, edits, stops)
    }

    func testEditsBegunDuringTheWorkQuestionDontSaveQuits() async throws {
        let url = dir.appendingPathComponent("r1a.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let result = await editsDuringWorkQuestion(viewer, url: url, edit: .discard)
        XCTAssertTrue(result.quits)
        XCTAssertEqual(result.edits, 1, "asked once for that viewer")
        XCTAssertEqual(result.stops, 1, "the work is stopped after the answer")
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testEditsBegunDuringTheWorkQuestionCancelKeepsEverything() async throws {
        let url = dir.appendingPathComponent("r1b.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let result = await editsDuringWorkQuestion(viewer, url: url, edit: .cancel)
        XCTAssertFalse(result.quits)
        XCTAssertEqual(result.edits, 1)
        XCTAssertEqual(result.stops, 0, "Cancel: the work goes on")
        let pending = await hasPendingEdits(viewer)
        XCTAssertTrue(pending, "the edits are still there")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    /// Plain ⌘Q with unsaved edits and no work: one question, not two.
    func testPlainQuitWithEditsAndNoWorkAsksOnce() async throws {
        let url = dir.appendingPathComponent("r1c.jpg")
        _ = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        var edits = 0
        EditExitModal.responderForTesting = { _ in edits += 1; return .discard }
        defer { EditExitModal.responderForTesting = nil }
        let c = WindowCoordinator()
        c.runningWorkOverride = { QuitWork() }
        c.unsavedEditsResolver = { await WindowCoordinator.resolveUnsavedEdits(in: [viewer]) }
        c.unsavedEditsRecheck = { await WindowCoordinator.resolveUnsavedEdits(in: [viewer]) }
        c.flushOverride = { true }
        let quits = await c.prepareToQuit()
        XCTAssertTrue(quits)
        XCTAssertEqual(edits, 1)
    }

    /// No work running: one question, acted on at once (as before).
    func testWithoutWorkTheEditAnswerActsAtOnce() async throws {
        let url = dir.appendingPathComponent("q2f.jpg")
        _ = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        EditExitModal.responderForTesting = { _ in .discard }
        defer { EditExitModal.responderForTesting = nil }
        let c = WindowCoordinator()
        c.runningWorkOverride = { QuitWork() }
        c.unsavedEditsResolver = { await WindowCoordinator.resolveUnsavedEdits(in: [viewer]) }
        c.unsavedEditsAsker = { XCTFail("no deferring without work"); return nil }
        c.flushOverride = { true }
        let quits = await c.prepareToQuit()
        XCTAssertTrue(quits)
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
    }

    // MARK: - ⌘S writes only when Done would (pass 2zc)

    /// Oriented size of the file on disk (EXIF orientation applied).
    private func orientedSize(_ url: URL) throws -> CGSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: 64]
        let image = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary))
        return CGSize(width: image.width, height: image.height)
    }

    /// Quarter turns that cancel out are no change for Done, the status and
    /// ⌘S alike. The raw edit list still holds both steps (undo needs them).
    func testQuarterTurnsLeftAndRightCancelOut() async {
        let recipe = EditRecipe()
        let start = await recipe.checkpoint()
        await recipe.append(.rotate90(quarters: -1))
        await recipe.append(.rotate90(quarters: 1))
        let changed = await recipe.hasContentChanges(since: start)
        let ops = await recipe.snapshot()
        XCTAssertFalse(changed, "ops \(ops)")
        XCTAssertEqual(ops.count, 2, "ops \(ops)")
    }

    /// ⌘S with a colour change put back to none: Done would just leave, so
    /// ⌘S leaves too, with no write and no new backup.
    func testCommandSWithEditsThatCancelOutWritesNothing() async throws {
        let url = dir.appendingPathComponent("cancel-save.jpg")
        let before = try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready)
        let controller = viewer.contentRootForTesting.editModeController
        viewer.contentRootForTesting.enterEditMode(image: Self.image(), url: url, landOn: .color)
        await controller.settleForTesting()
        let recipe = try XCTUnwrap(controller.recipe)
        let start = await EditRecipe().checkpoint()
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.3)))
        await recipe.append(.colorAdjust(.identity))
        let ops = await recipe.snapshot()
        XCTAssertEqual(ops.count, 2, "the raw edit list is not empty")
        let changed = await recipe.hasContentChanges(since: start)
        XCTAssertFalse(changed, "Done would see no change")
        XCTAssertNotNil(controller.sourceStamp)
        var asked = false
        viewer.alertResponderForTesting = { _ in asked = true; return 0 }
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertFalse(asked, "an untouched file needs no question")
        XCTAssertFalse(viewer.contentRootForTesting.isEditModeActive)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(try Data(contentsOf: url), before, "the file was written again")
        let records = await store.records(for: url)
        XCTAssertEqual(records.count, 0, "a new backup was made")
    }

    /// Edits that cancel out on a file another program rewrote: ⌘S does not
    /// just leave (the screen would show the old picture); it asks first, as with real edits.
    private func enterEditWithCancellingColor(_ viewer: ViewerWindow, url: URL) async throws -> EditModeController {
        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready)
        let controller = viewer.contentRootForTesting.editModeController
        viewer.contentRootForTesting.enterEditMode(image: Self.image(), url: url, landOn: .color)
        await controller.settleForTesting()
        XCTAssertNotNil(controller.sourceStamp, "the session knows the file it started from")
        let recipe = try XCTUnwrap(controller.recipe)
        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.3)))
        await recipe.append(.colorAdjust(.identity))
        let changed = await controller.hasSessionContentChanges(recipe)
        XCTAssertFalse(changed, "Done would see no change")
        return controller
    }

    func testCommandSWithEditsThatCancelOutOnAFileChangedOnDiskAsks_cancelKeepsEditing() async throws {
        let url = dir.appendingPathComponent("cancel-changed.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let controller = try await enterEditWithCancellingColor(viewer, url: url)
        let other = try rewriteBehindTheEditorsBack(url)
        var asked: String?
        viewer.alertResponderForTesting = { message in asked = message; return 0 }   // Cancel
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertFalse(saved)
        XCTAssertEqual(asked, "“cancel-changed.jpg” changed while you were editing it.")
        XCTAssertTrue(viewer.contentRootForTesting.isEditModeActive, "edit mode is not left without a word")
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(try Data(contentsOf: url), other, "Cancel changes nothing on disk")
    }

    func testCommandSWithEditsThatCancelOutOnAFileChangedOnDisk_saveAnywayWrites() async throws {
        let url = dir.appendingPathComponent("cancel-changed2.jpg")
        try Self.writeImage(url, type: .jpeg)
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        let controller = try await enterEditWithCancellingColor(viewer, url: url)
        let other = try rewriteBehindTheEditorsBack(url)
        var asked = false
        viewer.alertResponderForTesting = { _ in asked = true; return 1 }   // Save Anyway
        let saved = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(saved)
        XCTAssertTrue(asked)
        XCTAssertFalse(controller.isActive)
        XCTAssertNotEqual(try Data(contentsOf: url), other, "Save Anyway writes, as with real edits")
        let records = await store.records(for: url)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(try records.first.map { try Data(contentsOf: $0.backupURL) }, other, "the version on disk was backed up first")
    }

    /// Rotate, ⌘S, rotate back, ⌘S: each ⌘S starts from the saved file, so
    /// the second one is a real change and the file ends in the original orientation.
    func testRotateSaveRotateBackSaveEndsInTheOriginalOrientation() async throws {
        let url = dir.appendingPathComponent("twice.jpg")
        try Self.writeImage(url, type: .jpeg)
        XCTAssertEqual(try orientedSize(url), CGSize(width: 16, height: 8))
        let viewer = try await viewer(url, store: store)
        defer { viewer.close() }
        try await enterEditWithRotate(viewer, url: url)
        let first = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(first)
        XCTAssertEqual(try orientedSize(url), CGSize(width: 8, height: 16), "rotate + ⌘S writes")

        let ready = await waitUntil { viewer.navCoalescer.isIdle && viewer.displayedItem?.group.primary == url }
        XCTAssertTrue(ready)
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: Self.image(width: 8, height: 16), url: url, landOn: .rotate)
        content.editModeController.appendSnapped90(quarters: -1)
        await content.editModeController.settleForTesting()
        let second = await viewer.saveEditedFile(asPanel: false)
        XCTAssertTrue(second)
        XCTAssertFalse(content.isEditModeActive)
        XCTAssertEqual(try orientedSize(url), CGSize(width: 16, height: 8), "rotate back + ⌘S writes")
    }
}

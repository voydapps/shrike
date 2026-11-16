//
//  BatchConfirmOriginalsTests.swift
//  ShrikeUITests
//
//  A batch that would change original files (in place, or an output folder
//  that is a photo's own folder) asks "Change N original photos?" first.
//  Cancel is the default for Return and Esc. Temp copies only.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

@MainActor
final class BatchConfirmOriginalsTests: XCTestCase {

    private var dir: URL!
    private var backups: BackupStore!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-confirm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        backups = BackupStore(root: dir.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        await BatchUndo.lastTask?.value
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent("src").appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 240, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 160))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeModel() -> BatchModel {
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        return BatchModel(runner: runner, presetStore: BatchPresetStore(fileURL: dir.appendingPathComponent("p.plist")))
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func rotateInPlaceModel(_ urls: [URL]) -> BatchModel {
        let model = makeModel()
        model.add(urls.map { ImageGroup(primary: $0) })
        model.form.convertOn = false
        model.form.resizeOn = false
        model.form.rotateOn = true
        model.form.rotation = .right
        return model
    }

    func testInPlaceRunAsksAndCancelChangesNothing() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let before = try urls.map { try Data(contentsOf: $0) }
        let model = rotateInPlaceModel(urls)
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        var asked: [(String, String)] = []
        model.confirmChangeOriginals = { title, info in asked.append((title, info)); return false }
        model.requestRun()
        let answered = await waitUntil { !asked.isEmpty }
        XCTAssertTrue(answered)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked.first?.0, "Change 2 original photos?")
        XCTAssertEqual(model.confirmButtonTitle, "Change Originals")
        XCTAssertEqual(asked.first?.1, "Shrike keeps a backup of each original, and Undo or Revert can restore them.")
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }

    /// A rename in place changes no pixels: the question says Undo Batch puts
    /// the names back, not that a backup is kept.
    func testRenameOnlyConfirmSaysUndoBatchNotBackup() async throws {
        XCTAssertEqual(BatchModel.ConfirmCopy.information(1, renameOnly: true),
                       "Only the name changes. Undo Batch can put the old name back.")
        XCTAssertEqual(BatchModel.ConfirmCopy.information(3, renameOnly: true, otherFilesReplaced: 1),
                       "Only the names change. Undo Batch can put the old names back. 1 other file will be replaced and moved to the Trash.")
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let model = makeModel()
        model.add(urls.map { ImageGroup(primary: $0) })
        model.form.convertOn = false; model.form.resizeOn = false; model.form.rotateOn = false
        model.form.renameOn = true; model.form.template = "pic-{counter}"
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        var asked: [String] = []
        model.confirmChangeOriginals = { _, info in asked.append(info); return false }
        model.requestRun()
        let answered = await waitUntil { !asked.isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual(asked.first, "Only the names change. Undo Batch can put the old names back.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].path), "Cancel renames nothing")
    }

    /// R2: photos added and form changes made while the question is up are
    /// refused, so the run changes exactly the photos the question named.
    func testAddWhileConfirmingIsRefusedAndTheNamedCountRuns() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let extra = try [jpeg("c.jpg"), jpeg("d.jpg"), jpeg("e.jpg")]
        let extraBefore = try extra.map { try Data(contentsOf: $0) }
        let model = rotateInPlaceModel(urls)
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        var title = ""
        model.confirmChangeOriginals = { t, _ in
            title = t
            model.add(extra.map { ImageGroup(primary: $0) })
            model.form.rotation = .left
            try? await Task.sleep(for: .milliseconds(400))   // past the 150 ms preview
            return true
        }
        model.requestRun()
        let started = await waitUntil { model.phase != .form }
        XCTAssertTrue(started)
        await model.waitForRun()
        XCTAssertEqual(title, "Change 2 original photos?")
        XCTAssertEqual(model.queue.count, 2, "nothing joins the queue while the question is up")
        XCTAssertEqual(model.lastPlan?.items.count, 2, "the run changes the photos the question named")
        XCTAssertEqual(model.form.rotation, .right)
        XCTAssertEqual(try extra.map { try Data(contentsOf: $0) }, extraBefore)
    }

    /// R2 defence in depth: a new plan between the question and the answer
    /// (even one with the same photos) does not run; the form stays.
    func testPlanChangeBetweenQuestionAndAnswerDoesNotRun() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let before = try urls.map { try Data(contentsOf: $0) }
        let model = rotateInPlaceModel(urls)
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        model.confirmChangeOriginals = { _, _ in
            model.schedulePreview()
            _ = await self.waitUntil { model.canRun }
            return true
        }
        model.requestRun()
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.phase, .form)
        XCTAssertFalse(model.isConfirming)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
    }

    /// R2: Photo ▸ Batch… from a browser while the question is up adds
    /// nothing and keeps Undo on the window that asked.
    func testOpenWhileConfirmingAddsNothingAndKeepsTheLauncher() async throws {
        BatchWindowController.presentsWindows = false
        defer { BatchWindowController.presentsWindows = true }
        let a = try jpeg("a.jpg"), b = try jpeg("b.jpg")
        let services = ShrikeServices.makeDefault()
        let batch = BatchWindowController.open(groups: [ImageGroup(primary: a)], services: services, launcher: nil)
        defer { batch.close() }
        batch.model.form.convertOn = false
        batch.model.form.resizeOn = false
        batch.model.form.rotateOn = true
        let ready = await waitUntil { batch.model.canRun }
        XCTAssertTrue(ready)
        var answer: CheckedContinuation<Bool, Never>?
        batch.model.confirmChangeOriginals = { _, _ in await withCheckedContinuation { answer = $0 } }
        batch.model.requestRun()
        let asking = await waitUntil { answer != nil }
        XCTAssertTrue(asking)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50), styleMask: [.titled],
                             backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        XCTAssertTrue(BatchWindowController.open(groups: [ImageGroup(primary: b)], services: services,
                                                 launcher: other) === batch)
        XCTAssertEqual(batch.model.queue.count, 1)
        XCTAssertNil(batch.launcher)
        answer?.resume(returning: false)
        let closed = await waitUntil { !batch.model.isConfirming }
        XCTAssertTrue(closed)
    }

    /// While the question is up, every other change to the queue or the
    /// form is refused too: the run changes exactly what the question named.
    /// Batch has no drop target of its own; photos dropped or opened onto a
    /// finished Batch arrive through `replaceQueue`.
    func testEveryQueueAndFormChangeIsRefusedWhileConfirming() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg"), jpeg("c.jpg")]
        let extra = try jpeg("d.jpg")
        let model = rotateInPlaceModel(urls)
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        let preset = try XCTUnwrap(BatchPresetStore.builtIns.first { $0.renameTemplate != nil })
        let attempts: [(String, () -> Void)] = [
            ("move", { model.move(from: IndexSet(integer: 0), to: 3) }),
            ("remove", { model.selection = [urls[1]]; model.removeSelected() }),
            ("preset change", { model.apply(preset) }),
            ("Run Another", { model.runAnother() }),
            ("drop", { model.replaceQueue(with: [ImageGroup(primary: extra)]) }),
        ]
        var answer: CheckedContinuation<Bool, Never>?
        model.confirmChangeOriginals = { _, _ in await withCheckedContinuation { answer = $0 } }
        model.requestRun()
        let asking = await waitUntil { answer != nil }
        XCTAssertTrue(asking)
        let form = model.form
        for (name, attempt) in attempts {
            attempt()
            XCTAssertEqual(model.queue.map(\.group.primary), urls, "\(name) is refused")
            XCTAssertEqual(model.form, form, "\(name) leaves the form")
            XCTAssertEqual(model.phase, .form, "\(name)")
            XCTAssertTrue(model.isConfirming, "\(name)")
        }
        answer?.resume(returning: false)
        let closed = await waitUntil { !model.isConfirming }
        XCTAssertTrue(closed)
        XCTAssertEqual(model.queue.map(\.group.primary), urls)
    }

    func testSinglePhotoTitleNamesThePhoto() async throws {
        let model = rotateInPlaceModel([try jpeg("X.jpg")])
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        var title = ""
        model.confirmChangeOriginals = { t, _ in title = t; return false }
        model.requestRun()
        let answered = await waitUntil { !title.isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual(title, "Change the original photo “X.jpg”?")
        XCTAssertEqual(model.confirmButtonTitle, "Change Original", "one photo: the button is singular too")
        XCTAssertEqual(BatchModel.ConfirmCopy.confirm(1), "Change Original")
        XCTAssertEqual(BatchModel.ConfirmCopy.confirm(2), "Change Originals")
    }

    func testConfirmingRunsAndKeepsBackups() async throws {
        let urls = try [jpeg("a.jpg")]
        let before = try Data(contentsOf: urls[0])
        let model = rotateInPlaceModel(urls)
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        model.confirmChangeOriginals = { _, _ in true }
        model.requestRun()
        let started = await waitUntil { model.phase != .form }
        XCTAssertTrue(started)
        await model.waitForRun()
        XCTAssertEqual(model.phase, .done)
        XCTAssertNotEqual(try Data(contentsOf: urls[0]), before)
        let backupFiles = FileManager.default.enumerator(at: dir.appendingPathComponent("_backups"), includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { ($0 as? URL).flatMap { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true ? $0 : nil } } ?? []
        XCTAssertFalse(backupFiles.isEmpty, "the original is backed up first")
    }

    func testOutputFolderThatIsThePhotosOwnFolderAsksToo() async throws {
        let url = try jpeg("a.jpg")
        let model = makeModel()
        model.add([ImageGroup(primary: url)])
        model.form.convertOn = false
        model.form.resizeOn = true
        model.form.resizeMode = .longEdge
        model.form.resizeValue = 100
        model.form.outputFolder = url.deletingLastPathComponent()
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready, model.validationLine ?? "")
        var title = ""
        model.confirmChangeOriginals = { t, _ in title = t; return false }
        model.requestRun()
        let answered = await waitUntil { !title.isEmpty }
        XCTAssertTrue(answered)
        XCTAssertEqual(title, "Change the original photo “a.jpg”?")
    }

    func testOutputToAnotherFolderRunsWithoutAsking() async throws {
        let url = try jpeg("a.jpg")
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = makeModel()
        model.add([ImageGroup(primary: url)])
        model.form.convertOn = false
        model.form.resizeOn = true
        model.form.resizeMode = .longEdge
        model.form.resizeValue = 100
        model.form.outputFolder = out
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready, model.validationLine ?? "")
        var asked = false
        model.confirmChangeOriginals = { _, _ in asked = true; return false }
        model.requestRun()
        XCTAssertEqual(model.phase, .running)
        await model.waitForRun()
        XCTAssertFalse(asked)
    }

    /// A spy target so a key press can be seen without running a modal.
    private final class Spy: NSObject {
        var fired: [String] = []
        @objc func hit(_ sender: NSButton) { fired.append(sender.title.replacingOccurrences(of: "\u{2063}", with: "")) }
    }

    private func key(_ chars: String, code: UInt16, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: chars,
                         charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testSafeCancelIsTheDefaultForReturnAndEsc() {
        let alert = ShrikeAlert.make(
            message: "Change 2 original photos?", information: "x",
            buttons: [ShrikeAlert.Button("Change Originals", role: .destructive), .safeCancel()])
        let spy = Spy()
        for b in alert.buttons { b.target = spy; b.action = #selector(Spy.hit(_:)) }
        let change = alert.buttons.first { $0.title == "Change Originals" }
        XCTAssertEqual(change?.keyEquivalent, "")
        XCTAssertTrue(change?.hasDestructiveAction ?? false)
        let window = alert.window
        _ = window.performKeyEquivalent(with: key("\u{1b}", code: 53, in: window))
        let afterEsc = spy.fired
        _ = window.performKeyEquivalent(with: key("\r", code: 36, in: window))
        XCTAssertEqual(afterEsc, ["Cancel"], "Esc fires Cancel")
        XCTAssertEqual(spy.fired, ["Cancel", "Cancel"], "Return fires Cancel, never Change Originals")
    }
}

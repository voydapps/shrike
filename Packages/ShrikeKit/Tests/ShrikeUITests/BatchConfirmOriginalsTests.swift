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
        XCTAssertEqual(asked.first?.1, "Shrike keeps a backup of each original, and Undo or Revert can restore them.")
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, before)
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
        @objc func hit(_ sender: NSButton) { fired.append(sender.title) }
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

//
//  BatchWindowTests.swift
//  ShrikeUITests
//
//  The Batch window on temp copies: the entry
//  points (Browser selection / whole folder, viewer list, F2 with several
//  items), the live preview (debounce, 200 rows, clashes), validation,
//  presets, the close alert with Keep Running (Dock badge, bounce) and
//  the VoiceOver strings. Windows are built offscreen and never shown.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

@MainActor
final class BatchWindowTests: XCTestCase {

    private var dir: URL!
    private var backups: BackupStore!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-batch-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        backups = BackupStore(root: dir.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        BatchWindowController.presentsWindows = false
    }

    override func tearDown() async throws {
        if let current = BatchWindowController.current {
            await current.model.waitForRun()
            current.close()
        }
        BatchWindowController.presentsWindows = true
        await BatchUndo.lastTask?.value
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Fixtures

    @discardableResult
    private func jpeg(_ name: String, in sub: String = "src", w: Int = 240, h: Int = 160,
                      type: UTType = .jpeg, dateTaken: String? = nil) throws -> URL {
        let folder = dir.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let dateTaken {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: dateTaken]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// A 1 × 1 lossless WebP (ImageIO reads WebP but can't write it).
    private func webp(_ name: String, in sub: String = "src") throws -> URL {
        let bytes: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
                              0x56, 0x50, 0x38, 0x4c, 0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
                              0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0x00]
        let url = dir.appendingPathComponent(sub, isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        return url
    }

    private func groups(_ urls: [URL]) -> [ImageGroup] { urls.map { ImageGroup(primary: $0) } }

    private func makeModel() -> BatchModel {
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                 backups: backups)
        return BatchModel(runner: runner,
                          presetStore: BatchPresetStore(fileURL: dir.appendingPathComponent("presets.plist")))
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    private func orientation(_ url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private func names(in sub: String) -> [String] {
        let folder = dir.appendingPathComponent(sub, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private func runAndWait(_ model: BatchModel) async throws {
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready, "Run stays disabled: \(model.validationLine ?? "no line")")
        model.run()
        XCTAssertEqual(model.phase, .running)
        await model.waitForRun()
        XCTAssertEqual(model.phase, .done)
    }

    // MARK: 40 JPEGs → PNG, long edge 1000, into a folder

    func testVector1ConvertsFortyJPEGsToPNGAndKeepsOriginals() async throws {
        let sources = try (0..<40).map { try jpeg(String(format: "DSC_%04d.jpg", $0), w: 1200, h: 900) }
        let before = try sources.map { try Data(contentsOf: $0) }
        let model = makeModel()
        model.add(groups(sources))
        model.form.format = .png
        model.form.resizeMode = .longEdge
        model.form.resizeValue = 1000
        XCTAssertEqual(model.outputFolder?.lastPathComponent, "Shrike Export", "default <source>/Shrike Export")
        XCTAssertNil(model.inPlaceText)

        try await runAndWait(model)
        let out = dir.appendingPathComponent("src/Shrike Export", isDirectory: true)
        let made = names(in: "src/Shrike Export")
        XCTAssertEqual(made.count, 40)
        XCTAssertTrue(made.allSatisfy { $0.hasSuffix(".png") })
        XCTAssertEqual(pixelSize(out.appendingPathComponent("DSC_0000.png")), CGSize(width: 1000, height: 750))
        for (i, url) in sources.enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), before[i], "original \(i) untouched")
        }
        XCTAssertEqual(model.summary, "Done. 40 images converted.")
        XCTAssertTrue(model.skippedRows.isEmpty)
        XCTAssertNil(model.undoActionName, "new files: no undo")
        XCTAssertEqual(model.doneFolders, [out])
    }

    // MARK: Stop at 10 leaves no partial files

    func testVector2StopAtTenLeavesNoPartialFiles() async throws {
        let sources = try (0..<40).map { try jpeg(String(format: "IMG_%04d.jpg", $0), w: 2400, h: 1800) }
        let model = makeModel()
        model.add(groups(sources))
        model.form.format = .png
        model.form.resizeValue = 2000
        model.onProgress = { [weak model] done, _ in if done >= 10 { model?.stop() } }
        try await runAndWait(model)

        let result = try XCTUnwrap(model.result)
        XCTAssertLessThan(result.doneCount, 40, "the Stop took effect")
        XCTAssertGreaterThanOrEqual(result.doneCount, 10)
        let made = names(in: "src/Shrike Export")
        XCTAssertEqual(made.count, result.doneCount, "only finished files: \(made)")
        let out = dir.appendingPathComponent("src/Shrike Export", isDirectory: true)
        for name in made {
            XCTAssertFalse(name.hasPrefix("."), "no temp file \(name)")
            XCTAssertEqual(pixelSize(out.appendingPathComponent(name)), CGSize(width: 2000, height: 1500),
                           "\(name) is whole")
        }
        XCTAssertTrue(model.skippedRows.contains { $0.reason == "Cancelled." })
        XCTAssertTrue(model.summary.hasPrefix("Done. \(result.doneCount) images converted, "))
    }

    // MARK: {yyyy-MM-dd}_{lens}_{counter:00} with no lens data

    func testVector3MissingLensCollapsesSeparators() async throws {
        let src = try jpeg("DSC_0001.jpg", dateTaken: "2026:09:25 10:00:00")
        let model = makeModel()
        model.add(groups([src]))
        model.form.convertOn = false
        model.form.resizeOn = false
        model.form.renameOn = true
        model.form.template = "{yyyy-MM-dd}_{lens}_{counter:00}"
        XCTAssertEqual(model.inPlaceText, "In place")
        let previewed = await waitUntil { model.isPreviewCurrent }
        XCTAssertTrue(previewed)
        XCTAssertEqual(model.previewRows.first?.outputName, "2026-09-25_01.jpg")

        try await runAndWait(model)
        XCTAssertEqual(names(in: "src"), ["2026-09-25_01.jpg"])
        XCTAssertEqual(model.summary, "Done. 1 image renamed.")
        XCTAssertEqual(model.undoActionName, "Batch Rename")
    }

    // MARK: Rotate only: 3 JPEGs rewritten, the WebP skipped

    func testVector4RotateOnlySkipsWebPWithReason() async throws {
        let jpegs = try (1...3).map { try jpeg("R\($0).jpg") }
        let webpFile = try webp("R4.webp")
        let webpBefore = try Data(contentsOf: webpFile)
        let model = makeModel()
        model.add(groups(jpegs + [webpFile]))
        model.form.convertOn = false
        model.form.resizeOn = false
        model.form.rotateOn = true
        model.form.rotation = .right
        XCTAssertEqual(model.inPlaceText, "In place — originals are kept (Settings ▸ Editing)")
        let previewed = await waitUntil { model.isPreviewCurrent }
        XCTAssertTrue(previewed)
        XCTAssertEqual(model.previewRows.last?.skip, .cannotRotateLosslessly, "the preview says so first")

        try await runAndWait(model)
        for url in jpegs { XCTAssertEqual(orientation(url), 6, "\(url.lastPathComponent): EXIF rewrite") }
        XCTAssertEqual(try Data(contentsOf: webpFile), webpBefore)
        XCTAssertEqual(model.skippedRows, [BatchModel.SkippedRow(
            name: "R4.webp", reason: "This file type can't be rotated without re-encoding — skipped.")])
        XCTAssertEqual(model.summary, "Done. 3 images rotated, 1 skipped.")
        XCTAssertEqual(model.undoActionName, "Batch Rotate")
    }

    // MARK: ⌘Z after a batch rename (F2 with several items)

    func testVector5UndoAfterBatchRenameRestoresAllNames() async throws {
        let originals = ["A.jpg", "B.jpg", "C.jpg"]
        for name in originals { try jpeg(name, in: "trip") }
        let folder = dir.appendingPathComponent("trip", isDirectory: true)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let browser = BrowserWindowController(services: services, initialFolder: folder)
        defer { browser.close() }
        let content = browser.contentController
        let listed = await waitUntil { content.visibleItems.count == 3 }
        XCTAssertTrue(listed)
        XCTAssertTrue(content.select(urls: content.visibleItems.map(\.url)))

        browser.renameSelection()   // F2 with several items
        let batch = try XCTUnwrap(BatchWindowController.current)
        let model = batch.model
        XCTAssertEqual(model.queue.count, 3)
        XCTAssertTrue(model.form.renameOn, "opens with Rename on")
        XCTAssertFalse(model.form.writesToFolder, "rename in place")
        XCTAssertEqual(model.presetTitle, "Rename by date")
        model.form.template = "Trip_{counter:000}"

        try await runAndWait(model)
        XCTAssertEqual(names(in: "trip"), ["Trip_001.jpg", "Trip_002.jpg", "Trip_003.jpg"])
        let undo = try XCTUnwrap(browser.window?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Batch Rename")

        undo.undo()
        await BatchUndo.lastTask?.value
        XCTAssertEqual(names(in: "trip"), originals)
    }

    // MARK: Entry points

    func testBrowserBatchTakesSelectionOrWholeFolder() async throws {
        for name in ["a.jpg", "b.jpg", "c.jpg"] { try jpeg(name, in: "folder") }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(),
                                              initialFolder: dir.appendingPathComponent("folder"))
        defer { browser.close() }
        let content = browser.contentController
        let listed = await waitUntil { content.visibleItems.count == 3 }
        XCTAssertTrue(listed)
        content.deselectAll()
        XCTAssertTrue(browser.canPerform(.batch))

        browser.perform(.batch)
        let first = try XCTUnwrap(BatchWindowController.current)
        XCTAssertEqual(first.model.queue.map(\.name), ["a.jpg", "b.jpg", "c.jpg"], "nothing selected: the folder")
        XCTAssertEqual(first.window?.title, "Batch — 3 images")
        XCTAssertFalse(first.model.form.renameOn)
        first.close()
        XCTAssertNil(BatchWindowController.current)

        let chosen = content.visibleItems.suffix(2).map(\.url)
        XCTAssertTrue(content.select(urls: chosen))
        browser.perform(.batch)
        XCTAssertEqual(BatchWindowController.current?.model.queue.map(\.id), chosen, "the selection")

        let menuTitles = content.tableViewForTesting.menu?.items.map(\.title) ?? []
        XCTAssertTrue(menuTitles.contains("Batch…"), "context menu: \(menuTitles)")
        let item = try XCTUnwrap(content.tableViewForTesting.menu?.items.first { $0.title == "Batch…" })
        XCTAssertEqual(item.action, ShrikeMainMenu.commandAction)
        XCTAssertEqual(item.shrikeCommand, .batch)
    }

    func testViewerBatchTakesTheListAndASecondOpenAddsItems() async throws {
        let a = try jpeg("a.jpg"), b = try jpeg("b.jpg"), c = try jpeg("c.jpg")
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: groups([a, b]), startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        XCTAssertTrue(viewer.canPerform(.batch))
        XCTAssertEqual(ViewerKeyMap.action(for: .batch, context: .viewer), .batch)

        viewer.perform(.batch)
        let batch = try XCTUnwrap(BatchWindowController.current)
        XCTAssertEqual(batch.model.queue.map(\.id), [a, b])

        // A second ⌥⌘B adds to the open window (no duplicates).
        BatchWindowController.open(groups: groups([b, c]), services: services, launcher: viewer)
        XCTAssertTrue(BatchWindowController.current === batch, "one window")
        XCTAssertEqual(batch.model.queue.map(\.id), [a, b, c])
        XCTAssertEqual(batch.window?.title, "Batch — 3 images")

        let window = try XCTUnwrap(batch.window)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 760, height: 520))
        XCTAssertEqual(window.contentRect(forFrameRect: window.frame).size, NSSize(width: 880, height: 600))
        XCTAssertNil(window.toolbar, "no toolbar")
    }

    // MARK: Preview, validation, tokens

    func testPreviewDebouncesAndShowsTwoHundredRowsThenAndMore() async throws {
        let sources = try (0..<205).map { try jpeg(String(format: "P%03d.jpg", $0), w: 16, h: 12) }
        let model = makeModel()
        model.add(groups(sources))
        XCTAssertFalse(model.isPreviewCurrent, "waits 150 ms")
        XCTAssertEqual(BatchModel.previewDebounce, .milliseconds(150))
        let previewed = await waitUntil { model.isPreviewCurrent }
        XCTAssertTrue(previewed)
        XCTAssertEqual(model.previewRows.count, 200)
        XCTAssertEqual(model.moreCount, 5)
        XCTAssertEqual(BatchModel.Copy.andMore(model.moreCount), "and 5 more")
        XCTAssertEqual(model.previewRows.first?.outputName, "P000.jpg")

        // Drag to reorder: the moved item comes first.
        model.move(from: IndexSet(integer: 3), to: 0)
        XCTAssertEqual(model.queue.first?.name, "P003.jpg")
        model.selection = [model.queue[0].id, model.queue[1].id]
        model.removeSelected()
        XCTAssertEqual(model.queue.count, 203)
        XCTAssertEqual(model.title, "Batch — 203 images")
    }

    func testClashRowIsMarkedAndKeepBothRenames() async throws {
        let src = try jpeg("a.jpg")
        try jpeg("a.png", in: "src/Shrike Export")
        let model = makeModel()
        model.add(groups([src]))
        model.form.format = .png
        let previewed = await waitUntil { model.isPreviewCurrent }
        XCTAssertTrue(previewed)
        let row = try XCTUnwrap(model.previewRows.first)
        XCTAssertTrue(row.nameClash)
        XCTAssertEqual(row.outputName, "a 2.png", "Keep Both")
        XCTAssertEqual(BatchModel.Copy.nameClash, "Name already used")

        model.form.onConflict = .skip
        _ = await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.previewRows.first?.skip, .nameExists)
    }

    func testValidationLinesDisableRun() async throws {
        let model = makeModel()
        XCTAssertEqual(model.validationLine, "Add images to the queue.")
        XCTAssertFalse(model.canRun)

        model.add(groups([try jpeg("a.jpg")]))
        _ = await waitUntil { model.isPreviewCurrent }
        XCTAssertTrue(model.canRun)
        XCTAssertNil(model.validationLine)

        model.form.convertOn = false
        model.form.resizeOn = false
        _ = await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.validationLine, "Choose at least one operation.")
        XCTAssertFalse(model.canRun)

        model.form.renameOn = true
        model.form.template = "{foo}_{counter}"
        XCTAssertEqual(model.templateError, "Unknown token {foo}.")
        XCTAssertEqual(model.validationLine, "Unknown token {foo}.")
        XCTAssertFalse(model.canRun)

        model.form.template = "{name"
        XCTAssertEqual(model.templateError, "Missing “}” in the name.")

        model.form.template = "{name}_x"
        _ = await waitUntil { model.isPreviewCurrent }
        XCTAssertNil(model.templateError)
        XCTAssertTrue(model.canRun)

        // Convert on with an output folder that can't exist.
        model.form.convertOn = true
        model.form.outputFolder = URL(fileURLWithPath: "/nonexistent-shrike-\(UUID().uuidString)/out")
        _ = await waitUntil { model.isPreviewCurrent }
        XCTAssertEqual(model.validationLine, "Choose an output folder.")
        XCTAssertFalse(model.canRun)
    }

    func testTokensPopoverListsEveryToken() {
        let listed = BatchTokens.groups.flatMap(\.tokens)
        XCTAssertEqual(Set(listed), Set(RenameTemplate.tokens))
        XCTAssertEqual(listed.count, RenameTemplate.tokens.count, "no token twice")
        // Every chip parses.
        for token in listed { XCTAssertNoThrow(try RenameTemplate(parsing: token)) }
    }

    func testResizeModeSwitchResetsNumber() {
        let model = makeModel()
        model.setResizeMode(.percent)
        XCTAssertEqual(model.form.resizeValue, 50)
        model.setResizeMode(.width)
        XCTAssertEqual(model.form.resizeValue, 2048)
        model.form.resizeValue = 800
        model.setResizeMode(.height)
        XCTAssertEqual(model.form.resizeValue, 800, "pixels to pixels keeps the number")
    }

    // MARK: Presets

    func testPresetsMatchApplySaveAndDelete() async throws {
        let model = makeModel()
        await model.reloadPresets()
        XCTAssertEqual(model.presets.map(\.name), ["Web 2048", "Email 1280", "Rename by date"])
        XCTAssertEqual(model.presetTitle, "Web 2048", "the default form")
        XCTAssertNil(model.deletablePresetName, "built-ins can't be deleted")
        // The Preset menu checks exactly the current preset.
        XCTAssertEqual(model.presets.filter(model.isCurrent).map(\.name), ["Web 2048"])

        model.apply(try XCTUnwrap(model.presets.first { $0.name == "Email 1280" }))
        XCTAssertEqual(model.form.quality, 80)
        XCTAssertEqual(model.form.resizeValue, 1280)
        XCTAssertEqual(model.presetTitle, "Email 1280")

        model.form.quality = 70
        XCTAssertEqual(model.presetTitle, "Custom")
        XCTAssertEqual(model.presets.filter(model.isCurrent).map(\.name), [], "Custom checks nothing")
        try await model.savePreset(named: "Mine")
        XCTAssertEqual(model.presets.last?.name, "Mine")
        XCTAssertEqual(model.presetTitle, "Mine")
        XCTAssertEqual(model.deletablePresetName, "Mine")
        XCTAssertEqual(model.presets.filter(model.isCurrent).map(\.name), ["Mine"])

        do {
            try await model.savePreset(named: "Web 2048")
            XCTFail("built-in names are taken")
        } catch {
            XCTAssertEqual(error as? BatchPresetError, .builtInName("Web 2048"))
        }

        try await model.deletePreset(named: "Mine")
        XCTAssertFalse(model.presets.contains { $0.name == "Mine" })
        XCTAssertEqual(model.presetTitle, "Custom")

        model.apply(try XCTUnwrap(model.presets.first { $0.name == "Rename by date" }))
        XCTAssertFalse(model.form.convertOn)
        XCTAssertFalse(model.form.resizeOn)
        XCTAssertTrue(model.form.renameOn)
        XCTAssertEqual(model.form.template, "{yyyy-MM-dd}_{counter:000}")
    }

    func testSavePresetThroughTheWindow() async throws {
        let batch = BatchWindowController.open(groups: groups([try jpeg("a.jpg")]),
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        batch.presetNameResponder = { "Night JPEGs \(UUID().uuidString.prefix(6))" }
        batch.model.form.quality = 93
        batch.savePreset()
        let saved = await waitUntil { batch.model.presetTitle.hasPrefix("Night JPEGs") }
        XCTAssertTrue(saved)
        let name = batch.model.presetTitle

        // Delete asks first; Cancel keeps the preset.
        var asked: [String] = []
        batch.deletePresetResponder = { asked.append($0); return false }
        batch.deletePreset(name)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(asked, ["Delete the preset “\(name)”?"])
        XCTAssertEqual(batch.model.presetTitle, name)
        XCTAssertTrue(batch.model.presets.contains { $0.name == name })

        batch.deletePresetResponder = { _ in true }
        batch.deletePreset(name)
        let deleted = await waitUntil { batch.model.presetTitle == "Custom" }
        XCTAssertTrue(deleted)
        XCTAssertFalse(batch.model.presets.contains { $0.name == name })
    }

    // MARK: Close while running, Dock badge, VoiceOver

    func testKeepRunningHidesWindowBadgesDockAndBouncesAtTheEnd() async throws {
        let sources = try (0..<24).map { try jpeg(String(format: "K%02d.jpg", $0), w: 2000, h: 1500) }
        let batch = BatchWindowController.open(groups: groups(sources),
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        var badges: [String?] = []
        var bounces = 0
        var announced: [String] = []
        var asked: (String, String)?
        batch.dockBadge = { badges.append($0) }
        batch.requestAttention = { bounces += 1 }
        batch.announce = { announced.append($0) }
        batch.closeAlertResponder = { message, info in
            asked = (message, info)
            return 1   // Keep Running
        }
        let model = batch.model
        model.form.format = .png
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        model.run()
        let window = try XCTUnwrap(batch.window)

        XCTAssertFalse(batch.windowShouldClose(window), "running: ask first")
        let hidden = await waitUntil(5) { batch.isHiddenWhileRunning }
        XCTAssertTrue(hidden)
        XCTAssertEqual(asked?.0, "Stop the batch?")
        XCTAssertTrue(asked?.1.hasSuffix(" of 24 images are done.") ?? false, asked?.1 ?? "")
        XCTAssertTrue(badges.last??.hasSuffix("%") ?? false, "Dock badge: \(badges)")

        await model.waitForRun()
        XCTAssertEqual(model.phase, .done)
        XCTAssertNil(badges.last ?? "x", "badge cleared at the end")
        XCTAssertEqual(bounces, 1, "the Dock icon bounces once")
        XCTAssertFalse(batch.isHiddenWhileRunning)
        XCTAssertEqual(announced, ["Done. 24 images converted."], "VoiceOver hears the summary")
        XCTAssertTrue(batch.windowShouldClose(window), "done: closes without asking")
    }

    func testStopFromTheCloseAlertStopsAndCloses() async throws {
        let sources = try (0..<24).map { try jpeg(String(format: "S%02d.jpg", $0), w: 2000, h: 1500) }
        let batch = BatchWindowController.open(groups: groups(sources),
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        batch.announce = { _ in }
        batch.closeAlertResponder = { _, _ in 0 }   // Stop
        let model = batch.model
        model.form.format = .png
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        model.run()
        XCTAssertFalse(batch.windowShouldClose(try XCTUnwrap(batch.window)))
        await Task.yield()
        let stopping = await waitUntil(5) { model.isStopping || model.phase == .done }
        XCTAssertTrue(stopping)
        await model.waitForRun()
        let closed = await waitUntil(5) { BatchWindowController.current == nil }
        XCTAssertTrue(closed, "Stop closes the window once the batch has stopped")
        XCTAssertTrue(model.skippedRows.contains { $0.reason == "Cancelled." } || model.result?.doneCount == 24)
    }

    func testVoiceOverAndBadgeStrings() {
        XCTAssertEqual(BatchModel.Copy.progress(17, 42), "17 of 42")
        XCTAssertEqual(BatchModel.Copy.stopAlertInfo(17, 42), "17 of 42 images are done.")
        XCTAssertEqual(BatchWindowController.badge(completed: 17, total: 42), "40%")
        XCTAssertEqual(BatchModel.Copy.title(42), "Batch — 42 images")
        XCTAssertEqual(BatchModel.Copy.title(1), "Batch — 1 image")
        XCTAssertEqual(BatchModel.Copy.runButton(42), "Run 42 Images")
        XCTAssertEqual(BatchModel.eta(completed: 10, total: 20, elapsed: .seconds(10)), "about 10 s left")
        XCTAssertEqual(BatchModel.eta(completed: 1, total: 20, elapsed: .seconds(10)), "about 4 min left")
        XCTAssertNil(BatchModel.eta(completed: 0, total: 20, elapsed: .seconds(10)))
    }

    func testDoneViewActionsUseTheResult() async throws {
        let src = try jpeg("a.jpg")
        let batch = BatchWindowController.open(groups: groups([src]),
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        var revealed: [URL] = []
        var opened: [URL] = []
        batch.announce = { _ in }
        batch.revealInFinder = { revealed = $0 }
        batch.openInShrike = { opened = $0 }
        batch.pasteboard = NSPasteboard(name: NSPasteboard.Name("shrike.tests.batch.\(UUID().uuidString)"))
        defer { batch.pasteboard.releaseGlobally() }
        try await runAndWait(batch.model)

        let out = dir.appendingPathComponent("src/Shrike Export", isDirectory: true)
        // The calm Done view names the Output folder under the summary.
        XCTAssertTrue(batch.model.skippedRows.isEmpty)
        XCTAssertEqual(batch.model.resultFolder?.standardizedFileURL.path, out.standardizedFileURL.path)
        XCTAssertEqual(batch.model.resultFolderText, UserFacingPath.string(out))
        XCTAssertFalse(try XCTUnwrap(batch.model.resultFolderText).hasPrefix("/private/"))
        batch.showInFinder()
        XCTAssertEqual(revealed, [out.appendingPathComponent("a.jpg")])
        batch.openResultInShrike()
        XCTAssertEqual(opened, [out])
        batch.copyLog()
        let log = try XCTUnwrap(batch.pasteboard.string(forType: .string))
        XCTAssertTrue(log.hasPrefix("Done. 1 image converted."), log)
        XCTAssertTrue(log.contains("a.jpg → "), log)

        // A second ⌥⌘B after Done starts a fresh form with the new items.
        let b = try jpeg("b.jpg")
        BatchWindowController.open(groups: groups([b]), services: ShrikeServices.makeDefault(), launcher: nil)
        XCTAssertEqual(batch.model.phase, .form)
        XCTAssertEqual(batch.model.queue.map(\.id), [b])
    }
}

/// Offscreen pictures of the three views for a visual check. Runs only
/// when SHRIKE_BATCH_SNAPSHOT_DIR names a folder (never in a normal run).
@MainActor
final class BatchWindowSnapshotHarness: XCTestCase {

    func testRenderFormRunningAndDone() async throws {
        guard let out = ProcessInfo.processInfo.environment["SHRIKE_BATCH_SNAPSHOT_DIR"] else {
            throw XCTSkip("set SHRIKE_BATCH_SNAPSHOT_DIR to render")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-batch-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var urls: [URL] = []
        for i in 0..<6 {
            let url = dir.appendingPathComponent(String(format: "DSC_%04d.jpg", i))
            let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            CGImageDestinationFinalize(dest)
            urls.append(url)
        }
        BatchWindowController.presentsWindows = false
        defer { BatchWindowController.presentsWindows = true }
        let batch = BatchWindowController.open(groups: urls.map { ImageGroup(primary: $0) },
                                               services: ShrikeServices.makeDefault(), launcher: nil)
        defer { batch.close() }
        batch.announce = { _ in }
        let model = batch.model
        model.form.renameOn = true
        model.form.template = "{yyyy-MM-dd}_{foo}"
        try await Task.sleep(for: .milliseconds(400))
        try snapshot(batch, to: out, name: "batch-form-error")
        model.form.template = "{yyyy-MM-dd}_{counter:000}"
        try await Task.sleep(for: .milliseconds(600))
        batch.window?.appearance = NSAppearance(named: .aqua)
        try snapshot(batch, to: out, name: "batch-form")
        batch.window?.appearance = NSAppearance(named: .darkAqua)
        try snapshot(batch, to: out, name: "batch-form-dark")
        batch.window?.appearance = nil
        model.run()
        try snapshot(batch, to: out, name: "batch-running")
        await model.waitForRun()
        try await Task.sleep(for: .milliseconds(100))
        batch.window?.appearance = NSAppearance(named: .aqua)
        try snapshot(batch, to: out, name: "batch-done")
        batch.window?.appearance = NSAppearance(named: .darkAqua)
        try snapshot(batch, to: out, name: "batch-done-dark")

        // Rotate only, with a WebP that can't be rotated: the reason list.
        let webp = dir.appendingPathComponent("Z_0001.webp")
        try Data([0x52, 0x49, 0x46, 0x46, 0x1a, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50,
                  0x56, 0x50, 0x38, 0x4c, 0x0d, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00,
                  0x10, 0x07, 0x10, 0x11, 0x11, 0x88, 0x88, 0xfe, 0x07, 0x00]).write(to: webp)
        let renamed = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.path < $1.path }
        batch.close()
        let second = BatchWindowController.open(groups: (renamed.prefix(3) + [webp]).map { ImageGroup(primary: $0) },
                                                services: ShrikeServices.makeDefault(), launcher: nil)
        defer { second.close() }
        second.announce = { _ in }
        second.model.form.convertOn = false
        second.model.form.resizeOn = false
        second.model.form.renameOn = false
        second.model.form.rotateOn = true
        try await Task.sleep(for: .milliseconds(400))
        // Convert and Resize off: their labels and the Quality slider grey
        // out.
        second.window?.appearance = NSAppearance(named: .darkAqua)
        try snapshot(second, to: out, name: "batch-form-convert-off-dark")
        second.model.run()
        await second.model.waitForRun()
        try await Task.sleep(for: .milliseconds(100))
        second.window?.appearance = NSAppearance(named: .aqua)
        try snapshot(second, to: out, name: "batch-done-skipped")
        second.window?.appearance = NSAppearance(named: .darkAqua)
        try snapshot(second, to: out, name: "batch-done-skipped-dark")
    }

    private func snapshot(_ batch: BatchWindowController, to folder: String, name: String) throws {
        let window = try XCTUnwrap(batch.window)
        let view = try XCTUnwrap(window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        let scale = 2
        let size = view.bounds.size
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        if view.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        let isDark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ctx.setFillColor(isDark ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.93, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let layer = try XCTUnwrap(view.layer)
        layer.render(in: ctx)
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}

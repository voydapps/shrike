//
//  BatchAddNoDiskCheckTests.swift
//  ShrikeUITests
//
//  Adding photos to a Batch compares plain paths only (no disk call on the
//  main thread). The same photo queued again through a symbolic link to its
//  folder is dropped by the preview, off the main thread, before Run turns on.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import os
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

@MainActor
final class BatchAddNoDiskCheckTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-nodisk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func jpeg(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent("src").appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func makeModel() -> BatchModel {
        let backups = BackupStore(root: dir.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let model = BatchModel(runner: runner, presetStore: BatchPresetStore(fileURL: dir.appendingPathComponent("p.plist")))
        model.form.outputFolder = dir.appendingPathComponent("out", isDirectory: true)
        return model
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testAddCallsNoDiskCheckAndDropsPlainDuplicates() throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let model = makeModel()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        model.canonical = { url in calls.withLock { $0 += 1 }; return url.path }
        model.add(urls.map { ImageGroup(primary: $0) })
        model.add([ImageGroup(primary: urls[0])])
        XCTAssertEqual(model.queue.count, 2)
        XCTAssertEqual(calls.withLock { $0 }, 0, "no disk check in the calling turn")
    }

    func testThePhotoQueuedAgainThroughALinkIsDroppedOffMainBeforeRun() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let link = dir.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("src"))
        let model = makeModel()
        let onMain = OSAllocatedUnfairLock(initialState: [Bool]())
        model.canonical = { url in
            onMain.withLock { $0.append(Thread.isMainThread) }
            return GroupList.canonical(url)
        }
        model.add(urls.map { ImageGroup(primary: $0) })
        model.add([ImageGroup(primary: link.appendingPathComponent("a.jpg"))])
        XCTAssertEqual(model.queue.count, 3, "plain paths differ: kept for now")
        XCTAssertEqual(onMain.withLock { $0 }, [])
        let ready = await waitUntil { model.canRun }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.queue.map(\.group.primary), urls, "the later copy goes; the order stays")
        XCTAssertFalse(onMain.withLock { $0 }.isEmpty)
        XCTAssertFalse(onMain.withLock { $0 }.contains(true))
    }

    /// A photo queued once directly and once through a link to the FILE (in the
    /// same folder and in another one): the later copy goes, off the main thread.
    func testThePhotoQueuedAgainThroughAFileLinkIsDropped() async throws {
        let urls = try [jpeg("a.jpg"), jpeg("b.jpg")]
        let same = urls[0].deletingLastPathComponent().appendingPathComponent("a-link.jpg")
        let otherFolder = dir.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let other = otherFolder.appendingPathComponent("b-link.jpg")
        try FileManager.default.createSymbolicLink(at: same, withDestinationURL: urls[0])
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: urls[1])
        XCTAssertEqual(BatchModel.linkedDuplicates([urls[0], same], canonical: { GroupList.canonical($0) }), [same])
        let model = makeModel()
        model.add((urls + [same, other]).map { ImageGroup(primary: $0) })
        XCTAssertEqual(model.queue.count, 4, "plain paths differ: kept for now")
        let ready = await waitUntil { model.canRun && model.queue.count == 2 }
        XCTAssertTrue(ready)
        XCTAssertEqual(model.queue.map(\.group.primary), urls, "the later copies go; the order stays")
    }

    /// The note under the queue line: its two texts, adding up, and the resets.
    func testTheDuplicatesNoteCountsAndClears() async throws {
        XCTAssertNil(BatchModel.duplicatesNote(0))
        XCTAssertEqual(BatchModel.duplicatesNote(1), "1 duplicate was left out. It is the same photo as one already chosen.")
        XCTAssertEqual(BatchModel.duplicatesNote(3), "3 duplicates were left out. They are the same photos as ones already chosen.")
        let urls = try [jpeg("n1.jpg"), jpeg("n2.jpg")]
        let folder = dir.appendingPathComponent("note-links", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let links = urls.map { folder.appendingPathComponent("link-" + $0.lastPathComponent) }
        for (link, url) in zip(links, urls) { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url) }
        let model = makeModel()
        model.add([ImageGroup(primary: urls[0]), ImageGroup(primary: links[0])])
        var ready = await waitUntil { model.canRun && model.queue.count == 1 && model.droppedDuplicateCount == 1 }
        XCTAssertTrue(ready, "one left out")
        model.add([ImageGroup(primary: urls[1]), ImageGroup(primary: links[1])])
        ready = await waitUntil { model.canRun && model.queue.count == 2 && model.droppedDuplicateCount == 2 }
        XCTAssertTrue(ready, "it adds up while photos are added")
        model.selection = [urls[1]]
        model.removeSelected()
        XCTAssertEqual(model.droppedDuplicateCount, 0, "removing a photo clears it")
        model.add([ImageGroup(primary: links[0])])
        ready = await waitUntil { model.canRun && model.droppedDuplicateCount == 1 }
        XCTAssertTrue(ready)
        model.replaceQueue(with: [])
        XCTAssertEqual(model.droppedDuplicateCount, 0, "a new queue clears it")
        model.add([ImageGroup(primary: urls[0]), ImageGroup(primary: links[0])])
        ready = await waitUntil { model.canRun && model.droppedDuplicateCount == 1 }
        XCTAssertTrue(ready)
        model.forgetDroppedDuplicates()
        XCTAssertEqual(model.droppedDuplicateCount, 0, "closing the window clears it")
    }

    /// Pass 3b: the note's count is cleared when a run starts (not only when it ends).
    func testTheDuplicatesNoteClearsWhenARunStarts() async throws {
        let url = try jpeg("run1.jpg")
        let folder = dir.appendingPathComponent("run-links", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link-run1.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let model = makeModel()
        model.add([ImageGroup(primary: url), ImageGroup(primary: link)])
        let ready = await waitUntil { model.canRun && model.droppedDuplicateCount == 1 }
        XCTAssertTrue(ready, "one left out before the run")
        model.run()
        // In the same turn: no run has finished yet.
        XCTAssertEqual(model.phase, .running)
        XCTAssertEqual(model.droppedDuplicateCount, 0, "the run starting clears it")
        await model.waitForRun()
        XCTAssertEqual(model.droppedDuplicateCount, 0)
    }

    /// Pass 3b: the window's real close (its delegate callback), not a helper call.
    func testClosingTheBatchWindowClearsTheDuplicatesNote() async throws {
        let url = try jpeg("close1.jpg")
        let folder = dir.appendingPathComponent("close-links", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = folder.appendingPathComponent("link-close1.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let model = makeModel()
        let batch = BatchWindowController(model: model, launcher: nil)
        BatchWindowController.setCurrentForTesting(batch)
        defer { BatchWindowController.setCurrentForTesting(nil) }
        model.add([ImageGroup(primary: url), ImageGroup(primary: link)])
        let ready = await waitUntil { model.canRun && model.droppedDuplicateCount == 1 }
        XCTAssertTrue(ready, "one left out before the close")
        let window = try XCTUnwrap(batch.window)
        XCTAssertTrue(window.delegate === batch, "the controller hears the close")
        window.close()
        XCTAssertEqual(model.droppedDuplicateCount, 0, "closing the window clears it")
    }

    /// A photo and a link to it, in either order: the REAL file stays (an
    /// in-place rename must rename the photo, not the link). A link alone stays.
    func testThePhotoStaysAndItsLinkGoesInEitherOrder() async throws {
        let real = try jpeg("a.jpg")
        let otherFolder = dir.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        let link = otherFolder.appendingPathComponent("a-link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let canonical: (URL) -> String = { GroupList.canonical($0) }
        XCTAssertEqual(BatchModel.linkedDuplicates([real, link], canonical: canonical), [link])
        XCTAssertEqual(BatchModel.linkedDuplicates([link, real], canonical: canonical), [link], "link first: still the link goes")
        XCTAssertEqual(BatchModel.linkedDuplicates([link], canonical: canonical), [], "a link alone stays")
        for order in [[real, link], [link, real]] {
            let model = makeModel()
            model.add(order.map { ImageGroup(primary: $0) })
            let ready = await waitUntil { model.canRun && model.queue.count == 1 }
            XCTAssertTrue(ready, "\(order.map(\.lastPathComponent))")
            XCTAssertEqual(model.queue.map(\.group.primary), [real], "the real photo's entry is kept")
        }
        let alone = makeModel()
        alone.add([ImageGroup(primary: link)])
        let shown = await waitUntil { alone.canRun }
        XCTAssertTrue(shown)
        XCTAssertEqual(alone.queue.map(\.group.primary), [link])
    }

    func testOneFolderPathNeedsNoDiskCheckAtAll() {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let urls = ["a.jpg", "b.jpg"].map { dir.appendingPathComponent($0) }
        let later = BatchModel.linkedDuplicates(urls) { url in calls.withLock { $0 += 1 }; return url.path }
        XCTAssertEqual(later, [])
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }
}

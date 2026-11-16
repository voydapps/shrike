//
//  ReplaceUndoHistoryTests.swift
//  ShrikeEditTests
//
//  Review U2: after an export that replaced another photo, Undo (Batch, or the viewer's restore of the
//  returned record) brings the victim back WITH its own history: Revert gives the victim's own original,
//  not the exported image, and the history survives the clean-up.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class ReplaceUndoHistoryTests: XCTestCase {

    private var root: URL!
    private let clock = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("ReplaceUndo-\(UUID().uuidString)", isDirectory: true)
        for d in ["src", "out"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func store() -> BackupStore {
        let clock = self.clock
        return BackupStore(root: root.appendingPathComponent("Backups"), retentionDays: { 30 },
                           maxBytes: { 0 }, now: { clock.withLock { $0 } })
    }

    private func writeJPEG(_ url: URL, width: Int) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: Double(width % 7) / 7, green: 0.4, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 40))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    /// A victim whose own original (V0) is in its chain; the file on disk is V1 (a Shrike edit).
    private func victimWithHistory(_ s: BackupStore, named name: String, in sub: String) async throws -> (url: URL, v0: Data, original: BackupRecord) {
        let url = root.appendingPathComponent(sub).appendingPathComponent(name)
        try writeJPEG(url, width: 30)
        let v0 = try Data(contentsOf: url)
        let original = try await s.backup(url, reason: .save)
        try writeJPEG(url, width: 50)
        await s.noteWritten(url)
        return (url, v0, original)
    }

    func testBatchUndoOfAReplaceExportBringsTheVictimBackWithItsOwnOriginal() async throws {
        let s = store()
        let source = root.appendingPathComponent("src/a.jpg")
        try writeJPEG(source, width: 70)
        let victim = try await victimWithHistory(s, named: "a.jpg", in: "out")
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: s, watchers: nil), backups: s)
        let plan = BatchPlan(items: [ImageGroup(primary: source)], convert: ConvertOptions(format: .jpeg),
                             output: .folder(root.appendingPathComponent("out")), onConflict: .replace)
        var final: BatchResult?
        for try await p in runner.run(plan) { if let r = p.result { final = r } }
        let result = try XCTUnwrap(final)
        XCTAssertEqual(result.replacedOriginals.count, 1)
        _ = try await runner.undo(result)

        let availability = await s.availability(for: victim.url)
        XCTAssertTrue(availability.canRevert)
        XCTAssertEqual(availability.originalRecord?.id, victim.original.id, "Revert offers the victim's OWN original")
        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await s.purge(olderThan: 30)
        let kept = Set(await s.allRecords().map(\.id)).contains(victim.original.id)
        XCTAssertTrue(kept, "the victim lives: its original survives the clean-up")
        try await s.revertToOriginal(victim.url)
        XCTAssertEqual(try Data(contentsOf: victim.url), victim.v0)
    }

    /// The viewer's Undo of "Save As onto another photo" restores the record the export returned.
    func testRestoringTheRecordOfAReplaceExportHealsTheVictimsHistory() async throws {
        let s = store()
        let source = root.appendingPathComponent("src/a.jpg")
        try writeJPEG(source, width: 70)
        let victim = try await victimWithHistory(s, named: "b.jpg", in: "out")
        let record = try await ImageExporter(backupStore: s).export(
            recipe: EditRecipe(operations: []), from: source, to: victim.url, format: .jpeg)
        try await s.restore(try XCTUnwrap(record))
        let availability = await s.availability(for: victim.url)
        XCTAssertEqual(availability.originalRecord?.id, victim.original.id)
        clock.withLock { $0 = $0.addingTimeInterval(40 * 86_400) }
        await s.purge(olderThan: 30)
        let kept = Set(await s.allRecords().map(\.id)).contains(victim.original.id)
        XCTAssertTrue(kept)
    }

    /// Y3: the heal cannot save the victim's records (their folder is read-only). Batch Undo counts it in
    /// the photos whose backup information could not be saved.
    func testBatchUndoCountsAHealThatCouldNotBeSaved() async throws {
        let s = store()
        let source = root.appendingPathComponent("src/a.jpg")
        try writeJPEG(source, width: 70)
        let victim = try await victimWithHistory(s, named: "a.jpg", in: "out")
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: s, watchers: nil), backups: s)
        let plan = BatchPlan(items: [ImageGroup(primary: source)], convert: ConvertOptions(format: .jpeg),
                             output: .folder(root.appendingPathComponent("out")), onConflict: .replace)
        var final: BatchResult?
        for try await p in runner.run(plan) { if let r = p.result { final = r } }
        let result = try XCTUnwrap(final)
        let folder = victim.original.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notSaved = try await runner.undo(result).backupsNotSaved
        XCTAssertEqual(notSaved, 1, "the record the heal moved could not be saved: counted")
        let availability = await s.availability(for: victim.url)
        XCTAssertEqual(availability.originalRecord?.id, victim.original.id, "in memory the chain is right")
    }

    /// Y3: Batch Undo of a lossless rotate whose chain was put aside under the same path (another app
    /// changed the file, then a Shrike save started a new chain). The heal cannot save the rotate record
    /// (read-only folder): Batch Undo counts it.
    func testBatchRotateUndoCountsAHealThatCouldNotBeSaved() async throws {
        let s = store()
        let photo = root.appendingPathComponent("src/r.jpg")
        try writeJPEG(photo, width: 60)
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: s, watchers: nil), backups: s)
        var final: BatchResult?
        for try await p in runner.run(BatchPlan(items: [ImageGroup(primary: photo)], rotate: 1, output: .inPlace)) {
            if let r = p.result { final = r }
        }
        let result = try XCTUnwrap(final)
        let rotation = try XCTUnwrap(result.rotations.first)
        try writeJPEG(photo, width: 90)                                   // another app changes the file ...
        _ = try await s.backup(photo, reason: .save)                      // ... then a Shrike save: new chain
        let parked = await s.allRecords().first { $0.id == rotation.backup.id }
        XCTAssertEqual(parked?.detachedFrom, CanonicalPath.of(photo), "the rotate chain is guarded by the path")
        let folder = rotation.backup.backupURL.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let notSaved = try await runner.undo(result).backupsNotSaved
        XCTAssertEqual(notSaved, 1)
    }
}

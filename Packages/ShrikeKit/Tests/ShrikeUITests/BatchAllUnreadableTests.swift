//
//  BatchAllUnreadableTests.swift
//  ShrikeUITests
//
//  F4 rest: every queued photo unreadable → Run is grey, and the "What will
//  happen" line of spec 28 §4 says why (no validation line hides it). Window-free.
//

import XCTest
@testable import ShrikeUI
import ShrikeCore
import ShrikeEdit
import ShrikeIO

@MainActor
final class BatchAllUnreadableTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory.appendingPathComponent("shrike-batch-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        try? FileManager.default.removeItem(at: dir)
    }

    func testEveryPhotoUnreadableGreysRunAndSaysWhy() async throws {
        let bad = [dir.appendingPathComponent("a.jpg"), dir.appendingPathComponent("b.jpg")]
        for url in bad { try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: url) }
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let backups = BackupStore(root: dir.appendingPathComponent("backups"))
        let model = BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups))
        model.form.resizeOn = false; model.form.format = .png; model.form.outputFolder = out
        model.add(bad.map { ImageGroup(primary: $0) })
        await model.waitForPreview()
        XCTAssertEqual(model.processableCount, 0)
        XCTAssertFalse(model.canRun, "nothing would be processed")
        XCTAssertNil(model.validationLine, "no validation line hides the reason")
        XCTAssertEqual(model.unreadableLine, "2 photos can't be read and will be skipped.", "the §4 line says why Run is grey")
        XCTAssertEqual(BatchModel.Copy.runButton(model.processableCount), "Run")
    }
}

//
//  BatchOtherFilesReplacedTests.swift
//  ShrikeUITests
//
//  Pass 2k task 3: a batch rename with Replace names the files outside
//  the queue it replaces, in the confirm text and in the result summary.
//

import XCTest
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeEdit
@testable import ShrikeIO

final class BatchOtherFilesReplacedTests: XCTestCase {

    private typealias Confirm = BatchModel.ConfirmCopy

    func testStrings() {
        XCTAssertNil(Confirm.otherFilesReplaced(0))
        XCTAssertEqual(Confirm.otherFilesReplaced(1), "1 other file will be replaced and moved to the Trash.")
        XCTAssertEqual(Confirm.otherFilesReplaced(3), "3 other files will be replaced and moved to the Trash.")
        XCTAssertEqual(Confirm.information(1, otherFilesReplaced: 1),
                       "Shrike keeps a backup of the original, and Undo or Revert can restore it."
                       + " 1 other file will be replaced and moved to the Trash.")
        XCTAssertEqual(Confirm.information(2, otherFilesReplaced: 0), Confirm.information(2))
        XCTAssertNil(Confirm.otherFilesWereReplaced(0))
        XCTAssertEqual(Confirm.otherFilesWereReplaced(1), "1 other file was replaced.")
        XCTAssertEqual(Confirm.otherFilesWereReplaced(4), "4 other files were replaced.")
    }

    private func row(_ source: String, to dest: String, clash: Bool, skip: BatchSkipReason? = nil) -> BatchPreviewRow {
        BatchPreviewRow(source: ImageGroup(primary: URL(fileURLWithPath: "/p/\(source)")),
                        outputName: dest, destination: URL(fileURLWithPath: "/p/\(dest)"),
                        outputSize: nil, nameClash: clash, skip: skip)
    }

    /// Pass 2m task 8: counted from the analysis' whole-plan Replace targets, minus queued photos.
    func testCountsOnlyFilesOutsideTheQueue() {
        let queued = ["IMG_1.jpg", "IMG_2.jpg"].map { ImageGroup(primary: URL(fileURLWithPath: "/p/\($0)")) }
        let targets: Set<URL> = ["/p/Trip.jpg", "/p/IMG_1.jpg", "/p/Far.jpg"].map { URL(fileURLWithPath: $0) }
            .reduce(into: []) { $0.insert($1) }
        XCTAssertEqual(BatchModel.otherFilesReplacedPaths(targets: targets, queued: queued, replaces: true),
                       ["/p/Trip.jpg", "/p/Far.jpg"])
        XCTAssertEqual(BatchModel.otherFilesReplacedPaths(targets: targets, queued: queued, replaces: false), [])
    }

    /// The analysis lists Replace targets beyond the first preview rows.
    func testAnalysisListsReplaceTargetsForTheWholeQueue() throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-replace-all-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photos = try (0..<5).map { i -> URL in
            let url = dir.appendingPathComponent("p\(i).jpg")
            try Data([0xFF, 0xD8, 0xFF]).write(to: url)
            try Data([1]).write(to: dir.appendingPathComponent("p\(i)_x.jpg"))
            return url
        }
        let plan = BatchPlan(items: photos.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{name}_x"), output: .inPlace, onConflict: .replace)
        let backups = BackupStore(root: dir.appendingPathComponent("_backups"), retentionDays: { 30 })
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let analysis = runner.analyze(plan, limit: 2)
        XCTAssertEqual(analysis.rows.count, 2)
        let names: Set<String> = Set(analysis.replaceTargets.map { $0.lastPathComponent })
        XCTAssertEqual(names, Set((0..<5).map { "p\($0)_x.jpg" }))
    }

    /// Pass 2m task 4 (28a round 8): the row words per "If a file exists" answer.
    func testRowClashTextPerPolicy() {
        let clash = row("IMG_1.jpg", to: "IMG_2.jpg", clash: true)
        let free = row("IMG_1.jpg", to: "Free.jpg", clash: false)
        XCTAssertEqual(BatchPreviewRowLook.clashText(clash, policy: .replace, replacesOutsideFile: true),
                       "Replaces “IMG_2.jpg”.")
        XCTAssertNil(BatchPreviewRowLook.clashText(clash, policy: .replace, replacesOutsideFile: false))
        XCTAssertNil(BatchPreviewRowLook.clashText(row("IMG_1.jpg", to: "IMG_2 2.jpg", clash: true),
                                                   policy: .keepBoth, replacesOutsideFile: false))
        XCTAssertEqual(BatchPreviewRowLook.clashText(row("IMG_1.jpg", to: "IMG_2.jpg", clash: true, skip: .nameExists),
                                                     policy: .skip, replacesOutsideFile: false),
                       "Skipped. A file with this name exists.")
        for policy in [ConflictAnswer.Action.replace, .keepBoth, .skip] {
            XCTAssertNil(BatchPreviewRowLook.clashText(free, policy: policy, replacesOutsideFile: false))
        }
    }

    // MARK: Pass 2n task 1

    /// A form change keeps the replaced list with the old rows until the new preview lands.
    @MainActor
    func testFormChangeKeepsTheReplacedListUntilTheNewPreviewLands() async throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-replace-keep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("p.jpg")
        _ = try SaveFlowTests.writeImage(photo, type: .jpeg)
        try Data([1]).write(to: dir.appendingPathComponent("victim.jpg"))
        let backups = BackupStore(root: dir.appendingPathComponent("_backups"), retentionDays: { 30 })
        let model = BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups))
        var form = BatchForm(); form.convertOn = false; form.resizeOn = false; form.renameOn = true
        form.template = "victim"; form.onConflict = .replace; model.form = form
        model.add([ImageGroup(primary: photo)]); await model.waitForPreview()
        XCTAssertEqual(model.otherFilesReplaced, 1)
        let row = try XCTUnwrap(model.previewRows.first)
        XCTAssertEqual(model.clashText(for: row), "Replaces “victim.jpg”.")
        model.form.counterStart = 7          // a new preview is scheduled; the old rows stay
        XCTAssertFalse(model.isPreviewCurrent)
        XCTAssertEqual(model.clashText(for: row), "Replaces “victim.jpg”.", "no 150 ms gap")
        await model.waitForPreview()
        XCTAssertEqual(model.otherFilesReplaced, 1)
    }

    func testStoppedRenameSummaryKeepsTheOtherFilesLineLast() {
        XCTAssertEqual(BatchModel.stoppedRenameSummary(["38 of 60 photos have their new names."], otherFilesReplaced: 2),
                       "38 of 60 photos have their new names.\n2 other files were replaced.")
        XCTAssertEqual(BatchModel.stoppedRenameSummary(["a", "b"], otherFilesReplaced: 0), "a\nb")
    }

    /// The name-clash alert's real text builder fills both lines for real files.
    @MainActor
    func testConflictDetailsFillExistingAndNewLines() throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-clash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let existing = dir.appendingPathComponent("IMG_1.jpg"), incoming = dir.appendingPathComponent("IMG_1 new.jpg")
        _ = try SaveFlowTests.writeImage(existing, type: .jpeg)
        _ = try SaveFlowTests.writeImage(incoming, type: .png)
        let lines = FileTransferCopy.conflictDetails(existing: existing, incoming: incoming).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Existing: ") && lines[1].hasPrefix("New: "), "\(lines)")
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1)[1].components(separatedBy: ", ")
            XCTAssertGreaterThanOrEqual(parts.count, 3, "size, bytes, date (the date may hold a comma): \(line)")
            XCTAssertTrue(parts[0].contains(" × "), line)
        }
    }
}

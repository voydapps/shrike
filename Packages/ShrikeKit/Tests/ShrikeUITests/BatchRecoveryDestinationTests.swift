import XCTest
import ImageIO
@testable import ShrikeUI
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// Model/runner/file coverage. Rendered Output/Choose and real folder-panel
/// binding/Cancel are required separately in normal-production native F01 QA.
@MainActor
final class BatchRecoveryDestinationTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-batch-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        try? FileManager.default.removeItem(at: dir)
    }

    func testFolderRecoveryUsesUpdatedDestinationAndPreservesCompletedOutput() async throws {
        let good = dir.appendingPathComponent("good.png"), broken = dir.appendingPathComponent("broken.png")
        let originalBytes = try SaveFlowTests.writeImage(good, type: .png)
        try Data([0, 1, 2]).write(to: broken)
        let firstFolder = dir.appendingPathComponent("First", isDirectory: true)
        let nextFolder = dir.appendingPathComponent("Retry", isDirectory: true)
        for folder in [firstFolder, nextFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let backups = BackupStore(root: dir.appendingPathComponent("backups"))
        let model = BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups))
        model.form.resizeOn = false; model.form.format = .png; model.form.outputFolder = firstFolder
        model.add([ImageGroup(primary: good), ImageGroup(primary: broken)])
        await model.waitForPreview()
        XCTAssertTrue(model.canRun)
        model.run(); await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        XCTAssertEqual(model.result?.skippedCount, 1)
        XCTAssertEqual(model.result?.failedCount, 1, "a file Shrike cannot read is a failure, not a skip")
        XCTAssertEqual(model.summary, "1 completed · 1 failed")
        XCTAssertFalse(model.hasIntentionalSkips, "an unreadable file is retried on its own; no hint to select it")
        let unreadable = try XCTUnwrap(model.result?.items.first { $0.source.primary == broken })
        if case .skipped(.unreadable) = unreadable.outcome {} else { XCTFail("Corrupt input must be skipped as unreadable") }
        let completed = firstFolder.appendingPathComponent("good.png"), completedBytes = try Data(contentsOf: completed)
        XCTAssertTrue(model.canReviewRemaining)
        model.reviewRemaining(); await model.waitForPreview()
        XCTAssertTrue(model.reviewingRemaining)
        XCTAssertEqual(model.queue.map(\.id), [broken], "completed input is excluded from retry")

        // This is an explicit model edit, not a simulated chooser or Cancel.
        model.form.outputFolder = nextFolder
        await model.waitForPreview()
        let retry = try XCTUnwrap(model.makePlan().plan)
        if case .folder(let folder) = retry.output { XCTAssertEqual(folder, nextFolder) }
        else { XCTFail("Folder recovery must keep folder output") }
        XCTAssertEqual(retry.items.map(\.primary), [broken])
        XCTAssertTrue(model.consequenceSummary.contains("Destination: \(UserFacingPath.string(nextFolder))."))
        XCTAssertFalse(model.consequenceSummary.contains(UserFacingPath.string(firstFolder)))
        XCTAssertTrue(model.consequenceSummary.contains("Completed steps will not run again."))
        XCTAssertEqual(try Data(contentsOf: completed), completedBytes)

        // Repair the actual unreadable source, then execute the retry plan.
        let repairedBytes = try SaveFlowTests.writeImage(broken, type: .png)
        model.run(); await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        XCTAssertEqual(model.result?.skippedCount, 0)
        XCTAssertEqual(model.result?.failedCount, 0)
        XCTAssertEqual(model.result?.items.map { $0.source.primary }, [broken])
        let recovered = nextFolder.appendingPathComponent("broken.png")
        XCTAssertEqual(model.doneURLs, [recovered])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(recovered as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 16); XCTAssertEqual(image.height, 8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nextFolder.appendingPathComponent("good.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstFolder.appendingPathComponent("broken.png").path))
        XCTAssertEqual(try Data(contentsOf: completed), completedBytes)
        XCTAssertEqual(try Data(contentsOf: good), originalBytes)
        XCTAssertEqual(try Data(contentsOf: broken), repairedBytes)
    }

    func testInPlaceRecoveryKeepsModeAndDoesNotRepeatCommittedRotation() async throws {
        let url = dir.appendingPathComponent("partial.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let checkpoint = RecoveryCheckpoint()
        let backups = BackupStore(root: dir.appendingPathComponent("in-place-backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
            phaseCheckpoint: { phase, _ in try await checkpoint.hit(phase) })
        let model = BatchModel(runner: runner)
        model.form.convertOn = false; model.form.resizeOn = false
        model.form.rotateOn = true; model.form.renameOn = true; model.form.template = "renamed_{counter}"
        model.add([ImageGroup(primary: url)])
        await model.waitForPreview()
        XCTAssertTrue(model.canRun)
        model.run(); await model.waitForRun()
        let partial = try XCTUnwrap(model.result?.items.first)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.completedPhases, [.rotate])
        XCTAssertEqual(partial.failurePhase, .rename)
        let committedBytes = try Data(contentsOf: url)
        model.reviewRemaining(); await model.waitForPreview()
        XCTAssertTrue(model.reviewingRemaining)
        XCTAssertEqual(model.queue.map(\.id), [url])
        let retry = try XCTUnwrap(model.makePlan().plan)
        if case .inPlace = retry.output {} else { XCTFail("In-place recovery must remain in place") }
        XCTAssertEqual(retry.items.map(\.primary), [url])
        XCTAssertTrue(model.consequenceSummary.contains("Remaining work may change the original file."))
        XCTAssertTrue(model.consequenceSummary.contains("Completed steps will not run again."))
        XCTAssertFalse(model.consequenceSummary.lowercased().contains("rotate"))
        XCTAssertEqual(try Data(contentsOf: url), committedBytes)
        await checkpoint.allowRename()
        model.run(); await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        XCTAssertEqual(model.result?.skippedCount, 0)
        XCTAssertEqual(model.result?.failedCount, 0)
        let rotations = await checkpoint.rotations
        XCTAssertEqual(rotations, 1, "Retry must never repeat the committed rotation")
        let renamed = try XCTUnwrap(model.doneURLs.first)
        XCTAssertNotEqual(renamed, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: renamed), committedBytes, "Rename preserves the already rotated bytes")
    }
}

private actor RecoveryCheckpoint {
    var rotations = 0
    private var failsRename = true
    func hit(_ phase: BatchPhase) throws {
        if phase == .rotate { rotations += 1 }
        if phase == .rename && failsRename { throw CocoaError(.fileWriteNoPermission) }
    }
    func allowRename() { failsRename = false }
}

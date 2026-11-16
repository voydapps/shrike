import XCTest
import ImageIO
@testable import ShrikeUI
import ShrikeCore
import ShrikeEdit
import ShrikeIO

/// Audit 2026-10-24 FS-1: an output folder that is the photos' own folder
/// is an in-place run. The window says so and asks before it runs.
@MainActor
final class BatchOverwriteConfirmationTests: XCTestCase {
    private var dir: URL!
    private var photo: URL!
    private var original: Data!

    override func setUp() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        dir = TestScratch.directory
            .appendingPathComponent("shrike-batch-overwrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        photo = dir.appendingPathComponent("p.jpg")
        original = try SaveFlowTests.writeImage(photo, type: .jpeg)
    }

    override func tearDown() async throws {
        ShrikeDefaults.store.removeObject(forKey: BatchModel.lastFormKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeModel() async -> BatchModel {
        let backups = BackupStore(root: dir.appendingPathComponent("backups"))
        let model = BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups))
        model.form.convertOn = false
        model.form.resizeOn = true; model.form.resizeValue = 40
        model.form.outputFolder = dir
        model.add([ImageGroup(primary: photo)])
        await model.waitForPreview()
        return model
    }

    func testSummaryNeverSaysOriginalsStayUnchanged() async throws {
        let model = await makeModel()
        XCTAssertEqual(model.overwriteCount, 1)
        XCTAssertTrue(model.changesOriginals, "A-3: a folder output on the photo's own file changes originals")
        XCTAssertFalse(model.consequenceSummary.contains("unchanged"), model.consequenceSummary)
        XCTAssertTrue(model.consequenceSummary.contains("changes in place"), model.consequenceSummary)
    }

    func testRunWithoutAnswerNeverTouchesTheOriginal() async throws {
        let model = await makeModel()
        model.requestRun()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(try Data(contentsOf: photo), original)
        // A run that was never confirmed also never overwrites: it gets a " 2" name.
        model.run()
        await model.waitForRun()
        XCTAssertEqual(try Data(contentsOf: photo), original)
    }

    func testDeclinedConfirmationNeverTouchesTheOriginal() async throws {
        let model = await makeModel()
        var asked = 0
        model.confirmChangeOriginals = { title, _ in asked = title == "Change the original photo “p.jpg”?" ? 1 : 0; return false }
        model.requestRun()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(model.phase, .form)
        XCTAssertEqual(try Data(contentsOf: photo), original)
    }

    func testConfirmedRunChangesTheOriginalAndKeepsABackup() async throws {
        let model = await makeModel()
        model.confirmChangeOriginals = { _, _ in true }
        model.requestRun()
        try await Task.sleep(for: .milliseconds(100))
        await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        XCTAssertNotEqual(try Data(contentsOf: photo), original)
        XCTAssertEqual(model.result?.replacedOriginals.count, 1)
        XCTAssertEqual(model.undoActionName, "Batch Changes")
    }

    func testOtherFolderKeepsTheOldWording() async throws {
        let model = await makeModel()
        model.form.outputFolder = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: model.form.outputFolder!, withIntermediateDirectories: true)
        await model.waitForPreview()
        XCTAssertEqual(model.overwriteCount, 0)
        XCTAssertTrue(model.consequenceSummary.contains("stays unchanged"), model.consequenceSummary)
    }

    /// 28a round 2 finding 2: from the moment `Change Originals` is pressed the
    /// batch counts as running for ⌘Q, before the waiting task resumes; it runs once.
    func testConfirmedBatchIsRunningForQuitBeforeTheTaskResumes() async throws {
        let model = await makeModel()
        let batch = BatchWindowController(model: model, launcher: nil)
        BatchWindowController.setCurrentForTesting(batch)
        defer { BatchWindowController.setCurrentForTesting(nil); batch.close() }
        let coordinator = WindowCoordinator()
        var planAtConfirm: QuitPlan?
        var batchSeen = false
        model.confirmChangeOriginals = { _, _ in
            // What the sheet's completion does, then ⌘Q in the same stretch.
            model.startConfirmedRun()
            planAtConfirm = coordinator.quitPlan
            batchSeen = coordinator.runningWork().batch != nil
            return true
        }
        model.requestRun()
        try await Task.sleep(for: .milliseconds(50))
        await model.waitForRun()
        XCTAssertEqual(planAtConfirm, .later, "the work question is required")
        XCTAssertTrue(batchSeen)
        XCTAssertEqual(model.result?.doneCount, 1, "ran exactly once")
        XCTAssertEqual(model.result?.items.count, 1)
    }

    /// The window's own wiring (test responder path) also starts at once, once.
    func testWindowResponderStartsTheRunOnce() async throws {
        let model = await makeModel()
        let batch = BatchWindowController(model: model, launcher: nil)
        defer { batch.close() }
        batch.changeOriginalsResponder = { _, _ in true }
        model.requestRun()
        try await Task.sleep(for: .milliseconds(50))
        await model.waitForRun()
        XCTAssertEqual(model.result?.doneCount, 1)
        XCTAssertEqual(model.result?.items.count, 1)
    }

    /// With no operation chosen nothing changes the originals: no Run dots, no notice.
    func testNoOperationDoesNotChangeOriginals() async throws {
        let model = await makeModel()
        model.form.resizeOn = false; model.form.convertOn = false; model.form.renameOn = false; model.form.rotateOn = false
        XCTAssertNil(model.inPlaceText)
        XCTAssertFalse(model.changesOriginals)
        await model.waitForPreview()
        XCTAssertFalse(model.canRun, "nothing chosen: Run is off, so no question without dots")
        model.form.renameOn = true
        XCTAssertTrue(model.changesOriginals, "a rename in place does")
    }
}

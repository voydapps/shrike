import XCTest
@testable import ShrikeUI
import ShrikeCore
@testable import ShrikeEdit
import ShrikeIO

/// How a finished batch sorts its items: failed, skipped on purpose, or not
/// processed; and when the Done view hints at selecting skips.
@MainActor
final class BatchResultClassificationTests: XCTestCase {

    private func result(_ outcomes: [BatchItemOutcome]) -> BatchResult {
        var r = BatchResult()
        r.items = outcomes.enumerated().map { index, outcome in
            BatchItemResult(source: ImageGroup(primary: URL(fileURLWithPath: "/tmp/shrike-classify/\(index).jpg")),
                            outcome: outcome)
        }
        return r
    }

    func testUnreadableCountsAsFailedNotSkipped() {
        let r = result([.done(URL(fileURLWithPath: "/tmp/a.jpg")), .skipped(.unreadable), .skipped(.cannotRotateLosslessly)])
        XCTAssertEqual(r.failedCount, 1)
        XCTAssertEqual(BatchModel.summary(r, verb: "rotated"), "1 completed · 1 failed · 1 skipped")
    }

    func testAllUnreadableIsNoPhotosCompleted() {
        let r = result([.skipped(.unreadable)])
        XCTAssertEqual(r.doneCount, 0)
        XCTAssertGreaterThan(r.failedCount, 0, "the title reads 'No photos completed'")
    }

    func testHintOnlyForIntentionalSkips() {
        XCTAssertFalse(result([.skipped(.cancelled), .skipped(.cancelled)]).hasIntentionalSkips)
        XCTAssertFalse(result([.skipped(.unreadable), .skipped(.diskFull)]).hasIntentionalSkips)
        XCTAssertTrue(result([.skipped(.cancelled), .skipped(.cannotRotateLosslessly)]).hasIntentionalSkips)
        XCTAssertTrue(result([.skipped(.nameExists)]).hasIntentionalSkips)
    }

    /// Workers finish out of order; the Done list follows the queue (audit on-screen L2).
    func testSkippedRowsFollowTheQueueNotTheFinishOrder() {
        let urls = (0..<6).map { URL(fileURLWithPath: "/tmp/shrike-order/s\($0).jpg") }
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) }, rotate: 1, output: .inPlace)
        let finishOrder = [3, 1, 5, 0, 4, 2]
        let rows = finishOrder.map {
            BatchModel.SkippedRow(name: urls[$0].lastPathComponent, reason: "Cancelled.", source: urls[$0])
        }
        let stranger = BatchModel.SkippedRow(name: "x.jpg", reason: "?", source: URL(fileURLWithPath: "/tmp/shrike-order/x.jpg"))
        let sorted = BatchModel.inQueueOrder(rows + [stranger], plan: plan)
        XCTAssertEqual(sorted.map(\.name), ["s0.jpg", "s1.jpg", "s2.jpg", "s3.jpg", "s4.jpg", "s5.jpg", "x.jpg"])
    }

    func testRetryPlanAgreesWithTheHint() {
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: BackupStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("shrike-classify-\(UUID().uuidString)")), watchers: nil))
        for reason in [BatchSkipReason.cancelled, .unreadable, .diskFull, .nameExists, .cannotRotateLosslessly,
                       .cannotSaveInPlace, .emptyName] {
            let r = result([.skipped(reason)])
            let plan = BatchPlan(items: r.items.map(\.source), rotate: 1, output: .inPlace)
            let retried = !runner.retryPlan(for: r, original: plan).items.isEmpty
            XCTAssertEqual(retried, reason.isRetriedAutomatically, "\(reason)")
            XCTAssertEqual(r.hasIntentionalSkips, !reason.isRetriedAutomatically, "\(reason)")
        }
    }
}

/// A new Batch window starts from the settings of the last run.
@MainActor
final class BatchRememberedFormTests: XCTestCase {

    private func model(_ defaults: UserDefaults) -> BatchModel {
        let backups = BackupStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-batch-remember-\(UUID().uuidString)"))
        return BatchModel(runner: BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups),
                          defaults: defaults)
    }

    func testCustomSetupSurvivesANewWindow() {
        let defaults = makeTestDefaults()
        let first = model(defaults)
        XCTAssertEqual(first.presetTitle, "Web 2048", "nothing remembered yet: the default preset")
        first.form.convertOn = false
        first.form.resizeOn = false
        first.form.rotateOn = true
        first.form.rotation = .left
        XCTAssertEqual(first.presetTitle, BatchModel.Copy.customPreset)
        first.rememberForm()

        let second = model(defaults)
        XCTAssertEqual(second.form, first.form)
        XCTAssertEqual(second.presetTitle, BatchModel.Copy.customPreset)
        XCTAssertTrue(second.form.rotateOn)
        XCTAssertFalse(second.form.convertOn)
    }

    func testNamedPresetStillWorksAfterARememberedForm() throws {
        let defaults = makeTestDefaults()
        let first = model(defaults)
        first.form.convertOn = false; first.form.resizeOn = false; first.form.rotateOn = true
        first.rememberForm()
        let second = model(defaults)
        let web = try XCTUnwrap(second.presets.first { $0.name == "Web 2048" } ?? BatchPresetStore.builtIns.first { $0.name == "Web 2048" })
        second.apply(web)
        XCTAssertEqual(second.presetTitle, "Web 2048")
        XCTAssertFalse(second.form.rotateOn)
        XCTAssertTrue(second.form.convertOn)
    }

    func testChangedResizeValueIsRemembered() {
        let defaults = makeTestDefaults()
        let first = model(defaults)
        first.form.resizeValue = 1024
        first.rememberForm()
        let second = model(defaults)
        XCTAssertEqual(second.form.resizeValue, 1024)
    }

    func testRunRemembersTheForm() async throws {
        let defaults = makeTestDefaults()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-batch-remember-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("a.jpg")
        _ = try SaveFlowTests.writeImage(photo, type: .jpeg)
        let first = model(defaults)
        first.form.convertOn = false; first.form.resizeOn = false; first.form.rotateOn = true
        first.add([ImageGroup(primary: photo)])
        await first.waitForPreview()
        first.run(); await first.waitForRun()
        let second = model(defaults)
        XCTAssertTrue(second.form.rotateOn)
        XCTAssertFalse(second.form.convertOn)
        XCTAssertFalse(second.form.resizeOn)
    }
}

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class AuditWriteSafetyTests: XCTestCase {
    private func copyFixture(_ tmp: EditTempDir, _ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        try FileManager.default.copyItem(at: EditFixture.url("small.jpg"), to: url)
        return url
    }
    private func drain(_ stream: AsyncThrowingStream<BatchProgress, any Error>) async throws -> BatchResult {
        var result: BatchResult?
        for try await update in stream { if let final = update.result { result = final } }
        return try XCTUnwrap(result)
    }
    func testCancelAtEveryExportBoundaryKeepsOldDestinationOrLeavesNoNewFile() async throws {
        let tmp = EditTempDir("AuditExportCancellation"); defer { tmp.cleanup() }
        let source = try copyFixture(tmp, "source.jpg"), destination = try copyFixture(tmp, "destination.jpg")
        let before = try Data(contentsOf: destination)
        let points: [ImageExporter.Checkpoint] = [.decoded, .rendered, .encoded, .beforeBackup, .beforeCommit]
        for point in points {
            let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")),
                checkpoint: { current in if current == point { throw CancellationError() } })
            do {
                _ = try await exporter.export(recipe: EditRecipe(operations: [.colorAdjust(.init(brightness: 0.1))]),
                                               from: source, to: destination, format: .jpeg)
                XCTFail("boundary cancellation must throw")
            } catch is CancellationError {}
            XCTAssertEqual(try Data(contentsOf: destination), before)
        }
        let missing = tmp.url.appendingPathComponent("new.jpg")
        let exporter = ImageExporter(checkpoint: { current in if current == .beforeCommit { throw CancellationError() } })
        do { _ = try await exporter.export(recipe: EditRecipe(), from: source, to: missing, format: .jpeg); XCTFail("cancelled commit") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: tmp.url.path)
        XCTAssertFalse(names.contains { $0.contains("shrikeedit") })
    }
    func testFailedReplaceKeepsVictimAndSuccessfulUndoRestoresActualDestination() async throws {
        let tmp = EditTempDir("AuditReplace"); defer { tmp.cleanup() }
        let source = try copyFixture(tmp, "source.jpg"), output = tmp.url.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let victim = output.appendingPathComponent("source.jpg")
        let oldBytes = Data("old destination bytes".utf8); try oldBytes.write(to: victim)
        let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let failing = ImageExporter(backupStore: backups, checkpoint: { point in
            if point == .encoded { throw ExportError.destinationFinalizeFailed }
        })
        do { _ = try await failing.export(recipe: EditRecipe(), from: source, to: victim, format: .jpeg); XCTFail("injected failure") }
        catch ExportError.destinationFinalizeFailed {}
        XCTAssertEqual(try Data(contentsOf: victim), oldBytes)
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
        let plan = BatchPlan(items: [ImageGroup(primary: source)], convert: .init(format: .jpeg), output: .folder(output), onConflict: .replace)
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 1); XCTAssertTrue(result.canUndo)
        XCTAssertNotEqual(try Data(contentsOf: victim), oldBytes)
        try await runner.undo(result)
        XCTAssertEqual(try Data(contentsOf: victim), oldBytes, "Undo restores the old destination, not the source")
    }
    func testFailedRenameRollbackPreservesRecoveryReceiptAndUndoRestoresVictimBytes() async throws {
        for failRollback in [false, true] {
            let tmp = EditTempDir("AuditRenameRollback-\(failRollback)"); defer { tmp.cleanup() }
            let source = try copyFixture(tmp, "source.jpg"), victim = tmp.url.appendingPathComponent("victim.jpg")
            let sourceBytes = try Data(contentsOf: source), victimBytes = Data("the original replace victim".utf8)
            try victimBytes.write(to: victim)
            let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
            // Fake Trash inside the temp folder: the real ~/.Trash must stay untouched.
            let fakeTrash = tmp.url.appendingPathComponent("FakeTrash")
            try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
            let ops = FileOps(metadata: nil, backups: backups, watchers: nil, trashItem: { url in
                let dest = fakeTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
                try FileManager.default.moveItem(at: url, to: dest)
                return dest
            })
            let runner = BatchRunner(fileOps: ops, backups: backups, renameCheckpoint: { point, _ in
                switch point {
                case .beforeMove: throw CocoaError(.fileWriteNoPermission)
                case .beforeRollback:
                    if failRollback { throw CocoaError(.fileWriteVolumeReadOnly) }
                }
            })
            let plan = BatchPlan(items: [ImageGroup(primary: source)], rename: try RenameTemplate(parsing: "victim"),
                                 output: .inPlace, onConflict: .replace)
            let result = try await drain(runner.run(plan))
            let item = try XCTUnwrap(result.items.first)
            XCTAssertEqual(result.doneCount, 0)
            XCTAssertEqual(item.failurePhase, .rename)
            XCTAssertEqual(item.finalURL, source)
            XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
            if failRollback {
                XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
                XCTAssertTrue(item.isPartial)
                XCTAssertTrue(result.canUndo)
                let record = try XCTUnwrap(item.recoveryRequired)
                XCTAssertEqual(record.originalURL, victim)
                XCTAssertEqual(try Data(contentsOf: record.backupURL), victimBytes)
                XCTAssertEqual(result.replacedOriginals, [record])
                guard case .failed(let error) = item.outcome else { return XCTFail("recovery must be an explicit failure") }
                XCTAssertTrue(error is BatchRecoveryRequiredError)
                XCTAssertTrue(error.localizedDescription.contains("backup is retained"))
                // The transient fault has cleared: actual Undo uses the retained
                // destination receipt and restores its original bytes.
                try await runner.undo(result)
                XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
            } else {
                XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
                XCTAssertNil(item.recoveryRequired)
                XCTAssertFalse(item.isPartial)
                XCTAssertFalse(result.canUndo, "successful automatic rollback leaves no outstanding change")
            }
        }
    }
    func testRotateRenameFailureReportsPhaseAndRetryDoesNotRotateTwiceOrRenumber() async throws {
        let tmp = EditTempDir("AuditRotateRename"); defer { tmp.cleanup() }
        let a = try copyFixture(tmp, "a.jpg"), b = try copyFixture(tmp, "b.jpg")
        let beforeA = try Data(contentsOf: a), beforeB = try Data(contentsOf: b)
        let backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let ops = FileOps(metadata: nil, backups: backups, watchers: nil)
        let failing = BatchRunner(fileOps: ops, backups: backups, phaseCheckpoint: { phase, source in
            if phase == .rename && source == b { throw CocoaError(.fileWriteNoPermission) }
        })
        let plan = BatchPlan(items: [ImageGroup(primary: a), ImageGroup(primary: b)], rotate: 1,
                             rename: try RenameTemplate(parsing: "{name}_{counter:00}"), output: .inPlace)
        let first = try await drain(failing.run(plan))
        let partial = try XCTUnwrap(first.items.first { $0.source.primary == b })
        XCTAssertTrue(partial.isPartial); XCTAssertEqual(partial.failurePhase, .rename)
        XCTAssertEqual(partial.finalURL, b); XCTAssertEqual(partial.completedPhases, [.rotate])
        let runner = BatchRunner(fileOps: ops, backups: backups)
        let retry = runner.retryPlan(for: first, original: plan)
        XCTAssertEqual(retry.items.count, 1)
        let preview = await runner.preview(retry)
        XCTAssertEqual(preview.first?.outputName, "b_02.jpg")
        let final = try await drain(runner.run(retry))
        XCTAssertEqual(final.doneCount, 1); XCTAssertEqual(final.rotations.count, 2, "only two original rotations, no repeated retry rotation")
        XCTAssertEqual(final.items.first?.finalURL?.lastPathComponent, "b_02.jpg")
        let rotatedURL = tmp.url.appendingPathComponent("b_02.jpg")
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(rotatedURL as CFURL, nil))
        let orientation = ExifOrientation(properties: CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(orientation, .right)
        try await runner.undo(final)
        XCTAssertEqual(try Data(contentsOf: a), beforeA); XCTAssertEqual(try Data(contentsOf: b), beforeB)
    }
    func testStopWaitsForActiveCheckpointAndReturnsTruthfulCancelledResult() async throws {
        let tmp = EditTempDir("AuditBatchStop"); defer { tmp.cleanup() }
        let source = try copyFixture(tmp, "source.jpg"), before = try Data(contentsOf: source)
        let gate = AuditPhaseGate(), backups = BackupStore(root: tmp.url.appendingPathComponent("backups"))
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
                                 phaseCheckpoint: { _, _ in await gate.wait() })
        let stop = BatchStop(), plan = BatchPlan(items: [ImageGroup(primary: source)], rotate: 1, output: .inPlace)
        let task = Task { () throws -> BatchResult in
            var final: BatchResult?
            for try await progress in runner.run(plan, stop: stop) { if let result = progress.result { final = result } }
            return try XCTUnwrap(final)
        }
        let deadline = Date().addingTimeInterval(2)
        while !(await gate.entered), Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        stop.stop(); XCTAssertFalse(stop.isSettled)
        await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.doneCount, 0); XCTAssertEqual(result.cancelledCount, 1)
        XCTAssertEqual(try Data(contentsOf: source), before)
    }
}

private actor AuditPhaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

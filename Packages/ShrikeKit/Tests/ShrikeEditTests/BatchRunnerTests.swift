//
//  BatchRunnerTests.swift
//  ShrikeEditTests
//
//  Runs against temp folders only.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchRunnerTests: XCTestCase {

    private var root: URL!
    private var backups: BackupStore!
    private var runner: BatchRunner!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeBatchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backups = BackupStore(root: root.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func image(_ name: String, in sub: String = "src", w: Int = 240, h: Int = 160,
                       type: UTType = .jpeg) throws -> URL {
        let folder = root.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func groups(_ urls: [URL]) -> [ImageGroup] { urls.map { ImageGroup(primary: $0) } }

    private func drain(_ stream: AsyncThrowingStream<BatchProgress, any Error>) async throws -> BatchResult {
        var last: BatchResult?
        for try await p in stream { if let r = p.result { last = r } }
        return try XCTUnwrap(last)
    }

    private func pixelSize(_ url: URL) -> CGSize? {
        BatchRunner.Header(url)?.displaySize
    }

    // (1) JPEGs → PNG long edge 100 into a folder; originals byte-identical.
    func testConvertResizeIntoFolder_keepsOriginals() async throws {
        let srcs = try (0..<6).map { try image("P\($0).jpg") }
        let before = try srcs.map { try Data(contentsOf: $0) }
        let out = root.appendingPathComponent("Shrike Export", isDirectory: true)
        let plan = BatchPlan(items: groups(srcs), convert: ConvertOptions(format: .png),
                             resize: ResizeOptions(mode: .longEdge, value: 100), output: .folder(out))

        let rows = await runner.preview(plan, limit: 200)
        XCTAssertEqual(rows.map(\.outputName), (0..<6).map { "P\($0).png" })
        XCTAssertEqual(rows.first?.outputSize, CGSize(width: 100, height: 67))

        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 6)
        XCTAssertFalse(result.canUndo, "new files: no undo")
        for i in 0..<6 {
            XCTAssertEqual(pixelSize(out.appendingPathComponent("P\(i).png")), CGSize(width: 100, height: 67))
            XCTAssertEqual(try Data(contentsOf: srcs[i]), before[i])
        }
    }

    // (2) Stop: no partial files in the output. Ending the stream (the
    // consumer breaks out, or its task is cancelled) is Stop.
    func testStopLeavesNoPartialFiles() async throws {
        let srcs = try (0..<40).map { try image("S\($0).jpg", w: 1600, h: 1200) }
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plan = BatchPlan(items: groups(srcs), convert: ConvertOptions(format: .png), output: .folder(out))
        let runner = self.runner!
        let consumer = Task { () -> Int in
            var seen = 0
            for try await p in runner.run(plan) where p.item != nil {
                seen += 1
                break
            }
            return seen
        }
        let seen = try await consumer.value
        XCTAssertEqual(seen, 1)
        try await Task.sleep(nanoseconds: 500_000_000)   // in-flight items settle
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertLessThan(names.count, 40, "stopped early")
        for name in names {
            XCTAssertFalse(name.hasPrefix("."), "temp file left: \(name)")
            XCTAssertNotNil(pixelSize(out.appendingPathComponent(name)), "complete file: \(name)")
        }
    }

    // (3) Missing token value collapses: {name}_{lens}_{counter:00} → a_01.
    // (5) Undo after a batch rename restores all names.
    func testRenameCollapsesMissingTokenAndUndoRestores() async throws {
        let a = try image("a.jpg"), b = try image("b.jpg")
        let template = try RenameTemplate(parsing: "{name}_{lens}_{counter:00}")
        let plan = BatchPlan(items: groups([a, b]), rename: template, output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertEqual(rows.map(\.outputName), ["a_01.jpg", "b_02.jpg"])

        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 2)
        XCTAssertTrue(result.canUndo)
        let folder = a.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a_01.jpg").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))

        try await runner.undo(result)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }

    // (4) Rotate only: JPEGs rotated losslessly, a type that can't be is skipped with the reason.
    func testRotateOnlySkipsTypesThatCantRotateLosslessly() async throws {
        let j1 = try image("r1.jpg"), j2 = try image("r2.jpg")
        let gif = try image("r3.gif", type: .gif)
        XCTAssertFalse(LosslessRotator.isSupported(gif))
        let plan = BatchPlan(items: groups([j1, j2, gif]), rotate: 1, output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertEqual(rows[2].skip, .cannotRotateLosslessly)
        XCTAssertEqual(rows[0].outputSize, CGSize(width: 160, height: 240))

        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.rotations.count, 2)
        XCTAssertEqual(pixelSize(j1), CGSize(width: 160, height: 240), "EXIF rewrite")
        let skipped = result.items.first { $0.source.primary == gif }
        guard case .skipped(let reason)? = skipped?.outcome else { return XCTFail("gif not skipped") }
        XCTAssertEqual(reason.message, "This file type can't be rotated without re-encoding — skipped.")

        try await runner.undo(result)
        XCTAssertEqual(pixelSize(j1), CGSize(width: 240, height: 160))
    }

    func testPreviewFlagsClashesAndConflictPolicies() async throws {
        let a = try image("dup.jpg")
        let b = try image("dup.png", type: .png)
        let out = root.appendingPathComponent("out", isDirectory: true)
        try image("dup.jpg", in: "out")   // already on disk
        let base = BatchPlan(items: groups([a, b]), convert: ConvertOptions(format: .jpeg), output: .folder(out))

        var plan = base
        plan.onConflict = .keepBoth
        var rows = await runner.preview(plan)
        XCTAssertEqual(rows.map(\.nameClash), [true, true])
        XCTAssertEqual(rows.map(\.outputName), ["dup 2.jpg", "dup 3.jpg"])

        plan.onConflict = .skip
        rows = await runner.preview(plan)
        XCTAssertEqual(rows[0].skip, .nameExists)
        XCTAssertEqual(rows[1].outputName, "dup 2.jpg", "clash inside the batch always keeps both")

        plan.onConflict = .replace
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 2)
        XCTAssertEqual(pixelSize(out.appendingPathComponent("dup.jpg")), CGSize(width: 240, height: 160))
    }

    func testInPlaceRecipeBacksUpAsBatchAndUndoRestores() async throws {
        let a = try image("edit.jpg")
        let original = try Data(contentsOf: a)
        let recipe: [EditOperation] = [.resize(ResizeSpec(width: 120, height: 80, interpolation: .lanczos,
                                                             preventUpscale: true))]
        let plan = BatchPlan(items: groups([a]), recipe: recipe, output: .inPlace)
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 1)
        XCTAssertEqual(result.replacedOriginals.map(\.reason), [.batch])
        XCTAssertEqual(pixelSize(a), CGSize(width: 120, height: 80))
        try await runner.undo(result)
        XCTAssertEqual(try Data(contentsOf: a), original)
    }

    // A recipe with two whole-state colour ops plus Rotate: only the last
    // colour state is applied (once), then the image is rotated.
    func testRecipeTwoColourOpsPlusRotate_appliesLastColourOnceThenRotates() async throws {
        let src = try image("C.png", type: .png)
        let colorA = ColorAdjustParams(brightness: 0.2, contrast: 0.2)
        let colorB = ColorAdjustParams(brightness: -0.1, saturation: 0.5)
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plan = BatchPlan(items: groups([src]), convert: ConvertOptions(format: .png), rotate: 1,
                             recipe: [.colorAdjust(colorA), .colorAdjust(colorB)], output: .folder(out))
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 1)

        func decode(_ url: URL) throws -> CGImage {
            let s = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(s, 0, nil))
        }
        func rgbx(_ img: CGImage) -> [UInt8] {
            var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8,
                                bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            return px
        }
        func maxDiff(_ x: CGImage, _ y: CGImage) -> Int {
            guard x.width == y.width, x.height == y.height else { return .max }
            return zip(rgbx(x), rgbx(y)).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
        }

        let saved = try decode(out.appendingPathComponent("C.png"))
        let original = try decode(src)
        XCTAssertEqual(saved.width, 160)
        XCTAssertEqual(saved.height, 240)
        let expected = RotateTool.apply90(quarters: 1, to: ColorAdjustTool.apply(colorB, to: original))
        XCTAssertLessThanOrEqual(maxDiff(saved, expected), 1, "colour b, then rotated")
        let doubled = RotateTool.apply90(quarters: 1,
                                         to: ColorAdjustTool.apply(colorB, to: ColorAdjustTool.apply(colorA, to: original)))
        XCTAssertGreaterThan(maxDiff(saved, doubled), 5, "a is not applied under b")
    }

    func testRetryRestoresPlanOrderAfterControlledParallelFailures() async throws {
        let urls = try [image("GPS.jpg"), image("Coast.jpg"), image("Gardener.jpg")]
        let items = groups(urls), gate = BatchRetryOrderGate(blocked: urls[0])
        let controlled = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                     backups: backups, phaseCheckpoint: { _, source in
            await gate.enter(source)
            throw CocoaError(.fileWriteNoPermission)
        })
        let plan = BatchPlan(items: items, convert: .init(format: .png),
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 7),
                             output: .folder(root.appendingPathComponent("out")))
        // This is a bounded gate watchdog, not a delay used to order work.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await gate.release(timedOut: true)
        }
        var final: BatchResult?
        for try await progress in controlled.run(plan) {
            if let item = progress.item { await gate.finished(item.source.primary) }
            if let result = progress.result { final = result }
        }
        await gate.release(); watchdog.cancel(); await watchdog.value
        let result = try XCTUnwrap(final), expired = await gate.timedOut
        XCTAssertFalse(expired, "the gate must be released by the other two actual completion events")
        XCTAssertEqual(result.items.last?.source.primary, urls[0])
        XCTAssertEqual(Set(result.items.prefix(2).map(\.source.primary)), Set(urls.suffix(2)))
        XCTAssertEqual(result.failedCount, 3)
        let retry = runner.retryPlan(for: result, original: plan)
        XCTAssertEqual(retry.items, items, "result completion order must never replace job counter order")
        let preview = await runner.preview(retry)
        XCTAssertEqual(preview.map(\.outputName), ["007_GPS.png", "008_Coast.png", "009_Gardener.png"])
    }

    func testIntentionalSkipSubsetAndRepeatedRetryKeepOriginalCounterIdentities() async throws {
        let urls = try [image("GPS.jpg"), image("Coast.jpg"), image("Gardener.jpg")]
        let before = try urls.map { try Data(contentsOf: $0) }, items = groups(urls)
        let out = root.appendingPathComponent("out")
        var plan = BatchPlan(items: items, convert: .init(format: .png),
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 7),
                             output: .folder(out))
        let first = try await drain(runner.run(plan))
        XCTAssertEqual(first.doneCount, 3)
        let originalNames = ["007_GPS.png", "008_Coast.png", "009_Gardener.png"]
        let oldOutputs = try originalNames.map { try Data(contentsOf: out.appendingPathComponent($0)) }
        plan.onConflict = .skip
        let skipped = try await drain(runner.run(plan))
        XCTAssertEqual(skipped.doneCount, 0); XCTAssertEqual(skipped.skippedCount, 3)
        let selected = Set([urls[0], urls[2]])
        let retry = runner.retryPlan(for: skipped, original: plan, selectedIntentionalSkips: selected)
        XCTAssertEqual(retry.items, [items[0], items[2]])
        var preview = await runner.preview(retry)
        XCTAssertEqual(preview.map(\.outputName), ["007_GPS.png", "009_Gardener.png"])
        let skippedAgain = try await drain(runner.run(retry))
        XCTAssertEqual(skippedAgain.skippedCount, 2)
        var finalPlan = runner.retryPlan(for: skippedAgain, original: retry, selectedIntentionalSkips: selected)
        finalPlan.onConflict = .keepBoth
        preview = await runner.preview(finalPlan)
        XCTAssertEqual(preview.map(\.outputName), ["007_GPS 2.png", "009_Gardener 2.png"])
        let final = try await drain(runner.run(finalPlan))
        XCTAssertEqual(final.doneCount, 2)
        for row in preview {
            let item = try XCTUnwrap(final.items.first { $0.source == row.source })
            XCTAssertEqual(item.finalURL, row.destination)
            XCTAssertEqual(item.destinationURL, row.destination)
            let originalName = row.source == items[0] ? "007_GPS.png" : "009_Gardener.png"
            XCTAssertEqual(item.plannedDestinationURL, out.appendingPathComponent(originalName),
                           "Keep Both changes the current output, not the original job's name identity")
            XCTAssertNotNil(pixelSize(row.destination))
        }
        for i in urls.indices {
            XCTAssertEqual(try Data(contentsOf: urls[i]), before[i])
            XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(originalNames[i])), oldOutputs[i])
        }
    }

    func testUnreadableMiddleRetryKeepsNameAcrossMetadataChangeAndNewFolderWithUndoReceipts() async throws {
        let a = try image("GPS.jpg"), c = try image("Gardener.jpg")
        let b = a.deletingLastPathComponent().appendingPathComponent("Coast.jpg")
        try Data("not an image".utf8).write(to: b)
        let urls = [a, b, c]
        for url in urls { FileAttributes.setRating(1, at: url); XCTAssertEqual(FileAttributes.rating(at: url), 1) }
        let counts = BatchRetryPhaseCounts()
        let counted = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                  backups: backups, phaseCheckpoint: { phase, url in await counts.record(phase, url) })
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let firstNames = ["007_GPS_1.png", "009_Gardener_1.png"]
        let victims = firstNames.map { out.appendingPathComponent($0) }
        let victimBytes = Data("original output victim".utf8)
        for victim in victims { try victimBytes.write(to: victim) }
        let plan = BatchPlan(items: groups(urls), convert: .init(format: .png),
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}_{rating}", counterStart: 7),
                             output: .folder(out), onConflict: .replace)
        let first = try await drain(counted.run(plan))
        XCTAssertEqual(first.doneCount, 2); XCTAssertEqual(first.replacedOriginals.count, 2)
        guard case .skipped(.unreadable)? = first.items.first(where: { $0.source.primary == b })?.outcome
        else { return XCTFail("middle input must be a real unreadable skip") }
        let completedBytes = try victims.map { try Data(contentsOf: $0) }
        _ = try image("Coast.jpg") // Deliberately repair only the failed input.
        FileAttributes.setRating(5, at: b); XCTAssertEqual(FileAttributes.rating(at: b), 5)
        let sourceBytes = try urls.map { try Data(contentsOf: $0) }
        let newOut = root.appendingPathComponent("new-output")
        try FileManager.default.createDirectory(at: newOut, withIntermediateDirectories: true)
        let retryVictim = newOut.appendingPathComponent("008_Coast_1.png")
        let retryVictimBytes = Data("new folder's previous output".utf8)
        try retryVictimBytes.write(to: retryVictim)
        var retry = counted.retryPlan(for: first, original: plan)
        retry.output = .folder(newOut); retry.onConflict = .replace
        XCTAssertEqual(retry.items, [ImageGroup(primary: b)])
        let rows = await counted.preview(retry)
        XCTAssertEqual(rows.map(\.outputName), ["008_Coast_1.png"], "counter and metadata identity belong to the original resolution")
        XCTAssertEqual(rows.first?.destination, retryVictim)
        let final = try await drain(counted.run(retry))
        XCTAssertEqual(final.doneCount, 1); XCTAssertEqual(final.replacedOriginals.count, 3)
        XCTAssertEqual(final.items.first?.finalURL, retryVictim)
        let exports = await counts.exports
        XCTAssertEqual(exports, Dictionary(uniqueKeysWithValues: urls.map { ($0, 1) }), "completed neighbors must not run again")
        for i in victims.indices { XCTAssertEqual(try Data(contentsOf: victims[i]), completedBytes[i]) }
        for i in urls.indices { XCTAssertEqual(try Data(contentsOf: urls[i]), sourceBytes[i]) }
        try await counted.undo(final)
        for victim in victims { XCTAssertEqual(try Data(contentsOf: victim), victimBytes) }
        XCTAssertEqual(try Data(contentsOf: retryVictim), retryVictimBytes)
    }

    func testStoppedNeverStartedItemsRetainOriginalNamesWhenRetryIsFiltered() async throws {
        let urls = try (0..<(BatchRunner.workerCount + 2)).map { try image("photo\($0).jpg") }
        let bytes = try urls.map { try Data(contentsOf: $0) }, items = groups(urls)
        let gate = BatchRetryStopGate(), stop = BatchStop()
        let held = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                               backups: backups, phaseCheckpoint: { _, _ in await gate.enter() })
        let plan = BatchPlan(items: items, rotate: 1,
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 7), output: .inPlace)
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            stop.stop(); await gate.release(timedOut: true)
        }
        let stream = held.run(plan, stop: stop) // Attach Stop before its controller can release a worker.
        let requestStop = Task { await gate.waitForEntry(); stop.stop(); await gate.release() }
        let result = try await drain(stream)
        await requestStop.value; watchdog.cancel(); await watchdog.value
        let expired = await gate.timedOut
        XCTAssertFalse(expired); XCTAssertEqual(result.cancelledCount, urls.count)
        XCTAssertEqual(result.rotations.count, 0)
        XCTAssertTrue(result.items.allSatisfy { $0.plannedDestinationURL != nil })
        XCTAssertTrue(result.items.allSatisfy { $0.finalURL == $0.source.primary },
                      "cancelled work must not claim its planned rename actually happened")
        XCTAssertGreaterThanOrEqual(result.items.filter { $0.destinationURL == nil }.count, 2,
                                    "the never-started tail keeps its existing nil actual/attempt destination field")
        var retry = runner.retryPlan(for: result, original: plan)
        XCTAssertEqual(retry.items, items)
        retry.items = [try XCTUnwrap(items.last)]
        let rows = await runner.preview(retry)
        XCTAssertEqual(rows.first?.outputName, String(format: "%03d_photo%d.jpg", 7 + urls.count - 1, urls.count - 1))
        for i in urls.indices { XCTAssertEqual(try Data(contentsOf: urls[i]), bytes[i]) }
    }

    func testNamingProvenanceDoesNotClaimEarlySkippedDestinationsWereWritten() async throws {
        let source = try image("source.jpg"), sourceBytes = try Data(contentsOf: source)
        let victim = try image("blocked.jpg"), victimBytes = try Data(contentsOf: victim)
        let rename = BatchPlan(items: groups([source]), rename: try RenameTemplate(parsing: "blocked"),
                               output: .inPlace, onConflict: .skip)
        let skipped = try await drain(runner.run(rename))
        let item = try XCTUnwrap(skipped.items.first)
        guard case .skipped(.nameExists) = item.outcome else { return XCTFail("actual rename conflict must skip") }
        XCTAssertEqual(item.plannedDestinationURL, victim)
        XCTAssertNil(item.destinationURL); XCTAssertEqual(item.finalURL, source)
        XCTAssertTrue(item.completedPhases.isEmpty); XCTAssertFalse(skipped.canUndo)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)

        let corrupt = source.deletingLastPathComponent().appendingPathComponent("corrupt.jpg")
        try Data("unreadable fixture".utf8).write(to: corrupt)
        let out = root.appendingPathComponent("out")
        let export = BatchPlan(items: groups([corrupt]), convert: .init(format: .png),
                               rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 7),
                               output: .folder(out))
        let result = try await drain(runner.run(export)), unreadable = try XCTUnwrap(result.items.first)
        let planned = out.appendingPathComponent("007_corrupt.png")
        guard case .skipped(.unreadable) = unreadable.outcome else { return XCTFail("actual unreadable input must skip") }
        XCTAssertEqual(unreadable.plannedDestinationURL, planned)
        XCTAssertNil(unreadable.destinationURL); XCTAssertEqual(unreadable.finalURL, corrupt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: planned.path))
    }

    func testRepeatedRetrySkipPreservesCommittedRotationAndOriginalUndoReceipts() async throws {
        let a = try image("a.jpg"), b = try image("b.jpg")
        let beforeA = try Data(contentsOf: a), beforeB = try Data(contentsOf: b)
        let partialRunner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                        backups: backups, phaseCheckpoint: { phase, source in
            if phase == .rename && source == b { throw CocoaError(.fileWriteNoPermission) }
        })
        let plan = BatchPlan(items: groups([a, b]), rotate: 1,
                             rename: try RenameTemplate(parsing: "{name}_{counter:00}"), output: .inPlace)
        let first = try await drain(partialRunner.run(plan))
        XCTAssertEqual(first.rotations.count, 2)
        var retry = runner.retryPlan(for: first, original: plan)
        let victim = b.deletingLastPathComponent().appendingPathComponent("b_02.jpg")
        let victimBytes = Data("owned conflict fixture".utf8); try victimBytes.write(to: victim)
        retry.onConflict = .skip
        let second = try await drain(runner.run(retry)), partial = try XCTUnwrap(second.items.first)
        XCTAssertEqual(partial.completedPhases, [.rotate]); XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(second.rotations.count, 2)
        var lastPlan = runner.retryPlan(for: second, original: retry)
        XCTAssertEqual(lastPlan.items, groups([b]), "a committed phase keeps the early skip eligible for recovery")
        lastPlan.onConflict = .keepBoth
        let preview = await runner.preview(lastPlan)
        XCTAssertEqual(preview.first?.outputName, "b_02 2.jpg")
        let final = try await drain(runner.run(lastPlan))
        XCTAssertEqual(final.doneCount, 1); XCTAssertEqual(final.rotations.count, 2, "never rotate the partial item twice")
        XCTAssertEqual(final.items.first?.finalURL, preview.first?.destination)
        let destination = try XCTUnwrap(preview.first?.destination)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 6)
        try await runner.undo(final)
        XCTAssertEqual(try Data(contentsOf: a), beforeA); XCTAssertEqual(try Data(contentsOf: b), beforeB)
        XCTAssertEqual(try Data(contentsOf: victim), victimBytes)
    }

    func testValidation() {
        let a = URL(fileURLWithPath: "/tmp/x.jpg")
        XCTAssertEqual(BatchPlan(items: groups([a]), output: .inPlace).validationError, .noOperation)
        XCTAssertEqual(BatchPlan(items: groups([a]), convert: ConvertOptions(format: .png), output: .inPlace)
            .validationError, .outputFolderRequired)
        XCTAssertEqual(BatchValidationError.noOperation.message, "Choose at least one operation.")
        XCTAssertEqual(ResizeOptions(mode: .percent, value: 50).targetSize(for: CGSize(width: 400, height: 300)),
                       CGSize(width: 200, height: 150))
        XCTAssertEqual(ResizeOptions(mode: .width, value: 800).targetSize(for: CGSize(width: 400, height: 300)),
                       CGSize(width: 400, height: 300), "don't enlarge")
    }

    func testResizePlanRejectsNonpositiveValuesForEveryModeAndAcceptsOne() {
        let item = ImageGroup(primary: URL(fileURLWithPath: "/tmp/x.jpg"))
        let output = BatchOutput.folder(URL(fileURLWithPath: "/tmp"))
        let sourceSize = CGSize(width: 400, height: 300)

        for mode in ResizeOptions.Mode.allCases {
            let invalid = BatchPlan(items: [item], resize: ResizeOptions(mode: mode, value: 0), output: output)
            XCTAssertEqual(invalid.validationError, .invalidResizeValue, "zero (mode) must be rejected")

            let valid = BatchPlan(items: [item], resize: ResizeOptions(mode: mode, value: 1), output: output)
            XCTAssertNil(valid.validationError, "one (mode) must be accepted")
            let expected: CGSize = mode == .percent ? CGSize(width: 4, height: 3) : CGSize(width: 1, height: 1)
            XCTAssertEqual(ResizeOptions(mode: mode, value: 1).targetSize(for: sourceSize), expected,
                           "one (mode) produces expected target dimensions")
        }
    }
}

private actor BatchRetryOrderGate {
    let blocked: URL
    private var waiter: CheckedContinuation<Void, Never>?
    private var completed = Set<URL>()
    private var released = false
    private(set) var timedOut = false
    init(blocked: URL) { self.blocked = blocked }
    func enter(_ source: URL) async {
        guard source == blocked, !released else { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finished(_ source: URL) {
        if source != blocked { completed.insert(source) }
        if completed.count == 2 { release() }
    }
    func release(timedOut: Bool = false) {
        self.timedOut = self.timedOut || timedOut; released = true
        waiter?.resume(); waiter = nil
    }
}

private actor BatchRetryPhaseCounts {
    private(set) var exports: [URL: Int] = [:]
    func record(_ phase: BatchPhase, _ source: URL) {
        if phase == .export { exports[source, default: 0] += 1 }
    }
}

private actor BatchRetryStopGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var entered = false
    private var released = false
    private(set) var timedOut = false
    func waitForEntry() async {
        guard !entered, !released else { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func enter() async {
        entered = true; entryWaiter?.resume(); entryWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release(timedOut: Bool = false) {
        self.timedOut = self.timedOut || timedOut; released = true
        entryWaiter?.resume(); entryWaiter = nil
        for waiter in waiters { waiter.resume() }; waiters = []
    }
}

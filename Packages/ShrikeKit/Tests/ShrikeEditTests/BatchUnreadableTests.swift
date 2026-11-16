//
//  BatchUnreadableTests.swift
//  ShrikeEditTests
//
//  Audit L-4 and E-2: the preview says exactly what the run does with a photo Shrike can't
//  read, and a preview refresh reads each header once.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchUnreadableTests: XCTestCase {

    private var root: URL!
    private var backups: BackupStore!
    private var runner: BatchRunner!

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("ShrikeBatchUnreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        backups = BackupStore(root: root.appendingPathComponent("_backups"), retentionDays: { 30 })
        runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func photo(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("src").appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: 30))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func broken(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("src").appendingPathComponent(name)
        try Data("not an image".utf8).write(to: url)
        return url
    }

    private func drain(_ stream: AsyncThrowingStream<BatchProgress, any Error>) async throws -> BatchResult {
        var last: BatchResult?
        for try await p in stream { if let r = p.result { last = r } }
        return try XCTUnwrap(last)
    }

    private func names(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: L-4

    func testRenameOnlyRenamesAnUnreadableFileToo() async throws {
        let urls = try [photo("a.jpg"), broken("broken.jpg"), photo("c.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{counter:000}", counterStart: 1), output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertEqual(rows.map(\.outputName), ["001.jpg", "002.jpg", "003.jpg"])
        XCTAssertEqual(rows.map { $0.skip == nil }, [true, true, true], "a plain rename needs no pixels")
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(names(root.appendingPathComponent("src")), ["001.jpg", "002.jpg", "003.jpg"])
        XCTAssertEqual(result.items.filter(\.isDone).count, 3)
    }

    func testAJobThatNeedsPixelsSkipsTheUnreadableFileAndLeavesNoGapInTheCounter() async throws {
        let urls = try [photo("a.jpg"), broken("broken.jpg"), photo("c.jpg")]
        let out = root.appendingPathComponent("out")
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) }, convert: ConvertOptions(format: .png),
                             rename: try RenameTemplate(parsing: "{counter:000}", counterStart: 1), output: .folder(out))
        let rows = await runner.preview(plan)
        XCTAssertEqual(rows[0].outputName, "001.png")
        XCTAssertEqual(rows[2].outputName, "002.png", "the counter does not count the skipped file")
        guard case .unreadable? = rows[1].skip else { return XCTFail("the unreadable file is skipped: \(String(describing: rows[1].skip))") }
        _ = try await drain(runner.run(plan))
        XCTAssertEqual(names(out), ["001.png", "002.png"], "the run matches the preview")
    }

    // MARK: E-2

    func testOneAnalysisReadsEachHeaderOnce() throws {
        let urls = try [photo("a.jpg"), broken("broken.jpg"), photo("c.jpg")]
        var plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) }, convert: ConvertOptions(format: .jpeg),
                             output: .folder(root.appendingPathComponent("src")))
        plan.overwritesOriginals = true
        let reads = OSAllocatedUnfairLock(initialState: [URL: Int]())
        let analysis = runner.analyze(plan, limit: 200) { url in
            reads.withLock { $0[url, default: 0] += 1 }
            return BatchRunner.Header(url)
        }
        // resolve runs twice (rows, overwrite list) but over the same pre-read headers.
        XCTAssertEqual(reads.withLock { $0 }.values.max(), 1, "one read per file, not one per question")
        XCTAssertEqual(analysis.rows.count, 3)
        XCTAssertEqual(analysis.skippedUnreadable, [urls[1]])
        XCTAssertEqual(analysis.overwritten.map(\.primary), [urls[0], urls[2]],
                       "the unreadable file is skipped, so it overwrites nothing")
        XCTAssertEqual(analysis.sizes[urls[0]], CGSize(width: 40, height: 30))
    }

    func testRenameOnlyAnalysisHasNoSkippedUnreadable() throws {
        let urls = try [photo("a.jpg"), broken("broken.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{counter:000}", counterStart: 1), output: .inPlace)
        let analysis = runner.analyze(plan, limit: 200) { BatchRunner.Header($0) }
        XCTAssertTrue(analysis.skippedUnreadable.isEmpty)
        XCTAssertEqual(analysis.unreadable, [urls[1]], "still known to be unreadable")
    }

    // MARK: Review F6

    func testAFilledTemplateThatEndsWithAPeriodIsSkippedInThePreviewAndTheRun() async throws {
        let urls = try [photo("a.jpg"), photo("b.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{name}.", counterStart: 1), output: .inPlace)
        let rows = await runner.preview(plan)
        for row in rows {
            guard case .invalidName(.trailingDot)? = row.skip else { return XCTFail("preview: \(String(describing: row.skip))") }
        }
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.items.count, 2)
        XCTAssertTrue(result.items.allSatisfy { if case .skipped(.invalidName) = $0.outcome { return true }; return false })
        XCTAssertEqual(names(root.appendingPathComponent("src")), ["a.jpg", "b.jpg"], "nothing was renamed")
    }

    // MARK: N8

    /// A template that fills to a no-break space only: preview and run must agree.
    func testATemplateThatFillsToSpacesOnlyIsSkippedAsEmptyInThePreviewAndTheRun() async throws {
        let urls = try [photo("a.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "\u{A0}", counterStart: 1), output: .inPlace)
        let rows = await runner.preview(plan)
        guard case .emptyName? = rows.first?.skip else { return XCTFail("preview: \(String(describing: rows.first?.skip))") }
        let result = try await drain(runner.run(plan))
        guard case .skipped(.emptyName)? = result.items.first?.outcome else { return XCTFail("run: \(String(describing: result.items.first?.outcome))") }
        XCTAssertEqual(names(root.appendingPathComponent("src")), ["a.jpg"])
    }

    func testEveryInvalidNameReasonReadsAsOneCleanSentence() {
        for why in [RenameValidation.trailingDot, .hidden, .edgeSpace, .invalidCharacters, .controlCharacters] {
            let text = BatchSkipReason.invalidName(why).message
            XCTAssertTrue(text.hasPrefix("The new name would "), text)
            XCTAssertTrue(text.hasSuffix(" — skipped."), text)
            XCTAssertFalse(text.contains(". —"), "one ending, not two: \(text)")
            XCTAssertEqual(text.components(separatedBy: " — ").count, 2)
        }
    }

    // MARK: B1, B2 (spec 28 section 18.5)

    private func spaced(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("src").appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    /// A photo skipped for its name takes no counter number: preview and run agree, no gap.
    func testAPhotoSkippedForItsNameTakesNoCounterNumber() async throws {
        let urls = try [spaced("a.jpg"), spaced("d..jpg"), spaced("c.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 1), output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertEqual(rows[0].outputName, "001_a.jpg")
        guard case .invalidName(.trailingDot)? = rows[1].skip else { return XCTFail("\(String(describing: rows[1].skip))") }
        XCTAssertEqual(rows[2].outputName, "002_c.jpg", "no gap: 001, 002")
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(names(root.appendingPathComponent("src")), ["001_a.jpg", "002_c.jpg", "d..jpg"], "the run agrees")
        XCTAssertEqual(result.doneCount, 2)
    }

    /// The count of name skips covers the WHOLE queue, not only the preview's first rows.
    func testSkippedInvalidNameCoversTheWholeQueue() throws {
        var urls: [URL] = []
        for i in 0..<250 { urls.append(try spaced(i == 229 ? "p\(i)..jpg" : "p\(i).jpg")) }
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "{counter:000}_{name}", counterStart: 1), output: .inPlace)
        let analysis = runner.analyze(plan, limit: 200)
        XCTAssertEqual(analysis.rows.count, 200)
        XCTAssertEqual(analysis.skippedInvalidName, [urls[229]], "photo 230 is beyond the rows but counted")
        XCTAssertTrue(analysis.skippedUnreadable.isEmpty)
    }

    func testEveryPhotoSkippedWhenTheTemplateFillsToSpacesOnly() throws {
        let urls = try [spaced("q1.jpg"), spaced("q2.jpg")]
        let plan = BatchPlan(items: urls.map { ImageGroup(primary: $0) },
                             rename: try RenameTemplate(parsing: "\u{A0}", counterStart: 1), output: .inPlace)
        let analysis = runner.analyze(plan, limit: 200)
        XCTAssertEqual(analysis.skippedInvalidName, Set(urls), ".emptyName counts as a name skip too")
    }
}

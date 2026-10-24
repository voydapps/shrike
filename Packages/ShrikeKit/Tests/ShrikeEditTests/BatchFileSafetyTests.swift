//
//  BatchFileSafetyTests.swift
//  ShrikeEditTests
//
//  Audit 2026-10-24: FS-1 / FS-9 (Batch must not overwrite originals by
//  accident) and COR-3 (renames onto names of other batch files).
//  Temp folders only.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchFileSafetyTests: XCTestCase {

    private var root: URL!
    private var backups: BackupStore!
    private var runner: BatchRunner!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShrikeBatchSafety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backups = BackupStore(root: root.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func image(_ name: String, in sub: String = "src", w: Int = 240, h: Int = 160,
                       type: UTType = .jpeg, shade: CGFloat = 0.3) throws -> URL {
        let folder = root.appendingPathComponent(sub, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.8, green: shade, blue: 0.1, alpha: 1))
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

    private func names(in folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: FS-1

    /// Output folder = the photos' own folder, Resize only: without the
    /// confirmation flag no original may change; the copies get " 2" names.
    func testFolderIsSourceFolder_withoutConfirmation_keepsOriginals() async throws {
        let srcs = try (0..<3).map { try image("P\($0).jpg") }
        let before = try srcs.map { try Data(contentsOf: $0) }
        let folder = srcs[0].deletingLastPathComponent()
        let plan = BatchPlan(items: groups(srcs), resize: ResizeOptions(mode: .longEdge, value: 100),
                             output: .folder(folder))
        let rows = await runner.preview(plan)
        XCTAssertTrue(rows.allSatisfy { $0.nameClash && !$0.overwritesOriginal })
        XCTAssertEqual(rows.map(\.outputName), ["P0 2.jpg", "P1 2.jpg", "P2 2.jpg"])
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 3)
        XCTAssertEqual(try srcs.map { try Data(contentsOf: $0) }, before, "no original may be overwritten")
        XCTAssertEqual(names(in: folder).count, 6)
    }

    /// Replace must never trash a photo of the batch itself.
    func testFolderIsSourceFolder_replaceNeverTouchesOriginals() async throws {
        let srcs = try (0..<2).map { try image("P\($0).jpg") }
        let before = try srcs.map { try Data(contentsOf: $0) }
        let folder = srcs[0].deletingLastPathComponent()
        let plan = BatchPlan(items: groups(srcs), resize: ResizeOptions(mode: .longEdge, value: 100),
                             output: .folder(folder), onConflict: .replace)
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 2)
        XCTAssertEqual(try srcs.map { try Data(contentsOf: $0) }, before)
    }

    /// Confirmed: the originals are re-encoded, each with a backup, and Undo restores them.
    func testFolderIsSourceFolder_confirmed_overwritesWithBackupAndUndo() async throws {
        let srcs = try (0..<2).map { try image("P\($0).jpg") }
        let before = try srcs.map { try Data(contentsOf: $0) }
        let folder = srcs[0].deletingLastPathComponent()
        var plan = BatchPlan(items: groups(srcs), resize: ResizeOptions(mode: .longEdge, value: 100),
                             output: .folder(folder))
        XCTAssertEqual(runner.originalsOverwritten(by: plan), 2)
        plan.overwritesOriginals = true
        let rows = await runner.preview(plan)
        XCTAssertTrue(rows.allSatisfy { $0.overwritesOriginal && !$0.nameClash })
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 2)
        XCTAssertEqual(names(in: folder), ["P0.jpg", "P1.jpg"])
        XCTAssertEqual(BatchRunner.Header(srcs[0])?.displaySize.width, 100)
        XCTAssertEqual(result.replacedOriginals.count, 2)
        XCTAssertTrue(result.canUndo)
        try await runner.undo(result)
        XCTAssertEqual(try srcs.map { try Data(contentsOf: $0) }, before)
    }

    /// A separate output folder never counts as overwriting.
    func testSeparateFolderOverwritesNothing() async throws {
        let srcs = try (0..<2).map { try image("P\($0).jpg") }
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plan = BatchPlan(items: groups(srcs), resize: ResizeOptions(mode: .longEdge, value: 100), output: .folder(out))
        XCTAssertEqual(runner.originalsOverwritten(by: plan), 0)
    }

    /// Convert a.png -> jpg while a.jpg is another queued photo: a real clash, never an overwrite.
    func testConvertOntoAnotherQueuedPhoto_isAClash() async throws {
        let png = try image("a.png", type: .png)
        let jpg = try image("a.jpg", shade: 0.9)
        let folder = png.deletingLastPathComponent()
        var plan = BatchPlan(items: groups([png, jpg]), convert: ConvertOptions(format: .jpeg), output: .folder(folder))
        plan.overwritesOriginals = true
        let rows = await runner.preview(plan)
        let pngRow = try XCTUnwrap(rows.first { $0.source.primary == png })
        XCTAssertTrue(pngRow.nameClash)
        XCTAssertNotEqual(pngRow.outputName, "a.jpg")
        _ = try await drain(runner.run(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("a 2.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
    }

    // MARK: FS-9

    func testCaseOnlyDifferentOutputNamesGetSuffix() async throws {
        let a = try image("IMG_1.JPG", in: "a")
        let b = try image("img_1.jpg", in: "b")
        let out = root.appendingPathComponent("out", isDirectory: true)
        let plan = BatchPlan(items: groups([a, b]), convert: ConvertOptions(format: .jpeg), output: .folder(out))
        let rows = await runner.preview(plan)
        XCTAssertEqual(Set(rows.map { $0.outputName.lowercased() }).count, 2, "\(rows.map(\.outputName))")
        XCTAssertEqual(rows.filter(\.nameClash).count, 1)
    }
}

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
}

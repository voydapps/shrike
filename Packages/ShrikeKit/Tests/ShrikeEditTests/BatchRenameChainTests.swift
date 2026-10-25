//
//  BatchRenameChainTests.swift
//  ShrikeEditTests
//
//  Audit 2026-10-24 COR-3: a Batch rename onto the current name of another
//  photo of the same batch (shift or swap) runs in two phases, loses nothing
//  and undoes cleanly. Temp folders only.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class BatchRenameChainTests: XCTestCase {

    private var root: URL!
    private var backups: BackupStore!
    private var runner: BatchRunner!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("ShrikeRenameChain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        backups = BackupStore(root: root.appendingPathComponent("_backups", isDirectory: true), retentionDays: { 30 })
        runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// JPEGs whose width tells them apart: 100, 110, 120, ...
    private func numbered(_ names: [String]) throws -> [URL] {
        let folder = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try names.enumerated().map { i, name in
            let url = folder.appendingPathComponent(name)
            let w = 100 + i * 10, h = 80
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.3, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            return url
        }
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

    private func width(_ url: URL) -> CGFloat? { BatchRunner.Header(url)?.displaySize.width }

    func testShiftRenumberRunsAndUndoes() async throws {
        let srcs = try numbered(["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        let folder = srcs[0].deletingLastPathComponent()
        let plan = BatchPlan(items: groups(srcs), rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertTrue(rows.allSatisfy { !$0.nameClash && $0.skip == nil })
        XCTAssertEqual(rows.map(\.outputName), ["IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg"])

        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 3, "\(result.items.map(\.outcome))")
        XCTAssertEqual(names(in: folder), ["IMG_2.jpg", "IMG_3.jpg", "IMG_4.jpg"])
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_2.jpg")), 100)
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_3.jpg")), 110)
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_4.jpg")), 120)

        try await runner.undo(result)
        XCTAssertEqual(names(in: folder), ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_1.jpg")), 100)
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_2.jpg")), 110)
        XCTAssertEqual(width(folder.appendingPathComponent("IMG_3.jpg")), 120)
    }

    func testSwapRunsAndUndoes() async throws {
        let srcs = try numbered(["1.jpg", "2.jpg"])
        let folder = srcs[0].deletingLastPathComponent()
        // List order 2, 1 with counter 1: 2.jpg becomes 1.jpg and 1.jpg becomes 2.jpg.
        let plan = BatchPlan(items: groups([srcs[1], srcs[0]]), rename: try RenameTemplate(parsing: "{counter}"),
                             output: .inPlace)
        let result = try await drain(runner.run(plan))
        XCTAssertEqual(result.doneCount, 2, "\(result.items.map(\.outcome))")
        XCTAssertEqual(names(in: folder), ["1.jpg", "2.jpg"])
        XCTAssertEqual(width(folder.appendingPathComponent("1.jpg")), 110)
        XCTAssertEqual(width(folder.appendingPathComponent("2.jpg")), 100)
        try await runner.undo(result)
        XCTAssertEqual(width(folder.appendingPathComponent("1.jpg")), 100)
        XCTAssertEqual(width(folder.appendingPathComponent("2.jpg")), 110)
        XCTAssertEqual(names(in: folder), ["1.jpg", "2.jpg"])
    }

    /// A name used by a photo that is NOT in the batch is still a true clash.
    func testExternalPhotoStillClashes() async throws {
        let all = try numbered(["IMG_1.jpg", "IMG_2.jpg"])
        let other = all[1]
        let otherBytes = try Data(contentsOf: other)
        let plan = BatchPlan(items: groups([all[0]]), rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace)
        let rows = await runner.preview(plan)
        XCTAssertTrue(rows[0].nameClash)
        XCTAssertEqual(rows[0].outputName, "IMG_2 2.jpg")
        _ = try await drain(runner.run(plan))
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
    }

    /// Stop between the two phases: no photo is lost. One that could not get
    /// its old name back (an earlier item already took it) is reported by name.
    func testStopBetweenPhasesLosesNothingAndReportsTempNames() async throws {
        let srcs = try numbered(["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
        let folder = srcs[0].deletingLastPathComponent()
        let stop = BatchStop()
        let gated = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil), backups: backups,
                                renameCheckpoint: { point, _ in if point == .beforeMove { stop.stop() } })
        let plan = BatchPlan(items: groups(srcs), rename: try RenameTemplate(parsing: "IMG_{counter}", counterStart: 2),
                             output: .inPlace)
        let result = try await drain(gated.run(plan, stop: stop))
        let left = names(in: folder)
        XCTAssertEqual(left.count, 3, "no photo lost: \(left)")
        for temp in left where temp.contains("shrike-tmp") {
            let reported = result.items.contains { item in
                if case .failed(let error) = item.outcome { return error.localizedDescription.contains(temp) }
                return false
            }
            XCTAssertTrue(reported, "\(temp) must be named in a failed item")
        }
        // Undo walks the recorded steps back.
        try await runner.undo(result)
        XCTAssertEqual(names(in: folder), ["IMG_1.jpg", "IMG_2.jpg", "IMG_3.jpg"])
    }
}

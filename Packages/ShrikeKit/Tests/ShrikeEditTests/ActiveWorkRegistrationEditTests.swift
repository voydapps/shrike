//
//  ActiveWorkRegistrationEditTests.swift
//  ShrikeEditTests
//
//  Audit A-1: save, rotate write and Batch run register themselves in
//  `ActiveWork.shared`.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class ActiveWorkRegistrationEditTests: XCTestCase {

    private var tmp: EditTempDir!
    private var backups: BackupStore!

    override func setUp() {
        super.setUp()
        tmp = EditTempDir("ActiveWorkEdit")
        backups = BackupStore(root: tmp.url.appendingPathComponent("backups"), retentionDays: { 30 })
    }

    override func tearDown() {
        tmp.cleanup()
        super.tearDown()
    }

    private func writeJPEG(_ name: String) throws -> URL {
        let url = tmp.url.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testSaveHoldsASaveTokenAndReleasesIt() async throws {
        let src = try writeJPEG("a.jpg")
        let seen = OSAllocatedUnfairLock(initialState: false)
        let exporter = ImageExporter(backupStore: backups, checkpoint: { point in
            if point == .decoded { seen.withLock { $0 = ActiveWork.shared.snapshot().contains(.save) } }
        })
        try await exporter.export(recipe: EditRecipe(operations: []), from: src,
                                  to: tmp.url.appendingPathComponent("b.jpg"), format: .jpeg)
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }

    func testRotateWriteHoldsATokenWhileTheBackupIsTaken() async throws {
        let src = try writeJPEG("r.jpg")
        let seen = OSAllocatedUnfairLock(initialState: false)
        let store = BackupStore(
            root: tmp.url.appendingPathComponent("rb"), retentionDays: { 30 }, maxBytes: { 0 }, now: { Date() },
            copier: { from, to in
                seen.withLock { $0 = ActiveWork.shared.snapshot().contains(.rotateWrite) }
                try FileManager.default.copyItem(at: from, to: to)
            })
        _ = try await LosslessRotator(backupStore: store).rotate(url: src, quarters: 1)
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }

    func testBatchRunHoldsATokenUntilTheStreamHasEnded() async throws {
        let src = try writeJPEG("p.jpg")
        let seen = OSAllocatedUnfairLock(initialState: false)
        let runner = BatchRunner(fileOps: FileOps(metadata: nil, backups: backups, watchers: nil),
                                 backups: backups, phaseCheckpoint: { _, _ in
            seen.withLock { $0 = ActiveWork.shared.snapshot().contains(.batchRun) }
        })
        let plan = BatchPlan(items: [ImageGroup(primary: src)], rotate: 1, output: .inPlace)
        let stream = runner.run(plan)
        XCTAssertTrue(ActiveWork.shared.snapshot().contains(.batchRun), "open before the first element")
        for try await _ in stream {}
        for _ in 0..<200 where !ActiveWork.shared.snapshot().isIdle { await Task.yield() }
        XCTAssertTrue(seen.withLock { $0 })
        XCTAssertTrue(ActiveWork.shared.snapshot().isIdle)
    }
}

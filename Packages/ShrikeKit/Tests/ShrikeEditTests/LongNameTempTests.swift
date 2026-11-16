//
//  LongNameTempTests.swift
//  ShrikeEditTests
//
//  Review F9b: a rotate or a save on a file with a very long name still works; its temp name stays
//  under the 255-byte limit.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeEdit

final class LongNameTempTests: XCTestCase {

    func testRotateAndSaveWorkOnA240ByteName() async throws {
        let dir = TestScratch.directory.appendingPathComponent("LongNameTemp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(String(repeating: "n", count: 236) + ".jpg")      // 240 bytes
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let store = BackupStore(root: dir.appendingPathComponent("_b"), retentionDays: { 30 })
        _ = try await LosslessRotator(backupStore: store).rotate(url: url, quarters: 1)
        try await ImageExporter(backupStore: store).export(recipe: EditRecipe(operations: []), from: url, to: url, format: .jpeg)
        let left = (try FileManager.default.contentsOfDirectory(atPath: dir.path)).filter { $0 != "_b" }
        XCTAssertEqual(left, [url.lastPathComponent], "no temp file is left")
    }
}

//
//  ExporterCooperativePoolTests.swift
//  ShrikeEditTests
//
//  Audit MP-09: a Batch export (Core Image render + encode) must not park
//  Swift's cooperative threads, or every other async job in the app waits.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeEdit
import ShrikeIO

final class ExporterCooperativePoolTests: XCTestCase {

    func testManyExportsDoNotStarveTheCooperativePool() async throws {
        let tmp = EditTempDir("ExporterPool")
        defer { tmp.cleanup() }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let count = cores * 2
        // A 12 MP source, so each render/encode takes real time.
        let ctx = CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for i in 0..<64 {
            ctx.setFillColor(CGColor(red: CGFloat(i) / 64, green: 0.4, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: i * 62, y: 0, width: 62, height: 3000))
        }
        let source = tmp.url.appendingPathComponent("big.jpg")
        let dest = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let exporter = ImageExporter(backupStore: BackupStore(root: tmp.url.appendingPathComponent("backups")))

        let outDir = tmp.url
        let exports = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<count {
                    group.addTask {
                        let recipe = EditRecipe()
                        await recipe.append(.colorAdjust(ColorAdjustParams(brightness: 0.1)))
                        try await exporter.export(recipe: recipe, from: source,
                                                  to: outDir.appendingPathComponent("out\(i).jpg"),
                                                  format: .jpeg, quality: 0.8)
                    }
                }
                try await group.waitForAll()
            }
        }
        // While the exports run, a trivial job on the cooperative pool must
        // still start promptly.
        var worst = 0.0
        for _ in 0..<15 {
            let start = ContinuousClock.now
            await Task.detached { }.value
            let d = ContinuousClock.now - start
            worst = max(worst, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            try await Task.sleep(for: .milliseconds(40))
        }
        try await exports.value
        XCTAssertLessThan(worst, 0.25, "a trivial async job waited \(worst) s behind exports")
    }
}

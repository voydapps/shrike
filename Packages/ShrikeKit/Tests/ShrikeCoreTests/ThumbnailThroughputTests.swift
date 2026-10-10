//
//  ThumbnailThroughputTests.swift
//  ShrikeCoreTests
//
//  Benchmark for the goal "thumbnails: 80+/sec on 4-core,
//  12 MP JPEGs". Generates a few 12 MP JPEGs (4000 × 3000, noisy enough
//  that the JPEG decode costs what a camera file costs), clones them to N
//  files in a temp folder, then asks one `ThumbnailCache` for all of them
//  at once, the way a grid asks for its visible cells.
//
//  Prints `[thumbs] …` lines with thumbnails/sec: cold (decode), warm disk
//  (new cache over the same folder) and warm memory. Asserts only sanity,
//  never a speed: CI machines vary. Run with `-c release` for real numbers:
//    swift test -c release --filter ThumbnailThroughputTests
//  SHRIKE_THUMB_BENCH_N overrides N (default 96).
//  SHRIKE_THUMB_BENCH_FORMATS picks the formats, comma separated, from
//  jpeg, heic, png, tiff (default jpeg). The masters are the same pixels
//  in every format.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

final class ThumbnailThroughputTests: XCTestCase {

    private static let width = 4000
    private static let height = 3000

    /// A noisy 12 MP JPEG. Gradient + shapes + a tiled noise layer so the
    /// entropy (and so the decode cost) is close to a camera file.
    private static func writeImage12MP(to url: URL, seed: UInt64, type: UTType) throws {
        var rng = SplitMix(seed: seed)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("no CGContext")
        }
        let colors = [CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1),
                      CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1)]
        let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: .zero,
                               end: CGPoint(x: width, y: height), options: [])
        for _ in 0..<300 {
            ctx.setFillColor(CGColor(srgbRed: rng.unit(), green: rng.unit(), blue: rng.unit(),
                                     alpha: 0.3 + 0.5 * rng.unit()))
            let w = 40 + rng.unit() * 900, h = 40 + rng.unit() * 900
            ctx.fillEllipse(in: CGRect(x: rng.unit() * Double(width) - w / 2,
                                       y: rng.unit() * Double(height) - h / 2, width: w, height: h))
        }
        // 509 × 509 noise tile (prime, so the tiling doesn't line up with
        // JPEG's 8 × 8 blocks), drawn over everything at 35 % alpha.
        let tile = 509
        var noise = [UInt8](repeating: 255, count: tile * tile * 4)
        for i in stride(from: 0, to: noise.count, by: 4) {
            let v = rng.next()
            noise[i] = UInt8(truncatingIfNeeded: v)
            noise[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
            noise[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
        }
        let provider = CGDataProvider(data: Data(noise) as CFData)!
        let noiseImage = CGImage(width: tile, height: tile, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: tile * 4, space: space,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false,
                                 intent: .defaultIntent)!
        ctx.setAlpha(0.35)
        ctx.draw(noiseImage, in: CGRect(x: 0, y: 0, width: tile, height: tile), byTiling: true)
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw XCTSkip("no \(type.identifier) encoder") }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("\(type.identifier) encode failed") }
    }

    /// N files (clones of 6 masters) in `folder`.
    private static func makeCorpus(in folder: URL, count: Int, type: UTType = .jpeg) throws -> [URL] {
        let fm = FileManager.default
        let ext = type.preferredFilenameExtension ?? "img"
        var masters: [URL] = []
        for i in 0..<6 {
            let url = folder.appendingPathComponent("master_\(i).\(ext)")
            try writeImage12MP(to: url, seed: UInt64(i + 1) &* 0x9E37_79B9, type: type)
            masters.append(url)
        }
        var urls: [URL] = []
        for i in 0..<count {
            let url = folder.appendingPathComponent(String(format: "IMG_%04d.", i) + ext)
            try fm.copyItem(at: masters[i % masters.count], to: url)
            urls.append(url)
        }
        return urls
    }

    /// Requests every source at once (like a grid's visible cells) and
    /// returns thumbnails/sec for the whole batch.
    private static func run(_ cache: ThumbnailCache, _ sources: [FileImageSource], size: Int) async throws -> Double {
        let start = ContinuousClock.now
        try await withThrowingTaskGroup(of: Int.self) { group in
            for source in sources {
                group.addTask { try await cache.thumbnail(for: source, maxPixelSize: size).width }
            }
            for try await width in group { XCTAssertGreaterThan(width, 0) }
        }
        let elapsed = ContinuousClock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return Double(sources.count) / max(seconds, 1e-9)
    }

    func testThroughput_12MPJPEGs_coldAndWarm() async throws {
        let n = Int(ProcessInfo.processInfo.environment["SHRIKE_THUMB_BENCH_N"] ?? "") ?? 96
        let formats = (ProcessInfo.processInfo.environment["SHRIKE_THUMB_BENCH_FORMATS"] ?? "jpeg")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        for format in formats {
            let type: UTType
            switch format {
            case "heic": type = .heic
            case "png": type = .png
            case "tiff": type = .tiff
            default: type = .jpeg
            }
            try await runBenchmark(n: n, type: type, label: format.uppercased())
        }
    }

    private func runBenchmark(n: Int, type: UTType, label: String) async throws {
        let tmp = TempDir("thumb-bench")
        defer { tmp.cleanup() }
        let corpus = tmp.url.appendingPathComponent("corpus", isDirectory: true)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        let urls = try Self.makeCorpus(in: corpus, count: n, type: type)
        let sources = urls.map { FileImageSource(url: $0) }
        let cores = ProcessInfo.processInfo.activeProcessorCount

        // Warm-up, not measured: page the files in and start ImageIO's
        // helper, so "cold" means "not in Shrike's caches", like a folder
        // the user just opened.
        for url in urls { _ = try Data(contentsOf: url).count }
        let warmUp = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("warmup", isDirectory: true))
        _ = try await Self.run(warmUp, Array(sources.prefix(8)), size: 128)
        await warmUp.waitForPendingDiskWrites()

        // SHRIKE_THUMB_BENCH_SLOTS models a smaller machine (e.g. 4).
        let slots = Int(ProcessInfo.processInfo.environment["SHRIKE_THUMB_BENCH_SLOTS"] ?? "")
        for size in [256, 360] {
            let disk = tmp.url.appendingPathComponent("cache-\(size)-\(UUID().uuidString)", isDirectory: true)
            let cache = try ThumbnailCache(diskURL: disk, maxConcurrentDecodes: slots)
            let cold = try await Self.run(cache, sources, size: size)
            let warmMemory = try await Self.run(cache, sources, size: size)
            await cache.waitForPendingDiskWrites()

            let reopened = try ThumbnailCache(diskURL: disk)
            let warmDisk = try await Self.run(reopened, sources, size: size)

            let used = await cache.maxConcurrentDecodesForTesting
            print(String(format: "[thumbs] %d × 12 MP %@ @ %d px, %d cores, %d slots: cold %.1f/s · warm disk %.1f/s · warm memory %.0f/s",
                         n, label, size, cores, used, cold, warmDisk, warmMemory))
            let stats = await reopened.statistics()
            XCTAssertEqual(stats.misses, 0, "reopened cache served everything from disk")
            XCTAssertGreaterThan(cold, 0)
        }
    }
}

/// Deterministic, fast PRNG for fixtures.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

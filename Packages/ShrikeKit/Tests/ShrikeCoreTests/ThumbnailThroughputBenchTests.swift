//
//  ThumbnailThroughputBenchTests.swift
//  ShrikeCoreTests
//
//  Cold-cache grid thumbnail throughput. Off unless SHRIKE_BENCH_DIR names a
//  folder of JPEGs; prints thumbnails per second for 4 and 8 decode slots.
//

import XCTest
@testable import ShrikeCore

final class ThumbnailThroughputBenchTests: XCTestCase {

    func testColdCacheThroughput() async throws {
        guard let path = ProcessInfo.processInfo.environment["SHRIKE_BENCH_DIR"] else {
            throw XCTSkip("SHRIKE_BENCH_DIR not set")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
            .filter { $0.lowercased().hasSuffix(".jpg") }
        XCTAssertFalse(names.isEmpty)
        let urls = names.map { URL(fileURLWithPath: path).appendingPathComponent($0) }
        for slots in [4, 8] {
            let tmp = TempDir("thumb-bench-\(slots)")
            defer { tmp.cleanup() }
            let cache = try ThumbnailCache(diskURL: tmp.url, maxConcurrentDecodes: slots)
            let start = ContinuousClock.now
            let done = try await withThrowingTaskGroup(of: Bool.self) { group in
                for url in urls {
                    group.addTask {
                        _ = try await cache.thumbnail(for: FileImageSource(url: url), maxPixelSize: 320)
                        return true
                    }
                }
                var n = 0
                for try await _ in group { n += 1 }
                return n
            }
            let (s, a) = (ContinuousClock.now - start).components
            let seconds = Double(s) + Double(a) / 1e18
            print("BENCH slots=\(slots) n=\(done) seconds=\(seconds) perSecond=\(Double(done) / seconds)")
            XCTAssertEqual(done, urls.count)
        }
    }
}

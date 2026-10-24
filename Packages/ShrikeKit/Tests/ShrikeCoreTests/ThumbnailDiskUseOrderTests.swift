//
//  ThumbnailDiskUseOrderTests.swift
//  ShrikeCoreTests
//
//  Audit MP-11: a disk-tier hit counts as use, so the size trim deletes
//  least recently used thumbnails first, not the oldest written.
//

import XCTest
@testable import ShrikeCore

final class ThumbnailDiskUseOrderTests: XCTestCase {

    func testDiskHitRefreshesTheFileDate() async throws {
        let tmp = TempDir("thumb-use-order")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url, diskCeilingBytes: 10 * 1024 * 1024)
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        await cache.waitForPendingDiskWrites()

        let files = (FileManager.default.enumerator(at: tmp.url, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
        let file = try XCTUnwrap(files.first)
        let old = Date().addingTimeInterval(-3 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        await cache.evictMemory()
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)   // disk hit
        let stats = await cache.statistics()
        XCTAssertGreaterThanOrEqual(stats.diskHits, 1)
        let after = try XCTUnwrap(try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        XCTAssertGreaterThan(after.timeIntervalSince(old), 86_400, "the hit must refresh the date")
    }
}

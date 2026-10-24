//
//  ThumbnailCacheEvictTests.swift
//  ShrikeCoreTests
//
//  `ThumbnailCache.evict(url:)` and `setDiskCeiling(bytes:)`.
//

import XCTest
import CoreGraphics
@testable import ShrikeCore

final class ThumbnailCacheEvictTests: XCTestCase {

    private func copyFixture(_ name: String, to folder: URL, as newName: String) throws -> URL {
        let dst = folder.appendingPathComponent(newName)
        try FileManager.default.copyItem(at: try TestFixture.url(name), to: dst)
        return dst
    }

    /// Files under the cache root whose name starts with `prefix`.
    private func diskFiles(_ root: URL, prefix: String) -> [String] {
        let shard = root.appendingPathComponent(String(prefix.prefix(2)))
        return ((try? FileManager.default.contentsOfDirectory(atPath: shard.path)) ?? [])
            .filter { $0.hasPrefix(prefix) }
    }

    func testEvict_dropsEverySizeFromMemoryAndDisk_keepsOtherFiles() async throws {
        let tmp = TempDir("thumb-evict-url")
        defer { tmp.cleanup() }
        let cacheRoot = tmp.url.appendingPathComponent("cache")
        let cache = try ThumbnailCache(diskURL: cacheRoot)
        let a = FileImageSource(url: try copyFixture("small.jpg", to: tmp.url, as: "a.jpg"))
        let b = FileImageSource(url: try copyFixture("small.jpg", to: tmp.url, as: "b.jpg"))

        _ = try await cache.thumbnail(for: a, maxPixelSize: 64)
        _ = try await cache.thumbnail(for: a, maxPixelSize: 128)
        _ = try await cache.thumbnail(for: b, maxPixelSize: 64)
        await cache.waitForPendingDiskWrites()
        let aPrefix = ThumbnailCache.pathPrefix(for: a)
        let bPrefix = ThumbnailCache.pathPrefix(for: b)
        XCTAssertEqual(diskFiles(cacheRoot, prefix: aPrefix).count, 2)
        XCTAssertEqual(diskFiles(cacheRoot, prefix: bPrefix).count, 1)

        await cache.evict(url: a.url)

        XCTAssertNil(cache.cachedThumbnail(for: a, maxPixelSize: 64))
        XCTAssertNil(cache.cachedThumbnail(for: a, maxPixelSize: 128))
        XCTAssertNotNil(cache.cachedThumbnail(for: b, maxPixelSize: 64))
        XCTAssertEqual(diskFiles(cacheRoot, prefix: aPrefix), [])
        XCTAssertEqual(diskFiles(cacheRoot, prefix: bPrefix).count, 1)
    }

    func testEvict_afterTheFileChanged_stillFindsOldVersions() async throws {
        let tmp = TempDir("thumb-evict-changed")
        defer { tmp.cleanup() }
        let cacheRoot = tmp.url.appendingPathComponent("cache")
        let cache = try ThumbnailCache(diskURL: cacheRoot)
        let url = try copyFixture("small.jpg", to: tmp.url, as: "c.jpg")
        _ = try await cache.thumbnail(for: FileImageSource(url: url), maxPixelSize: 96)
        await cache.waitForPendingDiskWrites()

        // Saved in place: new bytes, new mtime, so a new content hash.
        try FileManager.default.removeItem(at: url)
        _ = try copyFixture("small.png", to: tmp.url, as: "c.jpg")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: url.path)
        await cache.evict(url: url)
        XCTAssertEqual(diskFiles(cacheRoot, prefix: ThumbnailCache.pathPrefix(forPath: url.standardizedFileURL.path)), [])
    }

    func testEvict_skipsAPendingDiskWrite() async throws {
        let tmp = TempDir("thumb-evict-pending")
        defer { tmp.cleanup() }
        let cacheRoot = tmp.url.appendingPathComponent("cache")
        let cache = try ThumbnailCache(diskURL: cacheRoot)
        let source = FileImageSource(url: try copyFixture("small.jpg", to: tmp.url, as: "d.jpg"))
        _ = try await cache.thumbnail(for: source, maxPixelSize: 80)
        // No wait: the HEIC write may still be queued.
        await cache.evict(url: source.url)
        await cache.waitForPendingDiskWrites()
        XCTAssertEqual(diskFiles(cacheRoot, prefix: ThumbnailCache.pathPrefix(for: source)), [])
        XCTAssertNil(cache.cachedThumbnail(for: source, maxPixelSize: 80))

        // The next request decodes again and caches normally.
        _ = try await cache.thumbnail(for: source, maxPixelSize: 80)
        await cache.waitForPendingDiskWrites()
        XCTAssertEqual(diskFiles(cacheRoot, prefix: ThumbnailCache.pathPrefix(for: source)).count, 1)
    }

    func testSetDiskCeiling_trimsAtOnce() async throws {
        let tmp = TempDir("thumb-ceiling")
        defer { tmp.cleanup() }
        let cache = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("cache"))
        let source = FileImageSource(url: try TestFixture.url("small.jpg"))
        for size in [48, 64, 80, 96, 112, 128] {
            _ = try await cache.thumbnail(for: source, maxPixelSize: size)
        }
        await cache.waitForPendingDiskWrites()
        let full = await cache.currentDiskBytes()
        XCTAssertGreaterThan(full, 0)

        await cache.setDiskCeiling(bytes: full / 2)
        let ceiling = await cache.diskCeiling
        XCTAssertEqual(ceiling, full / 2)
        let trimmed = await cache.currentDiskBytes()
        XCTAssertLessThanOrEqual(trimmed, full / 2)
        XCTAssertGreaterThan(trimmed, 0)

        await cache.setDiskCeiling(bytes: 0)
        let empty = await cache.currentDiskBytes()
        XCTAssertEqual(empty, 0)
    }

    func testEvictIfContentChanged_keepsThumbnailOnAttributeWrite_dropsOnContentChange() async throws {
        let tmp = TempDir("thumb-evict-xattr")
        defer { tmp.cleanup() }
        let cacheRoot = tmp.url.appendingPathComponent("cache")
        let cache = try ThumbnailCache(diskURL: cacheRoot)
        let url = try copyFixture("small.jpg", to: tmp.url, as: "x.jpg")
        let source = FileImageSource(url: url)
        _ = try await cache.thumbnail(for: source, maxPixelSize: 64)
        await cache.waitForPendingDiskWrites()
        let prefix = ThumbnailCache.pathPrefix(for: source)

        // A rating / flag / tag is an extended attribute.
        XCTAssertEqual(setxattr(url.path, "com.apple.metadata:test", "5", 1, 0, 0), 0)
        let evictedByAttribute = await cache.evictIfContentChanged(url: url)
        XCTAssertFalse(evictedByAttribute)
        XCTAssertNotNil(cache.cachedThumbnail(for: source, maxPixelSize: 64))
        XCTAssertEqual(diskFiles(cacheRoot, prefix: prefix).count, 1)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0, 0, 0])); try handle.close()
        let evictedByContent = await cache.evictIfContentChanged(url: url)
        XCTAssertTrue(evictedByContent)
        XCTAssertEqual(diskFiles(cacheRoot, prefix: prefix), [])
    }

    func testDroppedCache_endsItsEvictionTicker() async throws {
        let tmp = TempDir("thumb-ticker")
        defer { tmp.cleanup() }
        var cache: ThumbnailCache? = try ThumbnailCache(diskURL: tmp.url.appendingPathComponent("cache"))
        weak var weakCache = cache
        var ticker: Task<Void, Never>?
        for _ in 0..<200 where ticker == nil {
            ticker = await cache?.evictionTickerForTesting
            if ticker == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let task = try XCTUnwrap(ticker)
        cache = nil
        for _ in 0..<50 where weakCache != nil { await Task.yield() }
        XCTAssertNil(weakCache)
        let ended = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(ended, "the ticker should stop when its cache goes away")
    }
}

import XCTest
import CoreGraphics
import ImageIO
import ShrikeCore
@testable import ShrikeUI

final class DefaultServiceFallbackTests: XCTestCase {
    /// Every fault is local to this case. Never obstruct the process's
    /// ordinary default database: another test may still have it open.
    private func withPaths(
        _ body: (URL, ShrikeServices.StoragePaths) async throws -> Void
    ) async throws {
        let root = ShrikeDataPaths.testRoot.appendingPathComponent("fallback-factory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ShrikeServices.StoragePaths(
            applicationSupport: root.appendingPathComponent("Application Support", isDirectory: true),
            caches: root.appendingPathComponent("Caches", isDirectory: true),
            fallbackDirectory: root.appendingPathComponent("Fallback", isDirectory: true))
        try await body(root, paths)
    }

    private func blockDatabase(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func assertDescendant(_ url: URL, of root: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"), file: file, line: line)
    }

    func testBlockedPrimaryDatabaseUsesPrivateFallbackThenRecoversSessionAndFutureWrites() async throws {
        try await withPaths { root, paths in
            try blockDatabase(paths.metadata)
            let services = ShrikeServices.makeDefault(storagePaths: paths)
            let store = services.metadataStore
            XCTAssertFalse(store.isPersistent)
            XCTAssertNotNil(store.openError)
            XCTAssertEqual(store.persistenceStatus.primaryURL, paths.metadata)
            assertDescendant(paths.metadataFallback, of: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadataFallback.path))
            let initialRecents = try await store.recentFolders(limit: 100)
            XCTAssertEqual(initialRecents.count, 0, "no unrelated session rows may enter a fresh private fallback")

            // Deliberately absent files: xattrs cannot mask a database write
            // or make a reopened-primary assertion pass through a mirror.
            let image = root.appendingPathComponent("absent-photo.jpg")
            let futureImage = root.appendingPathComponent("absent-future-photo.jpg")
            let recent = root.appendingPathComponent("owned-recent", isDirectory: true)
            try await store.setRating(4, for: image)
            try await store.setFlag(true, for: image)
            try await store.addRecentFolder(recent)
            let fallback = try MetadataStore(databaseURL: paths.metadataFallback, writeFileAttributes: { false })
            let fallbackRecords = try await fallback.recordsStrict(for: [image])
            XCTAssertEqual(fallbackRecords[image], FileRecord(rating: 4, flagged: true))

            do {
                _ = try await store.retryPersistentStore()
                XCTFail("the owned primary obstruction must still fail")
            } catch {}
            XCTAssertFalse(store.isPersistent)
            let preserved = try await store.recordsStrict(for: [image])
            XCTAssertEqual(preserved, fallbackRecords)

            try FileManager.default.removeItem(at: paths.metadata)
            let result = try await store.retryPersistentStore()
            XCTAssertEqual(result.metadataCount, 1)
            XCTAssertEqual(result.recentFolderCount, 1)
            XCTAssertTrue(store.isPersistent)
            XCTAssertNil(store.openError)
            let reopened = try MetadataStore(databaseURL: paths.metadata, writeFileAttributes: { false })
            let records = try await reopened.recordsStrict(for: [image])
            let recents = try await reopened.recentFolders(limit: 100)
            XCTAssertEqual(records, fallbackRecords)
            XCTAssertEqual(recents.map(\.path), [recent.path])
            try await store.setRating(2, for: futureImage)
            let durableRating = try await reopened.rating(for: futureImage)
            XCTAssertEqual(durableRating, 2)
            await services.thumbnailCache.waitForPendingDiskWrites()
        }
    }

    func testBlockedPrimaryThumbnailDirectoryWritesOnlyToPrivateFallback() async throws {
        try await withPaths { root, paths in
            let primaryParent = paths.thumbnails.deletingLastPathComponent()
            try Data([1]).write(to: primaryParent)
            let services = ShrikeServices.makeDefault(storagePaths: paths)
            let cache = services.thumbnailCache
            let directory = await cache.diskDirectory
            XCTAssertEqual(directory, paths.thumbnailFallback)
            assertDescendant(directory, of: root)
            XCTAssertTrue(services.metadataStore.isPersistent)

            let imageURL = root.appendingPathComponent("owned-image.png")
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8,
                bytesPerRow: 64 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(imageURL as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let source = FileImageSource(url: imageURL)
            let image = try await cache.thumbnail(for: source, maxPixelSize: 32)
            XCTAssertEqual(image.width, 32)
            await cache.waitForPendingDiskWrites()
            let diskFile = try await cache.diskFileURL(for: source, maxPixelSize: 32)
            assertDescendant(diskFile, of: directory)
            XCTAssertTrue(FileManager.default.fileExists(atPath: diskFile.path))
            let onDisk = try XCTUnwrap(CGImageSourceCreateWithURL(diskFile as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(onDisk, 0, nil))
            XCTAssertEqual(decoded.width, 32)
            XCTAssertEqual(try Data(contentsOf: primaryParent), Data([1]), "the owned obstruction is untouched")
        }
    }

    func testBothDatabasePathsBlockedUseMemoryAndRecoverToOwnedPrimary() async throws {
        try await withPaths { root, paths in
            try blockDatabase(paths.metadata)
            try blockDatabase(paths.metadataFallback)
            let services = ShrikeServices.makeDefault(storagePaths: paths)
            let store = services.metadataStore
            XCTAssertFalse(store.isPersistent)
            XCTAssertNotNil(store.openError)
            XCTAssertEqual(store.persistenceStatus.primaryURL, paths.metadata)
            let image = root.appendingPathComponent("absent-memory-photo.jpg")
            let recent = root.appendingPathComponent("memory-recent", isDirectory: true)
            try await store.setRating(5, for: image)
            try await store.setFlag(true, for: image)
            try await store.addRecentFolder(recent)
            try FileManager.default.removeItem(at: paths.metadata)
            let result = try await store.retryPersistentStore()
            XCTAssertEqual(result.metadataCount, 1)
            XCTAssertEqual(result.recentFolderCount, 1)
            XCTAssertTrue(store.isPersistent)
            let reopened = try MetadataStore(databaseURL: paths.metadata, writeFileAttributes: { false })
            let records = try await reopened.recordsStrict(for: [image])
            let recents = try await reopened.recentFolders(limit: 100)
            XCTAssertEqual(records[image], FileRecord(rating: 5, flagged: true))
            XCTAssertEqual(recents.map(\.path), [recent.path])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.metadataFallback.path), [])
            await services.thumbnailCache.waitForPendingDiskWrites()
        }
    }

    func testHealthyDisposableFactoryUsesPrimaryPathsAndDoesNotCreateFallback() async throws {
        try await withPaths { root, paths in
            let services = ShrikeServices.makeDefault(storagePaths: paths)
            XCTAssertTrue(services.metadataStore.isPersistent)
            XCTAssertNil(services.metadataStore.openError)
            XCTAssertEqual(services.metadataStore.persistenceStatus.primaryURL, paths.metadata)
            let directory = await services.thumbnailCache.diskDirectory
            XCTAssertEqual(directory, paths.thumbnails)
            assertDescendant(directory, of: root)
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.metadata.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.metadataFallback.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.thumbnailFallback.path))
            await services.thumbnailCache.waitForPendingDiskWrites()
        }
    }
}

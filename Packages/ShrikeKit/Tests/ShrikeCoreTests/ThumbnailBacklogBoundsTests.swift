//
//  ThumbnailBacklogBoundsTests.swift
//  ShrikeCoreTests
//
//  Audit MP-14 (disk-write backlog bounded by bytes) and MP-15 (key memo
//  limit).
//

import XCTest
@testable import ShrikeCore

final class ThumbnailBacklogBoundsTests: XCTestCase {

    func testPendingWritesAreBoundedByBytesAsWellAsCount() async throws {
        let tmp = TempDir("thumb-backlog"); defer { tmp.cleanup() }
        let resources = ImageResourceBudget(configuration: .init(normalBudget: 1 << 30))
        let disk = ThumbnailDiskStore(root: tmp.url, resources: resources)
        disk.setWritesSuspendedForTesting(true)
        defer { disk.setWritesSuspendedForTesting(false) }
        let big = OrientedImageFixtures.quadrants(width: 1024, height: 1024)   // ~4 MB
        var accepted = 0
        for i in 0..<40 where disk.enqueueWrite(big, to: tmp.url.appendingPathComponent("w\(i).heic")) { accepted += 1 }
        let perImage = ThumbnailMemoryLRU.cost(of: big)
        XCTAssertGreaterThanOrEqual(accepted, 1)
        XCTAssertLessThanOrEqual(accepted * perImage, ThumbnailDiskStore.maxPendingBytes + perImage)
        XCTAssertLessThan(accepted, ThumbnailDiskStore.maxPendingWrites)
        disk.setWritesSuspendedForTesting(false)
        await disk.waitUntilIdle()
        // After the backlog drains, new writes are accepted again.
        XCTAssertTrue(disk.enqueueWrite(big, to: tmp.url.appendingPathComponent("again.heic")))
        await disk.waitUntilIdle()
    }

    func testKeyStemMemoStaysSmall() {
        let memo = KeyStemMemo()
        for i in 0..<25_000 {
            let source = FileImageSource(url: URL(fileURLWithPath: "/nonexistent/IMG_\(i).jpg"))
            memo.set("stem", for: KeyStemMemo.Key(source: source))
        }
        XCTAssertLessThanOrEqual(memo.count, 20_000)
    }
}

//
//  DecodeQueueWindowTests.swift
//  ShrikeCoreTests
//
//  Per-window queues and output decodes:
//  * one queue per window — two queues never share state;
//  * the cache is keyed by file, not index;
//  * results from a replaced list are dropped;
//  * evict(url:) forgets a file;
//  * jumping cancels decodes that left the window;
//  * the byte budget shrinks the window but never below ±1;
//  * the preparer runs for prefetched neighbours (GPU-ready);
//  * DecodeLane never runs work cancelled before it started.
//

import XCTest
import CoreGraphics
import os
@testable import ShrikeCore

private struct PreparedStub: PreparedDisplayImage {
    let byteCount: Int
}

final class DecodeQueueWindowTests: XCTestCase {

    private func sources(_ keys: Range<Int>, delayMS: Int = 0) -> [TestImageSource] {
        keys.map { TestImageSource(key: $0, decodeDelayMS: delayMS) }
    }

    /// Poll an async condition for up to `timeout` seconds.
    private func eventually(
        _ timeout: TimeInterval = 3,
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testTwoQueuesKeepTheirOwnListAndImage() async throws {
        let a = DecodeQueue()
        let b = DecodeQueue()
        let listA = sources(0..<3)
        let listB = sources(100..<103)
        await a.setNavigation(list: listA, currentIndex: 0)
        await b.setNavigation(list: listB, currentIndex: 0)

        let fromA = try await a.jumpToEntry(index: 1)
        _ = try await b.jumpToEntry(index: 1)
        let againA = try await a.jumpToEntry(index: 1)

        XCTAssertEqual(fromA.sourceID, listA[1].id)
        XCTAssertEqual(againA.sourceID, listA[1].id,
                       "window B's navigation must never change what window A shows")
    }

    func testCacheIsKeyedByFileNotIndex() async throws {
        let q = DecodeQueue()
        let list = sources(0..<3)
        await q.setNavigation(list: list, currentIndex: 0)
        _ = try await q.jumpToEntry(index: 1)

        // Same file at a different index in a new list: still a hit.
        let moved: [any ImageSource] = [list[1], TestImageSource(key: 50, decodeDelayMS: 0)]
        await q.setNavigation(list: moved, currentIndex: 0)
        let hit = await q.cachedEntry(at: 0)
        XCTAssertEqual(hit?.sourceID, list[1].id)

        // A different file at the old index is NOT served the old pixels.
        let other: [any ImageSource] = [list[0], TestImageSource(key: 77, decodeDelayMS: 200)]
        await q.setNavigation(list: other, currentIndex: 1)
        let wrong = await q.cachedEntry(at: 1)
        XCTAssertNil(wrong, "index 1 is a new file; the cache must not return file 1's image")
    }

    func testResultsFromReplacedListAreDropped() async throws {
        let q = DecodeQueue()
        let slow = sources(0..<3, delayMS: 250)
        await q.setNavigation(list: slow, currentIndex: 0)
        let fresh = sources(10..<13)
        await q.setNavigation(list: fresh, currentIndex: 0)

        try await Task.sleep(nanoseconds: 450_000_000)
        let cached = await q.cachedIDs()
        XCTAssertTrue(cached.isDisjoint(with: Set(slow.map(\.id))),
                      "stale decodes landed in the new list's cache: \(cached)")
        let landed = await eventually { await q.cachedIDs().contains(fresh[0].id) }
        XCTAssertTrue(landed)
    }

    func testEvictForgetsTheFile() async throws {
        let q = DecodeQueue()
        let list = sources(0..<2)
        await q.setNavigation(list: list, currentIndex: 0)
        _ = try await q.jumpToEntry(index: 0)
        let before = await q.cachedEntry(at: 0)
        XCTAssertNotNil(before)

        // TestImageSource ids are "test://N" URLs.
        await q.evict(url: URL(string: list[0].id)!)
        let after = await q.cachedEntry(at: 0)
        XCTAssertNil(after)
    }

    func testJumpCancelsDecodesThatLeftTheWindow() async throws {
        let q = DecodeQueue()
        let list = sources(0..<20, delayMS: 300)
        await q.setNavigation(list: list, currentIndex: 0)
        let early = await q.inFlightIDs()
        XCTAssertTrue(early.contains(list[0].id))

        Task { _ = try? await q.jumpToEntry(index: 15) }
        let moved = await eventually { await q.inFlightIDs().contains(list[15].id) }
        XCTAssertTrue(moved)
        let now = await q.inFlightIDs()
        XCTAssertFalse(now.contains(list[0].id), "old window decode was not cancelled: \(now)")
        XCTAssertFalse(now.contains(list[1].id))
    }

    func testByteBudgetShrinksWindowButKeepsDirectNeighbours() async throws {
        let q = DecodeQueue(windowRadius: 2, byteBudget: 1)
        let list = sources(0..<10)
        await q.setNavigation(list: list, currentIndex: 5)
        let wanted = await q.wantedIDs()
        XCTAssertEqual(wanted, Set([list[4].id, list[5].id, list[6].id]))

        let roomy = DecodeQueue(windowRadius: 2, byteBudget: 512 * 1_048_576)
        await roomy.setNavigation(list: list, currentIndex: 5)
        let wide = await roomy.wantedIDs()
        XCTAssertEqual(wide, Set((3...7).map { list[$0].id }))
    }

    func testPreparerRunsForPrefetchedNeighbours() async throws {
        let q = DecodeQueue(preparer: DisplayPreparer { img, _ in PreparedStub(byteCount: img.width * img.height * 4) })
        let list = sources(0..<4)
        await q.setNavigation(list: list, currentIndex: 0)
        let first = try await q.jumpToEntry(index: 0)
        XCTAssertNotNil(first.prepared)
        let ready = await eventually { await q.cachedEntry(at: 1)?.prepared != nil }
        XCTAssertTrue(ready, "the next image must be GPU-ready before the user presses the key")
    }

    func testLaneSkipsWorkCancelledBeforeItStarted() async throws {
        let lane = DecodeLane(width: 1, label: "test.lane")
        let ran = OSAllocatedUnfairLock(initialState: false)
        let blocker = Task {
            try await lane.run { Thread.sleep(forTimeInterval: 0.2); return 1 }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let victim = Task {
            try await lane.run { () -> Int in ran.withLock { $0 = true }; return 2 }
        }
        victim.cancel()
        _ = try await blocker.value
        do {
            _ = try await victim.value
            XCTFail("cancelled lane work must throw")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(ran.withLock { $0 }, "work cancelled before it got a slot must never run")
    }
}

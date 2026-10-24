//
//  FullResolutionDecodeTests.swift
//  ShrikeCoreTests
//
//  `DecodeQueue.loadFullResolution` / `FileImageSource.decodeFullResolution`
//  (zoom past the display texture) and `DecodeLane.runInterruptible`.
//

import XCTest
import CoreGraphics
import ImageIO
import os
@testable import ShrikeCore

final class FullResolutionDecodeTests: XCTestCase {

    private typealias F = OrientedImageFixtures

    func testUpright_fullSize_notCached() async throws {
        let tmp = TempDir("fullres-upright")
        defer { tmp.cleanup() }
        let urls = try (0..<3).map { i -> URL in
            let url = tmp.url.appendingPathComponent("u\(i).jpg")
            try F.write(F.quadrants(width: 3000, height: 2000), to: url)
            return url
        }
        let queue = DecodeQueue(windowRadius: 1)
        await queue.setMaxLongEdge(256)
        await queue.setNavigation(list: urls.map { FileImageSource(url: $0) }, currentIndex: 0)
        _ = try await queue.jumpToEntry(index: 0)
        let before = await queue.cachedEntry(at: 0)

        let full = try await queue.loadFullResolution(at: 0)
        XCTAssertEqual(full.image.width, 3000)
        XCTAssertEqual(full.image.height, 2000)
        XCTAssertFalse(full.imageIsLazy, "no preparer: the decoded image is returned")
        XCTAssertNil(full.requestedLongEdge)
        // The prefetch cache still holds the display-size entry.
        let after = await queue.cachedEntry(at: 0)
        XCTAssertEqual(after?.image.width, before?.image.width)
        XCTAssertLessThan(after?.image.width ?? .max, 3000)
    }

    func testAllEightOrientations_bothPaths_matchImageIOTransform() throws {
        let tmp = TempDir("fullres-orient")
        defer { tmp.cleanup() }
        let stored = F.quadrants(width: 240, height: 160)
        for orientation in UInt32(1)...8 {
            let url = tmp.url.appendingPathComponent("o\(orientation).jpg")
            try F.write(stored, to: url, orientation: orientation)
            let ref = try XCTUnwrap(F.imageIOOriented(url, maxPixelSize: 240))
            for path in [FileImageSource.FullResolutionPath.thumbnailTransform, .decodeThenDraw] {
                let out = try FileImageSource(url: url).decodeFullResolution(rotatedPath: path)
                XCTAssertEqual(out.width, ref.width, "orientation \(orientation) \(path)")
                XCTAssertEqual(out.height, ref.height, "orientation \(orientation) \(path)")
                for (fx, fy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let a = F.sample(out, fx, fy), b = F.sample(ref, fx, fy)
                    XCTAssertLessThan(a.distance(to: b), 24, "orientation \(orientation) \(path) at \(fx),\(fy)")
                }
            }
        }
    }

    func testRotated_sizeIsFileSizeAfterOrientation() async throws {
        let tmp = TempDir("fullres-rot")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("r.jpg")
        try F.write(F.quadrants(width: 3000, height: 2000), to: url, orientation: 6)
        let queue = DecodeQueue()
        await queue.setNavigation(list: [FileImageSource(url: url)], currentIndex: 0)
        let full = try await queue.loadFullResolution(at: 0)
        XCTAssertEqual(full.image.width, 2000)
        XCTAssertEqual(full.image.height, 3000)
    }

    private struct FakeTexture: PreparedDisplayImage {
        let width: Int, height: Int
        var byteCount: Int { width * height * 4 }
    }

    private final class LifetimeTexture: PreparedDisplayImage {
        let byteCount = 1
        let releases: OSAllocatedUnfairLock<Int>

        init(releases: OSAllocatedUnfairLock<Int>) { self.releases = releases }
        deinit { releases.withLock { $0 += 1 } }
    }

    func testFinishedFullResolution_doesNotRetainTextureAfterCallerReleasesIt() async throws {
        let tmp = TempDir("fullres-lifetime")
        defer { tmp.cleanup() }
        let url = tmp.url.appendingPathComponent("image.jpg")
        try F.write(F.quadrants(width: 240, height: 160), to: url)
        let releases = OSAllocatedUnfairLock(initialState: 0)
        let queue = DecodeQueue(preparer: DisplayPreparer { image, maxEdge in
            if maxEdge == nil { return LifetimeTexture(releases: releases) }
            return FakeTexture(width: image.width, height: image.height)
        })
        await queue.setNavigation(list: [FileImageSource(url: url)], currentIndex: 0)
        var entry: DecodedImage? = try await queue.loadFullResolution(at: 0)
        XCTAssertTrue(entry?.prepared is LifetimeTexture)
        XCTAssertEqual(releases.withLock { $0 }, 0, "the caller still owns the full-size texture")
        entry = nil
        let deadline = Date().addingTimeInterval(2)
        while releases.withLock({ $0 }) == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(releases.withLock { $0 }, 1,
                       "the live queue must not retain a completed full-resolution result")
        await queue.purge()
    }

    func testWithPreparer_uprightGetsLazyTwin_rotatedGetsOrientedTexture() async throws {
        let tmp = TempDir("fullres-prep")
        defer { tmp.cleanup() }
        let up = tmp.url.appendingPathComponent("up.jpg")
        let rot = tmp.url.appendingPathComponent("rot.jpg")
        try F.write(F.quadrants(width: 1200, height: 800), to: up)
        try F.write(F.quadrants(width: 1200, height: 800), to: rot, orientation: 8)
        let queue = DecodeQueue(preparer: DisplayPreparer { img, _ in
            FakeTexture(width: img.width, height: img.height)
        })
        await queue.setNavigation(list: [FileImageSource(url: up), FileImageSource(url: rot)], currentIndex: 0)

        let a = try await queue.loadFullResolution(at: 0)
        XCTAssertTrue(a.imageIsLazy)
        XCTAssertEqual((a.image.width, a.image.height).0, 1200)
        XCTAssertEqual((a.prepared as? FakeTexture)?.width, 1200)

        let b = try await queue.loadFullResolution(at: 1)
        XCTAssertFalse(b.imageIsLazy)
        XCTAssertEqual(b.image.width, 800)
        XCTAssertEqual(b.image.height, 1200)
        XCTAssertEqual((b.prepared as? FakeTexture)?.height, 1200)
        if let cached = await queue.cachedEntry(at: 1) {
            XCTAssertNotNil(cached.requestedLongEdge, "full resolution never enters the prefetch cache")
        }
    }

    func testOutOfRange_throws() async {
        let queue = DecodeQueue()
        do {
            _ = try await queue.loadFullResolution(at: 3)
            XCTFail("expected outOfRange")
        } catch DecodeQueueError.outOfRange {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Interruptible lane

    func testRunInterruptible_cancelStopsWaitingAtOnce_resultDropped() async throws {
        let lane = DecodeLane(width: 1, label: "test.interruptible")
        let started = OSAllocatedUnfairLockBox()
        let release = DispatchSemaphore(value: 0)
        let sawCancel = OSAllocatedUnfairLockBox()
        let task = Task {
            try await lane.runInterruptible { isCancelled -> Int in
                started.set(true)
                release.wait()          // "ImageIO" still busy
                sawCancel.set(isCancelled())
                return 42
            }
        }
        let startDeadline = Date().addingTimeInterval(30)
        while started.value == nil {
            guard Date() < startDeadline else { release.signal(); return XCTFail("the decode never started") }
            try await Task.sleep(for: .milliseconds(2))
        }
        task.cancel()
        let t0 = Date()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.5, "the waiter must not wait for the work")
        release.signal()
        // The work ends later; its result goes nowhere (no double resume).
        let deadline = Date().addingTimeInterval(2)
        while sawCancel.value == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(sawCancel.value, true)
    }

    func testRunInterruptible_cancelledBeforeSlot_neverRuns() async throws {
        let lane = DecodeLane(width: 1, label: "test.interruptible2")
        let release = DispatchSemaphore(value: 0)
        let ran = OSAllocatedUnfairLockBox()
        let blocker = Task { try await lane.runInterruptible { _ in release.wait(); return 0 } }
        try await Task.sleep(for: .milliseconds(20))
        let queued = Task { try await lane.runInterruptible { _ -> Int in ran.set(true); return 1 } }
        try await Task.sleep(for: .milliseconds(20))
        queued.cancel()
        do { _ = try await queued.value; XCTFail("expected CancellationError") } catch is CancellationError {}
        release.signal()
        _ = try await blocker.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(ran.value, "work cancelled before its slot must never run")
    }

    func testRunInterruptible_returnsValue() async throws {
        let lane = DecodeLane(width: 1, label: "test.interruptible3")
        let v = try await lane.runInterruptible { _ in 7 }
        XCTAssertEqual(v, 7)
    }

    func testNewerFullResolutionCall_cancelsOlder() async throws {
        let tmp = TempDir("fullres-newer")
        defer { tmp.cleanup() }
        let urls = try (0..<2).map { i -> URL in
            let url = tmp.url.appendingPathComponent("n\(i).jpg")
            try F.write(F.quadrants(width: 2400, height: 1600), to: url)
            return url
        }
        let queue = DecodeQueue()
        await queue.setNavigation(list: urls.map { FileImageSource(url: $0) }, currentIndex: 0)
        // Hold the full-res lane so the first request waits for its slot.
        let release = DispatchSemaphore(value: 0)
        let blocker = Task { try await DecodeLane.fullResolution.runInterruptible { _ in release.wait(); return 0 } }
        try await Task.sleep(for: .milliseconds(20))
        let first = Task { try await queue.loadFullResolution(at: 0) }
        try await Task.sleep(for: .milliseconds(20))
        let second = Task { try await queue.loadFullResolution(at: 1) }
        try await Task.sleep(for: .milliseconds(20))
        release.signal()
        _ = try await blocker.value
        do { _ = try await first.value; XCTFail("older request must be cancelled") } catch is CancellationError {}
        let img = try await second.value
        XCTAssertEqual(img.sourceID, FileImageSource(url: urls[1]).id)
    }

    func testOlderFullResolutionCompletion_preservesNewerCancellationHandle() async throws {
        let tmp = TempDir("fullres-handle")
        defer { tmp.cleanup() }
        let urls = try (0..<2).map { i -> URL in
            let url = tmp.url.appendingPathComponent("n\(i).jpg")
            try F.write(F.quadrants(width: 240 + i * 16, height: 160), to: url)
            return url
        }
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let queue = DecodeQueue(preparer: DisplayPreparer { image, maxEdge in
            if maxEdge == nil, image.width == 240 {
                started.withLock { $0 = true }
                release.wait()
            }
            return FakeTexture(width: image.width, height: image.height)
        })
        await queue.setNavigation(list: urls.map { FileImageSource(url: $0) }, currentIndex: 0)
        defer { release.signal() }
        let first = Task { try await queue.loadFullResolution(at: 0) }
        let startDeadline = Date().addingTimeInterval(30)
        while !started.withLock({ $0 }) {
            guard Date() < startDeadline else { return XCTFail("the first decode never started") }
            try await Task.sleep(for: .milliseconds(2))
        }
        let second = Task { try await queue.loadFullResolution(at: 1) }
        do { _ = try await first.value; XCTFail("the older request must be cancelled") }
        catch is CancellationError {}
        // The older request's cleanup has run while the newer work is
        // still blocked. Purge must retain the ability to cancel it.
        await queue.purge()
        release.signal()
        do { _ = try await second.value; XCTFail("purge must cancel the newer request") }
        catch is CancellationError {}
    }
}

/// Tiny thread-safe optional Bool for the lane tests.
private final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?
    func set(_ v: Bool) { lock.withLock { stored = v } }
    var value: Bool? { lock.withLock { stored } }
}

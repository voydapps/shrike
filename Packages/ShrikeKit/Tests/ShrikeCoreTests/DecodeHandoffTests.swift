//
//  DecodeHandoffTests.swift
//  ShrikeCoreTests
//
//  * a decode started before the viewer exists (cold open) is taken over
//    by the viewer's queue, once, and only when it is big enough;
//  * a background viewer keeps only its current photo, and gets its
//    neighbours back in the foreground;
//  * far neighbours come out of one budget shared by all windows.
//

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore

private struct PreparedBytes: PreparedDisplayImage {
    let byteCount: Int
}

/// A prepared image whose lifetime a test can watch.
private final class TrackedTexture: PreparedDisplayImage {
    let byteCount = 1
}

private final class WeakBox: @unchecked Sendable {
    weak var value: TrackedTexture?
}

final class DecodeHandoffTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func eventually(_ timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testClaimOnceAndOnlyWhenBigEnough() async throws {
        let url = try writeJPEG("a.jpg")
        let handoff = DecodeHandoff()
        handoff.start(url: url, targetLongEdge: 2048, preparer: nil)
        handoff.start(url: url, targetLongEdge: 4096, preparer: nil) // no-op: one waits already
        XCTAssertEqual(handoff.pendingCount, 1)
        XCTAssertNil(handoff.claim(url: url, target: 4096), "a decode made for less must not be used")
        let task = try XCTUnwrap(handoff.claim(url: url, target: 1024))
        XCTAssertNil(handoff.claim(url: url, target: 1024), "one claim per start")
        let entry = try await task.value
        XCTAssertEqual(entry.image.width, 64)
        XCTAssertEqual(entry.requestedLongEdge, 2048)
    }

    /// The new viewer can wait (bounded) for the early
    /// decode, even after its queue claimed the task; one take per start.
    func testWaitForFinishedReturnsTheEarlyDecodeOnce() async throws {
        let url = try writeJPEG("w.jpg")
        let handoff = DecodeHandoff()
        XCTAssertFalse(handoff.hasWaitableDecode(url: url))
        let t0 = DispatchTime.now()
        XCTAssertNil(handoff.waitForFinished(url: url, target: 1, deadline: .now() + .seconds(2)),
                     "nothing started: no wait")
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds, 500_000_000)
        handoff.start(url: url, targetLongEdge: 512, preparer: nil)
        XCTAssertTrue(handoff.hasWaitableDecode(url: url))
        _ = handoff.claim(url: url, target: 512)
        XCTAssertTrue(handoff.hasWaitableDecode(url: url), "a claim keeps the box for the viewer")
        let entry = await Task.detached {
            handoff.waitForFinished(url: url, target: 512, deadline: .now() + .seconds(5))
        }.value
        XCTAssertEqual(entry?.image.width, 64)
        XCTAssertFalse(handoff.hasWaitableDecode(url: url), "one take per start")
        XCTAssertEqual(handoff.waitableCount, 0)
    }

    func testWaitForFinishedRefusesASmallDecodeAndForgetDropsTheBox() throws {
        let a = try writeJPEG("small.jpg")
        let b = try writeJPEG("forget.jpg")
        let handoff = DecodeHandoff()
        handoff.start(url: a, targetLongEdge: 256, preparer: nil)
        XCTAssertNil(handoff.waitForFinished(url: a, target: 1024, deadline: .now() + .seconds(5)),
                     "made for less than the viewer needs")
        handoff.start(url: b, targetLongEdge: 256, preparer: nil)
        handoff.forgetFinished(url: b)
        XCTAssertFalse(handoff.hasWaitableDecode(url: b))
        XCTAssertEqual(handoff.waitableCount, 0)
    }

    /// Once claimed, the handoff keeps nothing.
    /// Its 15 s expiry timer used to hold the task, and with it the
    /// finished texture, long after the window had dropped it.
    func testClaimedDecodeIsFreedWhenTheClaimerDropsIt() async throws {
        let url = try writeJPEG("freed.jpg")
        let handoff = DecodeHandoff()
        let box = WeakBox()
        handoff.start(url: url, targetLongEdge: 256, preparer: DisplayPreparer { _, _ in
            let texture = TrackedTexture()
            box.value = texture
            return texture
        })
        var task = handoff.claim(url: url, target: 256)
        var entry: DecodedImage? = try await XCTUnwrap(task).value
        XCTAssertNotNil(entry?.prepared)
        XCTAssertNotNil(box.value, "alive while the claimer holds it")
        entry = nil
        task = nil
        XCTAssertNil(task)
        let freed = await eventually(2) { box.value == nil }
        XCTAssertTrue(freed, "nothing in the handoff may keep a claimed texture alive")
    }

    func testQueueTakesOverTheEarlyDecode() async throws {
        let url = try writeJPEG("b.jpg")
        let other = try writeJPEG("c.jpg")
        // The path form differs from the queue's URL: matched by path.
        let spelled = URL(fileURLWithPath: dir.path + "/./b.jpg")
        DecodeHandoff.shared.start(url: spelled, targetLongEdge: Prefs.maxDisplayLongEdge,
                                   preparer: DisplayPreparer { img, _ in PreparedBytes(byteCount: img.width * img.height * 4) })
        let q = DecodeQueue(preparer: DisplayPreparer { img, _ in PreparedBytes(byteCount: img.width * img.height * 4) })
        let list: [any ImageSource] = [FileImageSource(url: url), FileImageSource(url: other)]
        await q.setNavigation(list: list, currentIndex: 0)
        XCTAssertNil(DecodeHandoff.shared.claim(url: url, target: 1), "the queue must have claimed it")
        let entry = try await q.jumpToEntry(index: 0)
        XCTAssertEqual(entry.sourceID, list[0].id, "the entry carries the queue's own file id")
        XCTAssertNotNil(entry.prepared)
    }

    func testBackgroundKeepsOnlyTheCurrentPhoto() async throws {
        let list = (0..<7).map { TestImageSource(key: 500 + $0, decodeDelayMS: 0) }
        let q = DecodeQueue(windowRadius: 2)
        await q.setNavigation(list: list, currentIndex: 3)
        _ = try await q.jumpToEntry(index: 3)
        await q.setBackground(true)
        let wanted = await q.wantedIDs()
        XCTAssertEqual(wanted, [list[3].id])
        let onlyCurrent = await q.cachedIDs().isSubset(of: [list[3].id])
        XCTAssertTrue(onlyCurrent)
        let hit = await q.cachedEntry(at: 3)
        XCTAssertNotNil(hit, "the photo on screen stays cached")

        await q.setBackground(false)
        let back = await eventually {
            let ahead = await q.cachedEntry(at: 4)
            let behind = await q.cachedEntry(at: 2)
            return ahead != nil && behind != nil
        }
        XCTAssertTrue(back, "neighbours come back in the foreground")
    }

    func testFarNeighboursShareOneBudgetAcrossWindows() async throws {
        let ledger = DecodeMemoryLedger()
        let list = (0..<9).map { TestImageSource(key: 600 + $0, decodeDelayMS: 0) }
        let budget = 512 * 1_048_576
        let a = DecodeQueue(windowRadius: 2, ledger: ledger, sharedByteBudget: budget)
        await a.setNavigation(list: list, currentIndex: 4)
        let wide = await a.wantedIDs()
        XCTAssertEqual(wide.count, 5, "alone, a window gets its far neighbours")

        // Another window already holds the whole shared budget.
        let hog = DecodeQueue(windowRadius: 2, ledger: ledger, sharedByteBudget: budget)
        ledger.set(ObjectIdentifier(hog), bytes: budget)
        await a.setNavigation(list: list, currentIndex: 4)
        let narrow = await a.wantedIDs()
        XCTAssertEqual(narrow, Set((3...5).map { list[$0].id }),
                       "over the shared budget: current and direct neighbours only")
    }
}

//
//  StandInRulesTests.swift
//  ShrikeUITests
//
//  No visible low-res flash on cached or fast images.
//  * A prefetched (cached) neighbour paints once — the full image — with
//    no embedded preview or thumbnail stand-in before it.
//  * Embedded previews under 1/4 of the window's long edge are skipped.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore

@MainActor
final class StandInRulesTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() async throws {
        // The fixture files are written just before the window opens; their
        // file-system events arrive later (late under load) and make the
        // watcher redraw the shown photo, a second paint of the same file.
        ViewerWindow.watchFoldersForTesting = false
        tempDir = TestScratch.directory
            .appendingPathComponent("shrike-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ViewerWindow.watchFoldersForTesting = true
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeJPEG(_ name: String, gray: CGFloat) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: 1200, height: 800, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(CGColor(gray: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        let url = tempDir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await cond()
    }

    func testCachedNeighbourPaintsOnceWithoutStandIn() async throws {
        let a = FileImageSource(url: try writeJPEG("a.jpg", gray: 0.2))
        let b = FileImageSource(url: try writeJPEG("b.jpg", gray: 0.7))
        let window = ViewerWindow(imageSources: [a, b], startIndex: 0, services: .makeDefault())
        defer { window.close() }
        let view = window.imageViewForTesting

        let shownA = await waitUntil { view.sourceID == a.id && !view.isCurrentImagePlaceholder && view.image != nil }
        XCTAssertTrue(shownA)
        let nav = window.navigationForTesting
        let prefetched = await waitUntil { await nav.cachedEntry(at: 1)?.prepared != nil }
        XCTAssertTrue(prefetched, "the next photo must be decoded and GPU-ready before the key press")

        view.recordsImageAssignmentsForTesting = true
        view.imageAssignmentLogForTesting = []
        let refetchesBefore = window.textureRefetchCount
        let uploadsBefore = view.mainThreadUploadCountForTesting
        await window.navigate(to: 1)
        let shownB = await waitUntil { view.sourceID == b.id && view.image != nil }
        XCTAssertTrue(shownB)
        // Give any stray stand-in task time to (wrongly) land.
        try await Task.sleep(nanoseconds: 300_000_000)

        let log = view.imageAssignmentLogForTesting
        XCTAssertEqual(log.count, 1, "a cached neighbour must paint once, with no stand-in first: \(log.map { ($0.sourceID ?? "nil", "placeholder=\($0.isPlaceholder)", "resolutionSwap=\($0.isResolutionSwap)") }); texture refetches during the test: \(window.textureRefetchCount - refetchesBefore); assigned from:\n\(log.map { $0.callStack.joined(separator: "\n") }.joined(separator: "\n--\n"))")
        XCTAssertEqual(log.first?.sourceID, b.id)
        XCTAssertFalse(view.isCurrentImagePlaceholder)
        XCTAssertEqual(view.mainThreadUploadCountForTesting, uploadsBefore,
                       "the prefetched texture must be used; no main-thread upload")
    }

    func testTinyEmbeddedPreviewThreshold() {
        // 1200 pt window on a 2x screen = 2400 px → previews under 600 px are skipped.
        XCTAssertEqual(ViewerWindow.minEmbeddedPreviewLongEdge(windowLongEdgePixels: 2400), 600)
        XCTAssertEqual(ViewerWindow.fastDecodeThreshold, 0.040, accuracy: 0.0001)
    }
}

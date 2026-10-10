//
//  ViewerFilmstripMarksTests.swift
//  ShrikeUITests
//
//  Rating and flag set in the viewer reach the filmstrip cell at
//  once (stars bottom-left 8 pt, flag top-left 9 pt).
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerFilmstripMarksTests: XCTestCase {

    private var dir: URL!
    private var savedFilmstrip = true

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-marks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedFilmstrip = Prefs.filmstripVisibleInWindowed
        Prefs.filmstripVisibleInWindowed = true
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.filmstripVisibleInWindowed = savedFilmstrip
    }

    private func services() throws -> ShrikeServices {
        let support = dir.appendingPathComponent(".support", isDirectory: true)
        let thumbs = try ThumbnailCache(diskURL: support.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: support.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func writeJPEG(_ name: String) throws -> URL {
        let folder = dir.appendingPathComponent("a", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let url = folder.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return cond()
    }

    func testRatingAndFlagReachTheFilmstripCellAtOnce() async throws {
        let urls = try (0..<3).map { try writeJPEG("p\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 0, services: try services())
        defer { window.close() }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let root = window.contentRootForTesting
        let ready = await waitUntil { window.displayedItem?.listIndex == 0 && root.filmstripMarksForTesting(0) != nil }
        XCTAssertTrue(ready, "the filmstrip never built its cells")
        let start = try XCTUnwrap(root.filmstripMarksForTesting(0))
        XCTAssertFalse(start.flagDrawn)
        XCTAssertFalse(start.starsDrawn)

        window.dispatch(.toggleFlag)
        let flagged = await waitUntil { root.filmstripMarksForTesting(0)?.flagDrawn == true }
        XCTAssertTrue(flagged, "the flag is drawn on the filmstrip cell")

        window.dispatch(.rate(3))
        let rated = await waitUntil { root.filmstripMarksForTesting(0)?.starsDrawn == true }
        XCTAssertTrue(rated, "the stars are drawn on the filmstrip cell")
        let marks = try XCTUnwrap(root.filmstripMarksForTesting(0))
        XCTAssertEqual(marks.rating, 3)
        XCTAssertTrue(marks.flagDrawn, "rating keeps the flag")

        window.dispatch(.toggleFlag)
        let cleared = await waitUntil { root.filmstripMarksForTesting(0)?.flagDrawn == false }
        XCTAssertTrue(cleared, "unflag removes the flag from the cell")
        XCTAssertEqual(root.filmstripMarksForTesting(1)?.flagged, false, "other cells are untouched")
    }

    // MARK: A slow batched read never undoes a rating

    /// Holds a read in flight until the test opens it.
    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var arrivals = 0
        func wait() async {
            arrivals += 1
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func waitForGate(_ gate: Gate) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if await gate.arrivals > 0 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    /// The badge read (Finder tags, backups) is slow; a rating given
    /// meanwhile must survive when the read lands.
    func testARatingDuringASlowBadgeReadSurvives() async throws {
        let urls = try (0..<3).map { try writeJPEG("s\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 0, services: try services())
        defer { window.close() }
        let gate = Gate()
        let landed = Gate()
        window.badgeExtrasReaderForTesting = { listed in
            await gate.wait()
            await landed.wait()
            return [listed[0]: FileBadgeExtras(tags: [], edited: true)]
        }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let root = window.contentRootForTesting
        let inFlight = await waitForGate(gate)
        XCTAssertTrue(inFlight, "the badge read started")
        let ready = await waitUntil { window.displayedItem?.listIndex == 0 && root.filmstripMarksForTesting(0) != nil }
        XCTAssertTrue(ready)

        window.dispatch(.rate(3))
        let rated = await waitUntil { root.filmstripMarksForTesting(0)?.starsDrawn == true }
        XCTAssertTrue(rated)

        await landed.open()
        await gate.open()
        let primary = try XCTUnwrap(window.displayedItem?.group.primary)
        let done = await waitUntil { window.fileBadges[primary]?.edited == true }
        XCTAssertTrue(done, "the read landed")
        XCTAssertEqual(window.cullingRecords[primary]?.rating, 3, "the late read keeps the rating")
        XCTAssertEqual(root.filmstripMarksForTesting(0)?.rating, 3)
    }

    /// The records read itself is late (a busy store): a flag and a
    /// rating written meanwhile are newer and must win.
    func testWritesDuringASlowRecordsReadSurvive() async throws {
        let urls = try (0..<3).map { try writeJPEG("r\($0).jpg") }
        let window = ViewerWindow(imageSources: urls.map { FileImageSource(url: $0) },
                                  startIndex: 0, services: try services())
        defer { window.close() }
        let gate = Gate()
        let landed = Gate()
        window.cullingReadGateForTesting = { await gate.wait() }
        window.badgeExtrasReaderForTesting = { listed in
            await landed.wait()
            return [listed[0]: FileBadgeExtras(tags: [], edited: true)]
        }
        window.setContentSize(NSSize(width: 900, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let root = window.contentRootForTesting
        let inFlight = await waitForGate(gate)
        XCTAssertTrue(inFlight, "the records read started")
        let ready = await waitUntil { window.displayedItem?.listIndex == 0 && root.filmstripMarksForTesting(0) != nil }
        XCTAssertTrue(ready)

        window.dispatch(.toggleFlag)
        window.dispatch(.rate(3))
        let marked = await waitUntil {
            root.filmstripMarksForTesting(0)?.starsDrawn == true && root.filmstripMarksForTesting(0)?.flagDrawn == true
        }
        XCTAssertTrue(marked)

        await landed.open()
        await gate.open()
        let primary = try XCTUnwrap(window.displayedItem?.group.primary)
        let done = await waitUntil { window.fileBadges[primary]?.edited == true }
        XCTAssertTrue(done, "the read landed")
        XCTAssertEqual(window.cullingRecords[primary]?.rating, 3, "the older read does not undo the rating")
        XCTAssertEqual(window.cullingRecords[primary]?.flagged, true, "nor the flag")
        let marks = try XCTUnwrap(root.filmstripMarksForTesting(0))
        XCTAssertEqual(marks.rating, 3)
        XCTAssertTrue(marks.flagDrawn)
    }

    func testLateReadGuardKeepsOnlyNewerWrites() {
        let a = URL(fileURLWithPath: "/tmp/a.jpg"), b = URL(fileURLWithPath: "/tmp/b.jpg")
        var guardState = LateReadGuard()
        guardState.noteWrite([b])            // before the read: the read has it
        let token = guardState.begin()
        guardState.noteWrite([a])            // during the read: newer
        let merged = guardState.merge(read: [a: 1, b: 2], current: [a: 9, b: 7], since: token)
        XCTAssertEqual(merged[a], 9, "written during the read: keep")
        XCTAssertEqual(merged[b], 2, "written before the read: the read wins")
    }
}

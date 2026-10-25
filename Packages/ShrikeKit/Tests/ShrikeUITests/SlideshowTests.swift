//
//  SlideshowTests.swift
//  ShrikeUITests
//
//  Play order, loop, random, the key
//  table (incl. the FastStone ⌫ rule), prefs, rating and flag through
//  CullingUndo, the timer running through every image, the end toast
//  and where the origin lands. Headless (no window), temp folders and a
//  temp database only.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
import ShrikeCore

@MainActor
private final class FakeOrigin: SlideshowOrigin {
    let undo = UndoManager()
    var ended: (group: ImageGroup?, finished: Bool)?
    var cullingChanges = 0
    var slideshowUndoManager: UndoManager? { undo }
    func slideshowDidChangeCulling(_ values: [URL: FileRecord]) { cullingChanges += 1 }
    func slideshowDidEnd(lastShown: ImageGroup?, finished: Bool) { ended = (lastShown, finished) }
}

@MainActor
final class SlideshowTests: XCTestCase {

    private var tempDir: URL!
    private var savedSettings = SlideshowSettings()

    override func setUp() async throws {
        tempDir = TestScratch.directory
            .appendingPathComponent("shrike-slideshow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        savedSettings = SlideshowSettings.fromPrefs()
    }

    override func tearDown() async throws {
        savedSettings.save()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func services() throws -> ShrikeServices {
        let thumbs = try ThumbnailCache(diskURL: tempDir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(
            primary: tempDir.appendingPathComponent("meta.sqlite"), fallback: nil)
        return ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
    }

    private func groups(_ n: Int) throws -> [ImageGroup] {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        return try (0..<n).map { i in
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(gray: CGFloat(i) / CGFloat(n), alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let url = tempDir.appendingPathComponent(String(format: "S%02d.jpg", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            _ = try url.checkResourceIsReachable()
            return ImageGroup(primary: url, companions: [])
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ cond: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await cond()
    }

    // MARK: Order

    func testInOrderPlaylistStopsAtTheEndWithoutLoop() {
        var p = SlideshowPlaylist(count: 3, start: 1, random: false, loop: false)
        XCTAssertEqual(p.current, 1)
        XCTAssertTrue(p.next()); XCTAssertEqual(p.current, 2)
        XCTAssertFalse(p.next()); XCTAssertEqual(p.current, 2)
        p.first(); XCTAssertEqual(p.current, 0)
        XCTAssertFalse(p.previous())
        p.last(); XCTAssertEqual(p.current, 2)
        p.loop = true
        XCTAssertTrue(p.next()); XCTAssertEqual(p.current, 0)
        XCTAssertTrue(p.previous()); XCTAssertEqual(p.current, 2)
    }

    func testRandomKeepsTheCurrentImageFirstAndPlaysEachOnce() {
        var p = SlideshowPlaylist(count: 20, start: 7, random: true, loop: false)
        XCTAssertEqual(p.current, 7)
        XCTAssertEqual(p.order.sorted(), Array(0..<20))
        p.next(); p.next()
        let shown = p.current!
        p.setRandom(false)
        XCTAssertEqual(p.order, Array(0..<20))
        XCTAssertEqual(p.current, shown, "random off continues from the image on screen")
        p.setRandom(true)
        XCTAssertEqual(p.current, shown)
        XCTAssertEqual(p.position, 0)
    }

    // MARK: Keys

    func testKeyTable() {
        func a(_ code: UInt16, _ ch: String? = nil, _ mods: NSEvent.ModifierFlags = [], fs: Bool = false)
            -> SlideshowKeyAction? {
            SlideshowKeyAction.action(keyCode: code, characters: ch, modifiers: mods, fastStone: fs)
        }
        XCTAssertEqual(a(49, " "), .togglePause)
        XCTAssertEqual(a(124), .next)
        XCTAssertEqual(a(123), .previous)
        XCTAssertEqual(a(115), .first)
        XCTAssertEqual(a(119), .last)
        XCTAssertEqual(a(126), .intervalUp)
        XCTAssertEqual(a(125), .intervalDown)
        for n in 0...5 { XCTAssertEqual(a(0, "\(n)"), .rate(n)); XCTAssertEqual(a(0, "\(n)", fs: true), .rate(n)) }
        XCTAssertEqual(a(12, "q"), .toggleFlag)
        XCTAssertEqual(a(42, "\\"), .toggleFlag)
        XCTAssertEqual(a(15, "r"), .toggleRandom)
        XCTAssertEqual(a(37, "l"), .toggleLoop)
        XCTAssertEqual(a(53), .exit)
        XCTAssertEqual(a(3, "f"), .exit)
        XCTAssertEqual(a(51, fs: true), .previous, "FastStone: ⌫ is previous")
        XCTAssertNil(a(51), "Mac: ⌫ does nothing (no trashing during a show)")
        XCTAssertNil(a(51, nil, .command), "⌘⌫ never trashes in a show")
        XCTAssertNil(a(0, "6"))
        XCTAssertNil(a(0, "4", .command))
    }

    func testTransitionsAndReduceMotion() {
        XCTAssertEqual(SlideshowTransition.cut.duration, 0)
        XCTAssertEqual(SlideshowTransition.fade.duration, 0.32)
        XCTAssertEqual(SlideshowTransition.dissolve.duration, 0.48)
        XCTAssertEqual(SlideshowTransition.dissolve.effective(reduceMotion: true), .fade)
        XCTAssertEqual(SlideshowTransition.dissolve.effective(reduceMotion: false), .dissolve)
    }

    func testPrefsRoundTripAndClamp() {
        SlideshowSettings(intervalSec: 9, transition: .dissolve, random: true, fill: true, loop: false).save()
        XCTAssertEqual(SlideshowSettings.fromPrefs(),
                       SlideshowSettings(intervalSec: 9, transition: .dissolve, random: true, fill: true, loop: false))
        Prefs.slideshowIntervalSec = 500
        XCTAssertEqual(Prefs.slideshowIntervalSec, 60)
        Prefs.slideshowTransition = "wipe"
        XCTAssertEqual(Prefs.slideshowTransition, "fade")
    }

    func testScopeTitles() {
        let s = SlideshowScope(allCount: 180, folderName: "Italy 2026", selectedCount: 12)
        XCTAssertEqual(s.allTitle, "All 180 visible photos in “Italy 2026”")
        XCTAssertEqual(s.selectedTitle, "12 selected photos")
        XCTAssertTrue(s.offersSelection)
        let one = SlideshowScope(allCount: 5, folderName: "x", selectedCount: 1)
        XCTAssertEqual(one.allTitle, "All 5 visible photos in “x”")
        XCTAssertEqual(one.selectedTitle, "1 selected photo")
        XCTAssertTrue(one.offersSelection, "offered from 1")
        XCTAssertFalse(one.defaultsToSelection, "but not the default")
        XCTAssertTrue(s.defaultsToSelection)
        XCTAssertFalse(SlideshowScope(allCount: 5, folderName: "x", selectedCount: 0).offersSelection)
        let only = SlideshowScope(allCount: 1, folderName: "F", selectedCount: 1)
        XCTAssertEqual(only.allTitle, "All 1 visible photo in “F”")
        XCTAssertEqual(only.selectedTitle, "1 selected photo")
        let empty = SlideshowScope(allCount: 0, folderName: "F", selectedCount: 0)
        XCTAssertEqual(empty.allTitle, "All 0 visible photos in “F”")
        XCTAssertEqual(empty.selectedTitle, "0 selected photos")
        let two = SlideshowScope(allCount: 2, folderName: "F", selectedCount: 2)
        XCTAssertEqual(two.allTitle, "All 2 visible photos in “F”")
        XCTAssertEqual(two.selectedTitle, "2 selected photos")
    }

    // MARK: Rating in a show reaches the store

    func testPressing4RatesTheShownImage() async throws {
        let services = try services()
        let list = try groups(3)
        let origin = FakeOrigin()
        let show = SlideshowController(groups: list, start: 1, settings: SlideshowSettings(intervalSec: 60),
                                       services: services, origin: origin, presentsOnScreen: false)
        show.start(on: nil)
        let shown = await waitUntil { show.shownIndex == 1 }
        XCTAssertTrue(shown)
        show.handle(.rate(4))
        let rated = await waitUntil {
            await services.metadataStore.records(for: [list[1].primary])[list[1].primary]?.rating == 4
        }
        XCTAssertTrue(rated)
        await CullingUndo.waitForPendingWrites()
        XCTAssertEqual(show.toastsForTesting.last, "Rated 4 stars")
        XCTAssertEqual(origin.undo.undoActionName, "Rating")
        show.handle(.rate(0))
        await CullingUndo.waitForPendingWrites()
        let clearedRating = await services.metadataStore.records(for: [list[1].primary])[list[1].primary]?.rating
        XCTAssertEqual(clearedRating, 0)
        XCTAssertEqual(show.toastsForTesting.last, "Rating cleared")
        show.handle(.toggleFlag)
        let flagged = await waitUntil {
            await services.metadataStore.records(for: [list[1].primary])[list[1].primary]?.flagged == true
        }
        XCTAssertTrue(flagged)
        XCTAssertEqual(show.toastsForTesting.last, "Flagged")
        show.handle(.exit)
        XCTAssertEqual(origin.ended?.group, list[1])
        XCTAssertEqual(origin.ended?.finished, false)
    }

    // MARK: Every image in turn, then the end

    func testTimerShowsEveryImageAndLoopOffEndsWithFinished() async throws {
        let services = try services()
        let list = try groups(10)
        let origin = FakeOrigin()
        let show = SlideshowController(
            groups: list, start: 0,
            settings: SlideshowSettings(intervalSec: 1, transition: .fade, random: false, fill: false, loop: false),
            services: services, origin: origin, presentsOnScreen: false)
        show.intervalOverrideForTesting = 0.03
        show.start(on: nil)
        let ended = await waitUntil(10) { origin.ended != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(show.shownHistory, Array(0..<10), "no image skipped")
        XCTAssertEqual(origin.ended?.group, list[9])
        XCTAssertEqual(origin.ended?.finished, true)
        XCTAssertNil(SlideshowController.active)
    }

    func testEscLandsOnTheLastImageShownAndKeysMoveTheShow() async throws {
        let services = try services()
        let list = try groups(5)
        let origin = FakeOrigin()
        let show = SlideshowController(groups: list, start: 0, settings: SlideshowSettings(intervalSec: 60),
                                       services: services, origin: origin, presentsOnScreen: false)
        show.start(on: nil)
        _ = await waitUntil { show.shownIndex == 0 }
        show.handle(.last)
        _ = await waitUntil { show.shownIndex == 4 }
        show.handle(.previous)
        _ = await waitUntil { show.shownIndex == 3 }
        show.handle(.intervalUp)
        XCTAssertEqual(show.settings.intervalSec, 60, "clamped at 60")
        show.handle(.intervalDown)
        XCTAssertEqual(show.toastsForTesting.last, "59 s per photo")
        show.handle(.togglePause)
        XCTAssertTrue(show.isPaused)
        show.handle(.toggleLoop)
        XCTAssertEqual(show.toastsForTesting.last, "Loop off")
        show.handle(.toggleRandom)
        XCTAssertEqual(show.toastsForTesting.last, "Random order on")
        XCTAssertEqual(show.playlist.current, 3)
        show.handle(.exit)
        XCTAssertEqual(origin.ended?.group, list[3])
        XCTAssertEqual(origin.ended?.finished, false)
    }
}

/// COR-6: the first dissolve's end must not take away the second dissolve's mask.
@MainActor
final class DissolveMaskTests: XCTestCase {
    func testOnlyTheOwnMaskIsRemoved() {
        let layer = CALayer()
        let first = CALayer(), second = CALayer()
        layer.mask = first
        layer.mask = second            // a second present replaced it
        SlideshowController.removeDissolveMask(first, from: layer)
        XCTAssertTrue(layer.mask === second, "the newer dissolve keeps its mask")
        SlideshowController.removeDissolveMask(second, from: layer)
        XCTAssertNil(layer.mask)
    }
}

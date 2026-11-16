//
//  BrowserFollowsViewerTests.swift
//  ShrikeUITests
//
//  Spec 28 §14 (pass 2l): the paired Browser selects the viewer's shown
//  photo 150 ms after the last change, without coming forward.
//

import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class TrailingDebouncerTests: XCTestCase {
    func testOnlyTheLastCallRunsAfterTheDelay() {
        var pending: [(TimeInterval, @MainActor @Sendable () -> Void, Bool)] = []
        var cancelled = 0
        let debouncer = TrailingDebouncer(delay: 0.15) { delay, fire in
            pending.append((delay, fire, false))
            return { cancelled += 1 }
        }
        var ran: [Int] = []
        for n in 1...5 { debouncer.call { ran.append(n) } }
        XCTAssertEqual(pending.count, 5)
        XCTAssertEqual(cancelled, 4, "each call cancels the one before")
        XCTAssertTrue(pending.allSatisfy { $0.0 == 0.15 })
        // Even if a cancelled timer fires anyway, only the last call runs.
        for entry in pending { entry.1() }
        XCTAssertEqual(ran, [5])
        XCTAssertFalse(debouncer.isPending)
        debouncer.call { ran.append(6) }
        debouncer.cancel()
        pending.last?.1()
        XCTAssertEqual(ran, [5], "cancel drops the pending call")
    }
}

@MainActor
final class BrowserFollowsViewerTests: XCTestCase {
    private var dir: URL!
    private var savedSchedule: TrailingDebouncer.Schedule!
    private var savedForward: (@MainActor (NSWindow) -> Void)!
    private var fires: [@MainActor @Sendable () -> Void] = []

    override func setUp() async throws {
        dir = TestScratch.directory.appendingPathComponent("shrike-follow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedSchedule = ViewerWindow.browserFollowSchedule
        savedForward = ViewerWindow.bringBrowserForward
        ViewerWindow.browserFollowSchedule = { [weak self] _, fire in
            self?.fires.append(fire)
            return {}
        }
    }

    override func tearDown() async throws {
        ViewerWindow.browserFollowSchedule = savedSchedule
        ViewerWindow.bringBrowserForward = savedForward
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String) throws {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testBrowserSelectsTheShownPhotoAfterTheLastChangeOnly() async throws {
        let names = ["a.jpg", "b.jpg", "c.jpg", "d.jpg"]
        for name in names { try writeJPEG(name) }
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.window?.close() }
        let listed = await waitUntil { browser.contentController.visibleItems.count == names.count }
        XCTAssertTrue(listed)
        let urls = names.map { dir.appendingPathComponent($0) }
        // A multi-selection in the Browser.
        browser.contentController.select(urls: [urls[0], urls[1]])
        XCTAssertEqual(browser.contentController.selectedItems.count, 2)
        var forwarded = 0
        ViewerWindow.bringBrowserForward = { _ in forwarded += 1 }
        let viewer = ViewerWindow(groups: urls.map { ImageGroup(primary: $0) }, startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { viewer.close() }
        viewer.pair(with: browser)
        // Holding an arrow key: four changes, one scheduled call each.
        for index in [1, 2, 3, 2] { viewer.markDisplayedForTesting(index) }
        XCTAssertEqual(fires.count, 4)
        XCTAssertEqual(browser.contentController.selectedItems.count, 2, "nothing before the delay")
        for fire in fires { fire() }
        let selected = browser.contentController.selectedItems.map { $0.url.lastPathComponent }
        XCTAssertEqual(selected, ["c.jpg"], "the last shown photo replaces the multi-selection")
        XCTAssertEqual(forwarded, 0, "the Browser is not brought forward")
        // Another folder in the Browser: no change.
        fires.removeAll()
        browser.currentFolder = dir.deletingLastPathComponent()
        viewer.markDisplayedForTesting(0)
        for fire in fires { fire() }
        XCTAssertEqual(browser.contentController.selectedItems.map { $0.url.lastPathComponent }, ["c.jpg"])
    }
}

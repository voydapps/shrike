//
//  ViewerRedrawCoalescingTests.swift
//  ShrikeUITests
//
//  (launch speed): `needsDisplay` used to draw a whole Metal frame
//  at once, every time. Building a viewer set it about 20 times, each a
//  blocking ~8 ms frame. Now requests in one run-loop turn make one frame.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerRedrawCoalescingTests: XCTestCase {

    private func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testManyRequestsInOneTurnDrawOneFrame() {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        spin()
        let requests = view.redrawCountForTesting
        let frames = view.framesDrawnForTesting
        for _ in 0..<20 { view.needsDisplay = true }
        XCTAssertGreaterThanOrEqual(view.redrawCountForTesting, requests + 20, "every request is counted")
        XCTAssertEqual(view.framesDrawnForTesting, frames, "no frame is drawn inside the caller")
        spin()
        XCTAssertEqual(view.framesDrawnForTesting, frames + 1, "one frame for the whole turn")
    }

    func testBuildingAViewerDrawsAtMostOneFrameBeforeTheRunLoopTurns() throws {
        let dir = TestScratch.directory
            .appendingPathComponent("shrike-redraw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.jpg")
        let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let thumbs = try ThumbnailCache(diskURL: dir.appendingPathComponent("thumbs", isDirectory: true))
        let meta = MetadataStore.openWithFallback(primary: dir.appendingPathComponent("m.sqlite"), fallback: nil)
        let services = ShrikeServices(thumbnailCache: thumbs, metadataStore: meta)
        // Warm-up so the timing below is not the first-ever AppKit / Metal use.
        ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services).close()
        spin()

        let start = CFAbsoluteTimeGetCurrent()
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        let initMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        defer { viewer.close() }
        let view = viewer.imageViewForTesting
        let framesInInit = view.framesDrawnForTesting
        print("[redraw] ViewerWindow.init \(String(format: "%.1f", initMs)) ms, "
              + "\(view.redrawCountForTesting) redraw requests, \(framesInInit) frames drawn inside init")
        XCTAssertEqual(framesInInit, 0, "init only asks; the frame comes with the run loop")
        spin()
        // The first layout now happens in the run loop, not
        // inside init, and draws its own frame (the photo lands a turn
        // later offscreen; on a real open 1.1 puts both in one turn).
        XCTAssertLessThanOrEqual(view.framesDrawnForTesting, 3)
    }
}

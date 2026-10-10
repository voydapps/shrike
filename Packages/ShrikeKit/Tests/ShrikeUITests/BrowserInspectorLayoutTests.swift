//
//  BrowserInspectorLayoutTests.swift
//  ShrikeUITests
//
//  With a big photo selected, the Browser inspector keeps its
//  width (280 pt, 240–360), the preview fits its box, the
//  rows stay inside the pane, and the pane starts below the toolbar.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserInspectorLayoutTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-inspector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) throws -> URL {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = dir.appendingPathComponent(name)
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }

    // The click's main-thread turn (status bar + inspector update + the
    // layout it causes) stays under one frame with an 18 MP JPEG
    // selected, so the selection ring draws in the next frame.
    func testSelectionHandlerStaysUnderOneFrame() async throws {
        _ = try writeJPEG("A.JPG", width: 5184, height: 3888)
        _ = try writeJPEG("B.JPG", width: 5184, height: 3888)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let deadline = Date().addingTimeInterval(5)
        while browser.contentController.visibleItems.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let items = browser.contentController.visibleItems
        XCTAssertEqual(items.count, 2)
        // Warm-up (first SwiftUI build of the pane).
        browser.browserContentDidSelect([items[1]])
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        var times: [Double] = []
        for run in 0..<10 {
            let item = items[run % 2]
            let t0 = CACurrentMediaTime()
            browser.browserContentDidSelect([item])
            window.contentView?.layoutSubtreeIfNeeded()
            times.append((CACurrentMediaTime() - t0) * 1000)
            // Let the off-main reads land between clicks, like a user.
            try await Task.sleep(for: .milliseconds(30))
        }
        let sorted = times.sorted()
        let median = (sorted[4] + sorted[5]) / 2
        print(String(format: "browserSelectionChange median %.2f ms, max %.2f ms", median, sorted.last!))
        XCTAssertLessThan(median, 16, "the selection handler stays under one frame")
    }

    func testBigPhotoFitsThePreviewBoxAndRowsStayInsideThePane() async throws {
        _ = try writeJPEG("P1250300.JPG", width: 5184, height: 3888)
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let deadline = Date().addingTimeInterval(5)
        while browser.contentController.visibleItems.count < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.contentController.selectAll()
        let pane = browser.inspectorForTesting.view
        var preview: InspectorPreviewImageView?
        let found = Date().addingTimeInterval(5)
        while preview == nil, Date() < found {
            window.contentView?.layoutSubtreeIfNeeded()
            preview = find(InspectorPreviewImageView.self, in: pane)
            if preview == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let image = try XCTUnwrap(preview, "the preview never showed")
        await image.waitForLoad()
        XCTAssertNotNil(image.image, "the thumbnail loaded")
        let px = image.image.map { max($0.size.width, $0.size.height) } ?? 0
        XCTAssertLessThanOrEqual(px, CGFloat(InspectorPreviewImageView.maxPixelSize), "a thumbnail, not the full photo")
        window.contentView?.layoutSubtreeIfNeeded()

        // The pane keeps the split's width.
        let paneWidth = pane.frame.width
        XCTAssertGreaterThanOrEqual(paneWidth, 239)
        XCTAssertLessThanOrEqual(paneWidth, 361)
        // No intrinsic size: the photo never asks for its pixel width.
        XCTAssertEqual(image.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        let host = try XCTUnwrap(browser.inspectorForTesting.hostViewForTesting)
        XCTAssertLessThanOrEqual(host.fittingSize.width, paneWidth + 0.5, "the rows fit the pane")
        XCTAssertEqual(host.frame.width, pane.bounds.width, accuracy: 0.5)
        // The preview sits inside the pane, in its 180 pt box.
        let paneRect = pane.convert(pane.bounds, to: nil)
        let imageRect = image.convert(image.bounds, to: nil)
        XCTAssertTrue(paneRect.insetBy(dx: -0.5, dy: -0.5).contains(imageRect), "\(imageRect) in \(paneRect)")
        XCTAssertLessThanOrEqual(imageRect.height, 180.5)
        // Below the toolbar.
        let hostRect = host.convert(host.bounds, to: nil)
        XCTAssertLessThanOrEqual(hostRect.maxY, window.contentLayoutRect.maxY + 0.5)
        XCTAssertLessThanOrEqual(imageRect.maxY, window.contentLayoutRect.maxY + 0.5)
    }
}

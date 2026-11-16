//
//  CompareRotateFooterTests.swift
//  ShrikeUITests
//
//  After a Compare rotate is written to the file (and after its undo), the
//  pane's footer shows the file's new size, not the old one.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class CompareRotateFooterTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = TestScratch.directory
            .appendingPathComponent("shrike-comparerot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        CompareWindow.presentsWindows = false
    }

    override func tearDown() async throws {
        CompareWindow.current?.close()
        CompareWindow.presentsWindows = true
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeJPEG(_ name: String, width: Int, height: Int) -> URL {
        let url = dir.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    func testFooterShowsTheNewSizeAfterTheRotateLandsAndAfterUndo() async throws {
        let urls = [writeJPEG("r1.jpg", width: 400, height: 240), writeJPEG("r2.jpg", width: 400, height: 240)]
        var services = ShrikeServices.makeDefault()
        services.backupStore = BackupStore(root: dir.appendingPathComponent("Backups", isDirectory: true))
        let window = CompareWindow.open(
            CompareRequest(list: urls.map { ImageGroup(primary: $0) }, shown: [0, 1], truncated: false),
            services: services, origin: nil, frame: NSRect(x: 0, y: 0, width: 1000, height: 650))
        let loaded = await waitUntil { window.panes.allSatisfy { $0.view.imageView.image != nil && $0.info != nil } }
        XCTAssertTrue(loaded)
        let pane = try XCTUnwrap(window.focusedPane)
        XCTAssertTrue(pane.view.footerLabel.stringValue.contains("400 × 240"), pane.view.footerLabel.stringValue)

        window.rotateFocused(.rotate(quarters: 1))
        XCTAssertTrue(pane.view.footerLabel.stringValue.contains("240 × 400"), "at once, from the view turn")
        await window.waitForOrientationWrites()
        let settled = await waitUntil {
            pane.info?.pixelSize == CGSize(width: 240, height: 400) && pane.view.imageView.rotationDegrees == 0
                && pane.loadedURL == urls[pane.index]
        }
        XCTAssertTrue(settled, "the written file was read again")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(pane.view.footerLabel.stringValue.contains("240 × 400"),
                      "after the write: \(pane.view.footerLabel.stringValue)")
        XCTAssertEqual(pane.view.imageView.sourcePixelSize, CGSize(width: 240, height: 400))

        window.compareUndoManager.undo()
        await window.waitForOrientationWrites()
        let undone = await waitUntil {
            pane.info?.pixelSize == CGSize(width: 400, height: 240) && pane.view.imageView.image != nil
        }
        XCTAssertTrue(undone, "the undone file was read again")
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(pane.view.footerLabel.stringValue.contains("400 × 240"),
                      "after undo: \(pane.view.footerLabel.stringValue)")
        XCTAssertEqual(pane.view.imageView.sourcePixelSize, CGSize(width: 400, height: 240))
    }
}

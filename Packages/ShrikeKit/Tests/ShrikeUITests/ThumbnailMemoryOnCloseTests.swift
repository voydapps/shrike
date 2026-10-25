//
//  ThumbnailMemoryOnCloseTests.swift
//  ShrikeUITests
//
//  Audit MP-03: the thumbnail memory tier (up to 128 MB) is given back when
//  the last window closes, and kept while any window is open.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeUI
@testable import ShrikeCore

@MainActor
final class ThumbnailMemoryOnCloseTests: XCTestCase {

    private var root: URL!
    private var coordinator: WindowCoordinator!
    private var services: ShrikeServices!

    override func setUp() async throws {
        root = TestScratch.directory
            .appendingPathComponent("shrike-thumbclose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("B"), withIntermediateDirectories: true)
        coordinator = WindowCoordinator()
        services = ShrikeServices.makeDefault()
        coordinator.services = services
    }

    override func tearDown() async throws {
        for browser in coordinator.browsers { browser.close() }
        try? FileManager.default.removeItem(at: root)
    }

    private func writeJPEG(_ url: URL) throws {
        let ctx = CGContext(data: nil, width: 96, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func fillMemoryTier() async throws {
        let photo = root.appendingPathComponent("A/p.jpg")
        try writeJPEG(photo)
        _ = try await services.thumbnailCache.thumbnail(for: FileImageSource(url: photo), maxPixelSize: 64)
        let bytes = await services.thumbnailCache.memoryResidentBytes()
        XCTAssertGreaterThan(bytes, 0)
    }

    private func waitUntilEmpty() async -> Bool {
        for _ in 0..<100 {
            if await services.thumbnailCache.memoryResidentBytes() == 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    func testClosingTheLastWindowEmptiesTheMemoryTier() async throws {
        coordinator.openFolders([root.appendingPathComponent("A")])
        try await fillMemoryTier()
        for browser in coordinator.browsers { browser.close() }
        let emptied = await waitUntilEmpty()
        XCTAssertTrue(emptied)
    }

    func testTheTierStaysWarmWhileAnotherWindowIsOpen() async throws {
        coordinator.openFolders([root.appendingPathComponent("A"), root.appendingPathComponent("B")])
        XCTAssertEqual(coordinator.browsers.count, 2)
        try await fillMemoryTier()
        coordinator.browsers.first?.close()
        try? await Task.sleep(for: .milliseconds(200))
        let bytes = await services.thumbnailCache.memoryResidentBytes()
        XCTAssertGreaterThan(bytes, 0)
    }
}

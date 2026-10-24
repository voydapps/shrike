//
//  InspectorFileChangeTests.swift
//  ShrikeUITests
//
//  The viewer's info panel follows the file: when another app rewrites the
//  shown photo, the File rows (size, dimensions) are read again.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI
@testable import ShrikeCore
@testable import ShrikeIO

@MainActor
final class InspectorFileChangeTests: XCTestCase {

    private func writeJPEG(_ url: URL, side: Int, noise: Bool) throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for i in 0..<(noise ? 400 : 1) {
            ctx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: CGFloat(i % 5) / 5, blue: CGFloat(i % 3) / 3, alpha: 1))
            ctx.fill(CGRect(x: (i * 37) % side, y: (i * 53) % side, width: side / 8, height: side / 8))
        }
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }

    private func rows(_ viewer: ViewerWindow) -> [String: String] {
        Dictionary(uniqueKeysWithValues: viewer.contentRoot.inspectorPanel.modelForTesting.facts.file.map { ($0.label, $0.value) })
    }

    func testModifiedShownFileRefreshesInspectorFileRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shrike-insp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.jpg")
        try writeJPEG(url, side: 64, noise: false)
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        viewer.contentRoot.inspectorPanel.headerReadsEnabled = true
        viewer.contentRoot.setCurrentURL(url)
        try await waitFor { self.rows(viewer)["Dimensions"]?.contains("64") == true }
        let before = rows(viewer)

        try writeJPEG(url, side: 512, noise: true)
        viewer.watchedFolderPath = root.standardizedFileURL.path
        viewer.handleFolderChange(FolderChange(modified: [url]), in: root)
        try await waitFor { self.rows(viewer)["Dimensions"]?.contains("512") == true }
        let after = rows(viewer)
        XCTAssertNotEqual(before["Size"], after["Size"], "the size row follows the file")
        XCTAssertTrue(after["Dimensions"]?.contains("512") == true)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "timed out")
    }
}

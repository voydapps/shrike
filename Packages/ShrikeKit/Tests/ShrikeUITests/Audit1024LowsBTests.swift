//
//  Audit1024LowsBTests.swift
//  ShrikeUITests
//
//  Low findings of the 2026-10-24 audit, round B.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class Audit1024LowsBTests: XCTestCase {

    func testAGoneDiskIsNamedAndNeverLandsInVolumes() {
        let gone = URL(fileURLWithPath: "/Volumes/NoSuchDisk-\(UUID().uuidString)/DCIM/100CANON")
        let name = gone.pathComponents[2]
        XCTAssertEqual(BrowserWindowController.goneVolumeName(of: gone), name)
        XCTAssertEqual(BrowserContentViewController.folderGoneSubtitle(for: gone), "“\(name)” was disconnected.")
        let target = BrowserWindowController.nearestExistingAncestor(of: gone)
        XCTAssertNotEqual(target.path, "/Volumes")
        XCTAssertTrue(target.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path))
        // A normal missing folder keeps the old wording and its nearest parent.
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        XCTAssertNil(BrowserWindowController.goneVolumeName(of: missing))
        XCTAssertEqual(BrowserContentViewController.folderGoneSubtitle(for: missing),
                       "It may have been moved, or its disk was disconnected.")
    }

    func testRatingMenuItemsReadAsWords() {
        XCTAssertEqual(ShrikeCommand.rate3.accessibleRatingTitle, "Rate 3 Stars")
        XCTAssertEqual(ShrikeCommand.rate1.accessibleRatingTitle, "Rate 1 Star")
        XCTAssertNil(ShrikeCommand.toggleFlag.accessibleRatingTitle)
        XCTAssertEqual(ShrikeCommand.rate4.shortcutsTabTitle, "Rate 4 Stars")
    }

    func testHomeAndEndSelectTheFirstAndLastPhoto() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-homeend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for name in ["a.jpg", "b.jpg", "c.jpg", "d.jpg"] {
            let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                       UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
        Prefs.browserSortKey = "name"
        Prefs.browserSortAscending = true
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let deadline = Date().addingTimeInterval(5)
        while content.visibleItems.count < 4, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        content.select(url: dir.appendingPathComponent("b.jpg").standardizedFileURL)
        XCTAssertTrue(browser.handleKeySnapshot(KeyEventSnapshot(key: "", keyCode: 119)))
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["d.jpg"], "End")
        XCTAssertTrue(browser.handleKeySnapshot(KeyEventSnapshot(key: "", keyCode: 115)))
        XCTAssertEqual(content.selectedItems.map(\.displayName), ["a.jpg"], "Home")
    }

    func testEveryBatchFieldChipHasAMeaning() {
        for group in BatchTokens.groups {
            for token in group.tokens {
                XCTAssertNotEqual(BatchTokens.hint(token), "Add this field to the name", "\(token) needs a hint")
            }
        }
    }
}

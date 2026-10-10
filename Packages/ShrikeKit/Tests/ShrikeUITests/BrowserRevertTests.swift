//
//  BrowserRevertTests.swift
//  ShrikeUITests
//
//  In the Browser: File ▸ Revert to Original… acts on the
//  selection when it is one edited item (the Revert alert → original bytes →
//  toast with Undo; ⌘Z puts the edit back). Disabled for no selection,
//  an unedited item, or several items. Temp folders and a temp
//  `BackupStore` only.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class BrowserRevertTests: XCTestCase {

    private var root: URL!
    private var dir: URL!
    private var store: BackupStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-browser-revert-\(UUID().uuidString)", isDirectory: true)
        dir = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = BackupStore(root: root.appendingPathComponent("Backups", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func writeJPEG(_ url: URL, red: CGFloat) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return try Data(contentsOf: url)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// a.jpg edited once by Shrike (original kept); b.jpg never edited.
    private func makeBrowser() async throws -> (BrowserWindowController, original: Data, edited: Data) {
        let a = dir.appendingPathComponent("a.jpg")
        let original = try writeJPEG(a, red: 0.1)
        _ = try await store.backup(a, reason: .save)
        let edited = try writeJPEG(a, red: 0.9)
        try writeJPEG(dir.appendingPathComponent("b.jpg"), red: 0.4)
        var services = ShrikeServices.makeDefault()
        services.backupStore = store
        let browser = BrowserWindowController(services: services, initialFolder: dir)
        let loaded = await waitUntil {
            browser.contentController.visibleItems.count == 2
                && browser.contentController.visibleItems.contains { $0.edited }
        }
        XCTAssertTrue(loaded)
        return (browser, original, edited)
    }

    func testEnabledOnlyForOneEditedItem() async throws {
        let (browser, _, _) = try await makeBrowser()
        defer { browser.close() }
        let a = dir.appendingPathComponent("a.jpg"), b = dir.appendingPathComponent("b.jpg")
        XCTAssertFalse(browser.canPerform(.revertToOriginal), "nothing selected")
        XCTAssertTrue(browser.contentController.select(urls: [b]))
        XCTAssertFalse(browser.canPerform(.revertToOriginal), "not edited")
        XCTAssertTrue(browser.contentController.select(urls: [a, b]))
        XCTAssertFalse(browser.canPerform(.revertToOriginal), "two items")
        XCTAssertTrue(browser.contentController.select(urls: [a]))
        XCTAssertTrue(browser.canPerform(.revertToOriginal))
    }

    func testRevertAsksThenRestoresTheOriginalAndUndoes() async throws {
        let (browser, original, edited) = try await makeBrowser()
        defer { browser.close() }
        let a = dir.appendingPathComponent("a.jpg")
        var asked: [String] = []
        browser.alertResponderForTesting = { title in asked.append(title); return 1 }
        XCTAssertTrue(browser.contentController.select(urls: [a]))

        browser.perform(.revertToOriginal)
        await browser.revertTask?.value

        XCTAssertEqual(asked, ["Revert “a.jpg” to the original?"])
        XCTAssertEqual(try Data(contentsOf: a), original)
        XCTAssertEqual(browser.toastHost.content?.message, "Reverted “a.jpg” to the original.")
        XCTAssertEqual(browser.toastHost.content?.actionTitle, "Undo")

        let undo = try XCTUnwrap(browser.window?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Revert to Original")
        undo.undo()
        await browser.waitForOrientationWrites()
        XCTAssertEqual(try Data(contentsOf: a), edited, "⌘Z puts the edited version back")
    }

    func testCancelLeavesTheFile() async throws {
        let (browser, _, edited) = try await makeBrowser()
        defer { browser.close() }
        let a = dir.appendingPathComponent("a.jpg")
        browser.alertResponderForTesting = { _ in 0 }
        XCTAssertTrue(browser.contentController.select(urls: [a]))
        browser.perform(.revertToOriginal)
        await browser.revertTask?.value
        XCTAssertEqual(try Data(contentsOf: a), edited)
    }
}

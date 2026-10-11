//
//  BrowserOpenKeysTests.swift
//  ShrikeUITests
//
//  A Browser that has just opened a folder (`open -a Shrike <folder>`):
//  the grid / strip / list holds the keys and the first photo is selected,
//  so ← → ↑ ↓ work without a click (0.2.4 smoke, P3).
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class BrowserOpenKeysTests: XCTestCase {

    private var dir: URL!
    private var savedMode = 0

    override func setUp() async throws {
        savedMode = Prefs.browserViewMode
        BrowserWindowController.restoresViewModeUnderTests = true
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-openkeys-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for i in 0..<6 {
            let ctx = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let url = dir.appendingPathComponent(String(format: "p%03d.jpg", i))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }

    override func tearDown() async throws {
        Prefs.browserViewMode = savedMode
        BrowserWindowController.restoresViewModeUnderTests = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return cond()
    }

    private func key(_ code: UInt16, _ char: Int, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: String(UnicodeScalar(char)!),
            charactersIgnoringModifiers: String(UnicodeScalar(char)!), isARepeat: false, keyCode: code))
    }

    private func names(_ browser: BrowserWindowController) -> [String] {
        browser.contentController.selectedItems.map(\.url.lastPathComponent).sorted()
    }

    private func open(_ mode: BrowserViewMode) async throws -> BrowserWindowController {
        Prefs.browserViewMode = mode.rawValue
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        let listed = await waitUntil { browser.contentController.visibleItems.count == 6 }
        XCTAssertTrue(listed)
        XCTAssertEqual(browser.contentController.mode, mode)
        try await Task.sleep(for: .milliseconds(150))
        let window = try XCTUnwrap(browser.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.contentView?.layoutSubtreeIfNeeded()
        return browser
    }

    /// The folder just loaded: the view holds the keys, the first photo is
    /// selected, and a real arrow key through `sendEvent` moves it on.
    private func check(_ mode: BrowserViewMode, step: (code: UInt16, char: Int)) async throws {
        let browser = try await open(mode)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let content = browser.contentController
        XCTAssertTrue(window.firstResponder === content.focusView, "\(mode): the view holds the keys")
        XCTAssertEqual(names(browser), ["p000.jpg"], "\(mode): the first photo is selected")

        window.sendEvent(try key(step.code, step.char, in: window))
        XCTAssertEqual(names(browser), ["p001.jpg"], "\(mode): the arrow moved to the next photo")
        window.sendEvent(try key(step.code, step.char, in: window))
        XCTAssertEqual(names(browser), ["p002.jpg"], "\(mode): and on")
    }

    func testGridOpensWithKeysAndTheFirstPhotoSelected() async throws {
        try await check(.grid, step: (124, NSRightArrowFunctionKey))
    }

    func testFilmstripOpensWithKeysAndTheFirstPhotoSelected() async throws {
        try await check(.filmstrip, step: (124, NSRightArrowFunctionKey))
    }

    func testListOpensWithKeysAndTheFirstPhotoSelected() async throws {
        try await check(.list, step: (125, NSDownArrowFunctionKey))
    }

    func testAFolderLoadDoesNotTakeTheKeysFromTheSearchField() async throws {
        let browser = try await open(.grid)
        defer { browser.close() }
        let window = try XCTUnwrap(browser.window)
        let field = NSTextField(string: "x")
        window.contentView?.addSubview(field)
        XCTAssertTrue(window.makeFirstResponder(field))
        browser.claimKeysForContentIfIdle()
        XCTAssertTrue(window.firstResponder === field || window.firstResponder === field.currentEditor(),
                      "a field being typed in keeps its focus")
        field.removeFromSuperview()
    }
}

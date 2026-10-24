//
//  BrowserFocusRingTests.swift
//  ShrikeUITests
//
//  Audit on-screen M6: Tab leaves the photo grid. Ring: sidebar -> photos ->
//  info panel -> search -> sidebar.
//

import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import ShrikeUI

@MainActor
final class BrowserFocusRingTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-focusring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        for name in ["a.jpg", "b.jpg"] {
            let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent(name) as CFURL,
                                                       UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testTabWalksTheWholeWindowAndBack() async throws {
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        let content = browser.contentController
        let deadline = Date().addingTimeInterval(5)
        while content.visibleItems.count < 2, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        let window = try XCTUnwrap(browser.window)
        let ring = browser.focusRing()
        XCTAssertEqual(ring.count, 4, "photos, search, sidebar and info panel: \(ring)")
        XCTAssertTrue(ring[0] === content.focusView, "photos, then search, sidebar, info panel")
        XCTAssertTrue(ring[1] === browser.searchField)
        XCTAssertTrue(ring[2] === browser.treeController.focusView)
        XCTAssertTrue(ring[3] is InspectorFocusRootView, "the info panel is in the ring")
        XCTAssertTrue(ring.contains { $0 === content.focusView })
        XCTAssertTrue(ring.contains { $0 === browser.searchField })
        XCTAssertTrue(ring.contains { $0 === browser.treeController.focusView })

        XCTAssertTrue(window.makeFirstResponder(content.focusView))
        var visited: [NSView] = []
        for _ in 0..<ring.count {
            XCTAssertTrue(browser.moveFocus(from: window.firstResponder, backward: false))
            let responder = window.firstResponder
            let landed = ring.first { entry in
                guard let view = responder as? NSView else { return (responder as? NSTextView)?.delegate === entry }
                return view === entry || view.isDescendant(of: entry)
            }
            XCTAssertNotNil(landed, "focus lands on a ring pane, not nowhere: \(String(describing: responder))")
            if let landed { visited.append(landed) }
        }
        XCTAssertEqual(visited.count, ring.count)
        XCTAssertTrue(visited.last === content.focusView, "Tab goes all the way round and comes back to the photos")
        XCTAssertTrue(visited[2] is InspectorFocusRootView, "grid, search, sidebar, info panel, grid")
        XCTAssertEqual(Set(visited.map(ObjectIdentifier.init)).count, ring.count, "every pane once")

        // ⇧Tab goes the other way.
        XCTAssertTrue(window.makeFirstResponder(content.focusView))
        XCTAssertTrue(browser.moveFocus(from: window.firstResponder, backward: true))
        let back = window.firstResponder as? NSView
        let first = ring[(ring.firstIndex { $0 === content.focusView }! + ring.count - 1) % ring.count]
        XCTAssertTrue(back === first || back?.isDescendant(of: first) == true)
    }

    func testPlainTabIsRecognisedAndCommandTabIsNot() throws {
        func key(_ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                isARepeat: false, keyCode: 48))
        }
        XCTAssertTrue(BrowserFocusRing.isTab(try key([])))
        XCTAssertTrue(BrowserFocusRing.isTab(try key([.shift])))
        XCTAssertFalse(BrowserFocusRing.isTab(try key([.command])))
    }
}

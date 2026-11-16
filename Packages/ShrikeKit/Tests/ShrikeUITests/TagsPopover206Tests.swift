//
//  TagsPopover206Tests.swift
//  ShrikeUITests
//
//  Spec 28 §6 (L-6): Tags popover placement, heading, the seven named dots.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeIO
@testable import ShrikeUI

@MainActor
final class TagsPopover206Tests: XCTestCase {

    private let content = CGRect(x: 0, y: 52, width: 1000, height: 700)   // top-left space, under a 52 pt title bar
    private let size = CGSize(width: 280, height: 140)

    func testBelowThenRightThenAboveAndNeverOverTheTitleBar() {
        // Room below.
        var placed = TagsPopoverPlacement.place(anchor: CGRect(x: 100, y: 60, width: 120, height: 90), popover: size, content: content)
        XCTAssertEqual(placed.side, .below)
        // No room below, room right.
        placed = TagsPopoverPlacement.place(anchor: CGRect(x: 100, y: 600, width: 120, height: 90), popover: size, content: content)
        XCTAssertEqual(placed.side, .right)
        // No room below or right: above.
        placed = TagsPopoverPlacement.place(anchor: CGRect(x: 800, y: 600, width: 120, height: 90), popover: size, content: content)
        XCTAssertEqual(placed.side, .above)
        XCTAssertGreaterThanOrEqual(placed.anchor.minY - TagsPopoverPlacement.arrow - size.height, content.minY + 4)
        // Right, but a centred popover would rise over the title bar: clamped down.
        let tall = CGSize(width: 280, height: 600)
        placed = TagsPopoverPlacement.place(anchor: CGRect(x: 100, y: 200, width: 100, height: 10), popover: tall, content: content)
        XCTAssertEqual(placed.side, .right)
        XCTAssertGreaterThanOrEqual(placed.anchor.midY - tall.height / 2, content.minY + 4)
        // Nothing fits: below, pulled up, never above the title bar line.
        placed = TagsPopoverPlacement.place(anchor: CGRect(x: 800, y: 300, width: 190, height: 40),
                                            popover: CGSize(width: 280, height: 690), content: content)
        XCTAssertEqual(placed.side, .below)
        XCTAssertGreaterThanOrEqual(placed.anchor.maxY, content.minY + 4)
    }

    func testBelowIsMinYInAPlainViewAndMaxYInAFlippedOne() {
        XCTAssertEqual(TagsPopoverPlacement.edge(.below, flipped: false), .minY)
        XCTAssertEqual(TagsPopoverPlacement.edge(.below, flipped: true), .maxY)
        XCTAssertEqual(TagsPopoverPlacement.edge(.above, flipped: false), .maxY)
        XCTAssertEqual(TagsPopoverPlacement.edge(.right, flipped: true), .maxX)
    }

    func testPlacementInARealWindowUsesTheContentLayoutRect() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try! XCTUnwrap(window.contentView)
        // A cell near the top of a plain (unflipped) view: below.
        let cell = NSRect(x: 50, y: root.bounds.maxY - 150, width: 140, height: 140)
        let placed = TagsPopoverController.placement(for: cell, in: root, popover: size)
        XCTAssertEqual(placed.side, .below)
        XCTAssertEqual(placed.edge, root.isFlipped ? .maxY : .minY)
        XCTAssertEqual(placed.rect, cell)
    }

    func testDotModelNamesTooltipsAndVoiceOver() {
        let red = TagDotModel(name: "Red", color: .red, state: .off)
        XCTAssertEqual(red.toolTip, "Red · add")
        XCTAssertEqual(red.accessibilityValue, "off")
        let on = TagDotModel(name: "Red", color: .red, state: .on)
        XCTAssertEqual(on.toolTip, "Red · remove")
        XCTAssertEqual(on.accessibilityValue, "on")
        XCTAssertFalse(on.checkIsDark)
        XCTAssertTrue(TagDotModel(name: "Gray", color: .gray, state: .on).checkIsDark)
    }

    func testPopoverHasHeadingAndSevenNamedDotsInFinderOrder() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tags206-\(UUID()).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        defer { try? FileManager.default.removeItem(at: url) }
        let session = TagEditSession(groups: [ImageGroup(primary: url)], undoManager: nil, onChange: { _ in }, onError: { _ in })
        let controller = TagsPopoverController(session: session)
        _ = controller.view
        XCTAssertEqual(controller.heading?.stringValue, "Tags")
        XCTAssertEqual(controller.heading?.font?.pointSize, 13)
        XCTAssertEqual(controller.toggles.map(\.tag0.color), FinderTagColor.finderMenuOrder)
        for toggle in controller.toggles {
            XCTAssertEqual(toggle.accessibilityRole(), NSAccessibility.Role.checkBox)
            XCTAssertEqual(toggle.accessibilityLabel(), toggle.tag0.name)
            XCTAssertEqual(toggle.accessibilityValue() as? String, "off")
            XCTAssertEqual(toggle.toolTip, "\(toggle.tag0.name) · add")
            XCTAssertTrue(toggle.canBecomeKeyView, "Tab reaches every dot")
            XCTAssertEqual(toggle.fittingSize, NSSize(width: 24, height: 24))
        }
        let red = try XCTUnwrap(controller.toggles.first)
        red.state = .on
        XCTAssertEqual(red.toolTip, "\(red.tag0.name) · remove")
        XCTAssertEqual(red.accessibilityValue() as? String, "on")
    }

    /// The tags are read off the main thread, so the field is disabled at
    /// open; once they have been read it takes the focus (typing goes there).
    func testTheFieldTakesTheFocusOnceTheTagsHaveBeenRead() async throws {
        let url = TestScratch.directory.appendingPathComponent("tags-focus-\(UUID()).jpg")
        FileManager.default.createFile(atPath: url.path, contents: Data([0xFF, 0xD8, 0xFF, 0xD9]))
        defer { try? FileManager.default.removeItem(at: url) }
        let session = TagEditSession(groups: [ImageGroup(primary: url)], undoManager: nil,
                                     onChange: { _ in }, onError: { _ in },
                                     read: { urls in
                                         try? await Task.sleep(for: .milliseconds(150))
                                         return Dictionary(uniqueKeysWithValues: urls.map { ($0, ["Blue"]) })
                                     })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)
        let controller = TagsPopoverController(session: session)
        let anchor = try XCTUnwrap(window.contentView)
        controller.present(relativeTo: NSRect(x: 290, y: 190, width: 20, height: 20), of: anchor, edge: .minY)
        defer { controller.cancelOperation(nil) }
        XCTAssertFalse(session.isLoaded)
        XCTAssertFalse(controller.tokenField.isEnabled)
        let end = Date().addingTimeInterval(5)
        while !session.isLoaded, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(session.isLoaded)
        XCTAssertTrue(controller.tokenField.isEnabled)
        let popoverWindow = try XCTUnwrap(controller.view.window)
        let responder = popoverWindow.firstResponder
        let editing = responder === controller.tokenField
            || (responder as? NSTextView)?.delegate === controller.tokenField
        XCTAssertTrue(editing, "first responder: \(String(describing: responder))")
    }
}

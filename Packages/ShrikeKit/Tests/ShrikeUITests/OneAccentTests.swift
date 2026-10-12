//
//  OneAccentTests.swift
//  ShrikeUITests
//
//  Spec 22 §3.5 / §7.3: one blue per window. The toolbar Done, the capsule
//  Done and every panel Apply take their fill through the same call
//  (`NSButton.useAccentFill()`), so the system draws them the same.
//
//  A bitmap sample of the fill is not possible on macOS 26: a default
//  button is tinted glass, drawn by the window server, and an offscreen
//  render keeps only a 20/255 overlay (checked 2026-10-10 with a key-window
//  stand-in, cacheDisplay and layer.render, light and dark). So the test
//  pins the mechanism: same call, same resulting properties, and the
//  fill is never a hard-coded colour.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class OneAccentTests: XCTestCase {

    private var expected: String {
        if #available(macOS 26, *) { return "prominent" }
        return "accent"
    }

    func testToolbarDoneAndCapsuleDoneUseTheSameAccentFill() {
        let capsule = EditCapsuleView()
        let buttons: [(String, NSButton)] = [
            ("capsule Done", capsule.doneButton),
            ("toolbar Done", EditToolbarController().doneButton),
        ]
        for (name, b) in buttons {
            XCTAssertEqual(b.accentFillMechanism, expected, name)
            XCTAssertEqual(b.keyEquivalent, "\r", "\(name): default button")
        }
    }

    func testToolbarDoneIsTheSystemAccentReference() {
        let edit = EditToolbarController()
        let item = edit.toolbar(edit.toolbar, itemForItemIdentifier: EditToolbarController.ItemID.done,
                                                    willBeInsertedIntoToolbar: true)
        let done = item?.view as? NSButton
        XCTAssertEqual(done?.keyEquivalent, "\r")
        // The button itself carries the fill, as Apply does; the item's
        // own prominent style would draw a second, different blue.
        XCTAssertEqual(done?.accentFillMechanism, expected)
        if #available(macOS 26, *) { XCTAssertNotEqual(item?.style, .prominent) }
    }

    func testAccentFillIsTheSystemAccentNotAFixedColour() {
        let b = NSButton(title: "OK", target: nil, action: nil)
        b.useAccentFill()
        if #available(macOS 26, *) {
            XCTAssertNil(b.bezelColor)
            XCTAssertEqual(b.tintProminence, .primary)
            XCTAssertEqual(b.bezelStyle, .glass, "the glass bezel draws the same blue in a toolbar and a panel")
        } else {
            XCTAssertEqual(b.bezelColor, .controlAccentColor)
        }
    }
}

//
//  AccentLabelColorTests.swift
//  ShrikeUITests
//
//  The label of an accent-filled default button (glass, macOS 26) is white
//  on a dark accent and black on a light one (Yellow). The system accent
//  is a pick of the user's, so it can't be changed here: the colour rule is
//  tested on the system colours the accent choices are made of.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class AccentLabelColorTests: XCTestCase {

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        var out = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func label(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor {
        NSColor.accentLabelColor(for: resolved(color, name))
    }

    func testDarkAccentsGetAWhiteLabelAndYellowABlackOne() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(label(.systemBlue, appearance), .white, "blue, \(appearance.rawValue)")
            XCTAssertEqual(label(.systemPurple, appearance), .white, "purple")
            XCTAssertEqual(label(.systemPink, appearance), .white, "pink")
            XCTAssertEqual(label(.systemRed, appearance), .white, "red")
            XCTAssertEqual(label(.systemOrange, appearance), .white, "orange")
            XCTAssertEqual(label(.systemGreen, appearance), .white, "green")
            XCTAssertEqual(label(.systemYellow, appearance), .black, "yellow, \(appearance.rawValue)")
        }
    }

    func testLuminanceNumbers() {
        // Recorded so a changed threshold is a visible decision.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let l = { (c: NSColor) in NSColor.relativeLuminance(of: self.resolved(c, appearance)) }
            XCTAssertGreaterThan(l(.systemYellow), NSColor.lightAccentLuminance, "yellow is light")
            XCTAssertLessThan(l(.systemBlue), 0.3)
            XCTAssertLessThan(l(.systemGreen), NSColor.lightAccentLuminance, "green \(l(.systemGreen))")
            XCTAssertLessThan(l(.systemOrange), NSColor.lightAccentLuminance, "orange \(l(.systemOrange))")
        }
        XCTAssertEqual(NSColor.relativeLuminance(of: .white), 1, accuracy: 0.001)
        XCTAssertEqual(NSColor.relativeLuminance(of: .black), 0, accuracy: 0.001)
    }

    func testTheButtonLabelIsDynamicAndFollowsTheSystemAccent() {
        let button = NSButton(title: "Rename", target: nil, action: nil)
        button.useAccentFill()
        if #available(macOS 26, *) {
            let color = button.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            XCTAssertNotNil(color, "the label colour is set")
            // Whatever accent the system has now, the dynamic colour is
            // the rule applied to it, in each appearance.
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                var drawn = NSColor.clear
                NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                    drawn = color?.usingColorSpace(.sRGB) ?? .clear
                }
                XCTAssertEqual(drawn, NSColor.accentLabelColor(in: NSAppearance(named: appearance)!)
                    .usingColorSpace(.sRGB), "\(appearance.rawValue)")
            }
        }
    }
}

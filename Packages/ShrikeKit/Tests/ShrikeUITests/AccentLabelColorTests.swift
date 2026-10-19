//
//  AccentLabelColorTests.swift
//  ShrikeUITests
//
//  The app-owned accent label chooses the stronger black/white contrast
//  in each resolved appearance; the native accent fill remains unchanged.
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

    func testResolvedAccentLabelsMeetNormalTextContrast() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let context = NSAppearance(named: appearance)!
            for accent: NSColor in [.systemBlue, .systemPurple, .systemPink, .systemRed,
                                    .systemOrange, .systemGreen, .systemYellow] {
                let background = resolved(accent, appearance)
                let foreground = label(accent, appearance)
                XCTAssertGreaterThanOrEqual(Contrast.ratio(foreground, on: background, in: context), 4.5)
            }
        }
    }

    func testLuminanceNumbers() {
        // Independent luminance sanity checks, not a foreground cutoff.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let l = { (c: NSColor) in NSColor.relativeLuminance(of: self.resolved(c, appearance)) }
            XCTAssertGreaterThan(l(.systemYellow), 0.5, "yellow is light")
            XCTAssertLessThan(l(.systemBlue), 0.3)
            XCTAssertLessThan(l(.systemGreen), 0.5, "green \(l(.systemGreen))")
            XCTAssertLessThan(l(.systemOrange), 0.5, "orange \(l(.systemOrange))")
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

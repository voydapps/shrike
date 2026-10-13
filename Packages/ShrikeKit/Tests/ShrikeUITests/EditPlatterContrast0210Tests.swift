//
//  EditPlatterContrast0210Tests.swift
//  ShrikeUITests
//
//  0.2.10 audit item 4: the active edit tool must stand out from the dark bar
//  by at least 3:1 (WCAG 1.4.11), measured on pixels the picker really draws.
//

import AppKit
import XCTest
@testable import ShrikeUI

@MainActor
final class EditPlatterContrast0210Tests: XCTestCase {

    private final class Bar: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1).setFill()
            bounds.fill()
        }
    }

    private func luminance(_ c: NSColor) -> Double {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        func lin(_ v: CGFloat) -> Double {
            let d = Double(v)
            return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
    }

    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testChosenToolPlatterAndRingAreAtLeast3To1OnTheDarkBar() throws {
        let bar = Bar(frame: NSRect(x: 0, y: 0, width: 160, height: 28))
        bar.appearance = NSAppearance(named: .darkAqua)
        let picker = EditToolPicker()
        picker.frame = bar.bounds
        bar.addSubview(picker)
        bar.layoutSubtreeIfNeeded()
        picker.show(tool: .rotate)
        let rep = try XCTUnwrap(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
        bar.cacheDisplay(in: bar.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / bar.bounds.width

        func pixel(_ x: CGFloat, _ yFromTop: CGFloat) throws -> NSColor {
            try XCTUnwrap(rep.colorAt(x: Int(x * scale), y: Int(yFromTop * scale)))
        }
        let barColor = try pixel(0.5, 0.5)
        XCTAssertEqual(luminance(barColor), luminance(NSColor(srgbRed: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)),
                       accuracy: 0.004, "the sample bar is the audit's (17,17,17)")

        // Segment 1 spans x 32...64. Fill: inside the platter, above the glyph.
        let fill = try pixel(48, 5)
        XCTAssertGreaterThanOrEqual(ratio(fill, barColor), 3.0, "platter fill vs bar")
        // Ring: the leftmost drawn column of the platter, mid height.
        var best = 0.0
        for dx in stride(from: 0.0, through: 6.0, by: 0.5) {
            best = max(best, ratio(try pixel(32 + dx, 14), barColor))
        }
        XCTAssertGreaterThanOrEqual(best, 3.0, "ring vs bar")
        // And it stays clearly blue, not grey.
        let rgb = try XCTUnwrap(fill.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(rgb.blueComponent, rgb.redComponent + 0.25, "blue, not grey")
        // The white glyph stays readable on the fill (checked on the colours).
        XCTAssertGreaterThanOrEqual(ratio(.white, fill), 3.0)
    }
}

//
//  BatchDimmingTests.swift
//  ShrikeUITests
//
//  With Convert off, the Quality slider, its label and its
//  value grey out like the Format pop-up. Rendered offscreen in dark
//  mode; light text on a dark ground, so "grey" means "less bright".
//

import AppKit
import SwiftUI
import XCTest
@testable import ShrikeUI

@MainActor
final class BatchDimmingTests: XCTestCase {

    /// The brightest pixel (0…1) of `view` drawn offscreen in dark mode.
    private func brightest<V: View>(_ view: V, enabled: Bool) throws -> Double {
        let size = NSSize(width: 220, height: 44)
        let host = NSHostingView(rootView: view.disabled(!enabled).padding(8))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        let w = Int(size.width) * 2, h = Int(size.height) * 2
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: 2, y: 2)
        if host.isFlipped {
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        try XCTUnwrap(host.layer).render(in: ctx)
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        var best = 0.0
        for i in 0..<(w * h) {
            let p = data + i * 4
            let lum = (0.2126 * Double(p[0]) + 0.7152 * Double(p[1]) + 0.0722 * Double(p[2])) / 255
            best = max(best, lum)
        }
        return best
    }

    func testRowLabelsGreyOutWithTheirRow() throws {
        let on = try brightest(Text("Quality").dimsWithRow(), enabled: true)
        let off = try brightest(Text("Quality").dimsWithRow(), enabled: false)
        XCTAssertGreaterThan(on, 0.6, "a bright label when the row is on")
        XCTAssertLessThan(off, on * 0.6, "on \(on), off \(off)")

        let unitOn = try brightest(Text("px").dimsWithRow(secondary: true), enabled: true)
        let unitOff = try brightest(Text("px").dimsWithRow(secondary: true), enabled: false)
        XCTAssertLessThan(unitOff, unitOn, "on \(unitOn), off \(unitOff)")
    }

    func testTheQualitySliderGreysOutWithItsRow() throws {
        func slider() -> some View {
            Slider(value: .constant(85), in: 60...100).frame(width: 140).sliderDimsWithRow()
        }
        let on = try brightest(slider(), enabled: true)
        let off = try brightest(slider(), enabled: false)
        XCTAssertGreaterThan(on, 0.6, "the white knob when Convert is on")
        XCTAssertLessThan(off, on * 0.6, "on \(on), off \(off)")
    }
}

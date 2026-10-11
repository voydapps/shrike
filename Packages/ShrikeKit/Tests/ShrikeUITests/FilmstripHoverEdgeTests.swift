//
//  FilmstripHoverEdgeTests.swift
//  ShrikeUITests
//
//  Round 3: the strip hover maps to the column under the pointer along the
//  whole strip, right at the left edge and on a scrolled strip too.
//

import AppKit
import XCTest
@testable import ShrikeCore
import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class FilmstripHoverEdgeTests: XCTestCase {
    private var window: NSWindow!
    private var strip: FilmstripView!

    override func setUp() async throws {
        ReduceMotion.overrideForTesting = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: true)
        strip = FilmstripView()
        strip.setMode(.windowed)
        strip.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        window.contentView?.addSubview(strip)
        for i in 0..<20 { _ = strip.injectCellForTesting(globalIndex: i, aspect: 1.5) }
        strip.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        ReduceMotion.overrideForTesting = nil
        window.close()
    }

    private func point(x: CGFloat) -> NSPoint {
        strip.convert(NSPoint(x: x, y: strip.bounds.midY), to: nil)
    }

    /// The cell nearest to the window point (distance 0 inside a cell or
    /// its half gap); the lower index wins a tie.
    private func expected(at p: NSPoint) -> Int? {
        let slack: CGFloat = 4
        var best: (Int, CGFloat)?
        for i in strip.globalIndicesForTesting().sorted() {
            let cell = strip.cellViewForTesting(i)!
            let f = cell.convert(cell.bounds, to: nil)
            let d = max(f.minX - slack - p.x, p.x - (f.maxX + slack), 0)
            if best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    private func check(scroll: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        strip.scrollForTesting(by: scroll)
        strip.layoutSubtreeIfNeeded()
        var xs: [CGFloat] = [1, 4, 20, 300, 598]
        for i in strip.globalIndicesForTesting() {
            let cell = strip.cellViewForTesting(i)!
            let f = strip.convert(cell.convert(cell.bounds, to: nil), from: nil)
            guard f.maxX > 0, f.minX < 600 else { continue }
            xs += [f.midX, f.maxX + 1, f.minX - 1]
        }
        for x in xs where x >= 0 && x < 600 {
            let p = point(x: x)
            strip.hoverPointer(atWindowPoint: p)
            XCTAssertEqual(strip.hoveredGlobalIndexForTesting, expected(at: p), "x=\(x) scroll=\(scroll)",
                           file: file, line: line)
        }
    }

    func testHoverMapsToTheColumnAtScrollZero() { check(scroll: 0) }
    func testHoverMapsToTheColumnOnAScrolledStrip() { check(scroll: 137) }
    func testHoverMapsToTheColumnScrolledNearTheEnd() { check(scroll: 1700) }

    /// The side padding before the first cell belongs to the first cell.
    func testTheLeadingPaddingHoversTheFirstCell() {
        strip.hoverPointer(atWindowPoint: point(x: 1))
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 0)
        strip.hoverPointer(atWindowPoint: point(x: 4))
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 0)
    }

    /// A cell that changes width under a still pointer (its thumbnail
    /// arrived) moves the cells after it; the ring follows the pointer.
    func testTheHoverFollowsCellsThatMoveUnderAStillPointer() {
        let p = strip.cellCenterInWindowForTesting(2)!
        strip.hoverPointer(atWindowPoint: p)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 2)
        strip.simulateThumbnailDeliveredForTesting(globalIndex: 0, pixelWidth: 100, pixelHeight: 400)
        strip.simulateThumbnailDeliveredForTesting(globalIndex: 1, pixelWidth: 100, pixelHeight: 400)
        strip.layoutSubtreeIfNeeded()
        strip.displayIfNeeded()
        let now = strip.hoveredGlobalIndexForTesting
        XCTAssertEqual(now, expected(at: p), "ring is on the cell now under the pointer")
        XCTAssertNotEqual(now, 2, "the cells did move")
    }

    /// A short folder: empty strip past the last cell hovers nothing.
    func testEmptyRoomPastTheLastCellHoversNothing() {
        let short = FilmstripView()
        short.setMode(.windowed)
        short.frame = NSRect(x: 0, y: 0, width: 600, height: 100)
        window.contentView?.addSubview(short)
        for i in 0..<3 { _ = short.injectCellForTesting(globalIndex: i, aspect: 1.5) }
        short.layoutSubtreeIfNeeded()
        let p = short.convert(NSPoint(x: 580, y: short.bounds.midY), to: nil)
        short.hoverPointer(atWindowPoint: p)
        XCTAssertNil(short.hoveredGlobalIndexForTesting)
        let q = short.convert(NSPoint(x: 4, y: short.bounds.midY), to: nil)
        short.hoverPointer(atWindowPoint: q)
        XCTAssertEqual(short.hoveredGlobalIndexForTesting, 0, "side padding still maps to the first cell")
    }
}

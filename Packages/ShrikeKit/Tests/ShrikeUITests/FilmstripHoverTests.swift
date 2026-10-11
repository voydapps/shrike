//
//  FilmstripHoverTests.swift
//  ShrikeUITests
//
//  Spec 24 §2 (vector 9): a non-selected filmstrip cell under the pointer
//  shows a 1.5 pt labelColor 0.75 ring and a white 0.10 veil; the selected
//  cell keeps its accent ring and gets no hover; only one cell is hovered at
//  a time; the hover clears on exit, drag, hide and scroll.
//

import AppKit
import XCTest
@testable import ShrikeCore
import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class FilmstripHoverTests: XCTestCase {

    private var window: NSWindow!
    private var strip: FilmstripView!

    override func setUp() async throws {
        ReduceMotion.overrideForTesting = nil
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 120),
                          styleMask: [.titled], backing: .buffered, defer: true)
        strip = FilmstripView()
        strip.setMode(.windowed)
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: 100)
        window.contentView?.addSubview(strip)
        for i in 0..<4 { _ = strip.injectCellForTesting(globalIndex: i, aspect: 1.5) }
        strip.layoutSubtreeIfNeeded()
    }

    override func tearDown() async throws {
        ReduceMotion.overrideForTesting = nil
        window.close()
    }

    private func move(to index: Int) {
        let p = strip.cellCenterInWindowForTesting(index)!
        strip.hoverPointer(atWindowPoint: p)
    }

    private func look(_ index: Int) -> (ringWidth: CGFloat, ringColor: CGColor?, ringOpacity: Float, overlayAlpha: CGFloat) {
        strip.hoverLookForTesting(strip.cellViewForTesting(index)!)!
    }

    func testHoveredCellShowsRingAndVeilAndOthersDoNot() throws {
        ReduceMotion.overrideForTesting = true
        move(to: 1)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 1)
        let cell = try XCTUnwrap(strip.cellViewForTesting(1))
        cell.updateLayer()
        let on = look(1)
        XCTAssertEqual(on.ringOpacity, 1)
        XCTAssertEqual(on.ringWidth, 1.5, accuracy: 0.01)
        XCTAssertEqual(on.overlayAlpha, 0.10, accuracy: 0.001)
        let color = try XCTUnwrap(on.ringColor).components ?? []
        XCTAssertEqual(color.last ?? 0, 0.75, accuracy: 0.01, "labelColor at 0.75")
        for i in [0, 2, 3] {
            XCTAssertEqual(look(i).ringOpacity, 0, "cell \(i)")
            XCTAssertEqual(look(i).overlayAlpha, 0, "cell \(i)")
        }
    }

    func testMovingToAnotherCellClearsTheFirst() {
        ReduceMotion.overrideForTesting = true
        move(to: 0)
        move(to: 2)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 2)
        XCTAssertEqual(look(0).ringOpacity, 0)
        XCTAssertEqual(look(2).ringOpacity, 1)
        let hovered = (0..<4).filter { look($0).ringOpacity > 0 }
        XCTAssertEqual(hovered, [2], "at most one cell hovered")
    }

    func testExitClears() {
        ReduceMotion.overrideForTesting = true
        move(to: 1)
        let exit = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          trackingNumber: 0, userData: nil)!
        strip.mouseExited(with: exit)
        XCTAssertNil(strip.hoveredGlobalIndexForTesting)
        XCTAssertEqual(look(1).ringOpacity, 0)
    }

    func testARealMouseMovedEventHovers() throws {
        ReduceMotion.overrideForTesting = true
        let p = try XCTUnwrap(strip.cellCenterInWindowForTesting(3))
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved, location: p, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        strip.mouseMoved(with: event)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 3)
    }

    /// The first pointer event into the strip hovers: at the top padding
    /// above a cell and in the gap between two cells, not only on the cell.
    func testTheFirstMouseMoveInThePaddingOrTheGapHovers() throws {
        ReduceMotion.overrideForTesting = true
        let center = try XCTUnwrap(strip.cellCenterInWindowForTesting(2))
        let cell = try XCTUnwrap(strip.cellViewForTesting(2))
        let top = cell.convert(NSPoint(x: cell.bounds.midX, y: cell.bounds.maxY + 2), to: nil)
        XCTAssertEqual(top.x, center.x, accuracy: 0.1)
        XCTAssertGreaterThan(top.y, center.y)
        func event(_ type: NSEvent.EventType, at p: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        }
        // First event of all: a mouse-move 2 pt above the cell.
        strip.mouseMoved(with: try event(.mouseMoved, at: top))
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 2, "padding above the cell")
        strip.clearHover()
        // The gap just right of cell 1.
        let one = try XCTUnwrap(strip.cellViewForTesting(1))
        let gap = one.convert(NSPoint(x: one.bounds.maxX + 1, y: one.bounds.midY), to: nil)
        strip.mouseMoved(with: try event(.mouseMoved, at: gap))
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 1, "gap after the cell")
        // The strip's tracking area is a real, visible-rect, key-window one.
        let areas = strip.trackingAreas.filter { $0.options.contains(.mouseMoved) }
        XCTAssertTrue(areas.contains { $0.options.contains(.inVisibleRect) && $0.options.contains(.activeInKeyWindow) })
    }

    func testTheSelectedCellKeepsItsAccentRingAndShowsNoHover() throws {
        ReduceMotion.overrideForTesting = true
        strip.updateSelection(1)
        move(to: 1)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 1, "the pointer is on it")
        XCTAssertEqual(look(1).ringOpacity, 0, "no hover ring on the selected cell")
        XCTAssertEqual(look(1).overlayAlpha, 0, "no veil on the selected cell")
        let cell = try XCTUnwrap(strip.cellViewForTesting(1))
        cell.updateLayer()
        XCTAssertEqual(strip.selectionRingWidthForTesting(selecting: cell), ShrikeTokens.increaseContrast ? 3 : 2)
        // Selecting the hovered cell hides its hover; deselecting brings it back.
        strip.updateSelection(0)
        XCTAssertEqual(look(1).ringOpacity, 1)
    }

    func testADragStartClears() {
        ReduceMotion.overrideForTesting = true
        move(to: 2)
        strip.dragBeganOnCellForTesting(2)
        XCTAssertNil(strip.hoveredGlobalIndexForTesting)
        XCTAssertEqual(look(2).ringOpacity, 0)
    }

    func testHidingTheStripClears() {
        ReduceMotion.overrideForTesting = true
        move(to: 2)
        strip.isHidden = true
        XCTAssertNil(strip.hoveredGlobalIndexForTesting)
        strip.isHidden = false
        // The pointer is not remembered: nothing hovers until it moves.
        XCTAssertNil(strip.hoveredGlobalIndexForTesting)
    }

    func testLosingKeyClears() {
        ReduceMotion.overrideForTesting = true
        move(to: 2)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertNil(strip.hoveredGlobalIndexForTesting)
    }

    func testScrollingReHitTestsUnderAStillPointer() throws {
        ReduceMotion.overrideForTesting = true
        // A strip narrower than its cells so it scrolls.
        strip.frame = NSRect(x: 0, y: 0, width: 260, height: 100)
        strip.layoutSubtreeIfNeeded()
        let point = NSPoint(x: 100, y: 50)
        strip.hoverPointer(atWindowPoint: strip.convert(point, to: nil))
        let before = try XCTUnwrap(strip.hoveredGlobalIndexForTesting)
        strip.scrollForTesting(by: 120)
        let done = expectation(description: "main queue")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        let after = try XCTUnwrap(strip.hoveredGlobalIndexForTesting)
        XCTAssertNotEqual(before, after, "the pointer is over another cell now")
        XCTAssertEqual((0..<4).filter { look($0).ringOpacity > 0 }, [after])
    }

    func testFadesAreEighty120MillisecondsAndInstantUnderReduceMotion() throws {
        ReduceMotion.overrideForTesting = false
        move(to: 1)
        let cell = try XCTUnwrap(strip.cellViewForTesting(1))
        let fadeIn = try XCTUnwrap(strip.hoverFadeForTesting(cell) as? CABasicAnimation)
        XCTAssertEqual(fadeIn.duration, 0.08, accuracy: 0.001)
        move(to: 2)
        let fadeOut = try XCTUnwrap(strip.hoverFadeForTesting(cell) as? CABasicAnimation)
        XCTAssertEqual(fadeOut.duration, 0.12, accuracy: 0.001)

        ReduceMotion.overrideForTesting = true
        move(to: 3)
        XCTAssertNil(strip.hoverFadeForTesting(try XCTUnwrap(strip.cellViewForTesting(3))), "instant")
    }

    func testTheSameHoverShowsInFullScreenMode() {
        ReduceMotion.overrideForTesting = true
        strip.setMode(.fullscreen)
        strip.frame = NSRect(x: 0, y: 0, width: 700, height: 88)
        strip.layoutSubtreeIfNeeded()
        move(to: 2)
        XCTAssertEqual(strip.hoveredGlobalIndexForTesting, 2)
        XCTAssertEqual(look(2).ringOpacity, 1)
        XCTAssertEqual(look(2).overlayAlpha, 0.10, accuracy: 0.001)
    }

    func testTheCellTooltipIsTheFileNameWhenTheSourceIsAFile() {
        let url = URL(fileURLWithPath: "/tmp/P1250331.JPG")
        let strip2 = FilmstripView()
        strip2.updateNeighbors([(idx: 7, source: FileImageSource(url: url))], current: 7,
                               services: ShrikeServices.makeDefault())
        let cell = strip2.cellViewForTesting(7)
        XCTAssertEqual(cell?.toolTip, "P1250331.JPG")
    }
}

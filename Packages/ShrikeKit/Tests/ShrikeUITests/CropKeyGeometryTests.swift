//
//  CropKeyGeometryTests.swift
//  ShrikeUITests
//
//  Spec 28 §15 (H-3): the key table and the frame math, in image pixels.
//

import AppKit
import XCTest
@testable import ShrikeUI

final class CropKeyGeometryTests: XCTestCase {

    private let image = CGSize(width: 3000, height: 2000)
    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    private func key(_ code: Int) -> String { String(UnicodeScalar(UInt32(code))!) }

    // MARK: Key table

    func testKeyTable() {
        let left = key(NSLeftArrowFunctionKey), right = key(NSRightArrowFunctionKey)
        let up = key(NSUpArrowFunctionKey), down = key(NSDownArrowFunctionKey)
        func cmd(_ k: String, s: Bool = false, o: Bool = false, c: Bool = false, m: Bool = false) -> CropKeyCommand? {
            CropKeyCommand.command(key: k, shift: s, option: o, control: c, command: m)
        }
        XCTAssertEqual(cmd(left), .move(dx: -1, dy: 0, steps: 1))
        XCTAssertEqual(cmd(right), .move(dx: 1, dy: 0, steps: 1))
        XCTAssertEqual(cmd(up), .move(dx: 0, dy: -1, steps: 1))
        XCTAssertEqual(cmd(down, s: true), .move(dx: 0, dy: 1, steps: 10))
        XCTAssertEqual(cmd(right, o: true), .resize(.init(right: 1), steps: 1))
        XCTAssertEqual(cmd(left, o: true), .resize(.init(right: -1), steps: 1))
        XCTAssertEqual(cmd(down, o: true), .resize(.init(bottom: 1), steps: 1))
        XCTAssertEqual(cmd(up, s: true, o: true), .resize(.init(bottom: -1), steps: 10))
        XCTAssertEqual(cmd(right, o: true, c: true), .resize(.init(left: 1), steps: 1))
        XCTAssertEqual(cmd(left, o: true, c: true), .resize(.init(left: -1), steps: 1))
        XCTAssertEqual(cmd(down, s: true, o: true, c: true), .resize(.init(top: 1), steps: 10))
        XCTAssertEqual(cmd(up, o: true, c: true), .resize(.init(top: -1), steps: 1))
        XCTAssertNil(cmd(right, c: true), "a bare control + arrow is Mission Control")
        XCTAssertNil(cmd(right, m: true), "command + arrow is not ours")
        XCTAssertEqual(cmd("\r"), .done)
        XCTAssertEqual(cmd("\u{1b}"), .escape)
        XCTAssertNil(cmd("\r", s: true))
        XCTAssertNil(cmd("a"))
        XCTAssertNil(cmd(""))
    }

    // MARK: Move

    func testMoveStepsAndClamps() {
        var o = CropKeyGeometry.move(r(120, 80, 1000, 800), in: image, dx: 1, dy: 0, steps: 1)
        XCTAssertEqual(o.rect, r(121, 80, 1000, 800)); XCTAssertFalse(o.hitEdge)
        o = CropKeyGeometry.move(r(120, 80, 1000, 800), in: image, dx: 0, dy: -1, steps: 10)
        XCTAssertEqual(o.rect, r(120, 70, 1000, 800))
        o = CropKeyGeometry.move(r(5, 80, 1000, 800), in: image, dx: -1, dy: 0, steps: 10)
        XCTAssertEqual(o.rect.minX, 0); XCTAssertTrue(o.hitEdge, "cut at the left edge")
        o = CropKeyGeometry.move(r(0, 0, 1000, 800), in: image, dx: -1, dy: 0, steps: 1)
        XCTAssertEqual(o.rect, r(0, 0, 1000, 800)); XCTAssertTrue(o.hitEdge)
        o = CropKeyGeometry.move(r(1995, 1195, 1000, 800), in: image, dx: 1, dy: 1, steps: 10)
        XCTAssertEqual(o.rect, r(2000, 1200, 1000, 800)); XCTAssertTrue(o.hitEdge)
        o = CropKeyGeometry.move(r(0, 0, 3000, 2000), in: image, dx: 1, dy: 0, steps: 1)
        XCTAssertEqual(o.rect, r(0, 0, 3000, 2000), "a whole-photo frame cannot move"); XCTAssertTrue(o.hitEdge)
    }

    // MARK: Resize, no lock

    func testResizeBottomRightGrowAndShrink() {
        let start = r(100, 100, 1000, 800)
        var o = CropKeyGeometry.resize(start, in: image, edges: .init(right: 1), steps: 1, aspect: nil)
        XCTAssertEqual(o.rect, r(100, 100, 1001, 800))
        o = CropKeyGeometry.resize(start, in: image, edges: .init(bottom: -1), steps: 10, aspect: nil)
        XCTAssertEqual(o.rect, r(100, 100, 1000, 790))
        o = CropKeyGeometry.resize(start, in: image, edges: .init(left: 1), steps: 10, aspect: nil)
        XCTAssertEqual(o.rect, r(90, 100, 1010, 800), "top-left pull: the right edge stays")
        o = CropKeyGeometry.resize(start, in: image, edges: .init(top: -1), steps: 1, aspect: nil)
        XCTAssertEqual(o.rect, r(100, 101, 1000, 799))
    }

    func testResizeStopsAtThePhotoEdge() {
        var o = CropKeyGeometry.resize(r(2000, 100, 995, 800), in: image, edges: .init(right: 1), steps: 10, aspect: nil)
        XCTAssertEqual(o.rect.maxX, 3000); XCTAssertTrue(o.hitEdge)
        o = CropKeyGeometry.resize(r(2000, 100, 1000, 800), in: image, edges: .init(right: 1), steps: 1, aspect: nil)
        XCTAssertEqual(o.rect, r(2000, 100, 1000, 800)); XCTAssertTrue(o.hitEdge)
        o = CropKeyGeometry.resize(r(3, 100, 1000, 800), in: image, edges: .init(left: 1), steps: 10, aspect: nil)
        XCTAssertEqual(o.rect.minX, 0); XCTAssertTrue(o.hitEdge)
    }

    func testResizeKeepsOnePixel() {
        var o = CropKeyGeometry.resize(r(10, 10, 1, 50), in: image, edges: .init(right: -1), steps: 1, aspect: nil)
        XCTAssertEqual(o.rect, r(10, 10, 1, 50)); XCTAssertTrue(o.hitEdge)
        o = CropKeyGeometry.resize(r(10, 10, 4, 50), in: image, edges: .init(right: -1), steps: 10, aspect: nil)
        XCTAssertEqual(o.rect.width, 1); XCTAssertTrue(o.hitEdge)
    }

    // MARK: Resize, aspect lock

    func testAspectLockWidthDrivesHeight() {
        // 3:2 lock. Width +10 -> height +round(10 / 1.5) = 6.67 -> total 1010 / 1.5 = 673.33 -> 673.
        let start = r(100, 100, 1000, 667)
        let o = CropKeyGeometry.resize(start, in: image, edges: .init(right: 1), steps: 10, aspect: 1.5)
        XCTAssertEqual(o.rect.width, 1010)
        XCTAssertEqual(o.rect.height, 673)
        XCTAssertEqual(o.rect.origin, CGPoint(x: 100, y: 100), "bottom-right pull: top-left stays")
    }

    func testAspectLockHeightDrivesWidth() {
        let start = r(100, 100, 1500, 1000)
        let o = CropKeyGeometry.resize(start, in: image, edges: .init(bottom: -1), steps: 10, aspect: 1.5)
        XCTAssertEqual(o.rect.height, 990)
        XCTAssertEqual(o.rect.width, 1485)
        XCTAssertEqual(o.rect.minX, 100)
    }

    func testAspectLockTopLeftPullKeepsBottomRight() {
        let start = r(500, 500, 1500, 1000)
        let o = CropKeyGeometry.resize(start, in: image, edges: .init(left: 1), steps: 3, aspect: 1.5)
        XCTAssertEqual(o.rect.maxX, 2000)
        XCTAssertEqual(o.rect.minY, 500, "the top stays: the height follows at the bottom")
        XCTAssertEqual(o.rect.height, 1002)
        XCTAssertEqual(o.rect.width, 1503)
    }

    func testAspectLockTopEdgeKeepsTheBottom() {
        let start = r(500, 500, 1500, 1000)
        let o = CropKeyGeometry.resize(start, in: image, edges: .init(top: 1), steps: 3, aspect: 1.5)
        XCTAssertEqual(o.rect.maxY, 1500)
        XCTAssertEqual(o.rect.height, 1003)
        XCTAssertEqual(o.rect.maxX, 2005, "the width follows on the right side: 1003 x 1.5 = 1504.5, rounded up")
    }

    func testAspectLockReducesTheStepWhenTheFollowingSideWouldLeaveThePhoto() {
        // Height room: 2000 - 1990 = 10 px. Width +10 would need height +7 (fits); a frame at the bottom edge cannot grow.
        let start = r(100, 1200, 1200, 800)
        let o = CropKeyGeometry.resize(start, in: image, edges: .init(right: 1), steps: 10, aspect: 1.5)
        XCTAssertEqual(o.rect, start, "no step keeps the frame inside, so it stays")
        XCTAssertTrue(o.hitEdge)
        let o2 = CropKeyGeometry.resize(r(100, 1196, 1200, 800), in: image, edges: .init(right: 1), steps: 10, aspect: 1.5)
        XCTAssertLessThanOrEqual(o2.rect.maxY, 2000)
        XCTAssertEqual(o2.rect.width / o2.rect.height, 1.5, accuracy: 0.002)
        XCTAssertTrue(o2.hitEdge)
    }

    func testCornerHandleIncrementGrowsBothSides() {
        let start = r(100, 100, 1000, 800)
        let inc = CropKeyGeometry.resize(start, in: image, edges: CropKeyGeometry.Handle.bottomRight.edges(grow: 1), steps: 1, aspect: nil)
        XCTAssertEqual(inc.rect, r(100, 100, 1001, 801))
        let dec = CropKeyGeometry.resize(start, in: image, edges: CropKeyGeometry.Handle.topLeft.edges(grow: -1), steps: 1, aspect: nil)
        XCTAssertEqual(dec.rect, r(101, 101, 999, 799), "the dragged corner moves, the opposite corner stays")
    }

    func testEightHandlesWithTheSpecLabels() {
        XCTAssertEqual(CropKeyGeometry.Handle.allCases.map(\.label),
                       ["Top left corner", "Top edge", "Top right corner", "Right edge",
                        "Bottom right corner", "Bottom edge", "Bottom left corner", "Left edge"])
    }

    // MARK: Words and throttle

    func testValueText() {
        XCTAssertEqual(CropKeyGeometry.valueText(r(120, 80, 3000, 2000)), "3000 by 2000 pixels, left 120, top 80")
    }

    func testAnnouncementThrottle() {
        var t = AnnouncementThrottle(interval: CropKeyGeometry.announcementInterval)
        XCTAssertTrue(t.allow(at: 10))
        XCTAssertFalse(t.allow(at: 10.1))
        XCTAssertFalse(t.allow(at: 10.24))
        XCTAssertTrue(t.allow(at: 10.26))
    }
}

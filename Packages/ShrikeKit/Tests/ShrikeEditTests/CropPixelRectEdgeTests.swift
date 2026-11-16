//
//  CropPixelRectEdgeTests.swift
//  ShrikeEditTests
//
//  Audit G-1: the crop's right and bottom edges are rounded as edges, then subtracted.
//

import XCTest
@testable import ShrikeEdit

final class CropPixelRectEdgeTests: XCTestCase {

    func testRightEdgeLandsWhereTheFrameWasDrawn() throws {
        // 1000 px wide. Frame from 10.4 px to 30.8 px: edges round to 10 and 31.
        // Rounding the size alone (20.4 -> 20) would end at 30.
        let crop = CropRect(originX: 0.0104, originY: 0, width: 0.0204, height: 1)
        let rect = try XCTUnwrap(CropTool.pixelRect(crop, width: 1000, height: 100))
        XCTAssertEqual(rect.minX, 10)
        XCTAssertEqual(rect.maxX, 31)
    }

    func testBottomEdgeLandsWhereTheFrameWasDrawn() throws {
        let crop = CropRect(originX: 0, originY: 0.0104, width: 1, height: 0.0204)
        let rect = try XCTUnwrap(CropTool.pixelRect(crop, width: 100, height: 1000))
        XCTAssertEqual(rect.minY, 10)
        XCTAssertEqual(rect.maxY, 31)
    }

    func testTinyAndEdgeCropsStayInsideTheImageAndNonEmpty() throws {
        let tiny = CropRect(originX: 0.5, originY: 0.5, width: 0.0001, height: 0.0001)
        let a = try XCTUnwrap(CropTool.pixelRect(tiny, width: 100, height: 100))
        XCTAssertGreaterThanOrEqual(a.width, 1)
        XCTAssertGreaterThanOrEqual(a.height, 1)
        let atEdge = CropRect(originX: 0.5, originY: 0.5, width: 0.5, height: 0.5)
        let b = try XCTUnwrap(CropTool.pixelRect(atEdge, width: 101, height: 101))
        XCTAssertLessThanOrEqual(b.maxX, 101)
        XCTAssertLessThanOrEqual(b.maxY, 101)
    }
}

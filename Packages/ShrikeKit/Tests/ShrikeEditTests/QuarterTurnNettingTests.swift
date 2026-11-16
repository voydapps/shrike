//
//  QuarterTurnNettingTests.swift
//  ShrikeEditTests
//
//  Adjacent quarter turns that add up to a full turn are no content change
//  (`EditRecipe.hasContentChanges`). Turns split by a real crop / resize /
//  free rotation are not netted. The raw op list is never rewritten.
//

import XCTest
@testable import ShrikeEdit

final class QuarterTurnNettingTests: XCTestCase {

    private let crop = CropRect(originX: 0.25, originY: 0.1, width: 0.5, height: 0.6)
    private let l = EditOperation.rotate90(quarters: -1)
    private let r = EditOperation.rotate90(quarters: 1)

    private func changed(start: [EditOperation] = [], then more: [EditOperation]) async -> Bool {
        let recipe = EditRecipe()
        for op in start { await recipe.append(op) }
        let cp = await recipe.checkpoint()
        for op in more { await recipe.append(op) }
        return await recipe.hasContentChanges(since: cp)
    }

    func testCancellingTurnsAreNoChange() async {
        let a = await changed(then: [l, r]); XCTAssertFalse(a, "left + right")
        let b = await changed(then: [r, l]); XCTAssertFalse(b, "right + left")
        let c = await changed(then: [r, r, r, r]); XCTAssertFalse(c, "four right")
        let d = await changed(then: [l, l, l, l]); XCTAssertFalse(d, "four left")
        let e = await changed(then: [.rotate90(quarters: 2), .rotate90(quarters: 2)]); XCTAssertFalse(e, "180 + 180")
        let f = await changed(then: [.rotate90(quarters: 4)]); XCTAssertFalse(f, "one full turn")
    }

    func testIdentityStepOrColourBetweenTurnsStillNets() async {
        let identityCrop = CropRect(originX: 0, originY: 0, width: 1, height: 1)
        let a = await changed(then: [r, .crop(identityCrop), l]); XCTAssertFalse(a)
        let b = await changed(then: [r, .colorAdjust(.identity), l]); XCTAssertFalse(b)
        let c = await changed(then: [r, .colorAdjust(ColorAdjustParams(brightness: 0.3)), l])
        XCTAssertTrue(c, "the colour change is real, the turns still net")
    }

    func testTurnsSplitByARealStepStillCount() async {
        let size = ResizeSpec(width: 10, height: 10, interpolation: .lanczos, preventUpscale: false)
        let a = await changed(then: [r, .crop(crop), l]); XCTAssertTrue(a, "rotate, crop, rotate back")
        let b = await changed(then: [r, .resize(size), l]); XCTAssertTrue(b, "rotate, resize, rotate back")
        let c = await changed(then: [r, .rotate(degrees: 5), l]); XCTAssertTrue(c, "rotate, free rotate, rotate back")
    }

    func testNetQuarterTurnStillCounts() async {
        let a = await changed(then: [r]); XCTAssertTrue(a)
        let b = await changed(then: [.rotate90(quarters: 3), .rotate90(quarters: 2)]); XCTAssertTrue(b)
        let c = await changed(then: [.rotate90(quarters: 2)]); XCTAssertTrue(c)
    }

    func testSessionThatStartedWithATurn() async {
        let a = await changed(start: [r], then: [l]); XCTAssertTrue(a, "net 0 against a start of 1")
        let b = await changed(start: [r], then: [r, l]); XCTAssertFalse(b, "adds nothing")
        let c = await changed(start: [l], then: [.rotate90(quarters: 2), .rotate90(quarters: 2)])
        XCTAssertFalse(c, "a full turn added on top of a start of -1")
        let d = await changed(start: [r], then: [r, r, r]); XCTAssertTrue(d, "1 + 3 = 4 is 0, start was 1")
    }

    func testRawListIsNotRewritten() async {
        let recipe = EditRecipe()
        await recipe.append(r); await recipe.append(l)
        let ops = await recipe.snapshot()
        XCTAssertEqual(ops, [r, l])
    }
}

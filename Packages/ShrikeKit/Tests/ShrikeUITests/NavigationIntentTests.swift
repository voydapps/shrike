//
//  NavigationIntentTests.swift
//  ShrikeUITests
//
//  Exercises the synchronous main-actor intent cursor that feeds the
//  position overlay. The regression we're guarding against:
//
//    When the user rapid-fires arrow / Space, `NavTaskCoalescer` cancels
//    prior decode tasks on every keyDown. The old code derived the overlay
//    index from `NavigationController.index()`, whose cursor only advances
//    on decode success — so the counter lagged behind (or stalled at) the
//    last decode that actually landed, not where the user had intended.
//
//  These tests pin the invariant that intent commits synchronously on
//  every call, regardless of whether downstream decode tasks finish or
//  are cancelled. They deliberately avoid the real `NavigationController`
//  / `DecodeQueue` stack — the intent layer is pure logic.
//

import XCTest
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class NavigationIntentTests: XCTestCase {

    // MARK: - Stub source — reused from NavigationControllerTests pattern

    struct StubSource: ImageSource {
        let identifier: String
        var id: String { identifier }
        var displayName: String { identifier }
        var fileSize: Int64? { 0 }
        var mtime: Date? { nil }

        func loadCGImage(maxPixelSize: Int?) async throws -> CGImage {
            throw NSError(domain: "StubSource", code: -1)
        }
        func loadProperties() async throws -> ImageProperties {
            throw NSError(domain: "StubSource", code: -1)
        }
    }

    private func makeSources(_ names: [String]) -> [any ImageSource] {
        names.map { StubSource(identifier: $0) }
    }

    // MARK: - Initial state

    func testInitialState_IsEmpty() {
        let intent = NavigationIntent()
        XCTAssertTrue(intent.isEmpty)
        XCTAssertEqual(intent.count, 0)
        XCTAssertEqual(intent.currentIndex, 0)
        XCTAssertNil(intent.currentSource())
        XCTAssertNil(intent.currentTarget())
    }

    func testSetNavigation_SeedsListAndClampsIndex() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c"]), currentIndex: 2)

        XCTAssertEqual(intent.count, 3)
        XCTAssertEqual(intent.currentIndex, 2)
        XCTAssertEqual(intent.currentSource()?.id, "c")
    }

    func testSetNavigation_ClampsOutOfRangeIndex() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b"]), currentIndex: 99)
        XCTAssertEqual(intent.currentIndex, 1,
                       "overshoot should clamp to last valid index")

        intent.setNavigation(list: makeSources(["a", "b"]), currentIndex: -5)
        XCTAssertEqual(intent.currentIndex, 0,
                       "negative seed should clamp to zero")
    }

    // MARK: - Core bug fix: rapid advances commit synchronously

    func testRapidAdvanceIntents_CommitSynchronously() {
        // 20 rapid advances in a row. This is the smoking-gun test for
        // the original bug: under the pre-fix implementation the overlay
        // would stop incrementing somewhere mid-burst because cancelled
        // decode tasks never updated the cursor. Intent commits on every
        // call, so the cursor reflects the full keystroke count.
        let intent = NavigationIntent()
        intent.setNavigation(
            list: makeSources((0..<100).map { "img\($0).jpg" }),
            currentIndex: 0
        )

        var lastTarget: NavTarget?
        for _ in 0..<20 {
            lastTarget = intent.advanceIntent()
        }

        XCTAssertEqual(intent.currentIndex, 20)
        XCTAssertEqual(lastTarget?.index, 20)
        XCTAssertEqual(lastTarget?.total, 100)
        XCTAssertEqual(lastTarget?.filename, "img20.jpg")
    }

    func testRapidRetreatIntents_CommitSynchronously() {
        let intent = NavigationIntent()
        intent.setNavigation(
            list: makeSources((0..<100).map { "img\($0).jpg" }),
            currentIndex: 50
        )

        var lastTarget: NavTarget?
        for _ in 0..<10 {
            lastTarget = intent.retreatIntent()
        }

        XCTAssertEqual(intent.currentIndex, 40)
        XCTAssertEqual(lastTarget?.index, 40)
        XCTAssertEqual(lastTarget?.filename, "img40.jpg")
    }

    func testAdvanceIntent_WrapsAroundAtEnd() {
        // Mirrors `DecodeQueue.advance`'s modular wrap so the overlay
        // doesn't desync from the decoder when the user runs off the end.
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c"]), currentIndex: 2)

        let target = intent.advanceIntent()
        XCTAssertEqual(target?.index, 0)
        XCTAssertEqual(intent.currentIndex, 0)
    }

    func testRetreatIntent_WrapsAroundAtStart() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c"]), currentIndex: 0)

        let target = intent.retreatIntent()
        XCTAssertEqual(target?.index, 2)
        XCTAssertEqual(intent.currentIndex, 2)
    }

    // MARK: - Jump intent

    func testJumpIntent_InRangeCommits() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c", "d"]), currentIndex: 0)

        let target = intent.jumpIntent(to: 3)
        XCTAssertEqual(target?.index, 3)
        XCTAssertEqual(target?.filename, "d")
        XCTAssertEqual(intent.currentIndex, 3)
    }

    func testJumpIntent_OutOfRangeReturnsNilAndDoesNotMutate() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b"]), currentIndex: 0)

        XCTAssertNil(intent.jumpIntent(to: 99))
        XCTAssertEqual(intent.currentIndex, 0,
                       "out-of-range jump must leave the cursor untouched")

        XCTAssertNil(intent.jumpIntent(to: -1))
        XCTAssertEqual(intent.currentIndex, 0)
    }

    // MARK: - Empty-list guards

    func testAdvanceIntent_OnEmptyListReturnsNil() {
        let intent = NavigationIntent()
        XCTAssertNil(intent.advanceIntent())
        XCTAssertEqual(intent.currentIndex, 0)
    }

    func testRetreatIntent_OnEmptyListReturnsNil() {
        let intent = NavigationIntent()
        XCTAssertNil(intent.retreatIntent())
        XCTAssertEqual(intent.currentIndex, 0)
    }

    func testJumpIntent_OnEmptyListReturnsNil() {
        let intent = NavigationIntent()
        XCTAssertNil(intent.jumpIntent(to: 0))
    }

    // MARK: - sourceAt / currentTarget

    func testSourceAt_ReturnsCorrectSource() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c"]), currentIndex: 1)

        XCTAssertEqual(intent.sourceAt(0)?.id, "a")
        XCTAssertEqual(intent.sourceAt(1)?.id, "b")
        XCTAssertEqual(intent.sourceAt(2)?.id, "c")
        XCTAssertNil(intent.sourceAt(-1))
        XCTAssertNil(intent.sourceAt(99))
    }

    func testCurrentTarget_ReflectsCursor() {
        let intent = NavigationIntent()
        intent.setNavigation(list: makeSources(["a", "b", "c"]), currentIndex: 1)

        let target = intent.currentTarget()
        XCTAssertEqual(target?.index, 1)
        XCTAssertEqual(target?.total, 3)
        XCTAssertEqual(target?.filename, "b")
    }

    // MARK: - Mixed advance / retreat / jump bursts

    func testMixedBurst_CursorFollowsIntent() {
        // Simulates a realistic user session: advance a few, retreat a
        // few, jump around. Every operation commits immediately so the
        // overlay can paint the exact sum of keystrokes without waiting
        // on any decode.
        let intent = NavigationIntent()
        intent.setNavigation(
            list: makeSources((0..<20).map { "f\($0)" }),
            currentIndex: 5
        )

        _ = intent.advanceIntent()   // 6
        _ = intent.advanceIntent()   // 7
        _ = intent.advanceIntent()   // 8
        XCTAssertEqual(intent.currentIndex, 8)

        _ = intent.retreatIntent()   // 7
        XCTAssertEqual(intent.currentIndex, 7)

        _ = intent.jumpIntent(to: 15)
        XCTAssertEqual(intent.currentIndex, 15)

        _ = intent.advanceIntent()   // 16
        XCTAssertEqual(intent.currentIndex, 16)
    }

    // MARK: - Target fidelity

    func testAdvanceIntent_TargetCarriesCorrectFilenameAndTotal() {
        // Overlay reads `index`, `total`, `filename` from the returned
        // target. Pin the payload end-to-end so a rename in
        // `NavTarget` is caught by the tests.
        let intent = NavigationIntent()
        intent.setNavigation(
            list: makeSources(["alpha.jpg", "beta.png", "gamma.heic"]),
            currentIndex: 0
        )

        let target = intent.advanceIntent()
        XCTAssertEqual(target?.index, 1)
        XCTAssertEqual(target?.total, 3)
        XCTAssertEqual(target?.filename, "beta.png")
    }
}

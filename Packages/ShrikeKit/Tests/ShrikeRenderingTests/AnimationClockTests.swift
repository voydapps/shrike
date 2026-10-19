import AppKit
import XCTest
@testable import ShrikeRendering

@MainActor
final class AnimationClockTests: XCTestCase {
    func testLegacyClockStopsAndReleasesCallbackOnInvalidate() async throws {
        let previous = ActiveAnimationClock.mode
        ActiveAnimationClock.mode = .legacy120
        defer { ActiveAnimationClock.mode = previous }
        final class Token {}
        var token: Token? = Token(); weak let weakToken = token
        var ticks = 0
        let clock = ActiveAnimationClock(view: NSView()) { [held = token] _ in
            withExtendedLifetime(held) {}; ticks += 1; return true
        }
        token = nil
        for _ in 0..<100 { if ticks > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertGreaterThan(ticks, 0)
        clock.invalidate(); XCTAssertNil(weakToken)
        let stopped = ticks
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(ticks, stopped)
    }
    func testDisplayClockCanReleaseWithoutVisibleWindowOrTick() {
        let previous = ActiveAnimationClock.mode
        ActiveAnimationClock.mode = .displayRefresh
        defer { ActiveAnimationClock.mode = previous }
        final class Token {}
        var token: Token? = Token(); weak let weakToken = token
        let clock = ActiveAnimationClock(view: NSView()) { [held = token] _ in
            withExtendedLifetime(held) {}; XCTFail("Hidden view must not create an active animation callback"); return true
        }
        token = nil; clock.invalidate(); XCTAssertNil(weakToken)
    }
}

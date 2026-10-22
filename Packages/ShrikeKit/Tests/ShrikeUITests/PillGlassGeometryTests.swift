//
//  PillGlassGeometryTests.swift
//  ShrikeUITests
//
//  User test 4: "32 / 41 · P1250331.JPG [RAW]" showed with its first digit
//  cut. The earlier layout test ran without a window, so the pill never
//  built its glass. These run in a real window, in full screen, on the
//  glass path (macOS 26), and measure where the text really is.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class PillGlassGeometryTests: XCTestCase {

    private var window: NSWindow!

    override func setUp() async throws {
        try await super.setUp()
        Prefs.resetAll()
        HUDGlass.forceFallbackForTesting = false
    }

    override func tearDown() async throws {
        window?.close()
        Prefs.resetAll()
        try await super.tearDown()
    }

    private func makeFullScreenContent() -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = content
        content.animatesPanelFades = false
        content.navigationPositionOverlayForTesting.autoHidesOverrideForTesting = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func report(_ pill: NavigationPositionOverlayView, _ tag: String) -> String {
        pill.layoutSubtreeIfNeeded()
        let host = pill.contentHost
        let labelInPill = pill.convert(pill.labelFrameForTesting, from: host)
        return "\(tag): look=\(pill.look) pill=\(pill.frame) host=\(host.frame) hostInPill=\(pill.convert(host.bounds, from: host)) "
            + "glass=\(String(describing: pill.glassViewForTesting?.frame)) label=\(labelInPill) "
            + "textW=\(pill.labelTextForTesting.size().width) marks=\(String(describing: pill.marksFrameForTesting)) contentSuperview=\(String(describing: host.superview.map { String(describing: type(of: $0)) }))"
    }

    /// Host must always equal the pill's bounds, whatever the look and
    /// whatever string came before.
    private func hostProblem(_ pill: NavigationPositionOverlayView) -> String? {
        pill.layoutSubtreeIfNeeded()
        let host = pill.convert(pill.contentHost.bounds, from: pill.contentHost)
        if abs(host.minX) > 0.5 || abs(host.minY) > 0.5 || abs(host.width - pill.bounds.width) > 0.5
            || abs(host.height - pill.bounds.height) > 0.5 {
            return "host \(host) != pill bounds \(pill.bounds) look=\(pill.look)"
        }
        return nil
    }

    func testTheContentHostAlwaysFillsThePillAcrossLooksAndTextChanges() {
        let content = makeFullScreenContent()
        let pill = content.navigationPositionOverlayForTesting
        pill.marks = PillMarks(flagged: false, hasRAW: true, pairKind: "JPG")
        var problems: [String] = []
        func check(_ tag: String) {
            content.layoutSubtreeIfNeeded()
            if let p = hostProblem(pill) { problems.append("\(tag): \(p)") }
        }
        let steps: [(Int, Int)] = [(8, 41), (31, 41), (0, 41), (98, 180), (3, 41), (31, 41)]
        for mode in [ViewerContentView.WindowMode.fullscreen, .windowed, .fullscreen, .windowed, .fullscreen] {
            content.windowMode = mode
            check("\(mode) switch")
            for (i, t) in steps {
                pill.show(index: i, total: t, filename: "P1250331.JPG")
                pill.alphaValue = 1
                check("\(mode) \(i + 1)/\(t)")
            }
        }
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
    }


    /// On the glass path (real window, macOS 26) the text sits 10 pt in from
    /// the pill edge in pill coordinates, the host equals the glass, and a
    /// wider string never leaves a stale width behind.
    func testGlassPathTextSitsTenPointsInAndFollowsEveryWidthChange() throws {
        let content = makeFullScreenContent()
        let pill = content.navigationPositionOverlayForTesting
        pill.marks = PillMarks(hasRAW: true, pairKind: "JPG")
        var seenWidths = Set<CGFloat>()
        for (i, t) in [(8, 41), (31, 41), (0, 41), (98, 180), (8, 41), (31, 41)] {
            pill.show(index: i, total: t, filename: "P1250331.JPG")
            pill.alphaValue = 1
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(pill.look, .glass)
            let glass = try XCTUnwrap(pill.glassViewForTesting)
            XCTAssertEqual(glass.frame, pill.bounds, "glass fills the pill (\(i + 1)/\(t))")
            XCTAssertEqual(pill.contentHost.frame, pill.bounds, "host fills the pill (\(i + 1)/\(t))")
            let label = pill.convert(pill.labelFrameForTesting, from: pill.contentHost)
            XCTAssertEqual(label.minX, 10, accuracy: 0.5, "text 10 pt in (\(i + 1)/\(t))")
            let marks = try XCTUnwrap(pill.marksFrameForTesting)
            XCTAssertLessThanOrEqual(pill.convert(marks, from: pill.contentHost).maxX, pill.bounds.width - 10 + 0.5)
            // The pill is exactly as wide as its text: no stale width.
            let need = 10 + pill.labelTextForTesting.size().width + pill.marksTextWidthForTesting + 10
            XCTAssertEqual(pill.bounds.width, need, accuracy: 3, "no stale width (\(i + 1)/\(t))")
            seenWidths.insert(pill.bounds.width.rounded())
        }
        XCTAssertGreaterThan(seenWidths.count, 2, "the width really followed the text")
    }

    /// Leaving the glass pins the host to the pill: the pill that lost its
    /// first digit had a host 10 pt off and a width behind the text.
    func testTheSolidLookPinsTheHostAfterTheGlass() {
        let content = makeFullScreenContent()
        let pill = content.navigationPositionOverlayForTesting
        pill.show(index: 8, total: 41, filename: "P1250331.JPG")
        pill.alphaValue = 1
        content.layoutSubtreeIfNeeded()
        XCTAssertFalse(pill.contentHostPinnedForTesting, "inside the glass the glass places the host")
        content.windowMode = .windowed
        pill.show(index: 31, total: 41, filename: "P1250331.JPG")
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(pill.look, .solid)
        XCTAssertTrue(pill.contentHostPinnedForTesting)
        XCTAssertEqual(pill.contentHost.frame, pill.bounds)
    }
}

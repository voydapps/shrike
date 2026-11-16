//
//  MetalDeviceCheckTests.swift
//  ShrikeRenderingTests
//
//  C-1 (spec 28 §17.5): no Metal device → alert and quit, not a crash. No GPU needed.
//

import Metal
import XCTest
@testable import ShrikeRendering

@MainActor
final class MetalDeviceCheckTests: XCTestCase {

    func testNoDeviceResolvesToNil() {
        XCTAssertNil(MetalDeviceCheck.resolve { nil })
    }

    func testARealDeviceResolves() throws {
        let found = MTLCreateSystemDefaultDevice()
        try XCTSkipUnless(found != nil, "no Metal on this machine")
        let device = try XCTUnwrap(found)
        let resolved = try XCTUnwrap(MetalDeviceCheck.resolve { device })
        XCTAssertTrue(resolved.0 === device)
    }

    func testTextsMatchTheSpec() {
        XCTAssertEqual(MetalDeviceCheck.title, "This Mac can't show photos in Shrike")
        XCTAssertEqual(MetalDeviceCheck.body,
                       "Shrike needs graphics support (Metal). This Mac, or this virtual machine, does not have it. Shrike will quit.")
        XCTAssertEqual(MetalDeviceCheck.button, "Quit")
    }

    func testNoAlertUnderTestsOrCI() {
        XCTAssertEqual(MetalDeviceCheck.noticeStyle(runningTests: true, environment: [:]), .stderr)
        XCTAssertEqual(MetalDeviceCheck.noticeStyle(runningTests: false, environment: ["GITHUB_ACTIONS": "true"]), .stderr)
        XCTAssertEqual(MetalDeviceCheck.noticeStyle(runningTests: false, environment: ["GITHUB_ACTIONS": "false"]), .alert)
        XCTAssertEqual(MetalDeviceCheck.noticeStyle(runningTests: false, environment: [:]), .alert)
    }
}

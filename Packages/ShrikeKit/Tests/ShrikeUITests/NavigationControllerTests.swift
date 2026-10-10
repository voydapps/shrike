//
//  NavigationControllerTests.swift
//  ShrikeUITests
//
//  Structural tests for NavigationController — verifies index tracking,
//  empty-list error behaviour, and sourceAt lookups.  End-to-end decode
//  paths are covered by the integration tests in ShrikeCoreTests against
//  a real DecodeQueue + FileImageSource; here we only want the navigation
//  state machine to stay sane.
//

import XCTest
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import ShrikeCore
@testable import ShrikeUI

final class NavigationControllerTests: XCTestCase {

    // MARK: - Stub source

    /// Minimal stub that satisfies `ImageSource` without touching disk. The
    /// `loadCGImage` / `loadProperties` paths would never fire because we
    /// don't call advance/retreat/jump in these tests — they throw if used.
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

    // MARK: - Tests

    func testInitialState_EmptyList() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)

        let count = await nav.count()
        let index = await nav.index()
        let current = await nav.currentSource()

        XCTAssertEqual(count, 0)
        XCTAssertEqual(index, 0)
        XCTAssertNil(current)
    }

    func testSetNavigation_StoresListAndCurrentIndex() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [
            StubSource(identifier: "a"),
            StubSource(identifier: "b"),
            StubSource(identifier: "c"),
        ]

        await nav.setNavigation(list: sources, currentIndex: 1)

        let count = await nav.count()
        let index = await nav.index()
        let current = await nav.currentSource()

        XCTAssertEqual(count, 3)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(current?.id, "b")
    }

    func testSetNavigation_ClampsIndexAbove() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [
            StubSource(identifier: "a"),
            StubSource(identifier: "b"),
        ]

        // Ask for index 99 — should clamp to last.
        await nav.setNavigation(list: sources, currentIndex: 99)
        let index = await nav.index()
        XCTAssertEqual(index, 1)
    }

    func testSetNavigation_ClampsIndexBelow() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [StubSource(identifier: "a")]

        // Ask for -3 — should clamp to 0.
        await nav.setNavigation(list: sources, currentIndex: -3)
        let index = await nav.index()
        XCTAssertEqual(index, 0)
    }

    func testSourceAt_InRangeReturnsSource() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [
            StubSource(identifier: "one"),
            StubSource(identifier: "two"),
            StubSource(identifier: "three"),
        ]
        await nav.setNavigation(list: sources, currentIndex: 0)

        let s0 = await nav.sourceAt(0)
        let s2 = await nav.sourceAt(2)
        XCTAssertEqual(s0?.id, "one")
        XCTAssertEqual(s2?.id, "three")
    }

    func testSourceAt_OutOfRangeReturnsNil() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [StubSource(identifier: "only")]
        await nav.setNavigation(list: sources, currentIndex: 0)

        let miss = await nav.sourceAt(99)
        XCTAssertNil(miss)
    }

    func testAdvanceOnEmptyList_Throws() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)

        do {
            _ = try await nav.advance()
            XCTFail("Expected emptyList error")
        } catch NavigationController.Error.emptyList {
            // Pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRetreatOnEmptyList_Throws() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)

        do {
            _ = try await nav.retreat()
            XCTFail("Expected emptyList error")
        } catch NavigationController.Error.emptyList {
            // Pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testJumpToOutOfRange_Throws() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [StubSource(identifier: "x")]
        await nav.setNavigation(list: sources, currentIndex: 0)

        do {
            _ = try await nav.jump(to: 42)
            XCTFail("Expected outOfRange error")
        } catch NavigationController.Error.outOfRange {
            // Pass
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Embedded preview path

    /// `embeddedPreview(at:)` must return nil for an out-of-range index
    /// rather than throwing — this is the contract the viewer relies on
    /// to silently fall through to the ThumbnailCache bridge.
    func testEmbeddedPreview_OutOfRangeReturnsNil() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [StubSource(identifier: "x")]
        await nav.setNavigation(list: sources, currentIndex: 0)

        let preview = await nav.embeddedPreview(at: 99)
        XCTAssertNil(preview)
    }

    /// Stub source's default `loadEmbeddedPreview` returns nil (protocol
    /// extension default). Verifies that nil bubbles cleanly through
    /// NavigationController without throwing.
    func testEmbeddedPreview_StubSourceReturnsNil() async {
        let queue = DecodeQueue()
        let nav = NavigationController(queue: queue)
        let sources: [any ImageSource] = [StubSource(identifier: "x")]
        await nav.setNavigation(list: sources, currentIndex: 0)

        let preview = await nav.embeddedPreview(at: 0)
        XCTAssertNil(preview, "stub source has no preview; controller must surface nil cleanly")
    }
}

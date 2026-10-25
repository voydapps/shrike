//
//  ViewerHiddenFullResolutionTests.swift
//  ShrikeUITests
//
//  Audit MP-04: a viewer hidden by Return-to-Browser gives back its
//  full-resolution texture (60 s trim, or memory pressure); showing it
//  again re-shows the photo.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeRendering
@testable import ShrikeUI

@MainActor
final class ViewerHiddenFullResolutionTests: XCTestCase {
    private var root: URL!
    private var savedEdge = 4096
    private var savedDelay: Duration = .seconds(60)
    private var viewer: ViewerWindow?
    private var browser: BrowserWindowController?

    override func setUp() async throws {
        root = TestScratch.directory.appendingPathComponent("shrike-hiddenfull-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        savedEdge = Prefs.maxDisplayLongEdge; Prefs.maxDisplayLongEdge = 1024
        savedDelay = ViewerWindow.hiddenTrimDelay
    }

    override func tearDown() async throws {
        viewer?.close(); browser?.close()
        Prefs.maxDisplayLongEdge = savedEdge
        ViewerWindow.hiddenTrimDelay = savedDelay
        try? FileManager.default.removeItem(at: root)
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func makePairedViewer() async throws -> ViewerWindow {
        let url = root.appendingPathComponent("big.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, SaveFlowTests.image(width: 3000, height: 2000, red: 0.4), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        self.viewer = viewer
        viewer.setContentSize(NSSize(width: 800, height: 600)); viewer.contentView?.layoutSubtreeIfNeeded()
        let browser = BrowserWindowController(services: services, initialFolder: root, selecting: nil)
        self.browser = browser
        viewer.pair(with: browser)
        let shown = await until { viewer.imageViewForTesting.sourcePixelSize != nil && viewer.navCoalescer.isIdle }
        XCTAssertTrue(shown)
        return viewer
    }

    func testHiddenViewerDropsFullResolutionAfterTheTrim() async throws {
        let viewer = try await makePairedViewer()
        let view = viewer.imageViewForTesting
        view.zoomToActual()
        let full = await until { view.isShowingFullResolution }
        XCTAssertTrue(full)
        let rectBefore = view.displayedImageRectForTesting

        ViewerWindow.hiddenTrimDelay = .milliseconds(30)
        viewer.returnToBrowser()
        let dropped = await until { !view.isShowingFullResolution }
        XCTAssertTrue(dropped, "The full-resolution texture must be released while hidden")
        XCTAssertNotNil(view.sourceID, "The photo itself stays so Return is instant")
        let rectAfter = view.displayedImageRectForTesting
        XCTAssertEqual(rectAfter.width, rectBefore.width, accuracy: 1)
        XCTAssertEqual(rectAfter.height, rectBefore.height, accuracy: 1)

        // Showing the viewer again re-shows the photo (Return navigates to it),
        // so nothing is lost by having dropped the detail.
        viewer.showFromBrowser(groups: viewer.groups, startIndex: 0)
        let shown = await until { view.sourcePixelSize != nil && viewer.navCoalescer.isIdle }
        XCTAssertTrue(shown)
        XCTAssertFalse(viewer.isParkedForBrowser)
    }

    func testPressureDropsFullResolutionOfAParkedViewerAtAnyZoom() async throws {
        let viewer = try await makePairedViewer()
        let view = viewer.imageViewForTesting
        view.zoomToActual()
        let full = await until { view.isShowingFullResolution }
        XCTAssertTrue(full)
        ViewerWindow.hiddenTrimDelay = .seconds(600)
        viewer.returnToBrowser()
        viewer.navigationForTesting.decodeQueue.resources.requestOptionalRelief()
        let dropped = await until { !view.isShowingFullResolution }
        XCTAssertTrue(dropped)
    }

    func testVisibleViewerKeepsFullResolutionUnderPressure() async throws {
        let viewer = try await makePairedViewer()
        let view = viewer.imageViewForTesting
        view.zoomToActual()
        let full = await until { view.isShowingFullResolution }
        XCTAssertTrue(full)
        viewer.navigationForTesting.decodeQueue.resources.requestOptionalRelief()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(view.isShowingFullResolution)
    }

    /// Returning to the same photo after the trim emptied the decode cache keeps the
    /// picture on screen: no low-resolution stand-in is painted over it (0.2.28 showed
    /// the PREVIEW layout for 3-6 frames on every such return).
    func testReturnToTheSamePhotoAfterTheTrimPaintsNoStandIn() async throws {
        let viewer = try await makePairedViewer()
        let view = viewer.imageViewForTesting
        ViewerWindow.hiddenTrimDelay = .milliseconds(30)
        viewer.returnToBrowser()
        let parked = await until { view.isCanvasParked }
        XCTAssertTrue(parked, "the trim also parks the canvas")
        view.recordsImageAssignmentsForTesting = true
        viewer.showFromBrowser(groups: viewer.groups, startIndex: 0)
        XCTAssertFalse(view.isCanvasParked, "the canvas is restored before the window shows")
        try? await Task.sleep(for: .milliseconds(300))
        _ = await until { viewer.navCoalescer.isIdle }
        XCTAssertTrue(view.imageAssignmentLogForTesting.isEmpty,
                      "the photo on screen stays: nothing is painted over it (\(view.imageAssignmentLogForTesting.map(\.isPlaceholder)))")
        XCTAssertNotNil(view.sourceID)
        XCTAssertTrue(view.showsPhotoNotStandIn)
    }
}

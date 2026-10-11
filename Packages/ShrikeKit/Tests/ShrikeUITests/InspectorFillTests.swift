//
//  InspectorFillTests.swift
//  ShrikeUITests
//
//  UX-02 check P1 / default / P2-2: the windowed inspector fills in whatever
//  order it is opened, a new window starts with it closed, and with the RAW
//  shown it reads the RAW file.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class InspectorFillTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-inspfill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Prefs.resetAll()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
        Prefs.resetAll()
    }

    /// A small JPEG with a camera and an ISO, so the Capture rows exist.
    private func jpegData(width: Int = 160, height: Int = 120, camera: String = "TestCam") -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        let props: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: camera],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifISOSpeedRatings: [400]],
        ]
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func waitUntil(_ timeout: TimeInterval = 10, _ cond: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return true }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return cond()
    }

    private func open(_ groups: [ImageGroup]) async -> ViewerWindow {
        let window = ViewerWindow(groups: groups, startIndex: 0, services: .makeDefault())
        window.setContentSize(NSSize(width: 900, height: 600))
        _ = await waitUntil {
            window.displayedItem?.group.primary == groups[0].primary
                && window.contentRootForTesting.imageView.image != nil
                && !window.contentRootForTesting.imageView.isCurrentImagePlaceholder
        }
        return window
    }

    // MARK: P1

    func testInspectorFillsWhenTheWindowOpensWithItAlreadyShown() async throws {
        Prefs.viewerInspectorVisibleWindowed = true
        let url = dir.appendingPathComponent("A.JPG")
        try jpegData().write(to: url)
        let window = await open([ImageGroup(primary: url)])
        defer { window.close() }
        let model = window.contentRootForTesting.inspectorPanel.viewModel
        let filled = await waitUntil { !model.facts.capture.isEmpty }
        XCTAssertTrue(filled, "File and Capture rows arrive with no toggle")
        XCTAssertEqual(model.url, url)
        XCTAssertEqual(model.facts.file.first?.value, "A.JPG")
        XCTAssertTrue(model.facts.file.contains { $0.label == "Dimensions" })
        XCTAssertTrue(model.facts.capture.contains { $0.label == "Camera" })
    }

    func testInspectorKeepsFollowingNavigationAfterAFullScreenRoundTrip() async throws {
        Prefs.viewerInspectorVisibleWindowed = true
        let a = dir.appendingPathComponent("A.JPG"), b = dir.appendingPathComponent("B.JPG")
        try jpegData().write(to: a)
        try jpegData(camera: "Other").write(to: b)
        let window = await open([ImageGroup(primary: a), ImageGroup(primary: b)])
        defer { window.close() }
        let model = window.contentRootForTesting.inspectorPanel.viewModel
        let split = try XCTUnwrap(window.splitController)
        split.willEnterFullScreen()
        split.willExitFullScreen()
        window.dispatch(.nextImage)
        let moved = await waitUntil { model.url == b && model.facts.capture.contains { $0.value.contains("Other") } }
        XCTAssertTrue(moved, "the inspector follows the next photo")
    }

    // MARK: Default

    func testANewWindowStartsWithTheInspectorClosedAndRemembersTheChoice() async throws {
        XCTAssertFalse(Prefs.viewerInspectorVisibleWindowed, "fresh store: closed")
        let url = dir.appendingPathComponent("A.JPG")
        try jpegData().write(to: url)
        let first = await open([ImageGroup(primary: url)])
        XCTAssertEqual(first.splitController?.isInspectorShown, false)
        first.splitController?.setInspectorShown(true, animated: false)
        XCTAssertTrue(Prefs.viewerInspectorVisibleWindowed, "the choice is remembered")
        first.close()
        let second = await open([ImageGroup(primary: url)])
        defer { second.close() }
        XCTAssertEqual(second.splitController?.isInspectorShown, true)
    }

    // MARK: P2-2

    func testInspectorFollowsTheRAWWhileItIsShown() async throws {
        let jpeg = dir.appendingPathComponent("P1.JPG"), raw = dir.appendingPathComponent("P1.ORF")
        try jpegData(width: 160, height: 120, camera: "JpgCam").write(to: jpeg)
        try jpegData(width: 320, height: 240, camera: "RawCam").write(to: raw)
        let pair = ImageGroup(primary: jpeg, companions: [.init(url: raw, kind: .raw)])
        let window = await open([pair])
        defer { window.close() }
        window.contentRootForTesting.inspectorPanel.headerReadsEnabled = true
        let model = window.contentRootForTesting.inspectorPanel.viewModel
        let onJPG = await waitUntil { model.url == jpeg && model.facts.capture.contains { $0.value.contains("JpgCam") } }
        XCTAssertTrue(onJPG)

        window.perform(.toggleRAWFile)
        let onRAW = await waitUntil { model.url == raw && model.facts.capture.contains { $0.value.contains("RawCam") } }
        XCTAssertTrue(onRAW, "name, facts and EXIF follow the RAW")
        XCTAssertEqual(model.facts.file.first?.value, "P1.ORF")
        XCTAssertTrue(model.facts.file.contains { $0.label == "Dimensions" && $0.value.contains("320") })

        window.perform(.toggleRAWFile)
        let back = await waitUntil { model.url == jpeg && model.facts.capture.contains { $0.value.contains("JpgCam") } }
        XCTAssertTrue(back, "and back to the JPEG")
    }
}

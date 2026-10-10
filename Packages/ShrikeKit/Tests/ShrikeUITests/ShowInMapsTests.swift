//
//  ShowInMapsTests.swift
//  ShrikeUITests
//
//  Image ▸ Show in Maps is enabled only when the photo has
//  GPS (viewer and Browser), opens Maps at a signed coordinate (33.86° S
//  is a negative latitude), and the key on a photo without GPS shows
//  "This photo has no location." Maps is never opened: `openURL` records.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ShowInMapsTests: XCTestCase {

    private var dir: URL!
    private var opened: [URL] = []
    private var savedOpenURL: ((URL) -> Void)!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shrike-maps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        opened = []
        savedOpenURL = ShowInMaps.openURL
        ShowInMaps.openURL = { [weak self] in self?.opened.append($0) }
    }

    override func tearDown() async throws {
        ShowInMaps.openURL = savedOpenURL
        try? FileManager.default.removeItem(at: dir)
    }

    /// A small JPEG; `gps` = (latitude, longitude), signed.
    private func writeJPEG(_ name: String, gps: (Double, Double)? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        var props: [CFString: Any] = [:]
        if let (lat, lon) = gps {
            props[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: abs(lat),
                kCGImagePropertyGPSLatitudeRef: lat < 0 ? "S" : "N",
                kCGImagePropertyGPSLongitude: abs(lon),
                kCGImagePropertyGPSLongitudeRef: lon < 0 ? "W" : "E",
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func viewer(_ url: URL) async -> ViewerWindow {
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        viewer.markDisplayedForTesting(0)
        await viewer.locationLookup?.value
        return viewer
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: URL

    func testSydneyOpensAtANegativeLatitude() throws {
        let file = URL(fileURLWithPath: "/tmp/Harbour Bridge.jpg")
        let url = try XCTUnwrap(ShowInMaps.url(for: .init(latitude: -33.86, longitude: 151.21), file: file))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(url.host, "maps.apple.com")
        XCTAssertEqual(items.first { $0.name == "ll" }?.value, "-33.860000,151.210000")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "Harbour Bridge.jpg")
    }

    // MARK: Viewer

    func testViewerEnabledWithGPSAndOpensMaps() async throws {
        let url = try writeJPEG("sydney.jpg", gps: (-33.86, 151.21))
        let viewer = await viewer(url)
        defer { viewer.close() }
        XCTAssertEqual(viewer.displayedCoordinate?.latitude ?? 0, -33.86, accuracy: 0.0001)
        XCTAssertTrue(viewer.canPerform(.showInMaps))
        viewer.perform(.showInMaps)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.absoluteString.contains("ll=-33.860000,151.210000") ?? false,
                      "\(opened)")
    }

    func testViewerDisabledWithoutGPSAndKeyShowsToast() async throws {
        let url = try writeJPEG("plain.jpg")
        let viewer = await viewer(url)
        defer { viewer.close() }
        XCTAssertNotNil(viewer.displayedLocation, "the header was read")
        XCTAssertFalse(viewer.canPerform(.showInMaps))

        // The key (not the disabled menu item) runs the action.
        let action = ViewerKeyMap.action(for: KeyEventSnapshot(key: "m", modifiers: [.control, .command]),
                                         context: .viewer, preset: .macNative)
        XCTAssertEqual(action, .showInMaps)
        viewer.dispatch(.showInMaps)
        await viewer.locationLookup?.value
        XCTAssertEqual(viewer.contentRootForTesting.toastHost.content?.message, "This photo has no location.")
        XCTAssertTrue(opened.isEmpty)
    }

    func testViewerKeyBeforeTheReadStillWorks() async throws {
        let url = try writeJPEG("early.jpg", gps: (45.4371, 12.3327))
        var services = ShrikeServices.makeDefault()
        services.backupStore = nil
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: services)
        defer { viewer.close() }
        viewer.markDisplayedForTesting(0)
        XCTAssertFalse(viewer.canPerform(.showInMaps), "not read yet: disabled")
        viewer.dispatch(.showInMaps)
        await viewer.locationLookup?.value
        XCTAssertEqual(opened.count, 1)
    }

    // MARK: Browser

    func testBrowserEnabledOnlyForOneItemWithGPS() async throws {
        let sydney = try writeJPEG("a-sydney.jpg", gps: (-33.86, 151.21))
        let plain = try writeJPEG("b-plain.jpg")
        let browser = BrowserWindowController(services: ShrikeServices.makeDefault(), initialFolder: dir)
        defer { browser.close() }
        _ = await waitUntil { browser.contentController.visibleItems.count == 2 }

        XCTAssertTrue(browser.contentController.select(urls: [plain]))
        browser.updateInspectorFromSelection()
        await browser.waitForInspectorInfo()
        XCTAssertFalse(browser.canPerform(.showInMaps), "no GPS")

        XCTAssertTrue(browser.contentController.select(urls: [sydney]))
        browser.updateInspectorFromSelection()
        await browser.waitForInspectorInfo()
        XCTAssertTrue(browser.canPerform(.showInMaps))
        browser.perform(.showInMaps)
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first?.absoluteString.contains("ll=-33.860000") ?? false)

        XCTAssertTrue(browser.contentController.select(urls: [sydney, plain]))
        browser.updateInspectorFromSelection()
        XCTAssertFalse(browser.canPerform(.showInMaps), "two items: disabled")
    }

    // MARK: Inspector

    func testInspectorFactsCarryTheCoordinate() throws {
        var info = PhotoInfo()
        info.gps = .init(latitude: -33.86, longitude: 151.21)
        let facts = InspectorRows.facts(url: URL(fileURLWithPath: "/tmp/x.jpg"), fileSize: nil, info: info)
        XCTAssertNotNil(facts.location)
        XCTAssertEqual(facts.coordinate, info.gps, "the Show in Maps link has the coordinate")
    }
}

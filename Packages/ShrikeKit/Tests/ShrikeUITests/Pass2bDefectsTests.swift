//
//  Pass2bDefectsTests.swift
//  ShrikeUITests
//
//  Defects found by pass 2a: the Keyboard Shortcuts window's Settings… link,
//  the histogram's per-corner tooltip and VoiceOver labels, and the names of
//  the viewer toolbar's groups.
//

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class Pass2bDefectsTests: XCTestCase {

    // MARK: Settings… link in the Keyboard Shortcuts window

    func testShortcutsWindowSettingsLinkIsWiredWhenTheAppSetsItsSettingsCommand() {
        let commands = AppCommands(coordinator: WindowCoordinator.shared)
        let saved = ShortcutsWindowController.openSettings
        defer { ShortcutsWindowController.openSettings = saved }
        ShortcutsWindowController.openSettings = nil
        var opened: [PreferencesTab?] = []
        commands.onShowSettings = { opened.append($0) }
        XCTAssertNotNil(ShortcutsWindowController.openSettings, "set as soon as the app wires its Settings command")
        ShortcutsWindowController.openSettings?()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened.first, .some(.shortcuts))
        // The Settings… item of the app menu goes to the same command (no tab).
        commands.showSettings(nil)
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(opened.last, .some(nil))
    }

    // MARK: Histogram corners

    private func bins(_ values: [Int: UInt32]) -> [UInt32] {
        var out = [UInt32](repeating: 0, count: 256)
        for (i, v) in values { out[i] = v }
        return out
    }

    /// 7.9 % pure black, 19 % pure white.
    private func litState() -> HistogramDisplayState {
        let data = HistogramData(red: bins([:]), green: bins([:]), blue: bins([:]),
                                 luminance: bins([0: 79, 128: 731, 255: 190]),
                                 pixelCount: 1000, sampleWidth: 10, sampleHeight: 100,
                                 anyChannelShadowPixels: 79, anyChannelHighlightPixels: 190)
        return HistogramDisplayState(data: data)
    }

    func testEachCornerHasItsOwnTooltipAndVoiceOverLabel() throws {
        let view = HistogramPlotView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        view.state = litState()
        let bounds = view.bounds
        XCTAssertEqual(HistogramPlotView.cornerTooltip(at: NSPoint(x: 20, y: 90), in: bounds, state: view.state),
                       "7.9 % of the pixels are pure black.")
        XCTAssertEqual(HistogramPlotView.cornerTooltip(at: NSPoint(x: 300, y: 90), in: bounds, state: view.state),
                       "19 % of the pixels are pure white.")
        XCTAssertEqual(view.view(view, stringForToolTip: 0, point: NSPoint(x: 20, y: 90), userData: nil),
                       "7.9 % of the pixels are pure black.")
        XCTAssertNil(view.toolTip, "no sentence on the whole plot")

        let labels = (view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertEqual(labels, ["Pure black pixels: 7.9 percent", "Pure white pixels: 19 percent"])
    }

    func testAnUnlitCornerHasNoTooltipOrLabel() {
        let view = HistogramPlotView(frame: NSRect(x: 0, y: 0, width: 320, height: 100))
        let data = HistogramData(red: bins([:]), green: bins([:]), blue: bins([:]),
                                 luminance: bins([128: 1000]), pixelCount: 1000, sampleWidth: 10, sampleHeight: 100,
                                 anyChannelShadowPixels: 0, anyChannelHighlightPixels: 190)
        view.state = HistogramDisplayState(data: data)
        XCTAssertNil(HistogramPlotView.cornerTooltip(at: NSPoint(x: 20, y: 5), in: view.bounds, state: view.state))
        XCTAssertEqual(view.accessibilityChildren()?.count, 1)
        view.state = HistogramDisplayState()
        XCTAssertEqual(view.accessibilityChildren()?.count, 0)
    }

    func testTheLevelsPanelKeepsItsNumberOnlyCorners() {
        XCTAssertTrue(HistogramPlotView().showsCornerWords, "the HUD and the inspector band show the words")
        XCTAssertEqual(HistogramPlot.cornerText(.black, percent: 7.9, hudWidth: 0), "7.9 %",
                       "hudWidth 0 (the Levels panel) draws the bare number")
    }

    // MARK: Toolbar group names

    private func writeJPEG(in dir: URL) -> URL {
        let url = dir.appendingPathComponent("p.jpg")
        let ctx = CGContext(data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return url
    }

    func testToolbarGroupsAreNamedInTheBuiltToolbar() async throws {
        let dir = TestScratch.directory.appendingPathComponent("shrike-grpname-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let savedHidden = Prefs.viewerToolbarAutoHide
        Prefs.viewerToolbarAutoHide = false
        defer { Prefs.viewerToolbarAutoHide = savedHidden }
        let window = ViewerWindow(groups: [ImageGroup(primary: writeJPEG(in: dir))], startIndex: 0,
                                  services: ShrikeServices.makeDefault())
        defer { window.close() }
        window.setContentSize(NSSize(width: 1100, height: 600))
        let bar = try XCTUnwrap(window.toolbarController)
        bar.toolbar.autosavesConfiguration = false
        bar.toolbar.isVisible = true
        while !bar.toolbar.items.isEmpty { bar.toolbar.removeItem(at: 0) }
        for (index, id) in ViewerWindowToolbar.defaultItems.enumerated() {
            bar.toolbar.insertItem(withItemIdentifier: id, at: index)
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        bar.validate()
        try await Task.sleep(nanoseconds: 100_000_000)

        // The group item has no view of its own; the segmented control AppKit built is named.
        func controls(in view: NSView) -> [NSSegmentedControl] {
            (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(controls)
        }
        let found = controls(in: try XCTUnwrap(window.contentView?.superview))
        for (first, name) in [("Previous", "Photo navigation"), ("Rotate Left", "Rotate photo")] {
            let control = try XCTUnwrap(found.first { $0.image(forSegment: 0)?.accessibilityDescription == first },
                                        "the built toolbar has the \(first) group")
            XCTAssertEqual(control.accessibilityLabel(), name)
            XCTAssertEqual(control.accessibilityRole(), .group)
        }
    }
}

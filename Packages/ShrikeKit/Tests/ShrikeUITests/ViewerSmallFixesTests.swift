//
//  ViewerSmallFixesTests.swift
//  ShrikeUITests
//
//  Small viewer fixes: centred fill on the colour sliders; the histogram
//  fits the canvas and stays clear of the edit panel; the full-screen
//  bottom stack stays while the pointer rests in its zone, the corner
//  never reveals the inspector, never two histograms; the tool picker shows the
//  active tool; no icon column in the viewer's right-click menu; the
//  window stays put across edit -> Don't Save -> slideshow sheet; every
//  shortcut key shows a real Mac key symbol.
//

import AppKit
import CoreText
import XCTest
import ShrikeCore
@testable import ShrikeUI

@MainActor
final class ViewerSmallFixesTests: XCTestCase {

    private var dir: URL!
    private var savedHistogram: Bool = false

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("A2sPolish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedHistogram = Prefs.viewerHistogramVisible
        for key in ["shrike.viewer.filmstrip.pinnedFullscreen",
                    "shrike.viewer.exifPanel.pinnedFullscreen"] {
            ShrikeDefaults.store.removeObject(forKey: key)
        }
    }

    override func tearDown() async throws {
        Prefs.viewerHistogramVisible = savedHistogram
        SlideshowSheet.responderForTesting = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func viewer(size: NSSize = NSSize(width: 900, height: 600)) throws -> ViewerWindow {
        let url = dir.appendingPathComponent("a.jpg")
        try SaveFlowTests.writeImage(url, type: .jpeg)
        let viewer = ViewerWindow(groups: [ImageGroup(primary: url)], startIndex: 0, services: .makeDefault())
        viewer.setContentSize(size)
        viewer.markDisplayedForTesting(0)
        return viewer
    }

    // MARK: 2.1 Colour sliders

    func testColourSlidersFillFromTheCentre() {
        let panel = ColorAdjustPanel()
        XCTAssertEqual(panel.slidersForTesting.count, 4)
        for slider in panel.slidersForTesting {
            XCTAssertTrue(slider.cell is CentredFillSliderCell, "\(slider.accessibilityLabel() ?? "") fills from 0")
        }
        let travel: ClosedRange<CGFloat> = 0...100
        func span(_ v: Double) -> ClosedRange<CGFloat> {
            CentredFillSliderCell.fillSpan(value: v, origin: 0, minValue: -1, maxValue: 1, travel: travel)
        }
        XCTAssertEqual(span(0), 50...50, "no change: no fill")
        XCTAssertEqual(span(0.5), 50...75)
        XCTAssertEqual(span(-1), 0...50, "a minus value fills left of the centre")
        let hue = CentredFillSliderCell.fillSpan(value: 90, origin: 0, minValue: -180, maxValue: 180, travel: travel)
        XCTAssertEqual(hue, 50...75)
    }

    // MARK: 2.2 Histogram size and place

    func testHistogramFitsASmallCanvasAndIsFullSizeInABigOne() throws {
        Prefs.viewerHistogramVisible = true
        let small = try viewer(size: NSSize(width: 800, height: 550))
        defer { small.close() }
        let content = small.contentRootForTesting
        content.layoutSubtreeIfNeeded()
        let canvas = content.imageView.frame
        let frame = content.histogramOverlayFrameForTesting()
        XCTAssertLessThanOrEqual(frame.width, canvas.width * 0.22 + 0.5, "at most 22 % of the width")
        XCTAssertLessThanOrEqual(frame.height, canvas.height * 0.3 + 0.5)
        XCTAssertGreaterThanOrEqual(frame.width, 132 - 0.5)
        XCTAssertEqual(frame.height / frame.width, 180.0 / 320.0, accuracy: 0.01, "same shape")
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)

        // A window too small for the cap keeps its size (the cap gives way).
        let tiny = try viewer(size: NSSize(width: 500, height: 400))
        defer { tiny.close() }
        tiny.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(tiny.contentRect(forFrameRect: tiny.frame).size, NSSize(width: 500, height: 400))
        XCTAssertGreaterThanOrEqual(tiny.contentRootForTesting.histogramOverlayFrameForTesting().width, 132 - 0.5)

        let big = try viewer(size: NSSize(width: 1800, height: 1200))
        defer { big.close() }
        big.contentRootForTesting.layoutSubtreeIfNeeded()
        XCTAssertEqual(big.contentRootForTesting.histogramOverlayFrameForTesting().size,
                       HistogramOverlayView.size, "a big canvas keeps 320 x 180")
    }

    /// Under a 600 pt wide canvas the histogram hides; the
    /// setting and the toggle stay on; it comes back when the window grows.
    func testHistogramHidesInASmallCanvasAndReturnsWhenTheWindowGrows() throws {
        Prefs.viewerHistogramVisible = true
        let viewer = try viewer(size: NSSize(width: 520, height: 420))
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        viewer.contentView?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(content.imageView.frame.width, 0)
        XCTAssertLessThan(content.imageView.frame.width, ViewerContentView.histogramMinimumCanvas.width)
        XCTAssertFalse(content.histogramOverlayVisibleForTesting, "hidden in a small canvas")
        XCTAssertTrue(content.isHistogramShown, "the toggle stays on")
        XCTAssertTrue(Prefs.viewerHistogramVisible)

        viewer.setContentSize(NSSize(width: 900, height: 600))
        viewer.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "back when the window grows")
        let frame = content.histogramOverlayFrameForTesting()
        XCTAssertLessThanOrEqual(frame.width, content.imageView.frame.width * 0.36 - 112 + 0.5)

        viewer.setContentSize(NSSize(width: 560, height: 600))
        viewer.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(content.histogramOverlayVisibleForTesting, "hides again when it shrinks")
    }

    /// Spec 27 V3: in edit mode the histogram docks in the tool column (below the
    /// panel, 280 wide, 16 pt from the edge), so it never sits over the photo.
    func testHistogramDocksInTheEditColumn() throws {
        Prefs.viewerHistogramVisible = true
        let viewer = try viewer(size: NSSize(width: 1000, height: 700))
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .color)
        content.layoutSubtreeIfNeeded()
        let panel = content.editModeController.parameterPanel.frame
        let histogram = content.histogramOverlayFrameForTesting()
        XCTAssertFalse(panel.isEmpty)
        XCTAssertEqual(histogram.maxX, content.bounds.maxX - 16, accuracy: 0.5, "16 pt from the right edge")
        XCTAssertEqual(histogram.width, EditParameterPanel.panelWidth, accuracy: 0.5, "the panel's width")
        XCTAssertFalse(histogram.intersects(panel), "below the panel")
        XCTAssertGreaterThanOrEqual(histogram.minX, content.imageView.drawnImageRect.maxX, "never over the photo")
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "the Color panel leaves room")
        content.editModeController.finalizeExit()
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.histogramOverlayFrameForTesting().maxX, content.bounds.maxX - 16, accuracy: 0.5,
                       "back at the right edge after edit mode")
    }

    // MARK: 2.3 Full-screen chrome

    private func fullScreenContent() -> (NSWindow, ViewerContentView) {
        let content = ViewerContentView(services: .makeDefault())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = content
        content.animatesPanelFades = false
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()
        return (window, content)
    }

    /// Spec 24 §1.2 (UX-02 P2-1): the old rule kept the stack for as long as
    /// the pointer rested at the bottom edge. It now fades after the idle
    /// delay, and a move in the zone brings it back.
    func testTheBottomStackFadesWhileThePointerRestsAtTheBottomEdgeAndReturnsOnMove() {
        let (window, content) = fullScreenContent()
        defer { window.close() }
        let edge = NSPoint(x: 720, y: 0)
        content.cursorLocationOverrideForTesting = edge
        content.evaluateZonesForTesting(at: edge)
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip))
        XCTAssertTrue(content.isHoveredForTesting(.toolbar))
        content.forceIdleFireForTesting()
        XCTAssertFalse(content.isHoveredForTesting(.filmstrip), "faded: the pointer rests below the strip")
        XCTAssertFalse(content.isHoveredForTesting(.toolbar))
        // Moving inside the zone brings the stack back.
        let moved = NSPoint(x: 730, y: 2)
        content.cursorLocationOverrideForTesting = moved
        content.evaluateZonesForTesting(at: moved)
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip), "a move in the zone reveals again")
        XCTAssertTrue(content.isHoveredForTesting(.toolbar))
    }

    func testOnlyTheRightEdgeRevealsTheInspector() {
        let (window, content) = fullScreenContent()
        defer { window.close() }
        content.evaluateZonesForTesting(at: NSPoint(x: 1435, y: 10))
        XCTAssertTrue(content.isHoveredForTesting(.filmstrip), "the bottom corner is the bottom zone")
        XCTAssertFalse(content.isHoveredForTesting(.inspector), "the corner never slides the inspector in")
        XCTAssertFalse(ViewerContentView.zonePanels(at: NSPoint(x: 5, y: 450), in: content.bounds).contains(.inspector))
        XCTAssertEqual(ViewerContentView.zonePanels(at: NSPoint(x: 1435, y: 450), in: content.bounds), [.inspector])
    }

    /// Spec 24 §1.3: the floating histogram steps aside while the HUD
    /// inspector shows (it has the same graph) and comes back after.
    func testFullScreenHistogramStepsAsideWhileTheInspectorShows() {
        Prefs.viewerHistogramVisible = true
        let (window, content) = fullScreenContent()
        defer { window.close() }
        content.kickIdleTimer()
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 450))
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        content.evaluateZonesForTesting(at: NSPoint(x: 1435, y: 450))
        XCTAssertTrue(content.isHoveredForTesting(.inspector))
        XCTAssertFalse(content.histogramOverlayVisibleForTesting, "hidden while the inspector shows")
        XCTAssertTrue(Prefs.viewerHistogramVisible, "the setting is untouched")
        content.cursorLocationOverrideForTesting = NSPoint(x: 720, y: 450)
        content.evaluateZonesForTesting(at: NSPoint(x: 720, y: 450))
        content.forceExitGraceFireForTesting(.inspector)
        XCTAssertTrue(content.histogramOverlayVisibleForTesting, "back when the inspector hides")
    }

    // MARK: 2.4 Tool picker

    func testThePickerShowsTheActiveTool() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        let content = viewer.contentRootForTesting
        let picker = content.editToolbarController.toolPicker
        XCTAssertEqual(picker.selectedSegment, -1, "nothing lit outside edit mode")
        content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .crop)
        XCTAssertEqual(picker.selectedSegment, 0)
        content.editModeController.selectTool(.color)
        XCTAssertEqual(picker.selectedSegment, 3, "follows the chosen tool")
        content.editModeController.finalizeExit()
        XCTAssertEqual(picker.selectedSegment, -1)
    }

    // MARK: 2.5 Right-click menu

    func testViewerRightClickMenuHasNoIconColumn() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        viewer.contextMenu.prepareForTesting()
        let menu = viewer.contextMenu.menu
        XCTAssertFalse(menu.items.isEmpty)
        // One image in a group gives that whole group an icon column (the
        // old standard Share item did this to the first group).
        for item in menu.items {
            XCTAssertNil(item.image, "\(item.title) carries no image, so every group lines up")
        }
    }

    // MARK: 2.6 Window position

    func testTheWindowStaysPutAcrossEditDontSaveAndTheSlideshowSheet() throws {
        let viewer = try viewer()
        defer { viewer.close() }
        viewer.setFrameOrigin(NSPoint(x: 680, y: 400))
        for toolbarShown in [false, true] {
            viewer.toolbar?.isVisible = toolbarShown
            let before = viewer.frame
            let content = viewer.contentRootForTesting
            content.enterEditMode(image: SaveFlowTests.image(), url: nil, landOn: .rotate)
            content.editModeController.finalizeExit()   // Don't Save
            var asked = false
            SlideshowSheet.responderForTesting = { _, _ in asked = true; return nil }
            viewer.startSlideshow()
            XCTAssertTrue(asked)
            XCTAssertEqual(viewer.frame.origin, before.origin, "toolbar shown: \(toolbarShown)")
            XCTAssertEqual(viewer.frame.size, before.size, "toolbar shown: \(toolbarShown)")
        }
    }

    // MARK: 2.7 Key symbols

    func testEveryShortcutKeyShowsAMacKeySymbol() {
        let font = NSFont.systemFont(ofSize: ShortcutsTab.keysFontSize) as CTFont
        for preset in [ShortcutPreset.macNative, .fastStoneCompat] {
            for row in ShortcutTable.rows(for: preset) {
                let text = row.binding.displayString
                XCTAssertFalse(text.isEmpty, "\(row.command) in \(preset)")
                XCTAssertFalse(text.contains("•"), "\(row.command): \(text)")
                for scalar in text.unicodeScalars {
                    XCTAssertFalse((0xE000...0xF8FF).contains(scalar.value),
                                   "\(row.command): a raw function-key code point is shown")
                    XCTAssertFalse(scalar.properties.generalCategory == .control, "\(row.command): control char")
                    // The Settings column's font (or its fallback) draws it.
                    let one = String(scalar) as CFString
                    let used = CTFontCreateForString(font, one, CFRange(location: 0, length: CFStringGetLength(one)))
                    let name = CTFontCopyPostScriptName(used) as String
                    XCTAssertFalse(name.contains("LastResort"), "\(row.command): no glyph for \(scalar)")
                }
            }
        }
        XCTAssertEqual(KeyBinding(SpecialKey.pageUp).displayString, "Page Up")
        XCTAssertEqual(KeyBinding(SpecialKey.pageDown).displayString, "Page Down")
        XCTAssertEqual(KeyBinding("\t").displayString, "⇥")
    }
}

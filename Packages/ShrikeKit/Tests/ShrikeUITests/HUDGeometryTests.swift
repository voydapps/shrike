//
//  HUDGeometryTests.swift
//  ShrikeUITests
//
//  Float geometry
//  (no two HUDs touch, 12 pt gaps), radii / shadow / clipping and the
//  `.hudWindow` grep gate.
//

import AppKit
import XCTest
@testable import ShrikeCore
@testable import ShrikeUI

@MainActor
final class HUDGeometryTests: XCTestCase {

    private let keys = [
        "shrike.viewer.filmstrip.pinnedFullscreen",
        "shrike.viewer.editRail.pinnedFullscreen",
        "shrike.viewer.exifPanel.pinnedFullscreen",
        "shrike.viewer.histogramVisible",
    ]

    override func setUp() {
        super.setUp()
        for key in keys { ShrikeDefaults.store.removeObject(forKey: key) }
        HUDGlass.forceFallbackForTesting = false
        ShrikeTokens.increaseContrastOverride = false
    }

    override func tearDown() {
        HUDGlass.forceFallbackForTesting = false
        ShrikeTokens.increaseContrastOverride = nil
        for key in keys { ShrikeDefaults.store.removeObject(forKey: key) }
        super.tearDown()
    }

    private func makeContent(_ size: NSSize, mode: ViewerContentView.WindowMode = .fullscreen) -> ViewerContentView {
        let content = ViewerContentView(services: .makeDefault())
        content.frame = CGRect(origin: .zero, size: size)
        content.animatesPanelFades = false
        content.windowMode = mode
        content.layoutSubtreeIfNeeded()
        return content
    }

    private func showAll(_ content: ViewerContentView) {
        content.togglePanel(.filmstrip)   // strip + capsule
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
        _ = content.histogramOverlayFrameForTesting()
        if let histogram = content.histogramOverlayIfBuiltForTesting {
            histogram.isHidden = false
            histogram.alphaValue = 1
        }
        let pill = content.navigationPositionOverlayForTesting
        pill.show(index: 3, total: 40, filename: "IMG_0001.jpg")
        pill.isHidden = false
        pill.alphaValue = 1
        content.layoutSubtreeIfNeeded()
    }

    private func hideAll(_ content: ViewerContentView) {
        content.togglePanel(.filmstrip)
        content.togglePanel(.editRail)
        content.togglePanel(.inspector)
    }

    // MARK: V6

    func testV6_NoTwoHUDsTouchAndTheGapsAre12() {
        for size in [NSSize(width: 2560, height: 1440), NSSize(width: 1280, height: 800)] {
            for fallback in [false, true] {
                HUDGlass.forceFallbackForTesting = fallback
                let content = makeContent(size)
                showAll(content)
                let strip = content.filmstripForTesting.frame
                let capsule = content.capsuleFrameForTesting
                let rail = content.editRailForTesting.frame
                let inspector = content.inspectorForTesting.frame
                let pill = content.pillFrameForTesting
                let histogram = content.histogramOverlayFrameForTesting()
                let named: [(String, NSRect)] = [
                    ("strip", strip), ("capsule", capsule), ("rail", rail),
                    ("inspector", inspector), ("pill", pill), ("histogram", histogram),
                ]
                let label = "\(Int(size.width)) fallback=\(fallback)"
                for i in 0..<named.count {
                    for j in (i + 1)..<named.count {
                        let a = named[i], b = named[j]
                        XCTAssertFalse(a.1.insetBy(dx: -11.5, dy: -11.5).intersects(b.1),
                                       "\(a.0) \(a.1) vs \(b.0) \(b.1) closer than 12 pt (\(label))")
                    }
                }
                XCTAssertEqual(strip.minX, 12, accuracy: 0.5, label)
                XCTAssertEqual(strip.minY, 12, accuracy: 0.5, label)
                XCTAssertEqual(size.width - strip.maxX, 12, accuracy: 0.5, label)
                XCTAssertLessThanOrEqual(inspector.minY, strip.maxY + 100_000)
                XCTAssertGreaterThanOrEqual(inspector.minY, strip.maxY + 12 - 0.5,
                                            "inspector ends 12 pt above the strip (\(label))")
                XCTAssertEqual(pill.minX, 12, accuracy: 0.5, label)
                XCTAssertEqual(rail.minX, 12, accuracy: 0.5, label)
                XCTAssertEqual(size.width - inspector.maxX, 12, accuracy: 0.5, label)
                hideAll(content)
            }
        }
    }

    func testV6_WithoutTheStripTheInspectorBottomClearanceIs12() {
        let content = makeContent(NSSize(width: 1440, height: 900))
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(content.inspectorForTesting.frame.minY, 12, accuracy: 0.5)
        content.togglePanel(.inspector)
    }

    /// The inspector is as tall as its content
    /// (header + content), hangs from the top, and is capped by the room.
    func testV6_InspectorHeightFollowsContentAndIsCapped() {
        let content = makeContent(NSSize(width: 1440, height: 900))
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()
        let inspector = content.inspectorForTesting
        let top = inspector.frame.maxY
        // Not measured yet: it fills the room (nothing stale or tiny).
        XCTAssertEqual(inspector.frame.minY, 12, accuracy: 0.5)
        inspector.applyContentHeight(300)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(inspector.frame.height, InspectorPanel.headerHeight + 300, accuracy: 0.5)
        XCTAssertEqual(inspector.frame.maxY, top, accuracy: 0.5, "hangs from the top")
        // Taller than the room: capped, the content scrolls.
        inspector.applyContentHeight(5000)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(inspector.frame.minY, 12, accuracy: 0.5)
        XCTAssertEqual(inspector.frame.maxY, top, accuracy: 0.5)
        // With the strip shown the cap is the strip top - 12.
        content.togglePanel(.filmstrip)
        content.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(inspector.frame.minY, content.filmstripForTesting.frame.maxY + 12 - 0.5)
        content.togglePanel(.filmstrip)
        content.togglePanel(.inspector)
    }

    /// V7: ⌃H toggles the histogram in the default (Mac) preset too.
    func testV7_ControlHTogglesTheHistogramInBothPresets() {
        let snap = KeyEventSnapshot(key: "h", modifiers: .control)
        for preset in [ShortcutPreset.macNative, ShortcutPreset.fastStoneCompat] {
            XCTAssertEqual(ViewerKeyMap.action(for: snap, context: .viewer, preset: preset), .toggleHistogram,
                           "\(preset)")
        }
    }

    func testV6_WindowFloatInsetsAre16() {
        let content = makeContent(NSSize(width: 1440, height: 900), mode: .windowed)
        _ = content.histogramOverlayFrameForTesting()
        content.layoutSubtreeIfNeeded()
        let histogram = content.histogramOverlayFrameForTesting()
        XCTAssertEqual(1440 - histogram.maxX, 16, accuracy: 0.5)
        XCTAssertEqual(content.pillFrameForTesting.minX, 16, accuracy: 0.5)
    }

    // MARK: V8

    func testV8_RadiiShadowAndClipping() throws {
        for fallback in [false, true] {
            HUDGlass.forceFallbackForTesting = fallback
            let content = makeContent(NSSize(width: 1440, height: 900))
            showAll(content)
            content.toastHost.show("Copied")
            content.toastHost.alphaValue = 1
            content.zoomBadgeForTesting.alphaValue = 1
            content.layoutSubtreeIfNeeded()
            let panels: [(String, HUDSurfaceView)] = [
                ("rail", content.editRailForTesting), ("inspector", content.inspectorForTesting),
                ("filmstrip", content.filmstripForTesting),
            ] + (content.histogramOverlayIfBuiltForTesting.map { [("histogram", $0 as HUDSurfaceView)] } ?? [])
            for (name, surface) in panels {
                let fill = try XCTUnwrap(surface.fillLayerForTesting, name)
                XCTAssertEqual(fill.cornerRadius, 16, name)
                XCTAssertTrue(fill.masksToBounds, name)
                XCTAssertEqual(surface.contentHost.layer?.cornerRadius, fill.cornerRadius, name)
                XCTAssertEqual(surface.contentHost.layer?.masksToBounds, true, name)
                XCTAssertEqual(surface.layer?.masksToBounds, false, name)
                XCTAssertEqual(surface.layer?.shadowOpacity ?? 0, 0.35, accuracy: 0.001, name)
                XCTAssertEqual(surface.layer?.shadowRadius ?? 0, 18, name)
                XCTAssertNotNil(surface.layer?.shadowPath, name)
            }
            let capsules: [(String, HUDSurfaceView)] = [
                ("capsule", content.toolbarForTesting), ("pill", content.navigationPositionOverlayForTesting),
                ("zoom", content.zoomBadgeForTesting), ("toast", content.toastHost),
            ]
            for (name, surface) in capsules {
                XCTAssertEqual(surface.cornerRadiusForDisplay, surface.bounds.height / 2, accuracy: 0.01, name)
                XCTAssertEqual(surface.layer?.masksToBounds, false, name)
                if surface.look == .solid {
                    XCTAssertEqual(surface.fillLayerForTesting?.cornerRadius ?? 0,
                                   surface.bounds.height / 2, accuracy: 0.01, name)
                }
            }
            hideAll(content)
        }
    }

    func testV8_FillColoursAndAppearance() throws {
        let content = makeContent(NSSize(width: 1440, height: 900))
        showAll(content)
        let fill = try XCTUnwrap(content.inspectorForTesting.fillLayerForTesting)
        let color = try XCTUnwrap(NSColor(cgColor: fill.backgroundColor!)?.usingColorSpace(.sRGB))
        XCTAssertEqual(color.redComponent, 28 / 255, accuracy: 0.004)
        XCTAssertEqual(color.blueComponent, 30 / 255, accuracy: 0.004)
        XCTAssertEqual(color.alphaComponent, 0.95, accuracy: 0.004)
        XCTAssertEqual(content.inspectorForTesting.appearance?.name, .darkAqua)
        hideAll(content)
    }

    // MARK: V7

    func testV7_HistogramShortcutInFullScreenAndTheInspectorGap() throws {
        Prefs.viewerHistogramVisible = false
        let content = makeContent(NSSize(width: 1440, height: 900))
        XCTAssertFalse(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        content.layoutSubtreeIfNeeded()
        XCTAssertTrue(content.isHistogramShown, "the shortcut shows it with the inspector hidden")
        XCTAssertTrue(content.histogramOverlayVisibleForTesting)
        content.toggleHistogramOverlay()
        XCTAssertFalse(content.isHistogramShown, "and hides it again")

        content.toggleHistogramOverlay()
        content.togglePanel(.inspector)
        content.layoutSubtreeIfNeeded()
        let histogram = content.histogramOverlayFrameForTesting()
        let inspector = content.inspectorForTesting.frame
        XCTAssertEqual(inspector.minX - histogram.maxX, 12, accuracy: 0.5, "12 pt left of the inspector")
        content.togglePanel(.inspector)
        content.toggleHistogramOverlay()
        Prefs.viewerHistogramVisible = false
    }

    /// No code path sets `.hudWindow` on a HUD.
    func testV8_NoHudWindowMaterialInTheHUDSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ShrikeUI")
        // Every source file of every module.
        var files: [URL] = []
        let sources = root.deletingLastPathComponent()
        if let walker = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) {
            for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        }
        XCTAssertGreaterThan(files.count, 100)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains(".hudWindow"), "\(url.lastPathComponent) uses .hudWindow")
        }
    }
}

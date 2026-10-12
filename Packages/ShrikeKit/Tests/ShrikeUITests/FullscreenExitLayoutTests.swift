//
//  FullscreenExitLayoutTests.swift
//  ShrikeUITests
//
//  Regression coverage for the fullscreen → windowed transition in the
//  image viewer.
//
//  The bug: after the user enters fullscreen and then
//  exits back to a windowed viewer, the image ended up anchored to the
//  bottom-right of the content area with a large black strip on the
//  top + left, instead of being centered. Resizing the window does NOT
//  correct it.
//
//  Re-running `configureForMode` or forcing
//  extra `refreshGeometry` calls from every window hook did not fix
//  the bug. Root cause: `MetalImageView` was in layer-HOSTING mode
//  (`wantsLayer = true` followed by `self.layer = metalLayer`), so
//  AppKit stopped syncing `layer.frame` with `bounds`. During the
//  fullscreen-exit animation AppKit implicitly animates the view's
//  bounds, and our manual `metalLayer.frame = bounds` inside
//  `updateDrawableSize()` raced that animation — leaving the layer
//  frame stuck at the fullscreen rect, with its drawable pinned to a
//  corner of the smaller windowed view. The fix switches to layer-
//  BACKED mode via `makeBackingLayer()` so AppKit owns the frame
//  contract, and adds `needsDisplay = true` to `layout()` /
//  `setFrameSize()` so the newly-sized drawable actually repaints.
//
//  This suite pins the post-fix invariants. The headless constraint-
//  solver path can't reproduce the real AppKit fullscreen animation,
//  but it CAN assert that: (a) after a bounds shrink, the Metal
//  layer's drawableSize tracks the new bounds, (b) the view is
//  layer-backed (so AppKit keeps layer.frame in sync), and (c) the
//  redraw invalidation fires on every layout pass.
//

import XCTest
import AppKit
import QuartzCore
@testable import ShrikeUI
@testable import ShrikeRendering
@testable import ShrikeCore

@MainActor
final class FullscreenExitLayoutTests: XCTestCase {

    private func clearChromePrefs() {
        let ud = ShrikeDefaults.store
        for key in [
            "shrike.viewer.filmstrip.visibleInWindowed",
            "shrike.viewer.filmstrip.heightPt",
            "shrike.viewer.filmstrip.pinnedFullscreen",
            "shrike.viewer.exifPanel.pinnedFullscreen",
        ] { ud.removeObject(forKey: key) }
    }

    override func setUp() async throws {
        try await super.setUp()
        clearChromePrefs()
    }

    override func tearDown() async throws {
        clearChromePrefs()
        try await super.tearDown()
    }

    /// Drawable size must track bounds × contentsScale across MANY
    /// successive bounds changes, not just the first. This models the
    /// per-frame resize that AppKit drives during a fullscreen-exit
    /// animation: setFrameSize is called repeatedly with shrinking
    /// sizes, and at every step the Metal drawable must be the right
    /// pixel size (otherwise the previously-presented drawable lingers
    /// at a stale size and ends up visually pinned to a corner of the
    /// new bounds).
    func testBoundsShrinkInSteps_DrawableStaysInSyncEveryStep() {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440))
        let scale = view.metalLayerContentsScaleForTesting

        // Simulate the multi-tick resize AppKit runs during fullscreen
        // exit. After every tick, drawableSize must match bounds.
        for size in [CGSize(width: 2000, height: 1200),
                     CGSize(width: 1600, height: 1000),
                     CGSize(width: 1200, height: 800)] {
            view.setFrameSize(size)
            XCTAssertEqual(
                view.drawableSizeForTesting.width,
                size.width * scale,
                accuracy: 0.5,
                "drawableSize.width must sync with bounds at size \(size)"
            )
            XCTAssertEqual(
                view.drawableSizeForTesting.height,
                size.height * scale,
                accuracy: 0.5,
                "drawableSize.height must sync with bounds at size \(size)"
            )
        }
    }

    /// A bounds shrink (which is what AppKit ultimately does when
    /// returning from fullscreen) must trigger a repaint so the newly-
    /// sized drawable actually gets presented. Prior to the fix,
    /// `layout()` / `setFrameSize()` mutated `zoomLevel` / `panOffset`
    /// via `applyContentMode()` but never invalidated the view, so
    /// the previous (fullscreen-sized) drawable stayed on screen until
    /// something unrelated triggered a redraw.
    func testBoundsShrink_SchedulesRedraw() {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 2560, height: 1440))
        let before = view.redrawCountForTesting

        view.setFrameSize(NSSize(width: 1200, height: 800))

        XCTAssertGreaterThan(
            view.redrawCountForTesting,
            before,
            "setFrameSize must schedule a redraw so the new-sized "
            + "drawable is presented promptly after a fullscreen exit "
            + "(regression: before the fix, bounds changes updated the "
            + "layer but never repainted)."
        )
    }

    /// End-to-end headless check of the fullscreen → windowed transition.
    /// We drive the full state machine — inflate to fullscreen bounds,
    /// flip mode, lay out, then shrink to windowed bounds, flip mode,
    /// lay out — and assert the Metal drawable / layer geometry match
    /// the view's bounds at each step.
    func testFullscreenExit_DrawableSizeTracksBounds() {
        let services = ShrikeServices.makeDefault()
        let content = ViewerContentView(services: services)

        // Enter fullscreen.
        content.frame = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        content.windowMode = .fullscreen
        content.layoutSubtreeIfNeeded()

        let imageView = content.imageView
        let scale = imageView.metalLayerContentsScaleForTesting

        let fullscreenBounds = imageView.bounds
        XCTAssertEqual(
            imageView.drawableSizeForTesting.width,
            fullscreenBounds.width * scale,
            accuracy: 0.5,
            "drawableSize.width should track bounds in fullscreen"
        )
        XCTAssertEqual(
            imageView.drawableSizeForTesting.height,
            fullscreenBounds.height * scale,
            accuracy: 0.5,
            "drawableSize.height should track bounds in fullscreen"
        )

        // Exit to windowed. This mirrors the runtime sequence: mode
        // flip first (as in willExitFullScreen), then bounds change
        // (as AppKit's animation settles).
        content.windowMode = .windowed
        content.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        content.layoutSubtreeIfNeeded()

        let windowedBounds = imageView.bounds
        XCTAssertNotEqual(
            windowedBounds.size,
            fullscreenBounds.size,
            "sanity: windowed imageView bounds must differ from fullscreen"
        )
        XCTAssertEqual(
            imageView.drawableSizeForTesting.width,
            windowedBounds.width * scale,
            accuracy: 0.5,
            "After fullscreen exit, drawableSize.width must shrink to "
            + "match the new windowed bounds — otherwise the previously "
            + "presented fullscreen-sized drawable stays pinned to one "
            + "corner of the smaller view."
        )
        XCTAssertEqual(
            imageView.drawableSizeForTesting.height,
            windowedBounds.height * scale,
            accuracy: 0.5,
            "After fullscreen exit, drawableSize.height must shrink to "
            + "match the new windowed bounds"
        )

        // And since MetalImageView is now layer-backed, AppKit is in
        // charge of layer.frame. At the end of a layout pass the layer
        // frame's SIZE must match the view's bounds size (origin is in
        // the superlayer space and may legitimately be non-zero).
        XCTAssertEqual(
            imageView.metalLayerFrameForTesting.size,
            windowedBounds.size,
            "After fullscreen exit, metalLayer.frame.size must match the "
            + "new windowed bounds (AppKit-managed in layer-backed mode)"
        )
    }

    // MARK: - CA implicit-action suppression on the Metal layer

    /// Toggling windowed → fullscreen → windowed produced
    /// a visible "shrink then un-shrink" pulse on the image during
    /// each AppKit fullscreen animation. Root cause: the
    /// layer-backed view means AppKit drives
    /// `metalLayer.frame` to follow `bounds` across the multi-tick
    /// fullscreen animation, but Core Animation also lays its OWN
    /// implicit tween over each `bounds` / `position` / `frame` /
    /// `contents` change. The visible result is the previously-
    /// presented (fullscreen-sized) drawable being CA-scaled DOWN
    /// inside the shrinking layer rect — i.e. the "shrink" — followed
    /// by a snap-out to the correct windowed fit once the post-
    /// transition refit lands — i.e. the "un-shrink".
    ///
    /// Fix: disable CA's implicit actions on those four keys via
    /// `metalLayer.actions = ["bounds": NSNull(), ...]`. Each AppKit
    /// layout tick remains atomic — `setFrameSize` →
    /// `updateDrawableSize` → `applyContentMode` → fresh draw at the
    /// correct intermediate size — without CA layering an extra tween
    /// of stale contents on top.
    ///
    /// This test pins the actions dictionary so a future CA-config
    /// edit doesn't silently re-enable implicit animations on those
    /// keys and reintroduce the pulse.
    func testMetalLayerActions_DisableImplicitAnimations() {
        let view = MetalImageView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))

        guard let actions = view.metalLayerActionsForTesting else {
            XCTFail(
                "MetalImageView's CAMetalLayer must have an `actions` "
                + "dictionary set in init — without it, Core Animation "
                + "applies implicit tweens to bounds/position/frame/"
                + "contents during AppKit's multi-tick fullscreen "
                + "animation, producing the visible 'shrink → un-shrink' "
                + "pulse this fix exists to prevent."
            )
            return
        }

        for key in ["bounds", "position", "frame", "contents"] {
            guard let action = actions[key] else {
                XCTFail(
                    "metalLayer.actions must contain a disabled (NSNull) "
                    + "action for `\(key)` — leaving any of these keys "
                    + "with the default CA implicit action lets CA tween "
                    + "the previously-presented drawable's contents "
                    + "during AppKit's fullscreen animation, which is "
                    + "the visible 'shrink → un-shrink' pulse."
                )
                continue
            }
            XCTAssertTrue(
                action is NSNull,
                "metalLayer.actions[\(key)] must be NSNull (implicit "
                + "animation explicitly disabled), got \(type(of: action))"
            )
        }
    }

    /// Even after CA implicit actions were disabled on the metalLayer
    /// LEAF, the "shrink → un-shrink" pulse on fullscreen toggle
    /// persisted. Root cause: the metalLayer is a
    /// sublayer of `ViewerContentView`'s backing layer, and AppKit's
    /// fullscreen animation drives the PARENT view's bounds across the
    /// multi-tick transition. Each intermediate `bounds` value triggers
    /// CA's default implicit tween on the parent layer's
    /// bounds/position/frame, which establishes an animating coordinate
    /// system for every sublayer underneath. The metalLayer's own frame
    /// jumps instantly to the final value (its actions are NSNull), but
    /// the parent's interpolating coordinate system visually rescales
    /// the rendered drawable during the tween — i.e., the pulse.
    ///
    /// Fix: extend the action-disable up the layer chain. `ViewerContentView`
    /// is the `NSWindow.contentView` of `ViewerWindow`, so disabling CA
    /// actions on its backing layer covers the immediate parent of
    /// metalLayer. `_NSThemeFrame` (the top-level frame view AppKit owns)
    /// is outside our reach, but the pulse is generated by the
    /// contentView's tween, not the theme frame's — disabling here is
    /// sufficient because metalLayer's nearest parent layer is now
    /// non-animating.
    ///
    /// This test pins the actions dictionary on the parent layer so a
    /// future rework of `ViewerContentView`'s init doesn't silently
    /// re-enable implicit animations and reintroduce the pulse.
    func testParentLayerActions_DisableImplicitAnimations() {
        let services = ShrikeServices.makeDefault()
        let content = ViewerContentView(services: services)

        guard let actions = content.layer?.actions else {
            XCTFail(
                "ViewerContentView's backing layer must have an `actions` "
                + "dictionary set in init — without it, Core Animation "
                + "applies implicit tweens to bounds/position/frame on the "
                + "PARENT layer of MetalImageView's metalLayer during "
                + "AppKit's multi-tick fullscreen animation, producing the "
                + "visible 'shrink → un-shrink' pulse this fix exists to "
                + "prevent. Disabling actions on metalLayer alone (per "
                + "`a439af1`) is insufficient — the parent's interpolating "
                + "coordinate system visually rescales the rendered "
                + "drawable even when the leaf layer's own frame is "
                + "atomic."
            )
            return
        }

        for key in ["bounds", "position", "frame", "contents", "sublayers"] {
            guard let action = actions[key] else {
                XCTFail(
                    "ViewerContentView.layer.actions must contain a disabled "
                    + "(NSNull) action for `\(key)` — leaving any of these "
                    + "keys with the default CA implicit action lets CA "
                    + "tween the parent coordinate system during AppKit's "
                    + "fullscreen animation, which scales the metalLayer "
                    + "sublayer's rendered drawable visually even when its "
                    + "own frame is atomic."
                )
                continue
            }
            XCTAssertTrue(
                action is NSNull,
                "ViewerContentView.layer.actions[\(key)] must be NSNull "
                + "(implicit animation explicitly disabled), got "
                + "\(type(of: action))"
            )
        }
    }
}

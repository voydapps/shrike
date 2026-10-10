//
//  ViewerFullScreenTransition.swift
//  ShrikeUI
//
//  Custom enter/exit full-screen animation for the viewer window.
//
//  WHY ("the previous photo flashes when leaving
//  full screen"): AppKit's stock full-screen transition animates a
//  *snapshot* of the window taken when full screen was entered. If the
//  user browsed to other photos while in full screen, the exit animation
//  replays the photo that was on screen at entry time, then snaps to the
//  live window. `MetalImageView` never draws the old texture (no
//  `imageFrame` / `placeholderFrame` signpost fires after the exit key)
//  — the flash is the window server's snapshot.
//
//  Fix: tell AppKit we animate the window ourselves
//  (`customWindowsToEnter/ExitFullScreen(for:)` → `[window]`) and grow or
//  shrink the real window with `setFrame`. The Metal layer re-renders the
//  CURRENT texture at every intermediate size, so there is no snapshot to
//  go stale.
//
//  Follows Apple's "custom full-screen animation" sample: add/remove the
//  `.fullScreen` style bit at animation start, lift the window above the
//  menu bar while it moves, and suspend frame constraining (see
//  `ViewerWindow.constrainFrameRect`) so the exit animation can start
//  from a frame that covers the menu bar.
//

import AppKit
import ShrikeCore

@MainActor
final class ViewerFullScreenTransition: NSObject, NSWindowDelegate {

    /// Frame of the window before it entered full screen. Restored by the
    /// exit animation. `nil` until the first enter.
    private(set) var windowedFrame: NSRect?

    /// True while a custom enter/exit animation is running. The window
    /// skips frame constraining while this is set.
    private(set) var isAnimating = false

    /// Called when AppKit reports that entering / exiting failed, so the
    /// window can roll back the mode flip it made in `willEnter`/`willExit`.
    var onEnterFailed: (() -> Void)?
    var onExitFailed: (() -> Void)?

    // MARK: - Close with unsaved edits

    /// This object is the viewer window's delegate (never reassign it), so
    /// ⌘W, the close button and Window ▸ Close ask here. With edit mode
    /// on, the window shows the edit exit alert and closes itself after
    /// Save or Don't Save.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let viewer = sender as? ViewerWindow else { return true }
        return viewer.shouldCloseResolvingEdits()
    }

    // MARK: - Opt in to the custom animation

    func customWindowsToEnterFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    func customWindowsToEnterFullScreen(
        for window: NSWindow,
        on screen: NSScreen
    ) -> [NSWindow]? {
        [window]
    }

    func customWindowsToExitFullScreen(for window: NSWindow) -> [NSWindow]? {
        [window]
    }

    // MARK: - Enter

    func window(
        _ window: NSWindow,
        startCustomAnimationToEnterFullScreenWithDuration duration: TimeInterval
    ) {
        enter(window, screen: window.screen ?? NSScreen.main, duration: duration)
    }

    func window(
        _ window: NSWindow,
        startCustomAnimationToEnterFullScreenOn screen: NSScreen,
        withDuration duration: TimeInterval
    ) {
        enter(window, screen: screen, duration: duration)
    }

    private func enter(_ window: NSWindow, screen: NSScreen?, duration: TimeInterval) {
        windowedFrame = window.frame
        ShrikeSignposts.navigation.event("fullScreenEnterAnimation")
        if !window.styleMask.contains(.fullScreen) {
            window.styleMask.insert(.fullScreen)
        }
        guard let target = screen?.frame else { return }
        animate(window, to: target, duration: duration)
    }

    // MARK: - Exit

    func window(
        _ window: NSWindow,
        startCustomAnimationToExitFullScreenWithDuration duration: TimeInterval
    ) {
        ShrikeSignposts.navigation.event("fullScreenExitAnimation")
        if window.styleMask.contains(.fullScreen) {
            window.styleMask.remove(.fullScreen)
        }
        animate(window, to: exitTargetFrame(for: window), duration: duration)
    }

    /// Where the exit animation lands: the saved windowed frame, or (if
    /// the window never went through our enter path) a centred default on
    /// the window's screen.
    func exitTargetFrame(for window: NSWindow) -> NSRect {
        if let windowedFrame { return windowedFrame }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(
            width: min(1200, visible.width),
            height: min(800, visible.height)
        )
        return NSRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Failure

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        finishAnimation(window)
        if window.styleMask.contains(.fullScreen) {
            window.styleMask.remove(.fullScreen)
        }
        if let windowedFrame {
            window.setFrame(windowedFrame, display: true)
        }
        onEnterFailed?()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        finishAnimation(window)
        if !window.styleMask.contains(.fullScreen) {
            window.styleMask.insert(.fullScreen)
        }
        if let screenFrame = window.screen?.frame {
            window.setFrame(screenFrame, display: true)
        }
        onExitFailed?()
    }

    // MARK: - Animation

    private var savedLevel: NSWindow.Level?

    /// Animate the real window frame. Every intermediate `setFrame`
    /// resizes the content view, and `MetalImageView` redraws its current
    /// texture at that size — the photo on screen is always the live one.
    func animate(_ window: NSWindow, to target: NSRect, duration: TimeInterval) {
        isAnimating = true
        if savedLevel == nil { savedLevel = window.level }
        // Above the menu bar and Dock while moving, as in Apple's sample.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = max(0, duration)
            context.allowsImplicitAnimation = false
            window.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self, weak window] in
            Task { @MainActor in
                guard let self, let window else { return }
                self.finishAnimation(window)
            }
        })
    }

    private func finishAnimation(_ window: NSWindow) {
        isAnimating = false
        if let savedLevel {
            window.level = savedLevel
            self.savedLevel = nil
        }
    }
}

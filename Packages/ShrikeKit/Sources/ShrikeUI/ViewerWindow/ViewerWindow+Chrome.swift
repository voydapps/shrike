//
//  ViewerWindow+Chrome.swift
//  ShrikeUI
//
//  Windowed viewer chrome glue: the toolbar host, toolbar
//  validation, the titlebar auto-hide wiring, the macOS 26 titlebar
//  scrim, and the standalone frame rule.
//

import AppKit
import ShrikeCore

extension ViewerWindow: ViewerToolbarHost {

    var toolbarZoomLine: String {
        let view = contentRoot.imageView
        guard view.image != nil else { return "Fit" }
        if view.isAtFit {
            return "Fit (\(Int((view.fitPixelScale * 100).rounded())) %)"
        }
        return "\(Int((view.pixelScale * 100).rounded())) %"
    }

    var toolbarShareURLs: [URL] { commandFileURLs }

    var toolbarZoomPercent: Int? {
        let view = contentRoot.imageView
        guard view.image != nil else { return nil }
        return Int((view.pixelScale * 100).rounded())
    }

    func toolbarToggleIsOn(_ command: ShrikeCommand) -> Bool {
        switch command {
        case .toggleFlag: return menuState(for: .toggleFlag) == .on
        case .toggleInspector: return toolbarInspectorShown
        case .toggleHistogram: return contentRoot.isHistogramShown
        case .toggleFilmstrip: return contentRoot.isFilmstripShown
        case .toggleFullScreen: return styleMask.contains(.fullScreen)
        default: return false
        }
    }

    var toolbarInspectorShown: Bool {
        contentRoot.windowMode == .fullscreen
            ? !contentRoot.inspectorPanel.isHidden
            : splitController?.isInspectorShown ?? false
    }

    /// Toolbar items grey out by the menu rule, once per event-loop pass
    /// (the same moment AppKit's own toolbar validation runs).
    public override func update() {
        super.update()
        if toolbar === toolbarController?.toolbar, toolbar?.isVisible == true {
            toolbarController?.validate()
            // A first image can arrive while the return item is hidden or
            // overflowed. Retry only when a genuine visible anchor exists.
            showBrowserReturnHint()
        }
    }

    /// The View menu reads "Hide Inspector" while it shows.
    func inspectorMenuTitle() -> String {
        toolbarInspectorShown ? "Hide Inspector" : "Show Inspector"
    }

    // MARK: Auto-hide

    func installAutoHide() {
        let hider = TitlebarAutoHider(window: self, enabled: Prefs.viewerToolbarAutoHide)
        hider.extraHolds = { [weak self] in
            guard let self else { return [] }
            var holds: TitlebarAutoHider.Holds = []
            if self.contentRoot.isEditModeActive { holds.insert(.editMode) }
            if self.contentRoot.isShowingDecodeError || self.isShowingEmptyState || self.list.isEmpty {
                holds.insert(.emptyOrError)
            }
            if self.styleMask.contains(.fullScreen) { holds.insert(.notKey) }
            return holds
        }
        autoHider = hider
        applyTitlebarLook()
        contentRoot.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hider, userInfo: nil))
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoHidePrefChanged(_:)),
            name: .shrikeToolbarAutoHideChanged, object: nil)
        installScrimIfNeeded()
    }

    /// User test 5: while the titlebar auto-hides, the window must not paint
    /// its own titlebar backdrop or separator under it. Hiding the titlebar
    /// container took the title away but left a flat grey band at the top of
    /// the window. The photo canvas already runs to the top edge
    /// (`imageViewTopToSelf`); with a transparent titlebar the canvas (and
    /// the black window background) is all that shows there. With auto-hide
    /// off the titlebar is always up and keeps the system look.
    func applyTitlebarLook() {
        let autoHides = autoHider?.isActive == true
        titlebarAppearsTransparent = autoHides
        titlebarSeparatorStyle = autoHides ? .none : .automatic
    }

    /// The pref changed (Settings › General): apply it and re-fit once.
    @objc nonisolated func autoHidePrefChanged(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.autoHider?.isEnabled = Prefs.viewerToolbarAutoHide
            self.applyTitlebarLook()
            self.installScrimIfNeeded()
            // The fit area follows the pref.
            self.contentRoot.needsLayout = true
        }
    }

    public override func sendEvent(_ event: NSEvent) {
        revealTitlebarIfStripMouseDown(event)
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            if let hider = autoHider, !styleMask.contains(.fullScreen) {
                hider.pointerMoved(inTitlebar: event.locationInWindow.y > contentLayoutRect.maxY)
            }
        case .keyDown:
            // Any key stops a playing Live Photo at once.
            contentRoot.stopLivePhoto()
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Step 1: a left mouse-down in the window-move strip
    /// while the titlebar is auto-hidden shows it at once (no fade), so
    /// AppKit hit-tests the real titlebar and runs its own window drag and
    /// double-click. Returns true when it revealed the titlebar.
    @discardableResult
    func revealTitlebarIfStripMouseDown(_ event: NSEvent) -> Bool {
        guard stripRevealEnabled, event.type == .leftMouseDown,
              !styleMask.contains(.fullScreen), attachedSheet == nil,
              let hider = autoHider, let container = hider.container,
              container.isHidden || !hider.isShown || container.alphaValue < 1,
              event.locationInWindow.y > contentLayoutRect.maxY else { return false }
        hider.show(animated: false)
        return true
    }

    // MARK: Native titlebar backing

    /// The backing belongs to the same measured native container as the title,
    /// subtitle and toolbar. Its parent supplies layout and the entire reveal /
    /// hide animation, so text can never outlive a separately fading scrim.
    /// With auto-hide off, AppKit's opaque titlebar supplies this surface.
    func installScrimIfNeeded() {
        guard autoHider?.isActive == true, contentRoot.windowMode == .windowed,
              !styleMask.contains(.fullScreen), let container = autoHider?.container else {
            titlebarScrim?.removeFromSuperview()
            titlebarScrim = nil
            return
        }
        if titlebarScrim?.superview === container { return }
        titlebarScrim?.removeFromSuperview()
        let backing = TitlebarScrimView(frame: container.bounds)
        backing.autoresizingMask = [.width, .height]
        container.addSubview(backing, positioned: .below, relativeTo: nil)
        titlebarScrim = backing
    }

    // MARK: Frames

    static let frameAutosaveName = "shrike.viewer"

    /// A viewer from Finder, Open…, Open Recent or a Dock drop: the saved
    /// frame, or a cascade from the last viewer so two never overlap.
    func applyStandaloneFrame(cascadingFrom last: NSWindow?) {
        if let last {
            setFrame(NSRect(origin: frame.origin, size: last.frame.size), display: false)
            setFrameTopLeftPoint(last.cascadeTopLeft(from: .zero))
        } else {
            setFrameUsingName(Self.frameAutosaveName)
            setFrameAutosaveName(Self.frameAutosaveName)
        }
    }
}

/// The backing of the revealed title bar and toolbar (spec 21b §2): a translucent
/// system-colour band with a 0.5 pt separator, so the photo shows softly through it and
/// the bar is no longer a solid block over the sky. Title and buttons stay readable
/// (the fill is 85 % opaque). It exists only while the bar is revealed; the photo's
/// fitted size never depends on it. This view no longer samples the image or fades
/// independently of its parent.
@MainActor
final class TitlebarScrimView: NSView {
    /// Spec 21b §2 fallback: `NSVisualEffectView` does not sample a `CAMetalLayer`, so the
    /// band is a translucent fill instead of the `.titlebar` material.
    static let fillAlpha: CGFloat = 0.85
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Resolve in the native titlebar's inherited effective appearance.
        // A dark canvas / HUD token would mismatch native light chrome.
        NSColor.windowBackgroundColor.withAlphaComponent(Self.fillAlpha).setFill()
        bounds.fill(using: .copy)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
    }
}

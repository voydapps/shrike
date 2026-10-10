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
        hider.onShownChanged = { [weak self] shown in self?.setScrimShown(shown) }
        // The windowed edit rail fades on the same clock.
        hider.railUsesClock = { [weak self] in
            guard let self, !self.styleMask.contains(.fullScreen) else { return false }
            return self.contentRoot.windowMode == .windowed && Prefs.editRailVisibleInWindowed
        }
        hider.onRailPointerMoved = { [weak self] in self?.contentRoot.railPointerMoved() }
        hider.onRailIdle = { [weak self] in self?.contentRoot.railIdleFired() }
        contentRoot.onRailShownFirst = { [weak hider] in hider?.startRailClock() }
        autoHider = hider
        contentRoot.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: hider, userInfo: nil))
        NotificationCenter.default.addObserver(
            self, selector: #selector(autoHidePrefChanged(_:)),
            name: .shrikeToolbarAutoHideChanged, object: nil)
        installScrimIfNeeded()
    }

    /// The pref changed (Settings › General): apply it and re-fit once.
    @objc nonisolated func autoHidePrefChanged(_ note: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.autoHider?.isEnabled = Prefs.viewerToolbarAutoHide
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

    // MARK: Titlebar scrim (macOS 26 only)

    func installScrimIfNeeded() {
        guard #available(macOS 26, *) else { return }
        let wanted = Prefs.viewerToolbarAutoHide && autoHider?.isActive == true
        if !wanted {
            titlebarScrim?.removeFromSuperview()
            titlebarScrim = nil
            return
        }
        guard titlebarScrim == nil else { return }
        let scrim = TitlebarScrimView()
        scrim.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(scrim, positioned: .above, relativeTo: contentRoot.imageView)
        let titlebarHeight = max(0, frame.height - contentLayoutRect.height)
        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            scrim.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
            scrim.heightAnchor.constraint(equalToConstant: titlebarHeight + 16),
        ])
        scrim.canvasColor = {
            ViewerContentView.canvasColor(windowed: true, alwaysBlack: Prefs.viewerBackgroundAlwaysBlack)
        }
        titlebarScrim = scrim
    }

    private func setScrimShown(_ shown: Bool) {
        guard let scrim = titlebarScrim else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? TitlebarAutoHider.showDuration : TitlebarAutoHider.hideDuration
            scrim.animator().alphaValue = shown ? 1 : 0
        }
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

/// Canvas colour at 55 % → 0 %, top to bottom, under the titlebar.
@MainActor
final class TitlebarScrimView: NSView {
    var canvasColor: () -> NSColor = { .black } { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = canvasColor()
        let gradient = NSGradient(starting: base.withAlphaComponent(0.55), ending: base.withAlphaComponent(0))
        gradient?.draw(in: bounds, angle: 90)
    }
}

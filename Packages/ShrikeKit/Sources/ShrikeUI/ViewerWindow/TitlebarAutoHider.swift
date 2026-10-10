//
//  TitlebarAutoHider.swift
//  ShrikeUI
//
//  QuickTime-style auto-hide of the windowed viewer's whole
//  titlebar container (title, traffic lights, toolbar). The pointer
//  moving shows it (80 ms); 2 s still over the canvas hides it (120 ms,
//  then `isHidden` so it takes no clicks); leaving the window hides it
//  after 0.5 s. Keys never show it.
//
//  The container is found ONCE per window
//  (`closeButton.superview.superview`, class name containing
//  "TitlebarContainer"). If that fails, auto-hide is off for the window
//  and one log line is written.
//

import AppKit
import os

@MainActor
final class TitlebarAutoHider: NSObject {

    /// Why the titlebar must stay (checked when a hide is due).
    struct Holds: OptionSet, Sendable {
        let rawValue: Int
        static let pointerInTitlebar = Holds(rawValue: 1 << 0)
        static let menuOpen = Holds(rawValue: 1 << 1)
        static let toolbarFocus = Holds(rawValue: 1 << 2)
        static let customizing = Holds(rawValue: 1 << 3)
        static let voiceOver = Holds(rawValue: 1 << 4)
        static let editMode = Holds(rawValue: 1 << 5)
        static let emptyOrError = Holds(rawValue: 1 << 6)
        static let sheet = Holds(rawValue: 1 << 7)
        static let notKey = Holds(rawValue: 1 << 8)
    }

    static let idleDelay: Duration = .seconds(2)
    static let exitDelay: Duration = .milliseconds(500)
    static let showDuration: TimeInterval = 0.08
    static let hideDuration: TimeInterval = 0.12

    private static let log = Logger(subsystem: "app.shrike", category: "viewer")

    private weak var window: NSWindow?
    /// The titlebar container, or nil when the lookup failed.
    private(set) var container: NSView?
    private(set) var lookupFailed = false
    /// The pref (`shrike.viewer.toolbarAutoHide`).
    var isEnabled: Bool { didSet { if !isEnabled { show(animated: false) } } }
    private(set) var isShown = true
    private var menuOpen = false
    private var pointerInTitlebar = false
    /// Holds the window adds (edit mode, empty / error state, …).
    var extraHolds: () -> Holds = { [] }
    /// The scrim fades with the titlebar (macOS 26).
    var onShownChanged: ((Bool) -> Void)?
    /// Where the pointer is now, in window coordinates. Read
    /// when a hide is due, so a pointer resting on the toolbar holds it
    /// even when the last event said otherwise. Replaced in tests.
    lazy var pointerLocation: () -> NSPoint? = { [weak self] in
        self?.window?.mouseLocationOutsideOfEventStream
    }
    private var timer: Task<Void, Never>?

    /// The edit rail fades on this pointer clock, one timer
    /// per window. It runs whenever the rail is on, even with auto-hide
    /// off (then only the rail fades).
    var railUsesClock: () -> Bool = { false }
    /// The pointer moved: the rail shows.
    var onRailPointerMoved: (() -> Void)?
    /// The idle (2 s) or exit (0.5 s) delay ran out: the rail may fade.
    var onRailIdle: (() -> Void)?
    /// The running timer was started for the rail alone (window open), so
    /// it must not hide the titlebar before the pointer ever moved.
    private var railOnlyTick = false

    /// `lookup` is replaced in tests (to simulate a failed lookup).
    init(window: NSWindow, enabled: Bool,
         lookup: @MainActor (NSWindow) -> NSView? = TitlebarAutoHider.findTitlebarContainer) {
        self.window = window
        self.isEnabled = enabled
        super.init()
        if let found = lookup(window) {
            container = found
        } else {
            lookupFailed = true
            Self.log.notice("Viewer: titlebar container not found; toolbar auto-hide is off for this window")
        }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBegan(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(menuEnded(_:)), name: NSMenu.didEndTrackingNotification, object: nil)
        // Customize Toolbar (a sheet since macOS 11) and every
        // other sheet show the titlebar at once, so the toolbar is there
        // to drop items on, and hold it until the sheet ends.
        center.addObserver(self, selector: #selector(sheetBegan(_:)), name: NSWindow.willBeginSheetNotification, object: window)
        center.addObserver(self, selector: #selector(sheetEnded(_:)), name: NSWindow.didEndSheetNotification, object: window)
    }

    static func findTitlebarContainer(in window: NSWindow) -> NSView? {
        guard let view = window.standardWindowButton(.closeButton)?.superview?.superview,
              NSStringFromClass(type(of: view)).contains("TitlebarContainer") else { return nil }
        return view
    }

    /// Auto-hide can act at all in this window.
    var isActive: Bool { isEnabled && container != nil }

    func stop() {
        timer?.cancel()
        timer = nil
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Menu tracking (held open while a menu is open)

    @objc nonisolated private func menuBegan(_ note: Notification) {
        Task { @MainActor [weak self] in self?.setMenuOpen(true) }
    }

    @objc nonisolated private func menuEnded(_ note: Notification) {
        Task { @MainActor [weak self] in self?.setMenuOpen(false) }
    }

    @objc nonisolated private func sheetBegan(_ note: Notification) {
        Task { @MainActor [weak self] in self?.setSheetOpen(true) }
    }

    @objc nonisolated private func sheetEnded(_ note: Notification) {
        Task { @MainActor [weak self] in self?.setSheetOpen(false) }
    }

    /// A sheet (the customization palette included) opened or closed.
    func setSheetOpen(_ open: Bool) {
        guard isActive else { return }
        if open {
            timer?.cancel()
            timer = nil
            show(animated: true)
        } else {
            restartTimer(Self.idleDelay)
        }
    }

    func setMenuOpen(_ open: Bool) {
        menuOpen = open
        guard isActive else { return }
        if open {
            // A menu in another window holds this one but never shows it.
            if window?.isKeyWindow == true { show(animated: true) }
        } else {
            restartTimer(Self.idleDelay)
        }
    }

    // MARK: Events

    /// The pointer moved inside the window.
    func pointerMoved(inTitlebar: Bool) {
        pointerInTitlebar = inTitlebar
        let rail = railUsesClock()
        if rail { onRailPointerMoved?() }
        guard isActive || rail else { return }
        if isActive { show(animated: true) }
        restartTimer(Self.idleDelay)
    }

    /// The window opened with the rail on: start the 2 s
    /// clock for the rail only (the titlebar waits for the pointer).
    func startRailClock() {
        guard railUsesClock(), timer == nil else { return }
        restartTimer(Self.idleDelay)
        railOnlyTick = true
    }

    /// The pointer left the window (or the canvas, for the titlebar: the
    /// pointer may be on the toolbar now, which the next check reads).
    func pointerExited() {
        pointerInTitlebar = false
        guard isActive || railUsesClock() else { return }
        restartTimer(Self.exitDelay)
    }

    // Tracking-area callbacks (the canvas's area; the owner is this object).
    // The ObjC names are spelled out: on a plain NSObject, Swift would
    // name them `mouseEnteredWith:` / `mouseExitedWith:`, the area sends
    // `mouseEntered:` / `mouseExited:`, and the "unrecognized selector"
    // exception AppKit catches in `sendEvent` leaked the event and the
    // window it was routed through (closed viewers were never freed).
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {}
    @objc(mouseExited:) func mouseExited(with event: NSEvent) { pointerExited() }

    /// Keys never show (or hide) the titlebar.
    func keyPressed() {}

    /// Everything holding the titlebar open right now.
    func currentHolds() -> Holds {
        var holds = extraHolds()
        if pointerInTitlebar || pointerIsOverTitlebar() { holds.insert(.pointerInTitlebar) }
        if menuOpen { holds.insert(.menuOpen) }
        if NSWorkspace.shared.isVoiceOverEnabled { holds.insert(.voiceOver) }
        if let window {
            if window.attachedSheet != nil { holds.insert(.sheet) }
            if !window.isKeyWindow { holds.insert(.notKey) }
            if window.toolbar?.customizationPaletteIsRunning == true { holds.insert(.customizing) }
            if let responder = window.firstResponder as? NSView, let container,
               responder.isDescendant(of: container) { holds.insert(.toolbarFocus) }
        }
        return holds
    }

    /// The pointer is on the titlebar strip right now (above the content
    /// layout rect, inside the window's width), whatever the last event
    /// said.
    func pointerIsOverTitlebar() -> Bool {
        guard let window, isShown, let point = pointerLocation() else { return false }
        let frame = window.frame
        return point.x >= 0 && point.x <= frame.width
            && point.y > window.contentLayoutRect.maxY && point.y <= frame.height
    }

    /// The idle / exit timer fired: hide unless something holds it.
    func hideIfAllowed() {
        let railOnly = railOnlyTick
        railOnlyTick = false
        if railUsesClock() { onRailIdle?() }
        guard !railOnly else { return }
        guard isActive, isShown else { return }
        let holds = currentHolds()
        if holds.contains(.notKey) { return } // keeps its last state
        guard holds.isEmpty else { return }
        hide()
    }

    private func restartTimer(_ delay: Duration) {
        timer?.cancel()
        railOnlyTick = false
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.timer = nil
            self?.hideIfAllowed()
        }
    }

    // MARK: Fades

    func show(animated: Bool) {
        guard let container else { return }
        let wasShown = isShown
        isShown = true
        container.isHidden = false
        if animated && !wasShown {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.showDuration
                container.animator().alphaValue = 1
            }
        } else {
            container.alphaValue = 1
        }
        if !wasShown { onShownChanged?(true) }
    }

    /// Test seam: hides at once, as the idle timer would.
    func hideForTesting() {
        hide()
        container?.isHidden = true
    }

    private func hide() {
        guard let container else { return }
        isShown = false
        onShownChanged?(false)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.hideDuration
            container.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Hidden views take no clicks and leave the key loop.
            Task { @MainActor [weak self] in
                guard let self, !self.isShown else { return }
                container.isHidden = true
            }
        })
    }
}

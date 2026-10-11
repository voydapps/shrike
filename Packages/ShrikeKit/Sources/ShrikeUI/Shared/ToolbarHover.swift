//
//  ToolbarHover.swift
//  ShrikeUI
//
//  A hover look for window toolbars that can be SEEN. On macOS 26 the
//  system's hover state of a toolbar button is a disc about 8 levels
//  (of 255) lighter than the glass around it: on a photo it is not
//  noticed (measured on screen 2026-10-11, mean 3, max 8). The toolbar
//  draws its items inside system views we cannot subclass (every button is
//  hosted SwiftUI), so one transparent overlay sits on top of the toolbar,
//  follows the pointer, and draws a platter over the item under it: white
//  14 % on a dark toolbar, black 8 % on a light one. The same platter on
//  the viewer's and the browser's toolbars; one item at a time (a group
//  such as Previous / Next hovers one segment); a disabled item and the
//  search field show none. The overlay never takes a click (`hitTest`
//  is nil) and it is not created before macOS 26: older systems already
//  draw a visible grey hover.
//

import AppKit

/// Draws and tracks the platter of one window's toolbar.
@MainActor
public final class ToolbarHover: NSObject {

    /// White (dark toolbar) or black (light toolbar) fill of the platter.
    static let darkAlpha: CGFloat = 0.14
    static let lightAlpha: CGFloat = 0.08
    /// The platter sits this far inside the item's frame, so it stays
    /// inside the glass capsule.
    static let inset: CGFloat = 2

    /// False before macOS 26 (the system's own hover is visible there).
    static var isNeeded: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    /// What the platter covers right now (the toolbar's coordinates).
    struct Target: Equatable {
        var rect: NSRect
        var radius: CGFloat
    }

    private weak var window: NSWindow?
    let overlay = HoverOverlayView()
    /// Item views are laid out late: tests and the first move re-check.
    private(set) var target: Target?

    /// Installs the overlay in `window`'s toolbar once it has one. Safe to
    /// call again after the toolbar was swapped (`attach()`).
    @discardableResult
    public static func install(in window: NSWindow) -> ToolbarHover? {
        guard isNeeded else { return nil }
        let hover = ToolbarHover(window: window)
        return hover
    }

    init(window: NSWindow) {
        self.window = window
        super.init()
        overlay.owner = self
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didEndLiveResizeNotification] {
            center.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: window)
        }
        // A swapped toolbar (the viewer's edit toolbar) brings a new
        // toolbar view: the overlay is put into it as soon as it is there.
        center.addObserver(self, selector: #selector(windowUpdated(_:)),
                           name: NSWindow.didUpdateNotification, object: window)
        center.addObserver(self, selector: #selector(windowResigned(_:)),
                           name: NSWindow.didResignKeyNotification, object: window)
        attach()
    }

    @objc private func windowChanged(_ note: Notification) { attach() }
    @objc private func windowUpdated(_ note: Notification) {
        // Cheap test first: the full search only runs when the overlay lost
        // its toolbar (or never had one).
        guard overlay.window == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastAttachTry > 0.25 else { return }
        lastAttachTry = now
        attach()
    }
    private var lastAttachTry: TimeInterval = 0
    @objc private func windowResigned(_ note: Notification) {
        attach()
        pointerLeft()
    }

    // MARK: Attaching

    /// The window's `NSToolbarView` (nil before the toolbar is laid out).
    var toolbarView: NSView? {
        guard let root = window?.contentView?.superview else { return nil }
        func find(_ v: NSView) -> NSView? {
            if String(describing: type(of: v)) == "NSToolbarView" { return v }
            for sub in v.subviews { if let hit = find(sub) { return hit } }
            return nil
        }
        return find(root)
    }

    /// Puts the overlay on top of the toolbar's items (again, after the
    /// toolbar was replaced or got new item views). Returns false while the
    /// window has no toolbar view yet.
    @discardableResult
    func attach() -> Bool {
        // Already in a toolbar of this window: no search of the view tree
        // (this runs on every pointer move).
        if let bar = overlay.superview, overlay.window === window {
            if bar.subviews.last !== overlay { bar.addSubview(overlay, positioned: .above, relativeTo: nil) }
            return true
        }
        guard let bar = toolbarView else { return false }
        if overlay.superview !== bar {
            overlay.removeFromSuperview()
            overlay.frame = bar.bounds
            overlay.autoresizingMask = [.width, .height]
            bar.addSubview(overlay)
        } else if bar.subviews.last !== overlay {
            bar.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        return true
    }

    // MARK: Hit testing the items

    /// The item views the toolbar made, left to right.
    private func itemViewers(in bar: NSView) -> [NSView] {
        bar.subviews.filter { String(describing: type(of: $0)) == "NSToolbarItemViewer" && !$0.isHidden }
    }

    /// First button / pop-up / segmented control inside an item viewer
    /// (not a text field: the search field has its own focus look).
    private func control(in viewer: NSView) -> NSControl? {
        for sub in viewer.subviews {
            if let c = sub as? NSControl, !(c is NSTextField), !c.isHidden, c.bounds.width > 0 { return c }
            if let c = control(in: sub) { return c }
        }
        return nil
    }

    /// The item (or the segment of a group) under `point`, in the
    /// overlay's coordinates; nil on gaps, separators, disabled items.
    func hitTarget(at point: NSPoint) -> Target? {
        guard let bar = overlay.superview else { return nil }
        let p = bar.convert(point, from: overlay)
        for viewer in itemViewers(in: bar) where viewer.frame.contains(p) {
            guard let item = viewer.value(forKey: "item") as? NSToolbarItem else { return nil }
            // Group: the picker view holds the segments, side by side.
            if let group = item as? NSToolbarItemGroup, !group.subitems.isEmpty,
               let picker = viewer.subviews.first(where: { String(describing: type(of: $0)).contains("GroupPicker") }) {
                let frame = bar.convert(picker.bounds, from: picker)
                guard frame.contains(p), frame.width > 0 else { return nil }
                let count = group.subitems.count
                let width = frame.width / CGFloat(count)
                let index = min(count - 1, max(0, Int((p.x - frame.minX) / width)))
                guard group.subitems[index].isEnabled else { return nil }
                let segment = NSRect(x: frame.minX + CGFloat(index) * width, y: frame.minY,
                                     width: width, height: frame.height)
                return makeTarget(bar.convert(segment, to: overlay))
            }
            guard let c = control(in: viewer), c.isEnabled else { return nil }
            let frame = bar.convert(c.bounds, from: c)
            guard frame.contains(p) else { return nil }
            return makeTarget(bar.convert(frame, to: overlay))
        }
        return nil
    }

    private func makeTarget(_ rect: NSRect) -> Target {
        let r = rect.insetBy(dx: Self.inset, dy: Self.inset)
        return Target(rect: r, radius: min(r.width, r.height) / 2)
    }

    // MARK: Pointer

    /// The pointer is at `point` (overlay coordinates).
    func pointerMoved(to point: NSPoint) {
        _ = attach()
        let next = hitTarget(at: point)
        guard next != target else { return }
        target = next
        overlay.show(next, color: platterColor)
        updateWatch()
    }

    func pointerLeft() {
        guard target != nil else { return }
        target = nil
        overlay.show(nil, color: platterColor)
        updateWatch()
    }

    /// While a platter is shown, the pointer is looked at every 80 ms. A
    /// menu (Share, Zoom), a drag or a window switch can swallow the
    /// "mouse exited" event, and the platter would stay (seen on screen:
    /// Share stayed lit 1.5 s after the pointer had left).
    private var watch: Timer?

    private func updateWatch() {
        if target == nil {
            watch?.invalidate()
            watch = nil
        } else if watch == nil {
            let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            watch = timer
        }
    }

    private func checkPointer() {
        guard let window, window.isVisible, overlay.window != nil else { pointerLeft(); return }
        let point = overlay.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if overlay.bounds.contains(point) { pointerMoved(to: point) } else { pointerLeft() }
    }

    /// The platter's fill for the window's appearance.
    var platterColor: CGColor {
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? NSColor.white.withAlphaComponent(Self.darkAlpha)
                     : NSColor.black.withAlphaComponent(Self.lightAlpha)).cgColor
    }

    // MARK: Test seams

    /// The platter's alpha as drawn (0 when none is shown).
    var platterAlphaForTesting: CGFloat {
        guard overlay.platter.opacity > 0 else { return 0 }
        return overlay.platter.backgroundColor.map { CGFloat($0.alpha) } ?? 0
    }
}

/// The transparent view over the toolbar: tracks the pointer, draws the
/// platter, takes no clicks.
@MainActor
final class HoverOverlayView: NSView {

    weak var owner: ToolbarHover?
    let platter = CALayer()
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        platter.opacity = 0
        platter.actions = ["opacity": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(platter)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: .zero,
                                 options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { moved(event) }
    override func mouseMoved(with event: NSEvent) { moved(event) }
    override func mouseExited(with event: NSEvent) { owner?.pointerLeft() }

    private func moved(_ event: NSEvent) {
        owner?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func viewDidHide() {
        super.viewDidHide()
        owner?.pointerLeft()
    }

    /// Shows the platter over `target`, or hides it.
    func show(_ target: ToolbarHover.Target?, color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let target {
            platter.frame = target.rect
            platter.cornerRadius = target.radius
            platter.backgroundColor = color
            platter.opacity = 1
        } else {
            platter.opacity = 0
        }
        CATransaction.commit()
    }
}

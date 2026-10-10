//
//  LiveColors.swift
//  ShrikeUI
//
//  Design tokens as dynamic colours, and the
//  rule: colours are resolved when a view draws, and a view redraws on
//  an appearance change, a system colour change (accent colour) and a
//  key-window change.
//

import AppKit

/// Dynamic design-token colours. They resolve against the drawing
/// appearance, so never store their `cgColor` outside `updateLayer()`.
enum ShrikeTokens {

    private static func dynamic(_ name: String, dark: UInt32, light: UInt32) -> NSColor {
        func rgb(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    /// `surface.base`: #1C1C1E dark / #F5F5F7 light. Default window background.
    static let surfaceBase = dynamic("shrike.surface.base", dark: 0x1C1C1E, light: 0xF5F5F7)

    /// `surface.sunken`: #0F0F11 dark / #E8E8EB light. Behind thumbnails.
    static let surfaceSunken = dynamic("shrike.surface.sunken", dark: 0x0F0F11, light: 0xE8E8EB)

    /// Increase Contrast. Tests set the override.
    @MainActor static var increaseContrastOverride: Bool?
    @MainActor static var increaseContrast: Bool {
        increaseContrastOverride ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
}

extension NSColor {
    /// This colour as a `CGColor` resolved for `appearance`.
    func resolvedCGColor(for appearance: NSAppearance) -> CGColor {
        var out = cgColor
        appearance.performAsCurrentDrawingAppearance { out = self.cgColor }
        return out
    }
}

/// Calls `onChange` (default: `view.needsDisplay = true`)
/// when the system colours change (accent colour), the display options
/// change (Increase Contrast) or the view's own window becomes or stops
/// being key. Appearance changes arrive through the view's
/// `viewDidChangeEffectiveAppearance`. The observer is removed when this
/// object is released.
@MainActor
final class LiveColorObserver: NSObject {

    private weak var view: NSView?
    private let onChange: (() -> Void)?

    init(view: NSView, onChange: (() -> Void)? = nil) {
        self.view = view
        self.onChange = onChange
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(colorsChanged(_:)),
                           name: NSColor.systemColorsDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(keyChanged(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(keyChanged(_:)),
                           name: NSWindow.didResignKeyNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(colorsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    // Selector-based observers are dropped by the notification centres
    // when this object is released (macOS 10.11+), so no deinit.

    @objc private func colorsChanged(_ note: Notification) { fire() }

    @objc private func keyChanged(_ note: Notification) {
        guard let window = view?.window, (note.object as? NSWindow) === window else { return }
        fire()
    }

    private func fire() {
        if let onChange { onChange() } else { view?.needsDisplay = true }
    }
}

/// A view filled with a (dynamic) colour, set in `updateLayer()` so it
/// follows Light/Dark and Increase Contrast at once.
@MainActor
class TokenBackgroundView: NSView {
    var fillColor: NSColor { didSet { needsDisplay = true } }

    init(fillColor: NSColor) {
        self.fillColor = fillColor
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.resolvedCGColor(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

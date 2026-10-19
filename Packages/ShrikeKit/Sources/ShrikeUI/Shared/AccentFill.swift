//
//  AccentFill.swift
//  ShrikeUI
//
//  One accent per window (spec 22 §3.5). Every default / call-to-action
//  button takes its fill through this one call, so edit actions, recovery
//  and sheet default buttons retain the native accent mechanism.
//
//  macOS 26: a glass bezel with `tintProminence = .primary` draws the
//  system accent the same inside the toolbar and in a panel (measured on
//  screen on 26.5: Done and Apply both (0, 121, 255)). The plain push
//  button (default-button look) drew a paler violet-blue (92, 121, 245)
//  in a panel, and a button inside a toolbar item drew no accent at all;
//  `bezelColor` is ignored there. The glass tints a plain label cyan, so
//  the label uses an explicit contrast-aware foreground. Before 26 the default
//  push button takes the accent as its bezel colour.
//

import AppKit

extension NSColor {

    /// WCAG relative luminance of `color` (sRGB), 0 black ... 1 white.
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// Choose the higher-contrast black/white foreground without changing
    /// the accent. For an opaque sRGB fill, the stronger ratio exceeds 4.5.
    static func accentLabelColor(for accent: NSColor) -> NSColor {
        let luminance = relativeLuminance(of: accent)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    /// The label colour on the system accent as `appearance` shows it
    /// (the accent has a light and a dark variant).
    static func accentLabelColor(in appearance: NSAppearance) -> NSColor {
        var accent = NSColor.controlAccentColor
        appearance.performAsCurrentDrawingAppearance { accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent }
        return accentLabelColor(for: accent)
    }

    /// Dynamic: resolved when drawn, so a changed accent colour or
    /// appearance needs no re-set.
    static var accentLabelColor: NSColor {
        NSColor(name: nil) { appearance in accentLabelColor(in: appearance) }
    }
}

extension NSButton {
    /// The system accent fill, the same on every macOS we support.
    func useAccentFill() {
        if #available(macOS 26, *) {
            bezelStyle = .glass
            bezelColor = nil
            tintProminence = .primary
            setAccentTitle(title)
        } else {
            bezelColor = .controlAccentColor
        }
    }

    /// Plain title assignment restores AppKit's selected-text colour, which
    /// glass can tint. Preserve this primary label's current native typography.
    func setAccentTitle(_ title: String) {
        self.title = title
        if #available(macOS 26, *) {
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.accentLabelColor,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        }
    }

    /// What `useAccentFill()` set, for tests: "prominent" (26+) or "accent" (before).
    var accentFillMechanism: String {
        if #available(macOS 26, *) {
            return bezelColor == nil && tintProminence == .primary ? "prominent" : "other"
        }
        return bezelColor == .controlAccentColor ? "accent" : "other"
    }
}

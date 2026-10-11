//
//  AccentFill.swift
//  ShrikeUI
//
//  One accent per window (spec 22 §3.5). Every default / call-to-action
//  button takes its fill through this one call, so the edit toolbar's Done,
//  the panels' Apply, the capsule's Done and the sheets' default buttons are
//  drawn by the same system routine and show the same blue.
//
//  macOS 26: a glass bezel with `tintProminence = .primary` draws the
//  system accent the same inside the toolbar and in a panel (measured on
//  screen on 26.5: Done and Apply both (0, 121, 255)). The plain push
//  button (default-button look) drew a paler violet-blue (92, 121, 245)
//  in a panel, and a button inside a toolbar item drew no accent at all;
//  `bezelColor` is ignored there. The glass tints a plain label cyan, so
//  the label is set white, as the toolbar draws it. Before 26 the default
//  push button takes the accent as its bezel colour.
//

import AppKit

extension NSColor {

    /// The accent is "light" above this relative luminance (WCAG): yellow
    /// is about 0.63; blue 0.21, green 0.40, orange 0.42, red 0.23 stay
    /// dark. (Plain contrast-ratio maximising would put black on the
    /// default blue, which the system does not.)
    static let lightAccentLuminance: CGFloat = 0.5

    /// WCAG relative luminance of `color` (sRGB), 0 black ... 1 white.
    static func relativeLuminance(of color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }

    /// The label colour for a button filled with `accent`: black on a
    /// light accent, white on a dark one.
    static func accentLabelColor(for accent: NSColor) -> NSColor {
        relativeLuminance(of: accent) > lightAccentLuminance ? .black : .white
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
            // The glass tints a plain label cyan, so the label is set: white
            // on a dark accent (blue, purple, graphite...), black on a light
            // one (yellow). It follows the accent and the appearance live.
            attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: NSColor.accentLabelColor,
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        } else {
            bezelColor = .controlAccentColor
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

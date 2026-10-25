//
//  ShrikeAccent.swift
//  ShrikeUI
//
//  Spec 27 P3-1: two named accent tokens for everything Shrike draws itself.
//  System-drawn controls (checkbox, radio, slider, selected tab, the default
//  button) keep the system's own tone; that two-tone is the system's.
//

import AppKit
import SwiftUI

public enum ShrikeAccent {
    /// How far `mark` is lightened toward white (4.5:1 on the dark toast pill).
    public static let markLightening: CGFloat = 0.25

    /// "A mark": rings, selection fills, text links and actions, the edit
    /// platter, the toast Undo, the Compare ring.
    public static var mark: NSColor {
        NSColor.controlAccentColor.blended(withFraction: markLightening, of: .white) ?? .controlAccentColor
    }

    /// "The button": the one filled accent button.
    public static var fill: NSColor { .controlAccentColor }

    /// How far `linkText` is darkened toward black on a light surface.
    public static let linkDarkening: CGFloat = 0.45

    /// `mark` for text on the system's own window colour: lightened toward
    /// white in a dark window (as `mark`), darkened toward black in a light
    /// one, where the lightened accent was nearly unreadable (the Browser
    /// info panel's "Clear" link).
    public static var linkText: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark ? mark : (NSColor.controlAccentColor.blended(withFraction: linkDarkening, of: .black) ?? .controlAccentColor)
        }
    }

    public static var linkTextColor: Color { Color(nsColor: linkText) }

    /// SwiftUI twin of `mark` for links in the inspectors.
    public static var markColor: Color { Color(nsColor: mark) }
}

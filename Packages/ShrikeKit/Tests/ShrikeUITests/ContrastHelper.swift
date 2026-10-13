//
//  ContrastHelper.swift
//  ShrikeUITests
//
//  WCAG contrast of dynamic colours resolved in a given appearance, with
//  alpha composited over the background.
//

import AppKit

enum Contrast {
    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private static func channel(_ c: CGFloat) -> CGFloat {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func luminance(r: CGFloat, g: CGFloat, b: CGFloat) -> CGFloat {
        0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    /// Contrast of `fg` (alpha respected) on `bg`, both resolved in `appearance`.
    static func ratio(_ fg: NSColor, on bg: NSColor, in appearance: NSAppearance) -> CGFloat {
        let b = resolve(bg, in: appearance)
        let f = resolve(fg, in: appearance)
        let a = f.alphaComponent
        let r = f.redComponent * a + b.redComponent * (1 - a)
        let g = f.greenComponent * a + b.greenComponent * (1 - a)
        let bl = f.blueComponent * a + b.blueComponent * (1 - a)
        let l1 = luminance(r: r, g: g, b: bl)
        let l2 = luminance(r: b.redComponent, g: b.greenComponent, b: b.blueComponent)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static var dark: NSAppearance { NSAppearance(named: .darkAqua)! }
    static var light: NSAppearance { NSAppearance(named: .aqua)! }
}

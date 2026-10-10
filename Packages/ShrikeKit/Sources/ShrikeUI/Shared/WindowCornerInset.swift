//
//  WindowCornerInset.swift
//  ShrikeUI
//
//  Bars along a window's bottom edge keep their ends out
//  of the rounded corners. macOS 26 windows have much larger corners than
//  macOS 14 / 15: 8 pt put the Browser's status text inside the bottom-left
//  curve and its slider into the bottom-right one.
//

import AppKit

@MainActor
enum WindowCornerInset {

    /// The inset of a bottom bar's first and last control from the window's
    /// side edges: 16 pt on macOS 26, 8 pt before (small corners).
    static var side: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        return 8
    }

    /// Keeps `view`'s leading edge (and / or trailing edge) inside
    /// `container`'s corner-adapted safe area on macOS 26, the system's own
    /// measure of the window's corners. The fixed `side` inset stays as
    /// the floor; this only adds room when the corners need more.
    static func clearCorners(of view: NSView, in container: NSView, leading: Bool, trailing: Bool) {
        guard #available(macOS 26.0, *) else { return }
        let guide = container.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        var constraints: [NSLayoutConstraint] = []
        if leading {
            constraints.append(view.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor))
        }
        if trailing {
            constraints.append(view.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}

//
//  StripHoverLook.swift
//  ShrikeUI
//
//  Spec 24 §2: the hover look of a filmstrip thumbnail, shared by the
//  viewer's strip and the Browser's filmstrip view.
//
//  A pointer over a NON-selected thumbnail shows a 1.5 pt `labelColor`
//  ring at 0.75 alpha and a white 0.10 overlay on the photo. In 80 ms,
//  out 120 ms; Reduce Motion: at once. Increase Contrast: a 2 pt ring at
//  full `labelColor`. The selected ring is a different thing (thick,
//  accent); a selected thumbnail shows no hover.
//

import AppKit
import ShrikeRendering

@MainActor
enum StripHoverLook {

    static let overlayAlpha: CGFloat = 0.10
    static let fadeIn: TimeInterval = 0.08
    static let fadeOut: TimeInterval = 0.12
    static let cornerRadius: CGFloat = 6

    /// 1.5 pt, 2 pt under Increase Contrast.
    static var ringWidth: CGFloat { ShrikeTokens.increaseContrast ? 2 : 1.5 }
    /// 0.75, 1.0 under Increase Contrast.
    static var ringAlpha: CGFloat { ShrikeTokens.increaseContrast ? 1.0 : 0.75 }

    static func ringColor(for appearance: NSAppearance) -> CGColor {
        NSColor.labelColor.withAlphaComponent(ringAlpha).resolvedCGColor(for: appearance)
    }

    static var overlayColor: CGColor {
        NSColor.white.withAlphaComponent(overlayAlpha).cgColor
    }

    /// Sets the model opacity to 1 or 0 and eases there (80 ms in, 120 ms
    /// out; at once under Reduce Motion or when not `animated`).
    static func fade(_ layer: CALayer, visible: Bool, animated: Bool = true) {
        let target: Float = visible ? 1 : 0
        guard layer.opacity != target else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        layer.removeAnimation(forKey: "shrike.stripHover")
        guard animated, !ReduceMotion.isOn else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = target
        fade.duration = visible ? fadeIn : fadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "shrike.stripHover")
    }
}

/// A decoration that never takes a click.
final class StripPassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Removes its observers when it goes away (a main-actor view cannot do
/// that from `deinit`).
final class StripObserverBag: @unchecked Sendable {
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { tokens.append(token) }
    func removeAll() {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}
